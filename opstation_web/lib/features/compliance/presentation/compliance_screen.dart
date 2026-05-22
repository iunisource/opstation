import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../auth/auth_controller.dart';

/// Compliance report — surfaces three classes of anomaly across the
/// last 90 days, scoped to the current user's organization:
///
///   1. No collection in last 3 visits  (verified visits, all amount=0)
///   2. No visit in last 3 routes       (on planned route 3x, never visited)
///   3. Skipped in last 3 routes        (status=skipped on 3 consecutive trips)
///
/// All checks are per-customer. Trip linkage uses
/// visits.trip_id -> trips.id, with sales_route membership inferred
/// from route_stops.
class ComplianceScreen extends ConsumerStatefulWidget {
  const ComplianceScreen({super.key});

  @override
  ConsumerState<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends ConsumerState<ComplianceScreen> {
  static const _border = Color(0xFFE5E7EB);
  static const _muted = Color(0xFF6B7280);
  static const _danger = Color(0xFFDC2626);
  static const _success = Color(0xFF059669);
  static const _zebra = Color(0xFFFAFAFA);

  bool _loading = true;
  String? _error;
  List<_AnomalyRow> _noCollection = [];
  List<_AnomalyRow> _noVisit = [];
  List<_AnomalyRow> _skipped = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      final orgId = auth?.orgId;
      if (orgId == null) {
        setState(() {
          _loading = false;
          _error = 'No organization context';
        });
        return;
      }

      final client = Supabase.instance.client;
      final cutoff = DateTime.now().subtract(const Duration(days: 90));
      final cutoffIso = cutoff.toIso8601String();

      // Stage 1: tables that have org_id (customers, users, trips) —
      // fetched in parallel. visits and route_stops have no org_id
      // column, so we scope them in stage 2 via the ids collected here.
      final stage1 = await Future.wait([
        client
            .from('customers')
            .select('id, code, shop_name')
            .eq('org_id', orgId)
            .eq('is_active', true)
            .limit(10000),
        client
            .from('users')
            .select('id, name')
            .eq('org_id', orgId)
            .limit(5000),
        client
            .from('trips')
            .select('id, route_id, started_at, user_id')
            .eq('org_id', orgId)
            .gte('started_at', cutoffIso)
            .limit(20000),
      ]);
      final customers = (stage1[0] as List).cast<Map<String, dynamic>>();
      final users = (stage1[1] as List).cast<Map<String, dynamic>>();
      final trips = (stage1[2] as List).cast<Map<String, dynamic>>();

      final customerIds =
          customers.map((c) => c['id'] as String).toList();
      final routeIds = trips
          .map((t) => t['route_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      // Stage 2: derived tables, scoped via the org-scoped ids above.
      // Chunked because PostgREST caps unbounded selects at 1000 rows
      // and its query string maxes around 8 KB — both of which bit
      // earlier versions of this screen on orgs with many customers.
      const batchSize = 50;
      final visits = <Map<String, dynamic>>[];
      for (var i = 0; i < customerIds.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, customerIds.length);
        final slice = customerIds.sublist(i, end);
        final batch = await client
            .from('visits')
            .select(
                'id, customer_id, trip_id, amount, status, timestamp, user_id')
            .inFilter('customer_id', slice)
            .gte('timestamp', cutoffIso)
            .limit(5000);
        visits.addAll((batch as List).cast<Map<String, dynamic>>());
      }
      final routeStops = <Map<String, dynamic>>[];
      for (var i = 0; i < routeIds.length; i += batchSize) {
        final end = (i + batchSize).clamp(0, routeIds.length);
        final slice = routeIds.sublist(i, end);
        final batch = await client
            .from('route_stops')
            .select('route_id, customer_id')
            .inFilter('route_id', slice)
            .limit(5000);
        routeStops.addAll((batch as List).cast<Map<String, dynamic>>());
      }

      final userNames = <String, String>{
        for (final u in users)
          (u['id'] as String): ((u['name'] as String?) ?? 'Unknown')
      };

      // customer_id -> set of route_ids
      final routesByCustomer = <String, Set<String>>{};
      for (final rs in routeStops) {
        final rid = rs['route_id'] as String?;
        final cid = rs['customer_id'] as String?;
        if (rid != null && cid != null) {
          routesByCustomer.putIfAbsent(cid, () => <String>{}).add(rid);
        }
      }

      // visits indexed by customer (sorted DESC) and by (trip,customer)
      final visitsByCustomer = <String, List<Map<String, dynamic>>>{};
      final visitByTripCust = <String, Map<String, dynamic>>{};
      for (final v in visits) {
        final cid = v['customer_id'] as String?;
        final tid = v['trip_id'] as String?;
        if (cid != null) {
          visitsByCustomer.putIfAbsent(cid, () => []).add(v);
        }
        if (cid != null && tid != null) {
          visitByTripCust['$tid|$cid'] = v;
        }
      }
      for (final list in visitsByCustomer.values) {
        list.sort((a, b) => (b['timestamp'] as String)
            .compareTo(a['timestamp'] as String));
      }

      // last 3 trips per customer (only trips on a route that includes them)
      final tripsByCustomer = <String, List<Map<String, dynamic>>>{};
      for (final c in customers) {
        final cid = c['id'] as String;
        final rids = routesByCustomer[cid] ?? <String>{};
        if (rids.isEmpty) continue;
        final relevant = trips
            .where((t) => rids.contains(t['route_id'] as String?))
            .toList();
        relevant.sort((a, b) => (b['started_at'] as String)
            .compareTo(a['started_at'] as String));
        tripsByCustomer[cid] = relevant.take(3).toList();
      }

      // Apply triggers
      final noCol = <_AnomalyRow>[];
      final noVis = <_AnomalyRow>[];
      final skipped = <_AnomalyRow>[];

      for (final c in customers) {
        final cid = c['id'] as String;
        final code = (c['code'] as String?) ?? '';
        final name = (c['shop_name'] as String?) ?? '(no name)';

        // Trigger 1
        final verifiedVisits = (visitsByCustomer[cid] ?? const [])
            .where((v) => v['status'] == 'verified')
            .take(3)
            .toList();
        if (verifiedVisits.length == 3) {
          final allZero = verifiedVisits.every((v) {
            final amt = v['amount'];
            return amt == null || (amt is num && amt == 0);
          });
          if (allZero) {
            noCol.add(_AnomalyRow(
              code: code,
              name: name,
              dates: verifiedVisits
                  .map((v) => _fmtDate(v['timestamp'] as String))
                  .toList(),
              salespeople: verifiedVisits
                  .map((v) => userNames[v['user_id']] ?? 'Unknown')
                  .toSet()
                  .toList(),
            ));
          }
        }

        // Triggers 2 & 3
        final recent = tripsByCustomer[cid] ?? const [];
        if (recent.length == 3) {
          int verifiedCount = 0;
          int skippedCount = 0;
          for (final t in recent) {
            final tid = t['id'] as String;
            final v = visitByTripCust['$tid|$cid'];
            final s = v?['status'] as String?;
            if (s == 'verified') verifiedCount++;
            if (s == 'skipped') skippedCount++;
          }
          final dates = recent
              .map((t) => _fmtDate(t['started_at'] as String))
              .toList();
          final people = recent
              .map((t) => userNames[t['user_id']] ?? 'Unknown')
              .toSet()
              .toList();
          if (verifiedCount == 0) {
            noVis.add(_AnomalyRow(
                code: code, name: name, dates: dates, salespeople: people));
          }
          if (skippedCount == 3) {
            skipped.add(_AnomalyRow(
                code: code, name: name, dates: dates, salespeople: people));
          }
        }
      }

      int byName(_AnomalyRow a, _AnomalyRow b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase());
      noCol.sort(byName);
      noVis.sort(byName);
      skipped.sort(byName);

      setState(() {
        _loading = false;
        _noCollection = noCol;
        _noVisit = noVis;
        _skipped = skipped;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  static String _fmtDate(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)}';
    } catch (_) {
      return iso.length >= 10 ? iso.substring(0, 10) : iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Could not load compliance data:\n$_error',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _danger),
                          ),
                        ),
                      )
                    : _content(),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      color: Colors.white,
      child: Row(
        children: [
          const Text('Compliance',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(width: 12),
          const Text('· Last 90 days',
              style: TextStyle(fontSize: 13, color: _muted)),
          const Spacer(),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  Widget _content() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(
            title: 'No Collection in Last 3 Visits',
            description:
                'Verified visits with zero amount, three in a row.',
            rows: _noCollection,
            empty: 'No anomalies — every customer has had non-zero collection.',
          ),
          const SizedBox(height: 20),
          _section(
            title: 'No Visit in Last 3 Routes',
            description:
                'Customer was on the planned route on three trips, but never verified.',
            rows: _noVisit,
            empty: 'No anomalies — every customer is being visited.',
          ),
          const SizedBox(height: 20),
          _section(
            title: 'Skipped in Last 3 Routes',
            description: 'Customer was marked as skipped on three trips in a row.',
            rows: _skipped,
            empty: 'No anomalies — no customer has been skipped repeatedly.',
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    required String description,
    required List<_AnomalyRow> rows,
    required String empty,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: rows.isEmpty
                        ? _success.withOpacity(0.12)
                        : _danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    rows.length.toString(),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: rows.isEmpty ? _success : _danger,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(description,
                style: const TextStyle(fontSize: 12, color: _muted)),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(empty,
                    style: const TextStyle(color: _muted, fontSize: 13)),
              )
            else
              _table(rows),
          ],
        ),
      ),
    );
  }

  Widget _table(List<_AnomalyRow> rows) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: _zebra,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(8),
                topRight: Radius.circular(8),
              ),
            ),
            child: Row(
              children: const [
                SizedBox(width: 110, child: Text('Code', style: _hStyle)),
                Expanded(flex: 3, child: Text('Customer', style: _hStyle)),
                Expanded(flex: 3, child: Text('Last 3 Dates', style: _hStyle)),
                Expanded(flex: 2, child: Text('Salesperson', style: _hStyle)),
              ],
            ),
          ),
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: i.isEven ? Colors.white : _zebra,
                border: const Border(top: BorderSide(color: _border)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(rows[i].code,
                        style:
                            const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(rows[i].name,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(rows[i].dates.join(', '),
                        style: const TextStyle(fontSize: 13, color: _muted)),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(rows[i].salespeople.join(', '),
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static const _hStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: _muted,
  );
}

class _AnomalyRow {
  final String code;
  final String name;
  final List<String> dates;
  final List<String> salespeople;
  _AnomalyRow({
    required this.code,
    required this.name,
    required this.dates,
    required this.salespeople,
  });
}
