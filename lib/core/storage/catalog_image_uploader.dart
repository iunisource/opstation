import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Uploads catalogue imagery (brand logos, product photos) to the public
/// `opstation-photos` bucket and returns the public URL.
///
/// Public, not signed, on purpose: a retailer scrolling 340 products would
/// otherwise trigger 340 signed-URL round trips. These are product photos and
/// brand marks — nothing confidential — so a stable public URL is both correct
/// and dramatically faster. (Contrast `retailer-files`, which is private and
/// signed per open.)
///
/// Returns null when the user cancels the picker.
class CatalogImageUploader {
  static const bucket = 'opstation-photos';

  /// Picks an image and uploads it under [folder]/[keyHint]-<ts>.<ext>.
  ///
  /// The timestamp defeats CDN caching: without it, replacing a logo would leave
  /// the old one showing until the cache expired, which looks like the upload
  /// silently failed.
  static Future<String?> pickAndUpload({
    required String orgId,
    required String folder, // 'brands' | 'products'
    required String keyHint, // taxonomy id or product id
  }) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true, // web has no file paths; we need the bytes
    );
    if (res == null || res.files.isEmpty) return null;

    final file = res.files.first;
    final Uint8List? bytes = file.bytes;
    if (bytes == null) return null;

    final ext = (file.extension ?? 'png').toLowerCase();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '$orgId/$folder/$keyHint-$ts.$ext';

    final storage = Supabase.instance.client.storage.from(bucket);
    await storage.uploadBinary(
      path,
      bytes,
      fileOptions: FileOptions(
        contentType: _mime(ext),
        upsert: true,
      ),
    );
    return storage.getPublicUrl(path);
  }

  static String _mime(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/png';
    }
  }
}
