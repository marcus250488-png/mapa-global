import 'package:workmanager/workmanager.dart';

import 'models.dart';
import 'notifier.dart';
import 'prefs.dart';
import 'sources.dart';

/// Ponto de entrada da tarefa em segundo plano (roda em outro isolate).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await runBackgroundCheck();
    } catch (_) {
      // Tenta de novo no próximo ciclo.
    }
    return true;
  });
}

/// Busca só o que gera aviso (respostas menores) e dispara as notificações.
Future<void> runBackgroundCheck() async {
  final prefs = await AlertPrefs.load();
  await Notifier.init();
  final events = <HazardEvent>[];

  Future<void> grab(Future<List<HazardEvent>> Function() fetch) async {
    try {
      events.addAll(await fetch());
    } catch (_) {
      // Fonte fora do ar: as outras seguem.
    }
  }

  await Future.wait([
    if (prefs.quakes) grab(fetchUsgs),
    if (prefs.disasters) grab(() => fetchGdacs(onlyAlerts: true)),
    if (prefs.alerts) grab(() => fetchNws(onlyExtreme: true)),
    if (prefs.alerts) grab(() => fetchAlertHub(limit: 800)),
  ]);
  await Notifier.process(events, prefs);
}

/// Agenda a checagem a cada 15 minutos (o mínimo que o Android permite).
Future<void> startBackgroundChecks() async {
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'monitor-periodic',
      'monitor-check',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {
    // Sem segundo plano: o app continua funcionando aberto.
  }
}
