// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

/// Area name for a GPS point ("Johar Town, Lahore"), from OpenStreetMap's
/// free lookup. Remembered for the session; a slow or failed lookup returns
/// null so reports fall back to coordinates and are never held up.
final Map<String, String?> _cache = {};

Future<String?> placeName(double lat, double lng) async {
  final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
  if (_cache.containsKey(key)) return _cache[key];
  try {
    final url = 'https://nominatim.openstreetmap.org/reverse?format=jsonv2&zoom=16&addressdetails=1'
        '&accept-language=en&lat=$lat&lon=$lng';
    final res = await html.HttpRequest.request(url, requestHeaders: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 5));
    final m = jsonDecode(res.responseText ?? '{}') as Map<String, dynamic>;
    final a = Map<String, dynamic>.from((m['address'] as Map?) ?? const {});
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = '${a[k] ?? ''}'.trim();
        if (v.isNotEmpty) return v;
      }
      return null;
    }
    final area = pick(['neighbourhood', 'suburb', 'quarter', 'residential', 'village', 'road']);
    final city = pick(['city', 'town', 'county', 'state_district']);
    final parts = <String>[
      if (area != null) area,
      if (city != null && city != area) city,
    ];
    final name = parts.isEmpty ? null : parts.join(', ');
    _cache[key] = name;
    return name;
  } catch (_) {
    _cache[key] = null;
    return null;
  }
}

/// Start / end place for a trip row (start_lat … end_lng), as
/// "Area, City\n31.47680, 74.24280" — or null when unknown.
Future<(String?, String?)> tripPlaceNames(Map<String, dynamic> trip) async {
  Future<String?> one(String la, String lo) async {
    final lat = (trip[la] as num?)?.toDouble(), lng = (trip[lo] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    final n = await placeName(lat, lng);
    if (n == null) return null;
    return '$n\n${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }
  final s = await one('start_lat', 'start_lng');
  final e = await one('end_lat', 'end_lng');
  return (s, e);
}
