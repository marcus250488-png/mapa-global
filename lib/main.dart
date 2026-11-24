import 'package:flutter/material.dart';

import 'background.dart';
import 'map_screen.dart';
import 'models.dart';
import 'notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Notifier.init();
  } catch (_) {
    // Sem notificações: o app continua funcionando.
  }
  runApp(const MonitorApp());
  startBackgroundChecks();
}

class MonitorApp extends StatelessWidget {
  const MonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitor Global',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Palette.ink),
        scaffoldBackgroundColor: Palette.paper,
      ),
      home: const MapScreen(),
    );
  }
}
