import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/salesperson/providers/trip_controller.dart';
import '../database/app_database.dart';
import '../database/app_database_provider.dart';

/// Periodically checks the wall clock against the configured cut-off.
/// Each open trip is auto-closed once ITS OWN start-day cut-off has passed,
/// with [TripCloseReason.cutoff] and `ended_at` backdated to that day — so a
/// trip always ends on the day it began, even if the app was closed at cut-off
/// time and the sweep only runs a day or more later.
///
/// The cut-off time is a string in 'HH:mm' local time, stored in app_config
/// under key 'cutoff_time'. Default: '23:00' (11 PM).
///
/// The sweep is idempotent (it only touches trips whose cut-off is already
/// past and still open), so it can safely run on every tick without a
/// once-per-day guard.
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

    // Close any open trip whose OWN start-day cut-off has already passed,
    // backdated to that day (see _closeOverdueTripsAsCutoff). This runs on
    // every tick rather than only "once, after today's cut-off": a trip left
    // open on a day when the app happened to be closed at cut-off time is then
    // caught up on the next launch and still stamped with its correct day —
    // instead of lingering open and later inheriting whatever day the sweep
    // finally ran on. A trip still inside its own current day stays open.
    final closed = await _closeOverdueTripsAsCutoff(cutH, cutM);

    if (closed > 0) {
      // Refresh the trip controller so the UI reflects the close.
      await _ref.read(tripControllerProvider.notifier).refreshAfterCutoff();
    }
  }

  /// Closes every open trip whose own start-day cut-off has already elapsed,
  /// stamping `ended_at` to that start day's cut-off time — NOT to the moment
  /// this sweep runs. Returns the number of trips closed.
  ///
  /// Why per-trip and backdated: a trip belongs to the day it began and must
  /// end that same day. The previous version set `ended_at = now()` for all
  /// open trips at once, so a trip started before midnight but not swept until
  /// the next morning was stamped with the wrong day (and several stale days'
  /// trips all collapsed onto one timestamp). That misdated close is what put
  /// yesterday's collections under today on the dashboards.
  ///
  /// Note on endLat/endLng: left NULL on cut-off. A cut-off happens at a fixed
  /// wall-clock time and the salesperson may be at home / asleep / offline —
  /// requesting a GPS fix here would usually fail or return a stale home fix.
  /// The PDF renders "Cut-off at HH:MM" without a location for cut-off trips.
  Future<int> _closeOverdueTripsAsCutoff(int cutH, int cutM) async {
    // Drift stores DateTime columns as unix seconds (int), not ISO strings, so
    // we read and write seconds throughout to match the column type (the same
    // representation tripsClosedOnLocalDate / tripsInRangeForUser range-query).
    final rows = await _db
        .customSelect('SELECT id, started_at FROM trips WHERE ended_at IS NULL')
        .get();
    if (rows.isEmpty) return 0;

    final now = DateTime.now();
    final nowSeconds = now.millisecondsSinceEpoch ~/ 1000;
    var closed = 0;

    for (final row in rows) {
      final id = row.read<String>('id');
      final startedSeconds = row.read<int>('started_at');
      final startedAt =
          DateTime.fromMillisecondsSinceEpoch(startedSeconds * 1000);

      // The cut-off instant for THIS trip's own start day.
      final cutoffAt =
          DateTime(startedAt.year, startedAt.month, startedAt.day, cutH, cutM);

      // Still inside its own day's window (cut-off yet to come) => a genuinely
      // open current trip => leave it alone.
      if (cutoffAt.isAfter(now)) continue;

      // Backdate to the start-day cut-off, clamped so the end is never before
      // the start (trip begun after its own cut-off time) nor in the future.
      final endSeconds = (cutoffAt.millisecondsSinceEpoch ~/ 1000)
          .clamp(startedSeconds, nowSeconds);

      await _db.customStatement(
        "UPDATE trips SET ended_at = ?, close_reason = 'cutoff' WHERE id = ?",
        [endSeconds, id],
      );
      closed++;
    }
    return closed;
  }
}

final cutoffServiceProvider = Provider<CutoffService>((ref) {
  final svc = CutoffService(ref);
  svc.start();
  ref.onDispose(svc.stop);
  return svc;
});
