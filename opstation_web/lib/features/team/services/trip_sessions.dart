/// Turns raw field trips into the "sessions" people actually worked.
///
/// 1. QUICK RESTART → ONE TRIP. When a trip ended with NO activity and the same
///    salesperson started the SAME route again within [restartWindow], both
///    are shown as one trip: start time/place from the first, everything else
///    (end, visits, collections) from the restarted one. E.g. Asim, 14 Oct:
///    10:42–11:02 (0 visits) + 11:02 → … (2 visits) = one trip from 10:42.
/// 2. EMPTY TRIP → ABANDONED. Any other trip that ended with no activity is
///    kept in lists (greyed, "Abandoned") but flagged so totals, averages and
///    trip counts can leave it out.
///
/// Nothing in the database changes — this only shapes what screens/reports
/// show. Each returned row is a COPY of a trip with extra keys:
///   '_trip_ids'  → every underlying trip id (oldest first)
///   '_restarts'  → how many empty trips were folded in
///   '_abandoned' → true for an ended trip with no activity
/// The row keeps the id of the LAST trip in the session; since only empty
/// trips are ever folded in, that trip holds all of the session's visits.
class TripSessions {
  static const restartWindow = Duration(minutes: 15);

  static DateTime? _t(dynamic v) => DateTime.tryParse('${v ?? ''}');

  /// [activity] returns the number of visits (or any activity) for a trip id.
  /// The result keeps the input's order direction (newest-first or oldest-first).
  static List<Map<String, dynamic>> collapse(
    List<Map<String, dynamic>> trips,
    int Function(String tripId) activity,
  ) {
    if (trips.isEmpty) return const [];
    final newestFirst = trips.length > 1 &&
        (_t(trips.first['started_at']) ?? DateTime(0))
            .isAfter(_t(trips.last['started_at']) ?? DateTime(0));

    final sorted = [...trips]..sort((a, b) =>
        (_t(a['started_at']) ?? DateTime(0)).compareTo(_t(b['started_at']) ?? DateTime(0)));

    // Open (still mergeable) session per salesperson + route.
    final open = <String, Map<String, dynamic>>{};
    final out = <Map<String, dynamic>>[];

    for (final raw in sorted) {
      final id = '${raw['id']}';
      final key = '${raw['user_id'] ?? raw['user_name'] ?? ''}|${raw['route_id'] ?? raw['route_name'] ?? ''}';
      final prev = open[key];
      final start = _t(raw['started_at']);
      final prevEnd = prev == null ? null : _t(prev['ended_at']);

      final canMerge = prev != null &&
          prevEnd != null &&
          start != null &&
          activity('${prev['id']}') == 0 &&
          !start.isBefore(prevEnd.subtract(const Duration(minutes: 1))) &&
          start.difference(prevEnd) <= restartWindow;

      if (canMerge) {
        final merged = Map<String, dynamic>.from(raw)
          ..['started_at'] = prev['started_at']
          ..['start_lat'] = prev['start_lat'] ?? raw['start_lat']
          ..['start_lng'] = prev['start_lng'] ?? raw['start_lng']
          ..['_trip_ids'] = [...(prev['_trip_ids'] as List<String>), id]
          ..['_restarts'] = (prev['_restarts'] as int) + 1;
        out[out.indexOf(prev)] = merged;
        open[key] = merged;
      } else {
        final row = Map<String, dynamic>.from(raw)
          ..['_trip_ids'] = <String>[id]
          ..['_restarts'] = 0;
        out.add(row);
        open[key] = row;
      }
    }

    for (final s in out) {
      s['_abandoned'] = s['ended_at'] != null && activity('${s['id']}') == 0;
    }
    return newestFirst ? out.reversed.toList() : out;
  }

  /// Short label for a session, e.g. "Abandoned", "Restarted once".
  static String? note(Map<String, dynamic> s) {
    if (s['_abandoned'] == true) return 'Abandoned — ended with no visits';
    final r = (s['_restarts'] as int?) ?? 0;
    if (r == 1) return 'Restarted once';
    if (r > 1) return 'Restarted $r times';
    return null;
  }
}
