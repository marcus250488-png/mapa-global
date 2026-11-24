import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'format.dart';
import 'models.dart';

// TROQUE pelo seu e-mail: a API do NWS pede identificação no User-Agent.
const _userAgent = 'MonitorGlobal/0.1 (contato: troque-por-seu-email@exemplo.com)';

Future<dynamic> _getJson(String url, {Map<String, String>? headers}) async {
  final res = await http
      .get(Uri.parse(url), headers: {'User-Agent': _userAgent, ...?headers})
      .timeout(const Duration(seconds: 25));
  if (res.statusCode != 200) {
    throw Exception('HTTP ${res.statusCode}');
  }
  return jsonDecode(utf8.decode(res.bodyBytes));
}

double? _num(dynamic v) => v is num ? v.toDouble() : null;

/// Lê datas ISO; sem fuso na string, assume UTC.
DateTime _parseUtc(dynamic v) {
  final s = v?.toString() ?? '';
  if (s.isEmpty) return DateTime.now().toUtc();
  final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(s);
  return (DateTime.tryParse(hasZone ? s : '${s}Z') ?? DateTime.now()).toUtc();
}

// ---------------------------------------------------------------------------
// USGS: terremotos M4.5+ nas últimas 24 h, no mundo todo.
// ---------------------------------------------------------------------------

