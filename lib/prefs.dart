import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quais eventos geram aviso no celular.
class AlertPrefs {
  const AlertPrefs({
    this.quakes = true,
    this.minMag = 5.5,
    this.disasters = true,
    this.alerts = true,
    this.radiusKm = 0,
    this.home,
  });

  /// Terremotos a partir da magnitude [minMag].
  final bool quakes;
  final double minMag;

  /// Ciclones, enchentes, vulcões etc. com alerta laranja ou vermelho (GDACS).
  final bool disasters;

  /// Avisos oficiais (tornado, vento extremo, alertas de outros países).
  final bool alerts;

  /// Avisar só perto de [home], em km (0 = mundo todo).
  final int radiusKm;

  /// "Meu local", usado nos filtros e nos avisos por distância.
  final LatLng? home;

  AlertPrefs copyWith({
    bool? quakes,
    double? minMag,
    bool? disasters,
    bool? alerts,
    int? radiusKm,
    LatLng? home,
    bool clearHome = false,
  }) {
    return AlertPrefs(
      quakes: quakes ?? this.quakes,
      minMag: minMag ?? this.minMag,
      disasters: disasters ?? this.disasters,
      alerts: alerts ?? this.alerts,
      radiusKm: radiusKm ?? this.radiusKm,
      home: clearHome ? null : (home ?? this.home),
    );
  }

  static Future<AlertPrefs> load() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    final lat = sp.getDouble('n_home_lat');
    final lng = sp.getDouble('n_home_lng');
    return AlertPrefs(
      quakes: sp.getBool('n_quakes') ?? true,
      minMag: sp.getDouble('n_minmag') ?? 5.5,
      disasters: sp.getBool('n_disasters') ?? true,
      alerts: sp.getBool('n_alerts') ?? true,
      radiusKm: sp.getInt('n_radius') ?? 0,
      home: (lat != null && lng != null) ? LatLng(lat, lng) : null,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('n_quakes', quakes);
    await sp.setDouble('n_minmag', minMag);
    await sp.setBool('n_disasters', disasters);
    await sp.setBool('n_alerts', alerts);
    await sp.setInt('n_radius', radiusKm);
    final h = home;
    if (h == null) {
      await sp.remove('n_home_lat');
      await sp.remove('n_home_lng');
    } else {
      await sp.setDouble('n_home_lat', h.latitude);
      await sp.setDouble('n_home_lng', h.longitude);
    }
  }
}
