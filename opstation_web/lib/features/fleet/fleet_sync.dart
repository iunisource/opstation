/// Keeps the vehicles' kilometres up to date. The database adds each driver's trips and deliveries to the
/// vehicle he drives (the `fleet_sync` function), but only when something asks it to. It used to run only
/// when the Fleet page was opened, so a vehicle profile opened from anywhere else (the Dispatch Dashboard,
/// for one) showed the kilometres as of the last visit to the Fleet page: a job done since was missing.
class FleetSync {
  FleetSync._();

  static final Map<String, DateTime> _last = {};

  /// How long a run stays good for: opening several profiles in a row asks the database once.
  static Duration gap = const Duration(minutes: 2);

  /// Clock and runner can be replaced (tests).
  static DateTime Function() now = DateTime.now;

  static void reset() => _last.clear();

  /// Runs the sync for [org] unless it ran in the last [gap] (or [force]). Returns true when it ran and
  /// the vehicles may have changed. Never throws: a sync that fails (or takes over [limit]) is simply
  /// tried again the next time.
  static Future<bool> ensure(
    String org,
    Future<dynamic> Function(String org) run, {
    bool force = false,
    Duration limit = const Duration(seconds: 25),
  }) async {
    final t = _last[org];
    if (!force && t != null && now().difference(t) < gap) return false;
    _last[org] = now(); // set first, so two profiles opened together do not both ask
    try {
      await run(org).timeout(limit);
      return true;
    } catch (_) {
      _last.remove(org);
      return false;
    }
  }
}
