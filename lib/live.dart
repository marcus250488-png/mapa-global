import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'format.dart';
import 'models.dart';

/// Terremotos quase em tempo real pelo EMSC (WebSocket do SeismicPortal).
/// Guarda só M4.5 ou mais, o mesmo corte do feed do USGS.
class LiveQuakes {
  LiveQuakes({required this.onEvent, required this.onStatus});

  final void Function(HazardEvent event) onEvent;
  final void Function(bool connected) onStatus;

  static const _url = 'wss://www.seismicportal.eu/standing_order/websocket';

  WebSocket? _ws;
  Timer? _retry;
  bool _stopped = true;
  int _attempts = 0;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    _ws?.close();
    _ws = null;
  }

  Future<void> _connect() async {
    if (_stopped) return;
    try {
      final ws =
          await WebSocket.connect(_url).timeout(const Duration(seconds: 15));
      if (_stopped) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 15);
      _ws = ws;
      _attempts = 0;
      onStatus(true);
      ws.listen(
        _onMessage,
        onDone: _closed,
        onError: (Object _) => _closed(),
        cancelOnError: true,
      );
    } catch (_) {
      _closed();
    }
  }

  /// Conexão caiu: tenta de novo com espera crescente (5 s até 60 s).
  void _closed() {
    _ws = null;
    onStatus(false);
    if (_stopped || _retry != null) return;
    _attempts++;
    _retry = Timer(Duration(seconds: math.min(60, 5 * _attempts)), () {
      _retry = null;
      _connect();
    });
  }

  void _onMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String);
      if (msg['action'] == 'delete') return;
      final f = msg['data'];
      final p = (f['properties'] as Map?) ?? const {};
      final mag = (p['mag'] as num?)?.toDouble();
      if (mag == null || mag < 4.5) return;
      final c = (f['geometry']?['coordinates'] as List?) ?? const [];
      final lat = (p['lat'] as num?)?.toDouble() ??
          (c.length > 1 ? (c[1] as num).toDouble() : null);
      final lon = (p['lon'] as num?)?.toDouble() ??
          (c.isNotEmpty ? (c[0] as num).toDouble() : null);
      if (lat == null || lon == null) return;
      final unid = (p['unid'] ?? f['id'])?.toString();
      if (unid == null) return;
      final depth = (p['depth'] as num?)?.toDouble();
      final when = DateTime.tryParse('${p['time']}') ?? DateTime.now();
      onEvent(HazardEvent(
        id: 'emsc:$unid',
        type: HazardType.earthquake,
        severity: severityForMagnitude(mag),
        magnitude: mag,
        title: 'M ${num1(mag)}',
        place: _titleCase('${p['flynn_region'] ?? ''}'),
        detail: [
          if (depth != null) 'Profundidade: ${depth.abs().round()} km.',
          'Dado preliminar do EMSC, em tempo real.',
        ].join(' '),
        point: LatLng(lat, lon),
        time: when.toUtc(),
        source: 'EMSC',
        url: 'https://www.seismicportal.eu/eventdetails.html?unid=$unid',
      ));
    } catch (_) {
      // Mensagem fora do formato esperado: ignora.
    }
  }

  static String _titleCase(String s) => s
      .toLowerCase()
      .split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
