import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/photo/photo_watermark.dart';

/// What came of opening the camera for a visit.
enum FreeVisitShotResult { taken, cancelled, unavailable }

class FreeVisitShot {
  const FreeVisitShot(this.result, [this.path]);

  final FreeVisitShotResult result;

  /// The stamped picture on the phone, when [result] is taken.
  final String? path;
}

/// Where the picture of a visit on a driver's free route is stored on the server
/// (bucket opstation-photos), the same folder scheme as the pictures of delivery stops.
String freeRoutePhotoRemotePath({required String deliveryId, required String driverName, required int stopNumber, required DateTime at}) {
  final safe = driverName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  final date = at.toIso8601String().split('T').first;
  return 'deliveries/$deliveryId/${safe}_${date}_visit$stopNumber.jpg';
}

/// The camera behind "Mark visit" on a free route: takes one picture, burns the
/// coordinates and the time into it, and keeps it on the phone until the upload
/// queue has sent it ({docs}/free_visit_photos/{timestamp}.jpg).
class FreeVisitPhotoService {
  FreeVisitPhotoService({ImagePicker? picker, Future<Directory> Function()? docsDir})
      : _picker = picker ?? ImagePicker(),
        _docsDir = docsDir ?? getApplicationDocumentsDirectory;

  final ImagePicker _picker;
  final Future<Directory> Function() _docsDir;

  /// Opens the camera for a visit: [FreeVisitShotResult.taken] with the stamped picture,
  /// [FreeVisitShotResult.cancelled] when the camera was closed without a picture, or
  /// [FreeVisitShotResult.unavailable] when it could not be opened (permission, no camera) — the
  /// caller then marks the visit without a picture.
  Future<FreeVisitShot> shoot({required double lat, required double lng}) async {
    try {
      final path = await capture(lat: lat, lng: lng);
      return path == null ? const FreeVisitShot(FreeVisitShotResult.cancelled) : FreeVisitShot(FreeVisitShotResult.taken, path);
    } catch (_) {
      return const FreeVisitShot(FreeVisitShotResult.unavailable);
    }
  }

  /// Opens the camera. Returns the saved path of the stamped picture, or null when the
  /// camera was closed without a picture. [lat]/[lng] are the visit's own GPS point.
  Future<String?> capture({required double lat, required double lng}) async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 80,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file == null) return null;
    return processAndSave(await File(file.path).readAsBytes(), lat: lat, lng: lng, at: DateTime.now());
  }

  /// Stamps [bytes] (a JPEG) with the coordinates and time and saves them.
  Future<String> processAndSave(Uint8List bytes, {required double lat, required double lng, required DateTime at}) async {
    final out = PhotoWatermark.addWatermark(jpegBytes: bytes, latitude: lat, longitude: lng, timestamp: at);
    final docs = await _docsDir();
    final dir = Directory(p.join(docs.path, 'free_visit_photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = p.join(dir.path, '${at.millisecondsSinceEpoch}.jpg');
    await File(path).writeAsBytes(out, flush: true);
    return path;
  }
}

final freeVisitPhotoServiceProvider = Provider<FreeVisitPhotoService>((ref) => FreeVisitPhotoService());
