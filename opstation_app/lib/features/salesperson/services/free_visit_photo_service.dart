import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/photo/photo_watermark.dart';

/// The camera behind "Mark visit here" on a free route: takes one picture, burns the
/// coordinates and the time into it, and keeps it on the phone until the upload
/// queue has sent it ({docs}/free_visit_photos/{timestamp}.jpg).
class FreeVisitPhotoService {
  FreeVisitPhotoService({ImagePicker? picker, Future<Directory> Function()? docsDir})
      : _picker = picker ?? ImagePicker(),
        _docsDir = docsDir ?? getApplicationDocumentsDirectory;

  final ImagePicker _picker;
  final Future<Directory> Function() _docsDir;

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
