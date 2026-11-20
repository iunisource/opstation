import 'dart:io';

import 'photo_watermark.dart';

/// Puts the coordinates and the time on a picture the phone has just taken, so the
/// photo says where and when it was taken even after it leaves the app.
class PhotoStamp {
  PhotoStamp._();

  /// Burns the coordinates (and time) into the JPEG at [path], in place. Returns true
  /// when the picture was stamped; false (picture left as it was) when it could not
  /// be read — the caller still has the plain photo to use.
  static Future<bool> stampFile(String path, {required double lat, required double lng, DateTime? at}) async {
    try {
      final f = File(path);
      final bytes = await f.readAsBytes();
      final out = PhotoWatermark.addWatermark(
        jpegBytes: bytes,
        latitude: lat,
        longitude: lng,
        timestamp: at ?? DateTime.now(),
      );
      if (identical(out, bytes)) return false; // not a decodable JPEG: unchanged
      await f.writeAsBytes(out, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }
}
