/// The rows of the Logistics Reports page: what each line shows, worked out from the
/// server rows. Kept apart from the page so it can be tested.

class JobRow {
  const JobRow({
    required this.id,
    required this.date,
    required this.driver,
    required this.type,
    required this.stops,
    required this.delivered,
    required this.failed,
    required this.status,
    required this.canReport,
  });

  final String id;
  final DateTime? date;
  final String driver;

  /// Delivery, Pickup or Delivery + pickup.
  final String type;
  final int stops;
  final int delivered;
  final int failed;
  final String status;

  /// A summary can be made once the job has started.
  final bool canReport;
}

class TripRow {
  const TripRow({required this.id, required this.date, required this.driver, required this.route, required this.visits, required this.done});

  final String id;
  final DateTime? date;
  final String driver;
  final String route;
  final int visits;
  final bool done;
}

String deliveryStatusLabel(String? s) {
  switch (s) {
    case 'assigned':
      return 'Assigned';
    case 'in_progress':
      return 'In progress';
    case 'completed':
      return 'Completed';
    case 'cancelled':
      return 'Cancelled';
    case 'draft':
      return 'Draft';
  }
  return s == null || s.isEmpty ? '-' : s;
}

/// Delivery, Pickup, or Delivery + pickup (a job can mix both); falls back to the job's own type
/// when it has no stops.
String jobTypeLabel(Iterable<String?> stopTypes, String? jobType) {
  final types = stopTypes.toList();
  if (types.isEmpty) return jobType == 'pickup' ? 'Pickup' : 'Delivery';
  final pickups = types.where((t) => t == 'pickup').length;
  if (pickups == 0) return 'Delivery';
  if (pickups == types.length) return 'Pickup';
  return 'Delivery + pickup';
}

DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

List<JobRow> buildJobRows(List<Map<String, dynamic>> deliveries, Map<String, List<Map<String, dynamic>>> stopsByDelivery) {
  return [
    for (final d in deliveries)
      () {
        final stops = stopsByDelivery['${d['id']}'] ?? const <Map<String, dynamic>>[];
        final status = '${d['status'] ?? ''}';
        return JobRow(
          id: '${d['id']}',
          date: _dt(d['created_at']),
          driver: '${d['driver_name'] ?? '-'}',
          type: jobTypeLabel([for (final s in stops) s['stop_type'] as String?], d['job_type'] as String?),
          stops: stops.length,
          delivered: stops.where((s) => s['status'] == 'delivered').length,
          failed: stops.where((s) => s['status'] == 'failed').length,
          status: deliveryStatusLabel(status),
          canReport: status == 'in_progress' || status == 'completed' || (status == 'assigned' && stops.any((s) => s['status'] != 'pending')),
        );
      }(),
  ];
}

List<TripRow> buildTripRows(List<Map<String, dynamic>> trips, Map<String, int> visitCounts) {
  return [
    for (final t in trips)
      TripRow(
        id: '${t['id']}',
        date: _dt(t['started_at']),
        driver: '${t['user_name'] ?? '-'}',
        route: '${t['route_name'] ?? '-'}',
        visits: visitCounts['${t['id']}'] ?? 0,
        done: t['ended_at'] != null,
      ),
  ];
}
