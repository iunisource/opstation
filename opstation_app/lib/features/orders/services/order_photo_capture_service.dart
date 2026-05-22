import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/photo/photo_watermark.dart';

enum OrderPhotoSource { camera, gallery }

/// Captures or picks an order photo, watermarks camera shots with GPS+time,
/// and uploads to the opstation-photos Supabase Storage bucket at
/// `orders/{orderId}/{timestamp}.jpg`. Returns the storage path so the
/// caller stores a cloud-resolvable reference instead of a local one —
/// the older local-only flow tied photos to a single device and could
/// not be rendered from the web.
class OrderPhotoCaptureService {
  final ImagePicker _picker;
  final SupabaseClient _supabase;

  OrderPhotoCaptureService({ImagePicker? picker, SupabaseClient? supabase})
      : _picker = picker ?? ImagePicker(),
        _supabase = supabase ?? Supabase.instance.client;

  Future<String?> capture({
    required String orderId,
    OrderPhotoSource source = OrderPhotoSource.camera,
  }) async {
    // GPS only for camera shots — watermarking a gallery pick with "now"
    // GPS would be misleading. Fetched in parallel with the picker.
    final positionFuture =
        source == OrderPhotoSource.camera ? _safeGetPosition() : null;

    final file = await _picker.pickImage(
      source: source == OrderPhotoSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
      preferredCameraDevice: CameraDevice.rear,
    );
    if (file == null) return null;

    final origBytes = await File(file.path).readAsBytes();

    Uint8List outputBytes = origBytes;
    if (source == OrderPhotoSource.camera && positionFuture != null) {
      final pos = await positionFuture;
      if (pos != null) {
        outputBytes = PhotoWatermark.addWatermark(
          jpegBytes: origBytes,
          latitude: pos.latitude,
          longitude: pos.longitude,
          timestamp: DateTime.now(),
        );
      }
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final storagePath = 'orders/$orderId/$ts.jpg';
    await _supabase.storage.from('opstation-photos').uploadBinary(
          storagePath,
          outputBytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: false,
          ),
        );
    return storagePath;
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
}

final orderPhotoCaptureServiceProvider =
    Provider<OrderPhotoCaptureService>((ref) {
  return OrderPhotoCaptureService();
});
