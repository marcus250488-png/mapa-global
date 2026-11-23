import 'package:flutter/material.dart';

import 'map_screen.dart';
import 'models.dart';

void main() => runApp(const MonitorApp());

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
