import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

enum Region { world, southAmerica, northAmerica, europe, africa, asia, oceania }

extension RegionInfo on Region {
  String get label => switch (this) {
        Region.world => 'Mundo',
        Region.southAmerica => 'América do Sul',
        Region.northAmerica => 'América do Norte e Central',
        Region.europe => 'Europa',
        Region.africa => 'África',
        Region.asia => 'Ásia',
        Region.oceania => 'Oceania',
      };

  /// Caixas aproximadas: perto das divisas um evento pode cair em duas regiões.
  bool contains(LatLng p) {
    final lat = p.latitude;
    final lon = ((p.longitude + 180) % 360) - 180;
    bool box(double s, double w, double n, double e) =>
        lat >= s && lat <= n && lon >= w && lon <= e;
    return switch (this) {
      Region.world => true,
      Region.southAmerica => box(-57, -82, 13, -34),
      Region.northAmerica => box(5, -170, 84, -50),
      Region.europe => box(34, -25, 72, 45),
      Region.africa => box(-35, -20, 38, 52),
      Region.asia => box(-11, 26, 78, 180),
      Region.oceania =>
        box(-50, 110, 0, 180) || box(-50, -180, 0, -140),
    };
  }
}

enum SortBy { severity, recent, nearest }

extension SortByInfo on SortBy {
  String get label => switch (this) {
        SortBy.severity => 'Gravidade',
        SortBy.recent => 'Mais recentes',
        SortBy.nearest => 'Mais perto de mim',
      };
}

const _allTypes = <HazardType>{
  HazardType.earthquake,
  HazardType.cyclone,
  HazardType.storm,
  HazardType.alert,
  HazardType.flood,
  HazardType.volcano,
  HazardType.wildfire,
  HazardType.drought,
};

/// Filtros do mapa e da lista (os avisos do celular têm ajustes próprios).
class MapFilters {
  const MapFilters({
    this.types = _allTypes,
    this.minSeverity = Severity.low,
    this.minMag = 4.5,
    this.hours = 0,
    this.region = Region.world,
    this.radiusKm = 0,
    this.sort = SortBy.severity,
  });

  final Set<HazardType> types;
  final Severity minSeverity;

  /// Magnitude mínima, só para terremotos.
  final double minMag;

  /// Só eventos das últimas [hours] horas (0 = tudo).
  final int hours;
  final Region region;

  /// Só eventos a até [radiusKm] de "meu local" (0 = sem limite).
  final int radiusKm;
  final SortBy sort;

  bool get isDefault =>
      types.length == _allTypes.length &&
      minSeverity == Severity.low &&
      minMag <= 4.5 &&
      hours == 0 &&
      region == Region.world &&
      radiusKm == 0 &&
      sort == SortBy.severity;

  MapFilters copyWith({
    Set<HazardType>? types,
    Severity? minSeverity,
    double? minMag,
    int? hours,
    Region? region,
    int? radiusKm,
    SortBy? sort,
  }) {
    return MapFilters(
      types: types ?? this.types,
      minSeverity: minSeverity ?? this.minSeverity,
      minMag: minMag ?? this.minMag,
      hours: hours ?? this.hours,
      region: region ?? this.region,
      radiusKm: radiusKm ?? this.radiusKm,
      sort: sort ?? this.sort,
    );
  }

  /// Aplica os filtros e ordena.
  List<HazardEvent> apply(List<HazardEvent> input, LatLng? home) {
    final now = DateTime.now().toUtc();
    final useRadius = radiusKm > 0 && home != null;
    final dist = <String, double>{};
    final out = <HazardEvent>[];
    for (final e in input) {
      if (!types.contains(e.type)) continue;
      if (e.severity.index < minSeverity.index) continue;
      if (e.type == HazardType.earthquake && (e.magnitude ?? 0) < minMag) {
        continue;
      }
      if (hours > 0 && now.difference(e.time) > Duration(hours: hours)) {
        continue;
      }
      if (!region.contains(e.point)) continue;
      if (home != null && (useRadius || sort == SortBy.nearest)) {
        final d = distanceToEvent(e, home);
        if (useRadius && d > radiusKm) continue;
        dist[e.id] = d;
      }
      out.add(e);
    }
    out.sort((a, b) {
      if (sort == SortBy.recent) return b.time.compareTo(a.time);
      if (sort == SortBy.nearest && home != null) {
        final c = (dist[a.id] ?? 0).compareTo(dist[b.id] ?? 0);
        if (c != 0) return c;
      }
      final s = b.severity.index.compareTo(a.severity.index);
      return s != 0 ? s : b.time.compareTo(a.time);
    });
    return out;
  }

  static Future<MapFilters> load() async {
    final sp = await SharedPreferences.getInstance();
    final names = sp.getStringList('f_types');
    final saved = names == null
        ? _allTypes
        : <HazardType>{
            for (final t in HazardType.values)
              if (names.contains(t.name)) t,
          };
    int pick(String key, int length) {
      final v = sp.getInt(key) ?? 0;
      return (v < 0 || v >= length) ? 0 : v;
    }

    return MapFilters(
      types: saved.isEmpty ? _allTypes : saved,
      minSeverity: Severity.values[pick('f_sev', Severity.values.length)],
      minMag: sp.getDouble('f_mag') ?? 4.5,
      hours: sp.getInt('f_hours') ?? 0,
      region: Region.values[pick('f_region', Region.values.length)],
      radiusKm: sp.getInt('f_radius') ?? 0,
      sort: SortBy.values[pick('f_sort', SortBy.values.length)],
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('f_types', [for (final t in types) t.name]);
    await sp.setInt('f_sev', minSeverity.index);
    await sp.setDouble('f_mag', minMag);
    await sp.setInt('f_hours', hours);
    await sp.setInt('f_region', region.index);
    await sp.setInt('f_radius', radiusKm);
    await sp.setInt('f_sort', sort.index);
  }
}
