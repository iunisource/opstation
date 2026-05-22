import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/storage_service.dart';
import '../../../core/sync/connectivity_service.dart';
import '../data/upload_queue_repository.dart';

/// Background-polling worker that drains the upload_queue table.
///
/// Lifecycle: started once per app session from `app.dart` via
/// [uploadWorkerStarterProvider]. Not attached to any UI.
///
/// Behavior: every [pollInterval], checks the queue for a due job.
/// If one exists and the device is online, runs it and immediately
/// looks for the next — so when connectivity comes back we drain
/// quickly rather than ticking through one per interval.
class UploadWorker {
  final Ref _ref;
  UploadWorker(this._ref);

  Timer? _timer;
  bool _working = false;

  static const Duration pollInterval = Duration(seconds: 15);
  static const int maxRetries = 5;

  void start() {
    print('UPLOAD WORKER: start() called');
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    // Also try immediately on start (handles photos queued while offline).
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_working) return; // avoid overlapping ticks
    _working = true;
    try {
      final online =
          await _ref.read(connectivityServiceProvider).isOnlineNow();
      if (!online) {
        print('UPLOAD WORKER: tick — offline, skipping');
        return;
      }
      print('UPLOAD WORKER: tick — online, checking queue');
      // Drain loop: keep processing as long as jobs are due AND we stay
      // online. Short-circuits quickly when the queue is empty.
      while (true) {
        final due = await _ref
            .read(uploadQueueRepositoryProvider)
            .nextDue(maxRetry: maxRetries);
        if (due == null) {
          print('UPLOAD WORKER: queue empty, idle');
          break;
        }
        final ok = await _process(due);
        if (!ok) break; // back off and let the next tick retry
      }
    } finally {
      _working = false;
    }
  }

  /// Returns true on success, false on failure (lets the caller stop
  /// draining when the network or server is misbehaving).
  Future<bool> _process(UploadJob job) async {
    final repo = _ref.read(uploadQueueRepositoryProvider);
    final storage = _ref.read(storageServiceProvider);

    final session = Supabase.instance.client.auth.currentSession;
    final user = Supabase.instance.client.auth.currentUser;
    print('UPLOAD WORKER: processing job=${job.id} bucket=${job.bucket} remotePath=${job.remotePath} retry=${job.retryCount}');
    print('UPLOAD WORKER: auth state — session=${session != null ? "present" : "NULL"} user=${user?.id ?? "NULL"} role=${session?.user.role ?? "?"}');

    final file = File(job.localPath);
    if (!file.existsSync()) {
      // Local file is gone — can't recover. Mark failed terminally.
      print('UPLOAD WORKER: file missing for job=${job.id} localPath=${job.localPath}');
      await repo.markFailed(
          job.id, 'Local file not found: ${job.localPath}', maxRetries + 1);
      return true; // done with this one, move on
    }

    try {
      await repo.markUploading(job.id);
      await storage.uploadFile(
        bucket: job.bucket,
        remotePath: job.remotePath,
        file: file,
      );
      print('UPLOAD WORKER: SUCCESS job=${job.id}');
      await repo.markUploaded(job.id);
      return true;
    } catch (e, st) {
      print('UPLOAD WORKER: FAILED job=${job.id} bucket=${job.bucket} remotePath=${job.remotePath}: $e');
      print(st);
      await repo.markFailed(job.id, e.toString(), job.retryCount + 1);
      return false;
    }
  }
}

final uploadWorkerProvider = Provider<UploadWorker>((ref) {
  final w = UploadWorker(ref);
  ref.onDispose(w.stop);
  return w;
});

/// Auto-start provider — read once at app boot to spin up the worker.
/// Keeping the start call behind a separate provider keeps the worker
/// class itself pure and testable.
final uploadWorkerStarterProvider = Provider<void>((ref) {
  ref.read(uploadWorkerProvider).start();
});