import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';

/// Status values used in the upload_queue table.
class UploadStatus {
  static const queued = 'queued';
  static const uploading = 'uploading';
  static const uploaded = 'uploaded';
  static const failed = 'failed';
}

/// Snapshot of an upload_queue row, exposed as a plain Dart object so
/// downstream callers don't have to import Drift types.
class UploadJob {
  final String id;
  final String localPath;
  final String remotePath;
  final String bucket;
  final String status;
  final int retryCount;
  final String? lastError;
  final String entityType;
  final String entityId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const UploadJob({
    required this.id,
    required this.localPath,
    required this.remotePath,
    required this.bucket,
    required this.status,
    required this.retryCount,
    required this.lastError,
    required this.entityType,
    required this.entityId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory UploadJob.fromRow(UploadQueueData r) {
    return UploadJob(
      id: r.id,
      localPath: r.localPath,
      remotePath: r.remotePath,
      bucket: r.bucket,
      status: r.status,
      retryCount: r.retryCount,
      lastError: r.lastError,
      entityType: r.entityType,
      entityId: r.entityId,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
  }
}

class UploadQueueRepository {
  final AppDatabase _db;
  UploadQueueRepository(this._db);

  String _newId() {
    final rng = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = rng.nextInt(1 << 32).toRadixString(36).padLeft(6, '0');
    return 'upl_${ts}_$rand';
  }

  /// Adds a new job. Returns the created row's ID.
  Future<String> enqueue({
    required String localPath,
    required String remotePath,
    required String bucket,
    required String entityType,
    required String entityId,
  }) async {
    final id = _newId();
    final now = DateTime.now();
    await _db.into(_db.uploadQueue).insert(UploadQueueCompanion(
          id: Value(id),
          localPath: Value(localPath),
          remotePath: Value(remotePath),
          bucket: Value(bucket),
          status: Value(UploadStatus.queued),
          retryCount: const Value(0),
          entityType: Value(entityType),
          entityId: Value(entityId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    return id;
  }

  /// Returns the next queued (or previously failed and retryable) job,
  /// or null if nothing to do. Failed jobs with retryCount >= [maxRetry]
  /// are skipped to avoid hammering a broken upload.
  Future<UploadJob?> nextDue({int maxRetry = 5}) async {
    final row = await (_db.select(_db.uploadQueue)
          ..where((t) =>
              t.status.isIn([UploadStatus.queued, UploadStatus.failed]) &
              t.retryCount.isSmallerOrEqualValue(maxRetry))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : UploadJob.fromRow(row);
  }

  Future<void> markUploading(String id) async {
    await (_db.update(_db.uploadQueue)..where((t) => t.id.equals(id))).write(
      UploadQueueCompanion(
        status: const Value(UploadStatus.uploading),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> markUploaded(String id) async {
    await (_db.update(_db.uploadQueue)..where((t) => t.id.equals(id))).write(
      UploadQueueCompanion(
        status: const Value(UploadStatus.uploaded),
        lastError: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> markFailed(String id, String error, int newRetryCount) async {
    await (_db.update(_db.uploadQueue)..where((t) => t.id.equals(id))).write(
      UploadQueueCompanion(
        status: const Value(UploadStatus.failed),
        lastError: Value(error),
        retryCount: Value(newRetryCount),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// All completed + failed uploads for an entity, for UI display.
  Future<List<UploadJob>> forEntity(
      String entityType, String entityId) async {
    final rows = await (_db.select(_db.uploadQueue)
          ..where((t) =>
              t.entityType.equals(entityType) &
              t.entityId.equals(entityId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return [for (final r in rows) UploadJob.fromRow(r)];
  }

  /// All jobs in the given status. Used for admin review/stats.
  Future<List<UploadJob>> inStatus(String status) async {
    final rows = await (_db.select(_db.uploadQueue)
          ..where((t) => t.status.equals(status))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    return [for (final r in rows) UploadJob.fromRow(r)];
  }

  /// Reset a failed job back to queued for one more try. Clears error
  /// but keeps the retry count honest so a persistently broken upload
  /// eventually stops.
  Future<void> requeue(String id) async {
    await (_db.update(_db.uploadQueue)..where((t) => t.id.equals(id))).write(
      UploadQueueCompanion(
        status: const Value(UploadStatus.queued),
        lastError: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> deleteJob(String id) async {
    await (_db.delete(_db.uploadQueue)..where((t) => t.id.equals(id))).go();
  }
}

final uploadQueueRepositoryProvider =
    Provider<UploadQueueRepository>((ref) {
  return UploadQueueRepository(ref.read(appDatabaseProvider));
});
