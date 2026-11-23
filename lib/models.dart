import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Cores da interface. O mapa-base é cinza: a cor fica só para os eventos.
abstract final class Palette {
  static const ink = Color(0xFF1B2B3A);
  static const paper = Color(0xFFF2F5F8);
  static const muted = Color(0xFF5B6B7A);
  static const line = Color(0xFFD5DCE3);
}

/// Camadas que a pessoa liga e desliga no mapa.
enum MapLayer { quakes, disasters, alerts, radar }

extension MapLayerInfo on MapLayer {
  String get label => switch (this) {
        MapLayer.quakes => 'Terremotos',
        MapLayer.disasters => 'Ciclones e desastres',
        MapLayer.alerts => 'Alertas EUA',
        MapLayer.radar => 'Radar',
      };

  Color get color => switch (this) {
        MapLayer.quakes => HazardType.earthquake.color,
        MapLayer.disasters => HazardType.cyclone.color,
        MapLayer.alerts => HazardType.storm.color,
        MapLayer.radar => const Color(0xFF2B8A3E),
      };
}

/// Tipo do fenômeno. A cor identifica o tipo; o tamanho do marcador, a gravidade.
enum HazardType { earthquake, cyclone, storm, flood, volcano, wildfire, drought }

extension HazardTypeInfo on HazardType {
  String get label => switch (this) {
        HazardType.earthquake => 'Terremoto',
        HazardType.cyclone => 'Ciclone',
        HazardType.storm => 'Tempestade severa',
        HazardType.flood => 'Enchente',
        HazardType.volcano => 'Vulcão',
        HazardType.wildfire => 'Incêndio',
        HazardType.drought => 'Seca',
      };

  Color get color => switch (this) {
        HazardType.earthquake => const Color(0xFFD9480F),
        HazardType.cyclone => const Color(0xFF1C7ED6),
        HazardType.storm => const Color(0xFFC2255C),
        HazardType.flood => const Color(0xFF0B7285),
        HazardType.volcano => const Color(0xFF7048E8),
        HazardType.wildfire => const Color(0xFFE67700),
        HazardType.drought => const Color(0xFF8D6E3F),
      };

  IconData get icon => switch (this) {
        HazardType.earthquake => Icons.vibration,
        HazardType.cyclone => Icons.air,
        HazardType.storm => Icons.bolt,
        HazardType.flood => Icons.waves,
        HazardType.volcano => Icons.terrain,
        HazardType.wildfire => Icons.local_fire_department,
        HazardType.drought => Icons.wb_sunny,
      };

  MapLayer get layer => switch (this) {
        HazardType.earthquake => MapLayer.quakes,
        HazardType.storm => MapLayer.alerts,
        _ => MapLayer.disasters,
      };
}

enum Severity { low, moderate, high, extreme }

extension SeverityInfo on Severity {
  String get label => switch (this) {
        Severity.low => 'Baixa',
        Severity.moderate => 'Moderada',
        Severity.high => 'Alta',
        Severity.extreme => 'Extrema',
      };

  double get markerSize => switch (this) {
        Severity.low => 22.0,
        Severity.moderate => 28.0,
        Severity.high => 36.0,
        Severity.extreme => 44.0,
      };
}

/// Formato comum a todas as fontes.
class HazardEvent {
  const HazardEvent({
    required this.id,
    required this.type,
    required this.severity,
    required this.title,
    required this.point,
    required this.time,
    required this.source,
    this.place,
    this.detail,
    this.url,
    this.area = const [],
  });

  final String id;
  final HazardType type;
  final Severity severity;
  final String title;
  final String? place;
  final String? detail;
  final LatLng point;

  /// Contorno da área do aviso (vazio quando a fonte só dá um ponto).
  final List<LatLng> area;
  final DateTime time;
  final String source;
  final String? url;
}
