import 'dart:math' as math;

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
enum MapLayer { quakes, disasters, alerts, radar, satellite }

extension MapLayerInfo on MapLayer {
  String get label => switch (this) {
        MapLayer.quakes => 'Terremotos',
        MapLayer.disasters => 'Ciclones e desastres',
        MapLayer.alerts => 'Alertas oficiais',
        MapLayer.radar => 'Radar',
        MapLayer.satellite => 'Satélite',
      };

  Color get color => switch (this) {
        MapLayer.quakes => HazardType.earthquake.color,
        MapLayer.disasters => HazardType.cyclone.color,
        MapLayer.alerts => HazardType.storm.color,
        MapLayer.radar => const Color(0xFF2B8A3E),
        MapLayer.satellite => const Color(0xFF5C6BC0),
      };
}

/// Tipo do fenômeno. A cor identifica o tipo; o tamanho do marcador, a gravidade.
enum HazardType {
  earthquake,
  cyclone,
  storm,
  alert,
  flood,
  volcano,
  wildfire,
  drought,
}

extension HazardTypeInfo on HazardType {
  String get label => switch (this) {
        HazardType.earthquake => 'Terremoto',
        HazardType.cyclone => 'Ciclone',
        HazardType.storm => 'Tempestade severa',
        HazardType.alert => 'Alerta oficial',
        HazardType.flood => 'Enchente',
        HazardType.volcano => 'Vulcão',
        HazardType.wildfire => 'Incêndio',
        HazardType.drought => 'Seca',
      };

  Color get color => switch (this) {
        HazardType.earthquake => const Color(0xFFD9480F),
        HazardType.cyclone => const Color(0xFF1C7ED6),
        HazardType.storm => const Color(0xFFC2255C),
        HazardType.alert => const Color(0xFFD6336C),
        HazardType.flood => const Color(0xFF0B7285),
        HazardType.volcano => const Color(0xFF7048E8),
        HazardType.wildfire => const Color(0xFFE67700),
        HazardType.drought => const Color(0xFF8D6E3F),
      };

  IconData get icon => switch (this) {
        HazardType.earthquake => Icons.vibration,
        HazardType.cyclone => Icons.air,
        HazardType.storm => Icons.bolt,
        HazardType.alert => Icons.warning_amber,
        HazardType.flood => Icons.waves,
        HazardType.volcano => Icons.terrain,
        HazardType.wildfire => Icons.local_fire_department,
        HazardType.drought => Icons.wb_sunny,
      };

  MapLayer get layer => switch (this) {
        HazardType.earthquake => MapLayer.quakes,
        HazardType.storm || HazardType.alert => MapLayer.alerts,
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
    this.areas = const [],
    this.magnitude,
  });

  final String id;
  final HazardType type;
  final Severity severity;
  final String title;
  final String? place;
  final String? detail;
  final LatLng point;

  /// Contornos da área do aviso (vazio quando a fonte só dá um ponto).
  final List<List<LatLng>> areas;
  final DateTime time;
  final String source;
  final String? url;

  /// Magnitude (só terremotos).
  final double? magnitude;
}

/// Gravidade de um terremoto a partir da magnitude.
Severity severityForMagnitude(double m) {
  if (m >= 7) return Severity.extreme;
  if (m >= 6) return Severity.high;
  if (m >= 5) return Severity.moderate;
  return Severity.low;
}

/// Distância em km entre dois pontos (haversine).
double distanceKm(LatLng a, LatLng b) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLon = rad(b.longitude - a.longitude);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final h = s1 * s1 +
      math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * s2 * s2;
  return 2 * 6371.0 * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Dois registros de terremoto de fontes diferentes que são o mesmo evento.
bool sameQuake(HazardEvent a, HazardEvent b) =>
    a.type == HazardType.earthquake &&
    b.type == HazardType.earthquake &&
    a.time.difference(b.time).inSeconds.abs() <= 180 &&
    distanceKm(a.point, b.point) <= 250;

/// O ponto está dentro do polígono?
bool pointInRing(LatLng p, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i];
    final b = ring[j];
    if ((a.latitude > p.latitude) != (b.latitude > p.latitude) &&
        p.longitude <
            (b.longitude - a.longitude) *
                    (p.latitude - a.latitude) /
                    (b.latitude - a.latitude) +
                a.longitude) {
      inside = !inside;
    }
  }
  return inside;
}

/// Distância em km de [home] até o evento: zero se estiver dentro da área do aviso.
double distanceToEvent(HazardEvent e, LatLng home) {
  var best = distanceKm(home, e.point);
  for (final ring in e.areas) {
    if (pointInRing(home, ring)) return 0;
    for (final v in ring) {
      best = math.min(best, distanceKm(home, v));
    }
  }
  return best;
}