Future<List<HazardEvent>> fetchUsgs() async {
  final json = await _getJson(
    'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/4.5_day.geojson',
  );
  final out = <HazardEvent>[];
  for (final f in (json['features'] as List? ?? const [])) {
    try {
      final p = (f['properties'] as Map?) ?? const {};
      final c = (f['geometry']?['coordinates'] as List?) ?? const [];
      final mag = _num(p['mag']);
      if (mag == null || c.length < 2 || p['time'] == null) continue;
      final depth = c.length > 2 ? _num(c[2]) : null;
      out.add(HazardEvent(
        id: 'usgs:${f['id']}',
        type: HazardType.earthquake,
        severity: severityForMagnitude(mag),
        magnitude: mag,
        title: 'M ${num1(mag)}',
        place: p['place']?.toString(),
        detail: [
          if (depth != null) 'Profundidade: ${depth.round()} km.',
          if (p['tsunami'] == 1)
            'Evento em região oceânica: consulte os avisos oficiais de tsunami.',
        ].join(' '),
        point: LatLng(_num(c[1])!, _num(c[0])!),
        time: DateTime.fromMillisecondsSinceEpoch(
          (p['time'] as num).toInt(),
          isUtc: true,
        ),
        source: 'USGS',
        url: p['url']?.toString(),
      ));
    } catch (_) {
      continue;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// GDACS: ciclones, enchentes, vulcões, secas e incêndios (últimos 7 dias).
// Terremotos ficam de fora porque o USGS já cobre.
// ---------------------------------------------------------------------------

Future<List<HazardEvent>> fetchGdacs({bool onlyAlerts = false}) async {
  String d(DateTime t) => '${t.year}-${two(t.month)}-${two(t.day)}';
  final now = DateTime.now().toUtc();
  // Em segundo plano só interessam os alertas laranja e vermelho (resposta bem menor).
  final levels = onlyAlerts ? 'Orange;Red' : 'Green;Orange;Red';
  final days = onlyAlerts ? 3 : 7;
  final url = 'https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH'
      '?eventlist=TC;FL;VO;DR;WF&alertlevel=$levels'
      '&fromdate=${d(now.subtract(Duration(days: days)))}'
      '&todate=${d(now.add(const Duration(days: 1)))}';
  final json = await _getJson(url);

  // A resposta traz vários itens por evento (ponto, polígonos, trilha).
  // Fica um por evento, preferindo o ponto central.
  final best = <String, (HazardEvent, bool)>{};
  for (final f in (json['features'] as List? ?? const [])) {
    try {
      final g = f['geometry'];
      if (g == null || g['type'] != 'Point') continue;
      final p = (f['properties'] as Map?) ?? const {};
      final type = switch (p['eventtype']) {
        'TC' => HazardType.cyclone,
        'FL' => HazardType.flood,
        'VO' => HazardType.volcano,
        'WF' => HazardType.wildfire,
        'DR' => HazardType.drought,
        _ => null,
      };
      if (type == null) continue;
      final cls = (p['Class'] ?? p['class'])?.toString().toLowerCase();
      final isCentroid = cls == null || cls.contains('centroid');
      final c = g['coordinates'] as List;
      final name = (p['name'] ?? p['eventname'] ?? '').toString().trim();
      final sevText = (p['severitydata'] as Map?)?['severitytext']?.toString();
      final ev = HazardEvent(
        id: 'gdacs:${p['eventtype']}:${p['eventid']}',
        type: type,
        severity: switch (p['alertlevel']?.toString().toLowerCase()) {
          'red' => Severity.extreme,
          'orange' => Severity.high,
          _ => Severity.low,
        },
        title: name.isEmpty ? type.label : name,
        place: p['country']?.toString(),
        detail: sevText ?? p['description']?.toString(),
        point: LatLng(_num(c[1])!, _num(c[0])!),
        time: _parseUtc(p['datemodified'] ?? p['fromdate']),
        source: 'GDACS',
        url: (p['url'] as Map?)?['report']?.toString(),
      );
      final old = best[ev.id];
      if (old == null ||
          (isCentroid != old.$2 ? isCentroid : ev.time.isAfter(old.$1.time))) {
        best[ev.id] = (ev, isCentroid);
      }
    } catch (_) {
      continue;
    }
  }
  return [for (final e in best.values) e.$1];
}

// ---------------------------------------------------------------------------
// NWS (EUA): avisos com polígono (tornado, tempestade severa etc.).
// Avisos por zona, sem polígono, ainda não entram.
// ---------------------------------------------------------------------------

const _nwsEvents = {
  'Tornado Warning': 'Aviso de tornado',
  'Severe Thunderstorm Warning': 'Aviso de tempestade severa',
  'Flash Flood Warning': 'Aviso de enchente repentina',
  'Extreme Wind Warning': 'Aviso de ventos extremos',
  'Special Marine Warning': 'Aviso marítimo especial',
};

List<LatLng> _firstRing(dynamic g) {
  if (g is! Map) return const [];
  final coords = g['coordinates'];
  dynamic ring;
  if (g['type'] == 'Polygon') {
    ring = (coords as List).first;
  } else if (g['type'] == 'MultiPolygon') {
    ring = ((coords as List).first as List).first;
  }
  if (ring is! List) return const [];
  return [
    for (final pt in ring) LatLng(_num(pt[1])!, _num(pt[0])!),
  ];
}

LatLng _centroid(List<LatLng> pts) {
  var lat = 0.0;
  var lng = 0.0;
  for (final p in pts) {
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / pts.length, lng / pts.length);
}

Future<List<HazardEvent>> fetchNws({bool onlyExtreme = false}) async {
  final severity = onlyExtreme ? '&severity=Extreme' : '';
  final url = 'https://api.weather.gov/alerts/active?status=actual&message_type=alert'
      '$severity'
      '&event=${Uri.encodeComponent(_nwsEvents.keys.join(','))}';
  final json = await _getJson(url, headers: {'Accept': 'application/geo+json'});
  final out = <HazardEvent>[];
  for (final f in (json['features'] as List? ?? const [])) {
    try {
      final ring = _firstRing(f['geometry']);
      if (ring.length < 3) continue;
      final p = (f['properties'] as Map?) ?? const {};
      final params = (p['parameters'] as Map?) ?? const {};
      String? param(String k) {
        final v = params[k];
        return v is List && v.isNotEmpty ? v.first.toString() : null;
      }

      final event = p['event']?.toString() ?? '';
      final extras = <String>[
        if (param('tornadoDetection') != null)
          'Tornado: ${param('tornadoDetection')}.',
        if (param('maxWindGust') != null)
          'Rajada máxima: ${param('maxWindGust')}.',
        if (param('maxHailSize') != null)
          'Granizo máximo: ${param('maxHailSize')} pol.',
      ];
      final area = p['areaDesc']?.toString() ?? '';
      out.add(HazardEvent(
        id: 'nws:${p['id'] ?? f['id']}',
        type: HazardType.storm,
        severity: switch (p['severity']) {
          'Extreme' => Severity.extreme,
          'Severe' => Severity.high,
          'Moderate' => Severity.moderate,
          _ => Severity.low,
        },
        title: _nwsEvents[event] ?? event,
        place: area.length > 140 ? '${area.substring(0, 140)}…' : area,
        detail: [p['headline']?.toString() ?? '', ...extras]
            .where((s) => s.isNotEmpty)
            .join('\n'),
        point: _centroid(ring),
        area: ring,
        time: _parseUtc(p['onset'] ?? p['effective'] ?? p['sent']),
        source: 'NWS (EUA)',
        url: 'https://www.weather.gov/',
      ));
    } catch (_) {
      continue;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Open-Meteo: vento, rajadas, CAPE e chuva num ponto (previsão de modelo).
// ---------------------------------------------------------------------------

class PointWeather {
  const PointWeather({
    this.wind,
    this.gust,
    this.direction,
    required this.gustPeak,
    required this.capePeak,
    required this.rain,
  });

  final double? wind;
  final double? gust;
  final double? direction;
  final double gustPeak;
  final double capePeak;
  final double rain;
}

Future<PointWeather> fetchPointWeather(LatLng p) async {
  final lng = ((p.longitude + 180) % 360) - 180;
  final url = 'https://api.open-meteo.com/v1/forecast'
      '?latitude=${p.latitude.toStringAsFixed(3)}&longitude=${lng.toStringAsFixed(3)}'
      '&current=wind_speed_10m,wind_gusts_10m,wind_direction_10m'
      '&hourly=cape,wind_gusts_10m,precipitation'
      '&forecast_days=2&timezone=UTC';
  final j = await _getJson(url);
  final cur = (j['current'] as Map?) ?? const {};
  final h = (j['hourly'] as Map?) ?? const {};
  final times =
      ((h['time'] as List?) ?? const []).map((e) => e.toString()).toList();
  final cape = (h['cape'] as List?) ?? const [];
  final gust = (h['wind_gusts_10m'] as List?) ?? const [];
  final prec = (h['precipitation'] as List?) ?? const [];

  // Janela de 24 h a partir da hora atual (UTC).
  final now = DateTime.now().toUtc();
  final hourStart = DateTime.utc(now.year, now.month, now.day, now.hour);
  var start =
      times.indexWhere((t) => !DateTime.parse('${t}Z').isBefore(hourStart));
  if (start < 0) start = 0;
  final end = math.min(start + 24, times.length);

  double at(List l, int i) => i < l.length ? (_num(l[i]) ?? 0) : 0;
  var capeMax = 0.0;
  var gustMax = 0.0;
  var rain = 0.0;
  for (var i = start; i < end; i++) {
    capeMax = math.max(capeMax, at(cape, i));
    gustMax = math.max(gustMax, at(gust, i));
    rain += at(prec, i);
  }
  return PointWeather(
    wind: _num(cur['wind_speed_10m']),
    gust: _num(cur['wind_gusts_10m']),
    direction: _num(cur['wind_direction_10m']),
    gustPeak: gustMax,
    capePeak: capeMax,
    rain: rain,
  );
}

// ---------------------------------------------------------------------------
// RainViewer: último quadro de radar (API gratuita só para uso pessoal).
// ---------------------------------------------------------------------------

class RadarInfo {
  const RadarInfo({required this.tileUrl, required this.time});

  final String tileUrl;
  final DateTime time;
}

Future<RadarInfo> fetchRadar() async {
  final j = await _getJson('https://api.rainviewer.com/public/weather-maps.json');
  final host = j['host'].toString();
  final last = (j['radar']['past'] as List).last as Map;
  return RadarInfo(
    tileUrl: '$host${last['path']}/256/{z}/{x}/{y}/2/1_1.png',
    time: DateTime.fromMillisecondsSinceEpoch(
      (last['time'] as num).toInt() * 1000,
      isUtc: true,
    ),
  );
}
