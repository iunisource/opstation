import 'package:supabase_flutter/supabase_flutter.dart';

/// Builds a public URL for a photo stored in Supabase Storage.
///
/// Mirrors the mobile app's PhotoUrl helper so both clients agree on
/// how to render a stored photo path. Visits and delivery stops keep
/// only the storage path in their photo_paths_json column (e.g.
/// `visits/<userId>/...jpg`); UIs call this to turn a path into a
/// renderable URL.
class PhotoUrl {
  static String build(String path) {
    if (path.startsWith('/') || path.startsWith('file://')) {
      // Legacy rows still occasionally hold local mobile paths.
      // Web can't render them at all — return as-is so an Image.network
      // call will fail loudly rather than silently mis-resolve.
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
