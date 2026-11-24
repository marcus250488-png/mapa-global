import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live.dart';
import 'models.dart';
import 'notifier.dart';
import 'prefs.dart';
import 'sources.dart';

/// Guarda os eventos de cada fonte, o modo ao vivo e as camadas ligadas.
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
  AlertPrefs prefs = const AlertPrefs();

  Future<void> _init() async {
    try {
      prefs = await AlertPrefs.load();
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

  /// Eventos das camadas ligadas, mais graves primeiro.
  List<HazardEvent> get visible {
    final usgs = _bySource['USGS'] ?? const <HazardEvent>[];
    final list = [
      for (final events in _bySource.values) ...events,
      // Terremotos ao vivo que o USGS ainda não publicou.
      for (final e in _liveEvents.values)
        if (!usgs.any((u) => sameQuake(u, e))) e,
    ].where((e) => enabled.contains(e.type.layer)).toList();
    list.sort((a, b) {
      final s = b.severity.index.compareTo(a.severity.index);
      return s != 0 ? s : b.time.compareTo(a.time);
    });
    return list;
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
      if (full) _loadRadar(),
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
    }
    if (layer == MapLayer.radar && !nowOn) errors.remove('Radar');
    _notify();
    if (layer == MapLayer.radar && nowOn) {
      _loadRadar().then((_) => _notify());
    }
  }

  void updatePrefs(AlertPrefs p) {
    prefs = p;
    p.save();
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
