import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Device connectivity (any non-none network counts as online).
///
/// The actual *reachability* of the sync server is a separate question —
/// SyncController combines this with the mock-server's online flag.
class ConnectivityService {
  final Connectivity _connectivity = Connectivity();

  Stream<bool> watchOnline() async* {
    // Emit initial state.
    yield _hasNet(await _connectivity.checkConnectivity());
    await for (final r in _connectivity.onConnectivityChanged) {
      yield _hasNet(r);
    }
  }

  Future<bool> isOnlineNow() async {
    return _hasNet(await _connectivity.checkConnectivity());
  }

  bool _hasNet(List<ConnectivityResult> r) {
    return r.any((x) => x != ConnectivityResult.none);
  }
}

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});

/// Simple boolean stream of online-ness. UI can watch this directly.
final isOnlineStreamProvider = StreamProvider<bool>((ref) {
  return ref.watch(connectivityServiceProvider).watchOnline();
});
