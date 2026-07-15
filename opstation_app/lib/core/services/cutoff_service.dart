import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';

/// Reads and writes the org cut-off time. It no longer CLOSES trips.
///
/// Trip auto-close is owned entirely by the server-side `cutoff-trips` Edge
/// Function (pg_cron, every minute), which runs regardless of whether any phone
/// is awake, sees every synced trip, and backdates each trip's `ended_at` to
/// its own Karachi start-day cut-off. Running a second closer on the device
/// raced that function and produced inconsistent end times, so the client sweep
/// was removed. This class now only surfaces the setting to the settings screen;
/// the value lives in app_config ('org.cutoff_time', Karachi local 'HH:mm') and
/// syncs to Supabase, where the server function reads it.
class CutoffService {
  CutoffService(this._ref);
  final Ref _ref;

  AppDatabase get _db => _ref.read(appDatabaseProvider);

  /// Default cut-off if none is configured (11 PM Karachi).
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
}

final cutoffServiceProvider = Provider<CutoffService>((ref) {
  return CutoffService(ref);
});
