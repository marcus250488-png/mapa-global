import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'sources.dart';

/// Guarda os eventos de cada fonte e as camadas ligadas.
/// Se uma fonte falha, mantém os dados anteriores dela e avisa na tela.
class EventsController extends ChangeNotifier {
  EventsController() {
    refresh();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => refresh());
  }

  Timer? _timer;
  bool _disposed = false;
  final Map<String, List<HazardEvent>> _bySource = {};

  final Set<MapLayer> enabled = {
    MapLayer.quakes,
    MapLayer.disasters,
    MapLayer.alerts,
  };
  final Map<String, String> errors = {};
  bool loading = false;
  DateTime? updatedAt;
  RadarInfo? radar;

  /// Eventos das camadas ligadas, mais graves primeiro.
  List<HazardEvent> get visible {
    final list = [
      for (final events in _bySource.values)
        for (final e in events)
          if (enabled.contains(e.type.layer)) e,
    ];
    list.sort((a, b) {
      final s = b.severity.index.compareTo(a.severity.index);
      return s != 0 ? s : b.time.compareTo(a.time);
    });
    return list;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    _notify();
    await Future.wait([
      _load('USGS', fetchUsgs),
      _load('GDACS', fetchGdacs),
      _load('NWS', fetchNws),
      _loadRadar(),
    ]);
    updatedAt = DateTime.now();
    loading = false;
    _notify();
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

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
