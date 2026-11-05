import 'dart:math';

/// Jarak (meter) antara dua koordinat.
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1), dLon = _rad(lon2 - lon1);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * r * atan2(sqrt(a), sqrt(1 - a));
}

/// Arah dari titik 1 ke titik 2 dalam derajat (0 = utara).
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final y = sin(_rad(lon2 - lon1)) * cos(_rad(lat2));
  final x = cos(_rad(lat1)) * sin(_rad(lat2)) - sin(_rad(lat1)) * cos(_rad(lat2)) * cos(_rad(lon2 - lon1));
  return (atan2(y, x) * 180 / pi + 360) % 360;
}

const _dirs = ['Utara', 'Timur Laut', 'Timur', 'Tenggara', 'Selatan', 'Barat Daya', 'Barat', 'Barat Laut'];
String compassName(double deg) => _dirs[((deg + 22.5) % 360 ~/ 45)];

double _rad(double d) => d * pi / 180;

String formatDistance(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

String timeAgo(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inSeconds < 60) return 'baru saja';
  if (d.inMinutes < 60) return '${d.inMinutes} mnt lalu';
  if (d.inHours < 24) return '${d.inHours} jam lalu';
  return '${d.inDays} hari lalu';
}

String clockTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  final today = DateTime.now();
  final sameDay = t.year == today.year && t.month == today.month && t.day == today.day;
  return sameDay ? '${two(t.hour)}.${two(t.minute)}' : '${t.day}/${t.month} ${two(t.hour)}.${two(t.minute)}';
}

String formatCoord(double lat, double lon) =>
    '${lat.abs().toStringAsFixed(5)}° ${lat < 0 ? 'LS' : 'LU'}, ${lon.abs().toStringAsFixed(5)}° ${lon < 0 ? 'BB' : 'BT'}';
