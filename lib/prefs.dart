import 'package:shared_preferences/shared_preferences.dart';

/// Quais eventos geram aviso no celular.
class AlertPrefs {
  const AlertPrefs({
    this.quakes = true,
    this.minMag = 5.5,
    this.disasters = true,
    this.alerts = true,
  });

  /// Terremotos a partir da magnitude [minMag].
  final bool quakes;
  final double minMag;

  /// Ciclones, enchentes, vulcões etc. com alerta laranja ou vermelho (GDACS).
  final bool disasters;

  /// Avisos extremos dos EUA (tornado, vento extremo).
  final bool alerts;

  AlertPrefs copyWith({
    bool? quakes,
    double? minMag,
    bool? disasters,
    bool? alerts,
  }) {
    return AlertPrefs(
      quakes: quakes ?? this.quakes,
      minMag: minMag ?? this.minMag,
      disasters: disasters ?? this.disasters,
      alerts: alerts ?? this.alerts,
    );
  }

  static Future<AlertPrefs> load() async {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return AlertPrefs(
      quakes: sp.getBool('n_quakes') ?? true,
      minMag: sp.getDouble('n_minmag') ?? 5.5,
      disasters: sp.getBool('n_disasters') ?? true,
      alerts: sp.getBool('n_alerts') ?? true,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('n_quakes', quakes);
    await sp.setDouble('n_minmag', minMag);
    await sp.setBool('n_disasters', disasters);
    await sp.setBool('n_alerts', alerts);
  }
}
