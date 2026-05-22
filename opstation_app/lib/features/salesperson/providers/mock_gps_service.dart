import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Simulated GPS fix. The dev panel remains useful for testing each code path,
/// but we now also support [GpsScenario.realDevice] which asks the device
/// for a real fix via the geolocator plugin.
///
/// Scenarios:
///   - realDevice → ask the actual device; null if denied/unavailable
///   - near       → mocked ~40m from customer
///   - far        → mocked ~7.2km from customer
///   - noGps      → forced unavailable
///   - custom     → user-supplied coordinates
enum GpsScenario { realDevice, near, far, noGps, custom }

extension GpsScenarioX on GpsScenario {
  String get label {
    switch (this) {
      case GpsScenario.realDevice:
        return 'Real device GPS';
      case GpsScenario.near:
        return 'Near customer';
      case GpsScenario.far:
        return 'Far from customer';
      case GpsScenario.noGps:
        return 'GPS off / unavailable';
      case GpsScenario.custom:
        return 'Custom coordinates';
    }
  }
}

class SimulatedFix {
  final double? lat;
  final double? lng;
  final double? accuracyMeters;
  final bool available;

  const SimulatedFix({
    this.lat,
    this.lng,
    this.accuracyMeters,
    this.available = true,
  });

  const SimulatedFix.unavailable()
      : lat = null,
        lng = null,
        accuracyMeters = null,
        available = false;
}

class MockGpsService {
  final _rng = math.Random();

  /// Async version — supports [GpsScenario.realDevice] via [deviceGps].
  /// Returns null for realDevice when permission is denied or GPS unavailable;
  /// callers should treat null the same as [SimulatedFix.unavailable].
  Future<SimulatedFix> fixAsync({
    required GpsScenario scenario,
    required double? customerLat,
    required double? customerLng,
    double? customLat,
    double? customLng,
    required Future<SimulatedFix> Function() realDeviceFixer,
  }) async {
    if (scenario == GpsScenario.realDevice) {
      return await realDeviceFixer();
    }
    return fix(
      scenario: scenario,
      customerLat: customerLat,
      customerLng: customerLng,
      customLat: customLat,
      customLng: customLng,
    );
  }

  /// Produce a simulated GPS fix for the given scenario, relative to a
  /// customer's stored location. Returns unavailable for [GpsScenario.realDevice]
  /// — use [fixAsync] to get a real fix.
  SimulatedFix fix({
    required GpsScenario scenario,
    required double? customerLat,
    required double? customerLng,
    double? customLat,
    double? customLng,
  }) {
    switch (scenario) {
      case GpsScenario.realDevice:
        // Caller should use fixAsync for this.
        return const SimulatedFix.unavailable();

      case GpsScenario.noGps:
        return const SimulatedFix.unavailable();

      case GpsScenario.near:
        // ~40m offset from customer; accuracy 12–20m.
        if (customerLat == null || customerLng == null) {
          // Customer has no stored location — return a default fix.
          return SimulatedFix(
            lat: 31.4700,
            lng: 74.2900,
            accuracyMeters: 15 + _rng.nextDouble() * 5,
          );
        }
        final (lat, lng) = _offset(customerLat, customerLng, 40);
        return SimulatedFix(
          lat: lat,
          lng: lng,
          accuracyMeters: 12 + _rng.nextDouble() * 8,
        );

      case GpsScenario.far:
        // ~7.2 km offset; accuracy 15–25m.
        if (customerLat == null || customerLng == null) {
          return SimulatedFix(
            lat: 31.4000,
            lng: 74.2000,
            accuracyMeters: 18 + _rng.nextDouble() * 7,
          );
        }
        final (lat, lng) = _offset(customerLat, customerLng, 7200);
        return SimulatedFix(
          lat: lat,
          lng: lng,
          accuracyMeters: 18 + _rng.nextDouble() * 7,
        );

      case GpsScenario.custom:
        if (customLat == null || customLng == null) {
          return const SimulatedFix.unavailable();
        }
        return SimulatedFix(
          lat: customLat,
          lng: customLng,
          accuracyMeters: 15 + _rng.nextDouble() * 10,
        );
    }
  }

  /// Offset a lat/lng by [meters] in a pseudorandom direction.
  (double, double) _offset(double lat, double lng, double meters) {
    const earthRadius = 6371000.0;
    final bearing = _rng.nextDouble() * 2 * math.pi;
    final dLat = (meters / earthRadius) * math.cos(bearing);
    final dLng = (meters / earthRadius) *
        math.sin(bearing) /
        math.cos(lat * math.pi / 180.0);
    return (lat + dLat * 180.0 / math.pi, lng + dLng * 180.0 / math.pi);
  }
}

final mockGpsServiceProvider = Provider<MockGpsService>((ref) {
  return MockGpsService();
});
