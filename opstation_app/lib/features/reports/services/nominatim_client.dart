import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/maps_config.dart';
import '../../admin_settings/providers/org_settings_controller.dart';

/// Reverse-geocoding client (lat/lng → short address string).
///
/// Default endpoint is the public Nominatim (OSM) demo which enforces
/// a strict 1 req/sec rate limit and requires a valid User-Agent.
/// We throttle client-side and cache per-coordinate.
///
/// Address quality is best-effort — Nominatim is free but uneven for
/// Pakistan. Swap to a paid provider via OrgSettings.nominatimBaseUrl
/// when quality matters.
class NominatimClient {
  final Ref? _ref;
  NominatimClient(Ref this._ref)
      : _http = null,
        _fixedBase = null,
        _googleKey = MapsConfig.apiKey,
        _retryDelay = const Duration(seconds: 2),
        _minGap = const Duration(milliseconds: 1100);

  /// For tests: a fixed server, an HTTP client, a Google key, short waits.
  NominatimClient.forTest({
    required String baseUrl,
    required http.Client client,
    String googleKey = '',
    Duration retryDelay = Duration.zero,
    Duration minGap = Duration.zero,
  })  : _ref = null,
        _http = client,
        _fixedBase = baseUrl,
        _googleKey = googleKey,
        _retryDelay = retryDelay,
        _minGap = minGap;

  final http.Client? _http;
  final String? _fixedBase;
  final String _googleKey;
  final Duration _retryDelay;
  final Duration _minGap;
  Future<http.Response> _get(Uri uri, {Map<String, String>? headers, Duration timeout = const Duration(seconds: 12)}) {
    final client = _http;
    return (client != null ? client.get(uri, headers: headers) : http.get(uri, headers: headers)).timeout(timeout);
  }

  /// Cache keyed by rounded "lat,lng" so repeated calls for the same
  /// location (e.g. the salesperson's home as trip start) hit cache.
  final Map<String, String?> _cache = {};
  DateTime? _lastCall;

  Future<String> _baseUrl() async {
    final fixed = _fixedBase;
    if (fixed != null) return fixed;
    final s = await _ref!.read(orgSettingsProvider.future);
    return s.nominatimBaseUrl;
  }

  String _cacheKey(double lat, double lng) {
    // 5 decimal places ≈ 1.1m precision — tight enough to keep distinct
    // visit sites distinct, loose enough to coalesce jitter.
    return '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  }

  /// Returns a short, PDF-friendly place name or null when none could be found.
  /// Null callers typically render raw lat/lng as fallback.
  ///
  /// Only names that were FOUND are remembered. A failed lookup is not: it used
  /// to be cached as "no name", so one slow moment made every later report in the
  /// session show coordinates. A failure is now retried once, and then Google's
  /// reverse lookup (the app's Maps key) is tried before giving up.
  Future<String?> reverseGeocode(double lat, double lng) async {
    final key = _cacheKey(lat, lng);
    final hit = _cache[key];
    if (hit != null) return hit;

    String? name;
    for (var attempt = 0; attempt < 2 && name == null; attempt++) {
      if (attempt > 0) await Future.delayed(_retryDelay);
      name = await _osm(lat, lng);
    }
    name ??= await _google(lat, lng);
    if (name != null) _cache[key] = name;
    return name;
  }

  Future<String?> _osm(double lat, double lng) async {
    // Respect the 1 req/sec policy for the public demo server.
    final now = DateTime.now();
    if (_lastCall != null) {
      final elapsed = now.difference(_lastCall!);
      if (elapsed < _minGap) {
        await Future.delayed(_minGap - elapsed);
      }
    }
    _lastCall = DateTime.now();

    try {
      final base = await _baseUrl();
      final uri = Uri.parse(
          '$base/reverse?format=jsonv2&lat=$lat&lon=$lng&zoom=16&addressdetails=1');
      final resp = await _get(uri, headers: {
        // Nominatim requires a descriptive User-Agent; generic browser
        // UAs get blocked. Identifies us clearly.
        'User-Agent': 'Opstation/1.0 (field-ops app; contact via app)',
        'Accept-Language': 'en',
      });

      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final addr = body['address'] as Map<String, dynamic>?;
      if (addr == null) return null;
      // Build a short line like "Multan Rd, Sarai, Lahore, Punjab" by
      // picking the most informative components in order.
      final parts = <String>[];
      void pick(String k) {
        final v = addr[k];
        if (v is String && v.trim().isNotEmpty && !parts.contains(v)) {
          parts.add(v);
        }
      }

      pick('road');
      pick('neighbourhood');
      pick('suburb');
      pick('city_district');
      pick('city');
      pick('town');
      pick('state_district');
      pick('state');

      final line = parts.take(4).join(', ');
      final value = line.isEmpty ? (body['display_name'] as String?) : line;
      return (value == null || value.trim().isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Google's reverse lookup — only when OpenStreetMap found nothing. "Area, City".
  Future<String?> _google(double lat, double lng) async {
    if (_googleKey.isEmpty) return null;
    try {
      final uri = Uri.parse('https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=$lat,$lng&language=en&key=$_googleKey');
      final resp = await _get(uri, timeout: const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;
      final results = (data['results'] as List?) ?? const [];
      String? comp(List<String> types) {
        for (final r in results) {
          for (final c in ((r as Map)['address_components'] as List? ?? const [])) {
            final t = ((c as Map)['types'] as List? ?? const []).cast<String>();
            if (types.any(t.contains)) return '${c['long_name']}'.trim();
          }
        }
        return null;
      }

      final area = comp(['sublocality_level_1', 'sublocality', 'neighborhood', 'route']);
      final city = comp(['locality', 'administrative_area_level_2']);
      final parts = <String>[if (area != null && area.isNotEmpty) area, if (city != null && city.isNotEmpty && city != area) city];
      if (parts.isNotEmpty) return parts.join(', ');
      final formatted = results.isEmpty ? null : '${(results.first as Map)['formatted_address'] ?? ''}'.trim();
      return (formatted == null || formatted.isEmpty) ? null : formatted;
    } catch (_) {
      return null;
    }
  }
}

final nominatimClientProvider =
    Provider<NominatimClient>((ref) => NominatimClient(ref));
