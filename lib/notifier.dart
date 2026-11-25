import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'format.dart';
import 'models.dart';
import 'prefs.dart';

/// Avisos locais, sem servidor. Usado pelo app aberto e pela checagem em segundo plano.
class Notifier {
  Notifier._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _maxPerRun = 5;
  static const _maxAge = Duration(hours: 12);

  static const _quakes = AndroidNotificationDetails(
    'quakes',
    'Terremotos',
    channelDescription: 'Avisos de terremotos',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _disasters = AndroidNotificationDetails(
    'disasters',
    'Ciclones e desastres',
    channelDescription: 'Ciclones, enchentes, vulcões e outros alertas do GDACS',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _alerts = AndroidNotificationDetails(
    'alerts',
    'Avisos de tempestade',
    channelDescription: 'Avisos extremos de tornado e vento (EUA)',
    importance: Importance.max,
    priority: Priority.high,
  );

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_notify'),
      ),
    );
    _ready = true;
  }

  /// Pede a permissão de notificações (Android 13 ou mais novo).
  static Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.requestNotificationsPermission() ?? false;
  }

  static Future<void> sendTest() async {
    await init();
    await _show(
      9000,
      'Aviso de teste',
      'Se você viu isto, as notificações estão funcionando.',
      _alerts,
    );
  }

  static Future<void> _show(
    int id,
    String title,
    String body,
    AndroidNotificationDetails details,
  ) {
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(android: details),
    );
  }

  static bool _wanted(HazardEvent e, AlertPrefs p) {
    final home = p.home;
    final radius = (home != null && p.radiusKm > 0) ? p.radiusKm : 0;
    bool near() => radius > 0 && distanceToEvent(e, home!) <= radius;
    switch (e.type) {
      case HazardType.earthquake:
        if (!p.quakes || (e.magnitude ?? 0) < p.minMag) return false;
      case HazardType.storm:
      case HazardType.alert:
        if (!p.alerts) return false;
        // Com raio definido, vale qualquer aviso grave ou extremo perto de mim.
        if (radius > 0) return near() && e.severity.index >= Severity.high.index;
        return e.severity == Severity.extreme;
      default:
        if (!p.disasters || e.severity.index < Severity.high.index) return false;
    }
    // Terremotos e desastres: com raio definido, só perto de mim, exceto os extremos.
    if (radius == 0 || e.severity == Severity.extreme) return true;
    return near();
  }

  static String _sig(HazardEvent e) =>
      '${e.time.millisecondsSinceEpoch}|${e.point.latitude.toStringAsFixed(2)}|${e.point.longitude.toStringAsFixed(2)}';

  /// O mesmo terremoto pode vir do USGS e do EMSC: só avisa uma vez.
  static bool _knownQuake(HazardEvent e, List<String> sigs) {
    for (final s in sigs) {
      final parts = s.split('|');
      if (parts.length != 3) continue;
      final t = int.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      final lng = double.tryParse(parts[2]);
      if (t == null || lat == null || lng == null) continue;
      final dt = (t - e.time.millisecondsSinceEpoch).abs();
      if (dt <= 180000 && distanceKm(LatLng(lat, lng), e.point) <= 250) {
        return true;
      }
    }
    return false;
  }

  static (String, String, AndroidNotificationDetails) _compose(HazardEvent e) {
    final place = e.place;
    final where = (place == null || place.isEmpty) ? 'Local não informado' : place;
    switch (e.type) {
      case HazardType.earthquake:
        return (
          'Terremoto M ${num1(e.magnitude ?? 0)}',
          '$where. ${agoLong(e.time)}.',
          _quakes,
        );
      case HazardType.storm:
      case HazardType.alert:
        return (e.title, where, _alerts);
      default:
        final level = e.severity == Severity.extreme ? 'vermelho' : 'laranja';
        return (
          '${e.type.label}: ${e.title} (alerta $level)',
          '$where. ${e.detail ?? ''}'.trim(),
          _disasters,
        );
    }
  }

  /// Decide quais eventos viram aviso e envia. Devolve quantos foram enviados.
  /// Na primeira vez só registra o que já existe, sem avisar (evita enxurrada).
  static Future<int> process(List<HazardEvent> events, AlertPrefs prefs) async {
    await init();
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    final seen = <String>[...?sp.getStringList('seen')];
    final sigs = <String>[...?sp.getStringList('quake_sigs')];
    final seeded = sp.getBool('seeded') ?? false;
    final now = DateTime.now().toUtc();

    final pending = <HazardEvent>[];
    for (final e in events) {
      if (seen.contains(e.id)) continue;
      seen.add(e.id);
      final isQuake = e.type == HazardType.earthquake;
      if (isQuake && _knownQuake(e, sigs)) continue;
      if (!seeded || now.difference(e.time) > _maxAge) {
        if (isQuake) sigs.add(_sig(e));
        continue;
      }
      if (!_wanted(e, prefs)) continue;
      if (isQuake) sigs.add(_sig(e));
      pending.add(e);
    }

    pending.sort((a, b) => b.severity.index.compareTo(a.severity.index));
    var sent = 0;
    for (final e in pending.take(_maxPerRun)) {
      final (title, body, details) = _compose(e);
      try {
        await _show(e.id.hashCode & 0x7fffffff, title, body, details);
        sent++;
      } catch (_) {
        // Sem permissão ou falha do sistema: segue para o próximo.
      }
    }
    if (pending.length > _maxPerRun) {
      try {
        await _show(
          1,
          'Mais ${pending.length - _maxPerRun} eventos',
          'Abra o app para ver todos.',
          _alerts,
        );
      } catch (_) {}
    }

    if (events.isNotEmpty) await sp.setBool('seeded', true);
    await sp.setStringList(
      'seen',
      seen.length > 400 ? seen.sublist(seen.length - 400) : seen,
    );
    await sp.setStringList(
      'quake_sigs',
      sigs.length > 60 ? sigs.sublist(sigs.length - 60) : sigs,
    );
    return sent;
  }
}
