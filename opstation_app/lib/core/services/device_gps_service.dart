import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Real device GPS. Wraps the geolocator plugin with a soft-permission
/// model: if permission is denied, we return a "no GPS" fix instead of
/// throwing, so the app continues working per spec.
class DeviceGpsService {
  /// Returns a fix or null if unavailable / denied / timed out.
  Future<DeviceFix?> getFix({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: timeout,
      );
      return DeviceFix(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: pos.accuracy,
      );
    } catch (_) {
      return null;
    }
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
