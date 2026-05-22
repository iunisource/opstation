import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

/// Compliance screen — surfaces three classes of anomaly across the
/// last 90 days, scoped to the current user's organization. Mirrors
/// the web admin panel's logic 1:1.
///
///   1. No collection in last 3 visits  (verified visits, all amount=0)
///   2. No visit in last 3 routes       (on planned route 3x, never visited)
///   3. Skipped in last 3 routes        (status=skipped on 3 consecutive trips)
///
/// Per-customer; trip linkage uses visits.trip_id -> trips.id.
class ComplianceScreen extends ConsumerStatefulWidget {
  const ComplianceScreen({super.key});

  @override
  ConsumerState<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends ConsumerState<ComplianceScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _loading = true;
  String? _error;
  List<_AnomalyRow> _noCollection = [];
  List<_AnomalyRow> _noVisit = [];
  List<_AnomalyRow> _skipped = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      final orgId = auth?.organizationId;
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

      // Stage 1: org-scoped tables (customers, users, trips).
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

      final routesByCustomer = <String, Set<String>>{};
      for (final rs in routeStops) {
        final rid = rs['route_id'] as String?;
        final cid = rs['customer_id'] as String?;
        if (rid != null && cid != null) {
          routesByCustomer.putIfAbsent(cid, () => <String>{}).add(rid);
        }
      }

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

      final noCol = <_AnomalyRow>[];
      final noVis = <_AnomalyRow>[];
      final skipped = <_AnomalyRow>[];

      for (final c in customers) {
        final cid = c['id'] as String;
        final code = (c['code'] as String?) ?? '';
        final name = (c['shop_name'] as String?) ?? '(no name)';

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
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Compliance',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _tab,
            isScrollable: true,
            labelStyle:
                const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            tabs: [
              Tab(text: 'No collection (${_noCollection.length})'),
              Tab(text: 'No visit (${_noVisit.length})'),
              Tab(text: 'Skipped (${_skipped.length})'),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Could not load compliance data:\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: const Color(0xFFF5F6F8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: const Text(
                        'Per customer · Last 90 days',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          _list(_noCollection,
                              empty:
                                  'No anomalies — every customer has had non-zero collection.',
                              caption:
                                  'Verified visits with zero amount, three in a row.'),
                          _list(_noVisit,
                              empty:
                                  'No anomalies — every customer is being visited.',
                              caption:
                                  'On the planned route on three trips, never verified.'),
                          _list(_skipped,
                              empty:
                                  'No anomalies — no customer has been skipped repeatedly.',
                              caption:
                                  'Marked as skipped on three trips in a row.'),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _list(
    List<_AnomalyRow> rows, {
    required String empty,
    required String caption,
  }) {
    return RefreshIndicator(
      onRefresh: () async => _load(),
      child: rows.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 80),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(empty,
                      style: const TextStyle(color: Colors.black54),
                      textAlign: TextAlign.center),
                ),
              ],
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              itemCount: rows.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 4),
                    child: Text(caption,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                  );
                }
                final row = rows[i - 1];
                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: Colors.grey.shade300),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(row.code,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(row.name,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600),
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.event,
                                size: 14, color: Colors.black54),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(row.dates.join(' · '),
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black87)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.person_outline,
                                size: 14, color: Colors.black54),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(row.salespeople.join(', '),
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.black87)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
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
