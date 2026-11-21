import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/driver_users.dart';
import '../../logistics_reports/logistics_report_rows.dart';

/// A place a driver has already been to on his current job.
class ActiveStop {
  const ActiveStop(this.name, this.at);

  final String name;
  final DateTime? at;
}

/// A driver who is out right now: on a job in progress (delivery, pickup, or a free route) — or, for
/// drivers who ran a free route the older way, on an open trip.
class ActiveDriverRow {
  const ActiveDriverRow({
    required this.driverId,
    required this.name,
    required this.kind,
    required this.startedAt,
    required this.done,
    required this.total,
    required this.visited,
  });

  final String driverId;
  final String name;

  /// Delivery, Pickup, Delivery + pickup, or Free route.
  final String kind;
  final DateTime? startedAt;

  /// Stops done and stops in all (a free route has no fixed total: both are its visits so far).
  final int done;
  final int total;
  final List<ActiveStop> visited;

  bool get isFree => kind == 'Free route';
}

DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// Who is out right now, worked out from the jobs in progress and the drivers' open trips. [driverIds]
/// are the organisation's drivers: only their open trips count (a salesperson's route is not here).
List<ActiveDriverRow> buildActiveDriverRows({
  required List<Map<String, dynamic>> jobs,
  required Map<String, List<Map<String, dynamic>>> stopsByJob,
  required List<Map<String, dynamic>> trips,
  required Map<String, int> visitCountByTrip,
  required Set<String> driverIds,
}) {
  final rows = <ActiveDriverRow>[];
  for (final j in jobs) {
    final stops = [...(stopsByJob['${j['id']}'] ?? const <Map<String, dynamic>>[])]
      ..sort((a, b) => ((a['sequence'] as num?) ?? 0).compareTo((b['sequence'] as num?) ?? 0));
    final doneStops = stops.where((s) => s['status'] == 'delivered' || s['status'] == 'failed').toList();
    final isFree = j['job_type'] == 'free';
    rows.add(ActiveDriverRow(
      driverId: '${j['driver_id']}',
      name: '${j['driver_name'] ?? 'Driver'}',
      kind: jobTypeLabel([for (final s in stops) s['stop_type'] as String?], j['job_type'] as String?),
      startedAt: _dt(j['started_at']),
      done: doneStops.length,
      total: isFree ? doneStops.length : stops.length,
      visited: [for (final s in doneStops) ActiveStop('${s['customer_name'] ?? ''}', _dt(s['delivered_at']))],
    ));
  }
  for (final t in trips) {
    if (!driverIds.contains('${t['user_id']}')) continue;
    final n = visitCountByTrip['${t['id']}'] ?? 0;
    rows.add(ActiveDriverRow(
      driverId: '${t['user_id']}',
      name: '${t['user_name'] ?? 'Driver'}',
      kind: 'Free route',
      startedAt: _dt(t['started_at']),
      done: n,
      total: n,
      visited: const [],
    ));
  }
  rows.sort((a, b) => (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0)));
  return rows;
}

/// How many different drivers are out.
int countActiveDrivers(Iterable<ActiveDriverRow> rows) => {for (final r in rows) r.driverId}.length;

List<List<T>> _chunks<T>(List<T> l, int n) => [for (var i = 0; i < l.length; i += n) l.sublist(i, i + n > l.length ? l.length : i + n)];

/// Loads who is out right now (the dashboard's Active Drivers tile and its list).
Future<List<ActiveDriverRow>> loadActiveDrivers(String orgId) async {
  final db = Supabase.instance.client;
  final driverIds = await loadDriverIds(orgId).catchError((_) => <String>{});
  final jobs = List<Map<String, dynamic>>.from(await db
      .from('deliveries')
      .select('id, driver_id, driver_name, status, job_type, started_at')
      .eq('org_id', orgId)
      .eq('status', 'in_progress')
      .not('driver_id', 'is', null));
  final stopsBy = <String, List<Map<String, dynamic>>>{};
  for (final chunk in _chunks([for (final j in jobs) '${j['id']}'], 100)) {
    final rows = await db.from('delivery_stops').select('delivery_id, stop_type, status, customer_name, delivered_at, sequence').inFilter('delivery_id', chunk);
    for (final r in rows) {
      stopsBy.putIfAbsent('${r['delivery_id']}', () => []).add(Map<String, dynamic>.from(r));
    }
  }
  var trips = <Map<String, dynamic>>[];
  final counts = <String, int>{};
  if (driverIds.isNotEmpty) {
    final all = List<Map<String, dynamic>>.from(await db.from('trips').select('id, user_id, user_name, started_at').eq('org_id', orgId).filter('ended_at', 'is', null));
    trips = [for (final t in all) if (driverIds.contains('${t['user_id']}')) t];
    for (final chunk in _chunks([for (final t in trips) '${t['id']}'], 100)) {
      final rows = await db.from('visits').select('trip_id').inFilter('trip_id', chunk);
      for (final r in rows) {
        counts['${r['trip_id']}'] = (counts['${r['trip_id']}'] ?? 0) + 1;
      }
    }
  }
  return buildActiveDriverRows(jobs: jobs, stopsByJob: stopsBy, trips: trips, visitCountByTrip: counts, driverIds: driverIds);
}

/// The Active Drivers list: one card per driver who is out, expanding to the places he has been to.
class ActiveDriversList extends StatelessWidget {
  const ActiveDriversList({super.key, required this.rows});

  final List<ActiveDriverRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No driver is out right now', style: TextStyle(color: AppTheme.textSecondary))));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final r = rows[i];
        final started = r.startedAt == null ? '' : 'Started ${DateFormat('hh:mm a').format(r.startedAt!)}';
        final progress = r.isFree ? '${r.done} visit${r.done == 1 ? '' : 's'}' : '${r.done} of ${r.total} stops';
        return Container(
          decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.primary.withOpacity(0.1),
                child: const Icon(Icons.local_shipping_outlined, size: 18, color: AppTheme.primary),
              ),
              title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Wrap(spacing: 10, children: [
                Text(r.kind, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                if (started.isNotEmpty) Text(started, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                Text(progress, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ]),
              children: [
                if (r.visited.isEmpty)
                  const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 12), child: Align(alignment: Alignment.centerLeft, child: Text('Nothing marked yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))))
                else
                  for (final v in r.visited)
                    ListTile(
                      dense: true,
                      title: Text(v.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      trailing: Text(v.at == null ? '' : DateFormat('hh:mm a').format(v.at!), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ActiveDriversDialog extends StatefulWidget {
  const _ActiveDriversDialog({required this.orgId});

  final String orgId;

  @override
  State<_ActiveDriversDialog> createState() => _ActiveDriversDialogState();
}

class _ActiveDriversDialogState extends State<_ActiveDriversDialog> {
  bool _loading = true;
  String? _error;
  List<ActiveDriverRow> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await loadActiveDrivers(widget.orgId);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.local_shipping_outlined, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(_loading ? 'Active Drivers' : 'Active Drivers (${countActiveDrivers(_rows)})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          IconButton(icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh', onPressed: () {
            setState(() {
              _loading = true;
              _error = null;
            });
            _load();
          }),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: SelectableText(_error!, style: const TextStyle(color: Color(0xFFDC2626)))))
                : ActiveDriversList(rows: _rows),
      ),
    ]);
  }
}

/// Opens the Active Drivers list.
Future<void> showActiveDriversDialog(BuildContext context, {required String orgId}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: _ActiveDriversDialog(orgId: orgId),
      ),
    ),
  );
}
