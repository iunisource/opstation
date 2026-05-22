import 'package:supabase_flutter/supabase_flutter.dart';

/// Builds a public URL for a photo stored in Supabase Storage.
///
/// Photos are stored under the `opstation-photos` bucket with paths like
/// `visits/<userId>/...jpg` or `deliveries/<deliveryId>/...jpg`. The
/// row's photo_paths_json contains these path strings; the UI calls
/// this helper to turn each path into a renderable URL.
///
/// If [path] looks like a local filesystem path (starts with `/`), we
/// pass it through unchanged so legacy rows that still have local
/// paths render via Image.file fallback. New rows always store cloud
/// paths and use the URL builder branch.
class PhotoUrl {
  static String build(String path) {
    if (path.startsWith('/') || path.startsWith('file://')) {
      return path;
    }
    return Supabase.instance.client.storage
        .from('opstation-photos')
        .getPublicUrl(path);
  }

  /// True if [path] is a remote storage path (not a local file).
  static bool isRemote(String path) =>
      !path.startsWith('/') && !path.startsWith('file://');
}
