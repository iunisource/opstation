import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Why a GPS capture attempt ended the way it did. Lets the UI show the real
/// reason (weak signal vs. permission vs. GPS-off) instead of one catch-all
/// "location unavailable" message that sends surveyors chasing the wrong fix.
enum GpsOutcome {
  success,
  serviceDisabled, // device location/GPS toggle is OFF
  permissionDenied, // denied this attempt — can ask again
  permissionBlocked, // deniedForever — must enable in app settings
  timeout, // services + permission OK, but no fix arrived in the budget
  error, // anything unexpected
}

class GpsFixResult {
  final GpsOutcome outcome;
  final DeviceFix? fix;

  /// True when [fix] came from the OS's last-known cache rather than a fresh
  /// live reading (used when a live fix times out but a recent one exists).
  final bool isStale;

  const GpsFixResult(this.outcome, {this.fix, this.isStale = false});

  bool get ok => outcome == GpsOutcome.success && fix != null;
}

/// Real device GPS. Wraps the geolocator plugin.
class DeviceGpsService {
  /// Capture a position with a generous budget.
  ///
  /// [timeout] is the time allowed for a *live* high-accuracy fix. Indoors or
  /// in a dense bazaar a cold fix routinely needs 20-40s, so 12s (the old
  /// default) failed at exactly those shops on an otherwise-fine device. If
  /// the live fix times out we fall back to the OS's last-known position
  /// (flagged stale) rather than returning nothing — a recent position is far
  /// better than none for pinning a shop, and the surveyor can re-capture in
  /// the open if the accuracy looks off.
  Future<GpsFixResult> getFixResult({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const GpsFixResult(GpsOutcome.serviceDisabled);
      }

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        return const GpsFixResult(GpsOutcome.permissionBlocked);
      }
      if (perm == LocationPermission.denied) {
        return const GpsFixResult(GpsOutcome.permissionDenied);
      }

      try {
        final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: timeout,
        );
        return GpsFixResult(
          GpsOutcome.success,
          fix: DeviceFix(
            lat: pos.latitude,
            lng: pos.longitude,
            accuracy: pos.accuracy,
          ),
        );
      } catch (_) {
        // Live fix failed — almost always a timeout under weak signal. Fall
        // back to the last-known cached position before giving up.
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          return GpsFixResult(
            GpsOutcome.success,
            fix: DeviceFix(
              lat: last.latitude,
              lng: last.longitude,
              accuracy: last.accuracy,
            ),
            isStale: true,
          );
        }
        return const GpsFixResult(GpsOutcome.timeout);
      }
    } catch (_) {
      return const GpsFixResult(GpsOutcome.error);
    }
  }

  /// Backwards-compatible helper — returns just the fix or null. Prefer
  /// [getFixResult] so the caller can surface the real failure reason.
  Future<DeviceFix?> getFix({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final res = await getFixResult(timeout: timeout);
    return res.fix;
  }
}

class DeviceFix {
  final double lat;
  final double lng;
  final double accuracy;
  const DeviceFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
  });
}

final deviceGpsServiceProvider = Provider<DeviceGpsService>((ref) {
  return DeviceGpsService();
});
