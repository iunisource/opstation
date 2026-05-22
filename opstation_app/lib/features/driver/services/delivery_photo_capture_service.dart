import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../../core/photo/photo_watermark.dart';

/// Wraps `image_picker` to capture a delivery PoD photo with our
/// preferred settings (compressed to keep upload payloads small) and
/// save it into the app's documents directory under a predictable
/// structure:
///
///   {docs}/delivery_photos/{deliveryId}/{stopId}/{timestamp}.jpg
///
/// A small coordinates+timestamp watermark is burned into the
/// bottom-right of the JPEG before saving — so the photo is
/// self-describing even after it leaves the app. GPS is fetched in
/// parallel with the camera so it doesn't add wait time, and the
/// watermark is silently skipped if location is unavailable.
class DeliveryPhotoCaptureService {
  final ImagePicker _picker;
  DeliveryPhotoCaptureService({ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  /// Captures a single photo from the camera. Returns the absolute
  /// saved path or null if the driver cancelled. Optional [latitude]
  /// /[longitude] override the auto-fetched GPS position.
  Future<String?> capture({
    required String deliveryId,
    required String stopId,
    double? latitude,
    double? longitude,
  }) async {
    final hasCoords = latitude != null && longitude != null;
    // Kick off GPS in parallel with the picker — by the time the
    // driver finishes composing the shot, the fix is already done.
    final Future<Position?> positionFuture =
        hasCoords ? Future.value(null) : _safeGetPosition();

    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file == null) return null;

    final origBytes = await File(file.path).readAsBytes();

    double? lat = latitude;
    double? lng = longitude;
    if (!hasCoords) {
      final pos = await positionFuture;
      if (pos != null) {
        lat = pos.latitude;
        lng = pos.longitude;
      }
    }

    final outputBytes = (lat != null && lng != null)
        ? PhotoWatermark.addWatermark(
            jpegBytes: origBytes,
            latitude: lat,
            longitude: lng,
            timestamp: DateTime.now(),
          )
        : origBytes;

    return _saveToDocuments(
      bytes: outputBytes,
      deliveryId: deliveryId,
      stopId: stopId,
    );
  }

  Future<Position?> _safeGetPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      ).timeout(const Duration(seconds: 12));
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  Future<String> _saveToDocuments({
    required Uint8List bytes,
    required String deliveryId,
    required String stopId,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(
      docs.path,
      'delivery_photos',
      deliveryId,
      stopId,
    ));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ts = DateTime.now().millisecondsSinceEpoch;
    final destPath = p.join(dir.path, '$ts.jpg');
    await File(destPath).writeAsBytes(bytes);
    return destPath;
  }
}

final deliveryPhotoCaptureServiceProvider =
    Provider<DeliveryPhotoCaptureService>((ref) {
  return DeliveryPhotoCaptureService();
});
