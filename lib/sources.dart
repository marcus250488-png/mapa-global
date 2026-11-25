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
        areas: [ring],
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

// ---------------------------------------------------------------------------
// Alert Hub (OMM/WMO): alertas oficiais CAP de dezenas de países, com polígonos.
// Os EUA ficam de fora porque já vêm direto do NWS.
// ---------------------------------------------------------------------------

const _hubHost = 'services9.arcgis.com';
const _hubPath =
    '/RHVPKKiFTONKtxq3/ArcGIS/rest/services/CAP_Alerts_Feed/FeatureServer/0/query';
const _hubFields = 'identifier,event,severity,sent,effective,onset,expires,language,'
    'headline,areaDesc,senderName,orgName,countryCode,web,hubLink,status,msgType';

Future<dynamic> _hubQuery(
  String where,
  String fields,
  int limit, {
  bool order = true,
}) {
  final uri = Uri.https(_hubHost, _hubPath, {
    'where': where,
    'outFields': fields,
    'returnGeometry': 'true',
    'outSR': '4326',
    'maxAllowableOffset': '0.05',
    'geometryPrecision': '2',
    if (order) 'orderByFields': 'sent DESC',
    'resultRecordCount': '$limit',
    'f': 'geojson',
  });
  return _getJson(uri.toString());
}

/// Inglês primeiro, depois português e espanhol; o resto por último.
int _langRank(dynamic l) {
  final s = '$l'.toLowerCase();
  if (s.startsWith('en')) return 0;
  if (s.startsWith('pt')) return 1;
  if (s.startsWith('es')) return 2;
  return 5;
}

DateTime? _anyDate(dynamic v) {
  if (v == null) return null;
  if (v is num) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
  }
  final s = v.toString();
  final n = num.tryParse(s);
  if (n != null) {
    return DateTime.fromMillisecondsSinceEpoch(n.toInt(), isUtc: true);
  }
  return DateTime.tryParse(s)?.toUtc();
}

/// Contornos externos de um Polygon ou MultiPolygon (GeoJSON).
List<List<LatLng>> _ringsOf(dynamic g) {
  if (g is! Map) return const [];
  final c = g['coordinates'];
  List<LatLng> toRing(dynamic ring) => [
        for (final pt in (ring as List)) LatLng(_num(pt[1])!, _num(pt[0])!),
      ];
  if (g['type'] == 'Polygon') return [toRing((c as List).first)];
  if (g['type'] == 'MultiPolygon') {
    return [for (final poly in (c as List)) toRing((poly as List).first)];
  }
  return const [];
}

LatLng _centroidOf(List<List<LatLng>> rings) {
  final biggest = rings.reduce((a, b) => a.length >= b.length ? a : b);
  return _centroid(biggest);
}

class _HubGroup {
  _HubGroup(this.rank, this.props);

  final int rank;
  final Map props;
  final rings = <List<LatLng>>[];
  final areas = <String>{};
}

