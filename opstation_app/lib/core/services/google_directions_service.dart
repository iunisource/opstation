import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/maps_config.dart';

/// A single lat/lng point passed to Google Directions.
class DirectionsPoint {
  final double lat;
  final double lng;
  const DirectionsPoint(this.lat, this.lng);
  String get param => '$lat,$lng';
}

/// Google Directions API wrapper.
///
/// One call for an entire ordered sequence of points — returns the
/// road distance in km for each consecutive leg:
///   points[0]→points[1], points[1]→points[2], …, points[n-2]→points[n-1]
///
/// Returns null on any failure (no key, network error, bad response)
/// so callers can fall back to Haversine without crashing.
class GoogleDirectionsService {
  static const _baseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  /// Fetches leg distances for [points] in order.
  ///
  /// Requires at least 2 points. Returns a list of length
  /// points.length - 1 where each entry is the road distance in km
  /// for that leg. Returns null if the call fails or no key is set.
  static Future<List<double>?> getLegsKm(
      List<DirectionsPoint> points) async {
    if (!MapsConfig.hasKey) return null;
    if (points.length < 2) return null;

    final origin = points.first.param;
    final destination = points.last.param;

    // Waypoints are all intermediate points (not origin or destination).
    final waypoints = points.length > 2
        ? points.sublist(1, points.length - 1).map((p) => p.param).join('|')
        : null;

    final params = {
      'origin': origin,
      'destination': destination,
      'key': MapsConfig.apiKey,
      if (waypoints != null) 'waypoints': waypoints,
    };

    final uri = Uri.parse(_baseUrl).replace(queryParameters: params);

    try {
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final status = json['status'] as String?;
      if (status != 'OK') return null;

      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;

      final legs = (routes.first as Map)['legs'] as List?;
      if (legs == null || legs.isEmpty) return null;

      final distances = <double>[];
      for (final leg in legs) {
        final distMap = (leg as Map)['distance'] as Map?;
        final meters = distMap?['value'] as int?;
        if (meters == null) return null; // partial failure → abort
        distances.add(meters / 1000.0);
      }

      // Sanity: should have exactly points.length - 1 legs.
      if (distances.length != points.length - 1) return null;

      return distances;
    } catch (_) {
      return null;
    }
  }
}
