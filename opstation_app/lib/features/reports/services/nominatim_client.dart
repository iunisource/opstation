import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

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
  final Ref _ref;
  NominatimClient(this._ref);

  /// Cache keyed by rounded "lat,lng" so repeated calls for the same
  /// location (e.g. the salesperson's home as trip start) hit cache.
  final Map<String, String?> _cache = {};
  DateTime? _lastCall;

  Future<String> _baseUrl() async {
    final s = await _ref.read(orgSettingsProvider.future);
    return s.nominatimBaseUrl;
  }

  String _cacheKey(double lat, double lng) {
    // 5 decimal places ≈ 1.1m precision — tight enough to keep distinct
    // visit sites distinct, loose enough to coalesce jitter.
    return '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
  }

  /// Returns a short, PDF-friendly address line or null on failure.
  /// Null callers typically render raw lat/lng as fallback.
  Future<String?> reverseGeocode(double lat, double lng) async {
    final key = _cacheKey(lat, lng);
    if (_cache.containsKey(key)) return _cache[key];

    // Respect the 1 req/sec policy for the public demo server.
    final now = DateTime.now();
    if (_lastCall != null) {
      final elapsed = now.difference(_lastCall!);
      if (elapsed < const Duration(milliseconds: 1100)) {
        await Future.delayed(
            const Duration(milliseconds: 1100) - elapsed);
      }
    }
    _lastCall = DateTime.now();

    try {
      final base = await _baseUrl();
      final uri = Uri.parse(
          '$base/reverse?format=jsonv2&lat=$lat&lon=$lng&zoom=16&addressdetails=1');
      final resp = await http.get(uri, headers: {
        // Nominatim requires a descriptive User-Agent; generic browser
        // UAs get blocked. Identifies us clearly.
        'User-Agent': 'Opstation/1.0 (field-ops app; contact via app)',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        _cache[key] = null;
        return null;
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final addr = body['address'] as Map<String, dynamic>?;
      if (addr == null) {
        _cache[key] = null;
        return null;
      }
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
      _cache[key] = value;
      return value;
    } catch (_) {
      _cache[key] = null;
      return null;
    }
  }
}

final nominatimClientProvider =
    Provider<NominatimClient>((ref) => NominatimClient(ref));