/// Alertas graves e extremos ainda válidos. O servidor é consultado de forma
/// cada vez mais simples se uma consulta falhar.
Future<List<HazardEvent>> fetchAlertHub({int limit = 1500}) async {
  final now = DateTime.now().toUtc();
  final stamp =
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  const base =
      "status='Actual' AND msgType<>'Cancel' AND severity IN ('Extreme','Severe')";
  final attempts = <(String, String, int, bool)>[
    ("$base AND expires > TIMESTAMP '$stamp'", _hubFields, limit, true),
    (base, _hubFields, math.min(limit, 800), true),
    (base, '*', math.min(limit, 400), true),
    ('1=1', '*', 300, false),
  ];
  dynamic json;
  Object? lastError;
  for (final (where, fields, n, order) in attempts) {
    try {
      final j = await _hubQuery(where, fields, n, order: order);
      if (j is Map && j['error'] != null) {
        lastError = '${j['error']['message'] ?? 'erro do servidor'}';
        continue;
      }
      json = j;
      break;
    } catch (e) {
      lastError = e;
    }
  }
  if (json == null) throw Exception('Alert Hub: $lastError');

  // Um alerta traz um registro por idioma e por área: agrupa por identificador,
  // fica com o melhor idioma e junta todos os contornos.
  final groups = <String, _HubGroup>{};
  for (final f in (json['features'] as List? ?? const [])) {
    try {
      final p = (f['properties'] as Map?) ?? const {};
      final country = '${p['countryCode'] ?? ''}'.toLowerCase();
      final org = '${p['orgName'] ?? p['senderName'] ?? ''}';
      if (country == 'us' || org.contains('National Weather Service')) continue;
      final sev = '${p['severity']}';
      if (sev != 'Extreme' && sev != 'Severe') continue;
      final status = p['status']?.toString();
      if (status != null && status != 'Actual') continue;
      if (p['msgType']?.toString() == 'Cancel') continue;
      final id = (p['identifier'] ?? p['alertId'])?.toString();
      final rings = _ringsOf(f['geometry']);
      if (id == null || rings.isEmpty) continue;
      final rank = _langRank(p['language']);
      final area = '${p['areaDesc'] ?? ''}'.trim();
      final g = groups[id];
      if (g == null || rank < g.rank) {
        groups[id] = _HubGroup(rank, p)
          ..rings.addAll(rings)
          ..areas.add(area);
      } else if (rank == g.rank) {
        g.rings.addAll(rings);
        g.areas.add(area);
      }
    } catch (_) {
      continue;
    }
  }

  final out = <HazardEvent>[];
  for (final entry in groups.entries) {
    final g = entry.value;
    final p = g.props;
    final expires = _anyDate(p['expires']);
    if (expires != null && expires.isBefore(now)) continue;
    final title = '${p['event'] ?? p['headline'] ?? ''}'.trim();
    final headline = '${p['headline'] ?? ''}'.trim();
    final org = '${p['orgName'] ?? p['senderName'] ?? ''}'.trim();
    final web = '${p['web'] ?? ''}';
    final hub = '${p['hubLink'] ?? ''}';
    final areaText = g.areas.where((a) => a.isNotEmpty).join('; ');
    out.add(HazardEvent(
      id: 'hub:${entry.key}',
      type: HazardType.alert,
      severity: '${p['severity']}' == 'Extreme' ? Severity.extreme : Severity.high,
      title: title.isEmpty ? 'Alerta oficial' : title,
      place: areaText.length > 140 ? '${areaText.substring(0, 140)}…' : areaText,
      detail: [
        headline,
        if (org.isNotEmpty) 'Emitido por $org.',
      ].where((s) => s.isNotEmpty).join('\n'),
      point: _centroidOf(g.rings),
      areas: g.rings,
      time: _anyDate(p['onset']) ??
          _anyDate(p['effective']) ??
          _anyDate(p['sent']) ??
          now,
      source: org.isEmpty ? 'Alert Hub (OMM)' : org,
      url: web.startsWith('http')
          ? web
          : (hub.startsWith('http') ? hub : null),
    ));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Satélite (NASA GIBS, via WMS): só entram as camadas que respondem com imagem.
// ---------------------------------------------------------------------------

class SatelliteSource {
  const SatelliteSource(this.layer, this.baseUrl);

  final String layer;

  /// URL base do WMS, terminada em "?".
  final String baseUrl;
}

const _satLayers = [
  'GOES-East_ABI_Band13_Clean_Infrared_v0_NRT_ZENJPEG',
  'GOES-West_ABI_Band13_Clean_Infrared_v0_NRT_ZENJPEG',
  'Himawari_AHI_Band13_Clean_Infrared_v0_NRT_ZENJPEG',
];
const _satEndpoints = ['nrt', 'best', 'all'];

/// Faz um pedido de teste para cada camada e endereço. Quem não responde com
/// imagem fica de fora, em vez de deixar o mapa em branco.
Future<List<SatelliteSource>> probeSatellite() async {
  final found = <SatelliteSource>[];
  for (final layer in _satLayers) {
    for (final ep in _satEndpoints) {
      final base = 'https://gibs.earthdata.nasa.gov/wms/epsg3857/$ep/wms.cgi?';
      final url = '${base}SERVICE=WMS&REQUEST=GetMap&VERSION=1.1.1&LAYERS=$layer'
          '&STYLES=&FORMAT=image/png&TRANSPARENT=TRUE&SRS=EPSG:3857'
          '&WIDTH=256&HEIGHT=256&BBOX=-10018754,-3503549,-5009377,1689200';
      try {
        final res = await http
            .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 20));
        final type = res.headers['content-type'] ?? '';
        if (res.statusCode == 200 && type.startsWith('image/')) {
          found.add(SatelliteSource(layer, base));
          break;
        }
      } catch (_) {
        // Tenta o próximo endereço.
      }
    }
  }
  if (found.isEmpty) throw Exception('nenhuma camada respondeu');
  return found;
}
