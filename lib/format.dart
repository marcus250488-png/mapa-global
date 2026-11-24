import 'package:latlong2/latlong.dart';

String two(int n) => n.toString().padLeft(2, '0');

/// "agora", "12 min", "3 h", "2 d".
String ago(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'agora';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 48) return '${d.inHours} h';
  return '${d.inDays} d';
}

/// "Agora há pouco", "Há 12 min", "Há 3 h".
String agoLong(DateTime t) {
  final a = ago(t);
  return a == 'agora' ? 'Agora há pouco' : 'Há $a';
}

String hhmm(DateTime t) {
  final l = t.toLocal();
  return '${two(l.hour)}:${two(l.minute)}';
}

String dayHhmm(DateTime t) {
  final l = t.toLocal();
  return '${two(l.day)}/${two(l.month)} ${hhmm(t)}';
}

/// Uma casa decimal com vírgula: 5,6.
String num1(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

/// Inteiro com ponto de milhar: 1.850.
String int0(num v) {
  final s = v.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

/// Direção do vento em pontos cardeais (L = leste, O = oeste).
String compass(double deg) {
  const dirs = ['N', 'NE', 'L', 'SE', 'S', 'SO', 'O', 'NO'];
  return dirs[(((deg % 360) + 22.5) ~/ 45) % 8];
}

String coords(LatLng p) {
  final lng = ((p.longitude + 180) % 360) - 180;
  final ns = p.latitude >= 0 ? 'N' : 'S';
  final lo = lng >= 0 ? 'L' : 'O';
  return '${num1(p.latitude.abs())}° $ns, ${num1(lng.abs())}° $lo';
}

String capeLabel(double v) =>
    v < 300 ? 'baixa' : v < 1000 ? 'moderada' : v < 2500 ? 'alta' : 'muito alta';
