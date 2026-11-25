import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'filters.dart';
import 'live.dart';
import 'models.dart';
import 'notifier.dart';
import 'prefs.dart';
import 'sources.dart';

/// Guarda os eventos de cada fonte, o modo ao vivo, as camadas e os filtros.
/// Se uma fonte falha, mantém os dados anteriores dela e avisa na tela.
class EventsController extends ChangeNotifier {
  EventsController() {
    _live = LiveQuakes(onEvent: _onLiveEvent, onStatus: _onLiveStatus);
    _init();
  }

  late final LiveQuakes _live;
  Timer? _timer;
  bool _disposed = false;
  int _ticks = 0;

  final Map<String, List<HazardEvent>> _bySource = {};
  final Map<String, HazardEvent> _liveEvents = {};

  final Set<MapLayer> enabled = {
    MapLayer.quakes,
    MapLayer.disasters,
    MapLayer.alerts,
  };
  final Map<String, String> errors = {};
  bool loading = false;
  bool liveConnected = false;
  DateTime? updatedAt;
  RadarInfo? radar;
  List<SatelliteSource> satellite = const [];
  AlertPrefs prefs = const AlertPrefs();
  MapFilters filters = const MapFilters();

  Future<void> _init() async {
    try {
      prefs = await AlertPrefs.load();
    } catch (_) {}
    try {
      filters = await MapFilters.load();
    } catch (_) {}
    _notify();
    _live.start();
    await refresh();
    if (_disposed) return;
    // USGS a cada 60 s; as demais fontes a cada 5 ciclos (5 min).
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    await _askPermissionOnce();
  }

  Future<void> _askPermissionOnce() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool('asked_notif') ?? false) return;
      await sp.setBool('asked_notif', true);
      await Notifier.requestPermission();
    } catch (_) {}
  }

  /// Eventos das camadas ligadas, já com filtros e ordem aplicados.
  List<HazardEvent> get visible {
    final usgs = _bySource['USGS'] ?? const <HazardEvent>[];
    final all = [
      for (final events in _bySource.values) ...events,
      // Terremotos ao vivo que o USGS ainda não publicou.
      for (final e in _liveEvents.values)
        if (!usgs.any((u) => sameQuake(u, e))) e,
    ].where((e) => enabled.contains(e.type.layer)).toList();
    return filters.apply(all, prefs.home);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onLiveEvent(HazardEvent e) {
    _liveEvents[e.id] = e;
    final cutoff = DateTime.now().toUtc().subtract(const Duration(hours: 6));
    _liveEvents.removeWhere((_, v) => v.time.isBefore(cutoff));
    _notify();
    Notifier.process([e], prefs).catchError((_) => 0);
  }

  void _onLiveStatus(bool connected) {
    if (liveConnected == connected) return;
    liveConnected = connected;
    _notify();
  }

  Future<void> _tick() async {
    _ticks++;
    await refresh(full: _ticks % 5 == 0);
  }

  /// [full] false atualiza só o USGS (ciclo de 60 s, sem piscar a tela).
  Future<void> refresh({bool full = true}) async {
    if (loading) return;
    loading = true;
    if (full) _notify();
    await Future.wait([
      _load('USGS', fetchUsgs),
      if (full) _load('GDACS', fetchGdacs),
      if (full) _load('NWS', fetchNws),
      if (full) _load('Alertas', fetchAlertHub),
      if (full) _loadRadar(),
      if (full) _loadSatellite(),
    ]);
    updatedAt = DateTime.now();
    loading = false;
    _notify();
    _alert();
  }

  Future<void> _load(
    String name,
    Future<List<HazardEvent>> Function() fetch,
  ) async {
    try {
      _bySource[name] = await fetch();
      errors.remove(name);
    } catch (e) {
      errors[name] = e.toString();
    }
  }

  Future<void> _loadRadar() async {
    if (!enabled.contains(MapLayer.radar)) return;
    try {
      radar = await fetchRadar();
      errors.remove('Radar');
    } catch (e) {
      errors['Radar'] = e.toString();
    }
  }

  /// Testa quais camadas de satélite respondem (só quando a camada está ligada).
  Future<void> _loadSatellite() async {
    if (!enabled.contains(MapLayer.satellite) || satellite.isNotEmpty) return;
    try {
      satellite = await probeSatellite();
      errors.remove('Satélite');
    } catch (e) {
      errors['Satélite'] = e.toString();
    }
  }

  void _alert() {
    final all = <HazardEvent>[
      for (final events in _bySource.values) ...events,
      ..._liveEvents.values,
    ];
    Notifier.process(all, prefs).catchError((_) => 0);
  }

  void toggle(MapLayer layer) {
    final nowOn = !enabled.contains(layer);
    if (nowOn) {
      enabled.add(layer);
    } else {
      enabled.remove(layer);
      if (layer == MapLayer.radar) errors.remove('Radar');
      if (layer == MapLayer.satellite) errors.remove('Satélite');
    }
    _notify();
    if (nowOn && layer == MapLayer.radar) {
      _loadRadar().then((_) => _notify());
    }
    if (nowOn && layer == MapLayer.satellite) {
      _loadSatellite().then((_) => _notify());
    }
  }

  void updatePrefs(AlertPrefs p) {
    prefs = p;
    p.save();
    _notify();
  }

  void updateFilters(MapFilters f) {
    filters = f;
    f.save();
    _notify();
  }

  /// Define (ou limpa, com null) "meu local".
  void setHome(LatLng? p) {
    prefs = prefs.copyWith(home: p, clearHome: p == null);
    if (p == null) {
      prefs = prefs.copyWith(radiusKm: 0);
      filters = filters.copyWith(radiusKm: 0, sort: SortBy.severity);
      filters.save();
    }
    prefs.save();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _live.stop();
    super.dispose();
  }
}
