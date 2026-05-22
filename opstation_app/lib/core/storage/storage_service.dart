import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StorageService {
  final SupabaseClient _client;
  StorageService(this._client);

  Future<String> uploadFile({
    required String bucket,
    required String remotePath,
    required File file,
  }) async {
    await _client.storage.from(bucket).upload(
      remotePath,
      file,
      fileOptions: const FileOptions(upsert: true),
    );
    return _client.storage.from(bucket).getPublicUrl(remotePath);
  }

  String getPublicUrl({required String bucket, required String remotePath}) {
    return _client.storage.from(bucket).getPublicUrl(remotePath);
  }
}

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService(Supabase.instance.client);
});
