import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory stand-in for the real backend.
///
/// Stores received visit payloads keyed by visit id. Supports being taken
/// "offline" from a dev panel to test the sync queue's offline behaviour.
///
/// Replace with a real API client in a later slice — only [syncVisit] needs
/// to change.
class MockSyncServer {
  /// Controlled from the dev panel. When false, all writes fail.
  bool online = true;

  /// Simulated one-way latency.
  Duration latency = const Duration(milliseconds: 350);

  /// Visits the "server" has received, keyed by id.
  final Map<String, Map<String, Object?>> received = {};

  /// If set, the next sync call will fail and clear this (to test retries).
  bool rejectNext = false;

  /// Push a visit payload. Returns true on success.
  Future<bool> syncVisit(Map<String, Object?> payload) async {
    await Future<void>.delayed(latency);
    if (!online) {
      throw const SyncUnreachable();
    }
    if (rejectNext) {
      rejectNext = false;
      throw const SyncRejected('Server rejected this visit.');
    }
    // Simulate a tiny flake rate so retries are exercised in the wild.
    if (math.Random().nextDouble() < 0.0) {
      throw const SyncUnreachable();
    }
    final id = payload['id'] as String;
    received[id] = Map<String, Object?>.from(payload);
    return true;
  }

  int get receivedCount => received.length;
}

class SyncUnreachable implements Exception {
  const SyncUnreachable();
  @override
  String toString() => 'SyncUnreachable: server is offline or unreachable';
}

class SyncRejected implements Exception {
  final String reason;
  const SyncRejected(this.reason);
  @override
  String toString() => 'SyncRejected: $reason';
}

final mockSyncServerProvider = Provider<MockSyncServer>((ref) {
  return MockSyncServer();
});
