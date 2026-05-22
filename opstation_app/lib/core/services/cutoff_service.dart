import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/salesperson/providers/trip_controller.dart';
import '../database/app_database.dart';
import '../database/app_database_provider.dart';

/// Periodically checks the wall clock against the configured cut-off.
/// At or after cut-off local time, any open trip is auto-closed with
/// [TripCloseReason.cutoff].
///
/// The cut-off time is a string in 'HH:mm' local time, stored in app_config
/// under key 'cutoff_time'. Default: '23:00' (11 PM).
///
/// To avoid double-close on the same day, a 'last_cutoff_run' date is
/// stamped in app_config.
class CutoffService {
  CutoffService(this._ref);
  final Ref _ref;

  Timer? _timer;

  AppDatabase get _db => _ref.read(appDatabaseProvider);

  /// Default cut-off if none is configured (11 PM local).
  static const _defaultCutoff = '23:00';

  Future<String> currentCutoff() async {
    // Prefer the new org-settings key; fall back to legacy 'cutoff_time'
    // for pre-Slice-5a databases.
    return await _db.getConfig('org.cutoff_time') ??
        await _db.getConfig('cutoff_time') ??
        _defaultCutoff;
  }

  Future<void> setCutoff(String hhmm) async {
    await _db.setConfig('org.cutoff_time', hhmm);
    await _db.setConfig('cutoff_time', hhmm);
  }

  void start() {
    _timer?.cancel();
    // Tick every minute — cheap enough, catches manual clock changes quickly.
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    // Run once immediately.
    Future.microtask(_tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    final cutoff = await currentCutoff();
    final parts = cutoff.split(':');
    if (parts.length != 2) return;
    final cutH = int.tryParse(parts[0]);
    final cutM = int.tryParse(parts[1]);
    if (cutH == null || cutM == null) return;

    final now = DateTime.now();
    final dayKey =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final lastRun = await _db.getConfig('last_cutoff_run');
    if (lastRun == dayKey) return;

    final past = now.hour > cutH || (now.hour == cutH && now.minute >= cutM);
    if (!past) return;

    await _closeOpenTripsAsCutoff();
    await _db.setConfig('last_cutoff_run', dayKey);

    // Refresh the trip controller so the UI reflects the close — must
    // always run, not only on day rollover.
    await _ref.read(tripControllerProvider.notifier).refreshAfterCutoff();
  }

  Future<void> _closeOpenTripsAsCutoff() async {
    // Drift stores DateTime columns as unix seconds (int), not ISO strings.
    // Use seconds-since-epoch to match the column type so date-range queries
    // (tripsClosedOnLocalDate) return these rows.
    //
    // Note on endLat/endLng: left NULL on cut-off. A cut-off happens at a
    // fixed wall-clock time (e.g. 23:59 local) and the salesperson may be
    // at home / asleep / offline — requesting a GPS fix here would usually
    // fail or return a stale home fix. The PDF renders "Cut-off at HH:MM"
    // without a location for cut-off trips.
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.customStatement(
      "UPDATE trips SET ended_at = ?, close_reason = 'cutoff' WHERE ended_at IS NULL",
      [nowSeconds],
    );
  }
}

final cutoffServiceProvider = Provider<CutoffService>((ref) {
  final svc = CutoffService(ref);
  svc.start();
  ref.onDispose(svc.stop);
  return svc;
});
