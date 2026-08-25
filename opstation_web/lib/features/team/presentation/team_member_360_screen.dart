// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/team_report_pdf.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import 'salesperson_history_screen.dart';

/// Expand a receipt-number field into every slip number it represents.
/// Salespeople routinely staple several slips to one collection and type
/// them into a single visit — "31457 & 31458", "31451 to 31452", or the
/// shorthand "32282 83 84" (= 32282, 32283, 32284, where later tokens drop
/// their leading digits). Reading only the first number made every extra
/// slip look "skipped". This returns all of them so the gap detector is
/// accurate. A plain "31457" returns [31457]; empty/garbage returns [].
List<int> receiptSlipNumbers(String raw) {
  final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
  final out = <int>[];
  int? prevFull;
  for (final t in toks) {
    final n = int.parse(t);
    final prevLen = prevFull?.toString().length ?? 0;
    if (prevFull == null || t.length >= prevLen) {
      out.add(n);
      prevFull = n;
    } else {
      // Shorthand: replace the trailing digits of the previous full number.
      var p10 = 1;
      for (var i = 0; i < t.length; i++) p10 *= 10;
      final expanded = (prevFull - (prevFull % p10)) + n;
      out.add(expanded);
      prevFull = expanded;
    }
  }
  return out;
}

/// 360° profile of a team member: general info, assigned routes, visit
/// history, customer-wise placement audit, competitor spotting, and open
/// tasks on the customers of their routes.
///
/// Attribution rule: an audit/spotting belongs to this member if they
/// surveyed it themselves (surveyed_by_user_id) OR the shop sits on one of
/// their assigned routes.
class TeamMember360Screen extends ConsumerStatefulWidget {
  final Map<String, dynamic> user;
  const TeamMember360Screen({super.key, required this.user});
  @override
  ConsumerState<TeamMember360Screen> createState() =>
      _TeamMember360ScreenState();
}

class _TeamMember360ScreenState extends ConsumerState<TeamMember360Screen> {
  bool _loading = true;
  String? _error;

  // Routes
  List<Map<String, dynamic>> _routes = [];
  final Map<String, int> _routeStopCount = {};
  final Map<String, List<String>> _routeStops = {}; // route_id -> customer ids
  final Set<String> _routeCustomerIds = {};
  final Set<String> _expandedRoutes = {};

  // Customers referenced anywhere (routes, audits, spottings, visits)
  final Map<String, Map<String, dynamic>> _custById = {};

  // Visits (last 30 days)
  List<Map<String, dynamic>> _trips = [];
  int _visitCount = 0;
  int _collected = 0;
  // Individual visit records (every type: verified / outside / no-location /
  // skipped / recorded) so the Visits & Reports tabs can show them all and
  // filter by type. {cid, status, t: DateTime, amount, receipt, trip_id,
  // route_name}
  final List<Map<String, dynamic>> _visitRecords = [];
  // Selected visit-type pill for the Visits / Reports tabs.
  String _visitTypeFilter = 'all';

  // Placement audit: customer_id -> product_id -> latest audit row
  final Map<String, Map<String, Map<String, dynamic>>> _audit = {};
  final Map<String, String> _productNames = {};

  // Competitor spotting: customer_id -> category_id -> latest row
  final Map<String, Map<String, Map<String, dynamic>>> _spot = {};
  final Map<String, String> _categoryNames = {};

  // Tasks (open / in progress) on this member's customers or assigned to them
  List<Map<String, dynamic>> _tasks = [];

  // Raw activity events: visit timestamps (+amounts) and this member's own
  // survey actions — used for the Today/Week/Month strip and the surveyor
  // activity feed.
  final List<Map<String, dynamic>> _visitEvents = []; // {t: DateTime, amount: int}
  final List<Map<String, dynamic>> _surveyEvents = []; // {t, cid, kind: audit|spotting}

  // Activity strip period + Visits/Reports range & search
  String _activityPeriod = 'today'; // today | week | month
  late DateTime _visitsFrom;
  late DateTime _visitsTo;
  final _visitsSearchCtrl = TextEditingController();

  // Placement/Spotting tab UI state
  final _placeSearchCtrl = TextEditingController();
  final _spotSearchCtrl = TextEditingController();
  final Set<String> _expandedPlacement = {};

  @override
  void dispose() {
    _placeSearchCtrl.dispose();
    _spotSearchCtrl.dispose();
    _visitsSearchCtrl.dispose();
    super.dispose();
  }

  bool _matchesCustomer(String cid, String q) {
    return matchesQuery('${_custName(cid)} ${_custCode(cid)}', q);
  }

  Widget _searchBox(TextEditingController ctrl, String hint) => Padding(
        padding: EdgeInsets.fromLTRB(
            context.isMobile ? 12 : 24, 12, context.isMobile ? 12 : 24, 0),
        child: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
            suffixIcon: ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 16),
                    onPressed: () => setState(() => ctrl.clear())),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onChanged: (_) => setState(() {}),
        ),
      );

  String get _uid => widget.user['id'] as String;
  String get _uname => widget.user['name'] as String? ?? '—';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visitsTo = DateTime(now.year, now.month, now.day);
    _visitsFrom = _visitsTo.subtract(const Duration(days: 29));
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final client = Supabase.instance.client;
      _visitEvents.clear();
      _surveyEvents.clear();
      _visitRecords.clear();

      // ── Visits: cover BOTH the last 30 days (for the stat tiles and the
      // Today/Week/Month strip) and the user-selected range, whichever is
      // wider. Tabs filter client-side by the selected range.
      final now = DateTime.now();
      final today0 = DateTime(now.year, now.month, now.day);
      final def30 = today0.subtract(const Duration(days: 30));
      final fetchFrom = _visitsFrom.isBefore(def30) ? _visitsFrom : def30;
      final fetchTo = (_visitsTo.isAfter(today0) ? _visitsTo : today0)
          .add(const Duration(days: 1));

      // ── Kick off every independent fetch concurrently. Each future guards
      // itself so one failure (e.g. a table absent for some roles) leaves the
      // rest intact. Assigning them to variables starts them in parallel; we
      // await below to collect results while the requests run together.
      final assignsFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('route_assignments')
              .select('route_id')
              .eq('user_id', _uid));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      final tripsFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('trips')
              .select()
              .eq('user_id', _uid)
              .gte('started_at', DateFormat('yyyy-MM-dd').format(fetchFrom))
              .lt('started_at', DateFormat('yyyy-MM-dd').format(fetchTo))
              .order('started_at', ascending: false));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      final auditFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('placement_audit')
              .select(
                  'customer_id, product_id, is_present, surveyed_at, surveyed_by_user_id')
              .eq('org_id', orgId)
              .order('surveyed_at', ascending: false)
              .limit(20000));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      final prodsFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('intelligence_products')
              .select('id, name')
              .eq('org_id', orgId));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      final catsFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('competitor_categories')
              .select('id, name')
              .eq('org_id', orgId));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      final actsFut = () async {
        try {
          return List<Map<String, dynamic>>.from(await client
              .from('customer_activities')
              .select('*')
              .eq('org_id', orgId)
              .inFilter('status', ['open', 'in_progress', 'pending'])
              .order('due_date', ascending: true)
              .limit(2000));
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }();
      // Competitor spotting: surveyed_by_user_id may not exist on older DBs.
      final spotFut = () async {
        try {
          return {
            'hasSurveyor': true,
            'rows': List<Map<String, dynamic>>.from(await client
                .from('competitor_spotting')
                .select(
                    'customer_id, category_id, brand_name, price, surveyed_at, surveyed_by_user_id')
                .eq('org_id', orgId)
                .order('surveyed_at', ascending: false)
                .limit(20000)),
          };
        } catch (_) {
          try {
            return {
              'hasSurveyor': false,
              'rows': List<Map<String, dynamic>>.from(await client
                  .from('competitor_spotting')
                  .select(
                      'customer_id, category_id, brand_name, price, surveyed_at')
                  .eq('org_id', orgId)
                  .order('surveyed_at', ascending: false)
                  .limit(20000)),
            };
          } catch (_) {
            return {'hasSurveyor': false, 'rows': <Map<String, dynamic>>[]};
          }
        }
      }();

      // ── Routes assigned to this member (needs assigns) → then stops ──────
      final assigns = await assignsFut;
      final routeIds = [for (final a in assigns) a['route_id'] as String];
      List<Map<String, dynamic>> routes = [];
      _routeStopCount.clear();
      _routeStops.clear();
      _routeCustomerIds.clear();
      if (routeIds.isNotEmpty) {
        final routesFut = () async {
          try {
            return List<Map<String, dynamic>>.from(await client
                .from('sales_routes')
                .select('id, name, kind, is_active')
                .inFilter('id', routeIds)
                .order('name'));
          } catch (_) {
            return <Map<String, dynamic>>[];
          }
        }();
        final stopsFut = () async {
          try {
            return List<Map<String, dynamic>>.from(await client
                .from('route_stops')
                .select('route_id, customer_id')
                .inFilter('route_id', routeIds));
          } catch (_) {
            return <Map<String, dynamic>>[];
          }
        }();
        routes = await routesFut;
        final stops = await stopsFut;
        for (final s in stops) {
          final rid = s['route_id'] as String;
          final cid = s['customer_id'] as String;
          _routeStopCount[rid] = (_routeStopCount[rid] ?? 0) + 1;
          _routeStops.putIfAbsent(rid, () => []).add(cid);
          _routeCustomerIds.add(cid);
        }
      }

      // ── Visits (needs trips) ────────────────────────────────────────────
      final trips = await tripsFut;
      int visitCount = 0, collected = 0;
      if (trips.isNotEmpty) {
        try {
          final routeNameByTrip = <String, String>{
            for (final t in trips)
              t['id'] as String: (t['route_name'] as String?) ?? '—',
          };
          final vRes = await client
              .from('visits')
              .select(
                  'trip_id, amount, customer_id, timestamp, receipt_number, status, captured_lat, captured_lng')
              .inFilter('trip_id', [for (final t in trips) t['id'] as String]);
          final perTrip = <String, int>{};
          final perTripAmt = <String, int>{};
          for (final v in vRes) {
            final tid = v['trip_id'] as String;
            final vt = v['timestamp'] as String?;
            final vdt = vt == null ? null : DateTime.tryParse(vt)?.toLocal();
            if (vdt != null) {
              _visitEvents.add({
                't': vdt,
                'amount': (v['amount'] as int?) ?? 0,
                'receipt': (v['receipt_number'] as String?) ?? '',
                'status': (v['status'] as String?) ?? '',
              });
              _visitRecords.add({
                'cid': v['customer_id'] as String?,
                'status': (v['status'] as String?) ?? '',
                't': vdt,
                'amount': (v['amount'] as int?) ?? 0,
                'receipt': (v['receipt_number'] as String?) ?? '',
                'trip_id': tid,
                'route_name': routeNameByTrip[tid] ?? '—',
                'lat': (v['captured_lat'] as num?)?.toDouble(),
                'lng': (v['captured_lng'] as num?)?.toDouble(),
              });
            }
            perTrip[tid] = (perTrip[tid] ?? 0) + 1;
            perTripAmt[tid] =
                (perTripAmt[tid] ?? 0) + ((v['amount'] as int?) ?? 0);
            visitCount++;
            collected += (v['amount'] as int?) ?? 0;
          }
          for (final t in trips) {
            t['_visits'] = perTrip[t['id']] ?? 0;
            t['_amount'] = perTripAmt[t['id']] ?? 0;
          }
          // Stat tiles stay a fixed 30-day window regardless of the
          // user-selected Visits range.
          visitCount = 0;
          collected = 0;
          for (final e in _visitEvents) {
            if (!(e['t'] as DateTime).isBefore(def30)) {
              visitCount++;
              collected += e['amount'] as int;
            }
          }
        } catch (_) {/* visits table may not exist for some roles */}
      }

      // ── Placement audit (needs _routeCustomerIds for attribution) ───────
      _audit.clear();
      {
        final rows = await auditFut;
        for (final a in rows) {
          final cid = a['customer_id'] as String?;
          final pid = a['product_id'] as String?;
          if (cid == null || pid == null) continue;
          if (a['surveyed_by_user_id'] == _uid) {
            final dt =
                DateTime.tryParse(a['surveyed_at'] as String? ?? '')?.toLocal();
            if (dt != null) {
              _surveyEvents.add({'t': dt, 'cid': cid, 'kind': 'audit'});
            }
          }
          final mine = a['surveyed_by_user_id'] == _uid ||
              _routeCustomerIds.contains(cid);
          if (!mine) continue;
          _audit.putIfAbsent(cid, () => {});
          _audit[cid]!.putIfAbsent(pid, () => Map<String, dynamic>.from(a));
        }
        final prods = await prodsFut;
        _productNames
          ..clear()
          ..addAll({for (final p in prods) p['id'] as String: (p['name'] as String?) ?? '-'});
      }

      // ── Competitor spotting ─────────────────────────────────────────────
      _spot.clear();
      {
        final spotRes = await spotFut;
        final hasSurveyor = spotRes['hasSurveyor'] as bool;
        final rows = spotRes['rows'] as List;
        for (final s in rows) {
          final cid = s['customer_id'] as String?;
          final catId = s['category_id'] as String?;
          if (cid == null || catId == null) continue;
          if (hasSurveyor && s['surveyed_by_user_id'] == _uid) {
            final dt =
                DateTime.tryParse(s['surveyed_at'] as String? ?? '')?.toLocal();
            if (dt != null) {
              _surveyEvents.add({'t': dt, 'cid': cid, 'kind': 'spotting'});
            }
          }
          final mine = (hasSurveyor && s['surveyed_by_user_id'] == _uid) ||
              _routeCustomerIds.contains(cid);
          if (!mine) continue;
          _spot.putIfAbsent(cid, () => {});
          _spot[cid]!.putIfAbsent(catId, () => Map<String, dynamic>.from(s));
        }
        final cats = await catsFut;
        _categoryNames
          ..clear()
          ..addAll({for (final c in cats) c['id'] as String: (c['name'] as String?) ?? '-'});
      }

      // ── Tasks: open activities assigned to member or on their customers ─
      List<Map<String, dynamic>> tasks = [];
      {
        final acts = await actsFut;
        for (final a in acts) {
          final cid = a['customer_id'] as String?;
          final assignee = (a['assigned_to'] ?? a['assignee_id']) as String?;
          if (assignee == _uid || (cid != null && _routeCustomerIds.contains(cid))) {
            tasks.add(Map<String, dynamic>.from(a));
          }
        }
      }

      // ── Customer names for everything we reference ──────────────────────
      final wantedCust = <String>{
        ..._routeCustomerIds,
        ..._audit.keys,
        ..._spot.keys,
        for (final v in _visitRecords)
          if (v['cid'] != null) v['cid'] as String,
        for (final t in tasks)
          if (t['customer_id'] != null) t['customer_id'] as String,
      };
      _custById.clear();
      final ids = wantedCust.toList();
      for (var i = 0; i < ids.length; i += 400) {
        final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        try {
          final rows = await client
              .from('customers')
              .select('id, shop_name, code')
              .inFilter('id', chunk);
          for (final c in rows) {
            _custById[c['id'] as String] = Map<String, dynamic>.from(c);
          }
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _routes = routes;
        _trips = trips;
        _visitCount = visitCount;
        _collected = collected;
        _tasks = tasks;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Aggregates ─────────────────────────────────────────────────────────
  (int found, int checks) get _placementTotals {
    var found = 0, checks = 0;
    _audit.forEach((_, m) {
      m.forEach((_, a) {
        checks++;
        if (a['is_present'] == true) found++;
      });
    });
    return (found, checks);
  }

  int get _spottingCount {
    var n = 0;
    _spot.forEach((_, m) => n += m.length);
    return n;
  }

  String _custName(String? id) =>
      _custById[id]?['shop_name'] as String? ?? '(unknown)';
  String _custCode(String? id) => _custById[id]?['code'] as String? ?? '';

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso);
    return d == null ? '—' : DateFormat('d MMM yyyy').format(d.toLocal());
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isMobile = context.isMobile;
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop()),
          title: Text(_uname,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          actions: [
            IconButton(
                icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
                tooltip: 'Refresh',
                onPressed: _load),
            const SizedBox(width: 8),
          ],
          bottom: TabBar(
            isScrollable: true,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            tabAlignment: TabAlignment.start,
            tabs: const [
              Tab(text: 'Overview'),
              Tab(text: 'Placement'),
              Tab(text: 'Spotting'),
              Tab(text: 'Visits'),
              Tab(text: 'Routes'),
              Tab(text: 'Tasks'),
              Tab(text: 'Reports'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text('Failed to load: $_error',
                        style: const TextStyle(color: AppTheme.danger)))
                : TabBarView(children: [
                    _overviewTab(isMobile),
                    _placementTab(),
                    _spottingTab(),
                    _visitsTab(),
                    _routesTab(),
                    _tasksTab(),
                    _reportsTab(),
                  ]),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
      padding: EdgeInsets.all(context.isMobile ? 12 : 24), child: child);

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: child,
      );

  Widget _statTile(String label, String value, {Color? color}) => Container(
        width: context.isMobile ? (MediaQuery.of(context).size.width - 36) / 2 : 170,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                  letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: color ?? AppTheme.textPrimary)),
        ]),
      );

  // ── Overview ───────────────────────────────────────────────────────────
  Widget _overviewTab(bool isMobile) {
    final u = widget.user;
    final role = u['role'] as String? ?? '';
    final isActive = u['is_active'] as bool? ?? true;
    final (found, checks) = _placementTotals;
    final score = checks == 0 ? null : found / checks;
    return SingleChildScrollView(
      child: _pad(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _card(Row(children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppTheme.primary.withOpacity(0.1),
            child: Text(_uname.isNotEmpty ? _uname[0].toUpperCase() : 'U',
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_uname,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Wrap(spacing: 12, runSpacing: 4, children: [
                _chip(role, AppTheme.primary),
                _chip(isActive ? 'Active' : 'Inactive',
                    isActive ? AppTheme.success : AppTheme.danger),
                if ((u['email'] as String?)?.isNotEmpty == true)
                  Text(u['email'] as String,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                if ((u['phone'] as String?)?.isNotEmpty == true)
                  Text(u['phone'] as String,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
              ]),
            ]),
          ),
        ])),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _statTile('Routes', '${_routes.length}'),
          _statTile('Route shops', '${_routeCustomerIds.length}'),
          _statTile('Trips (30d)', '${_trips.length}'),
          _statTile('Visits (30d)', '$_visitCount'),
          _statTile('Collected (30d)', 'Rs $_collected',
              color: AppTheme.success),
          _statTile(
              'Placement score',
              score == null ? '—' : '${(score * 100).toStringAsFixed(0)}%',
              color: score == null
                  ? null
                  : score >= 0.75
                      ? AppTheme.success
                      : score >= 0.5
                          ? Colors.amber.shade800
                          : AppTheme.danger),
          _statTile('Shelf checks', '$checks'),
          _statTile('Spottings', '$_spottingCount'),
          _statTile('Open tasks', '${_tasks.length}',
              color: _tasks.isEmpty ? null : Colors.orange),
        ]),
        const SizedBox(height: 16),
        _activityCard(),
        if (_visitEvents.isNotEmpty) ...[
          const SizedBox(height: 16),
          _behaviorCard(),
        ],
        const SizedBox(height: 16),
        if (_routes.isNotEmpty)
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('ASSIGNED ROUTES',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final r in _routes)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(8)),
                  child: Text(
                      '${r['name']} · ${_routeStopCount[r['id']] ?? 0} shops',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primary)),
                ),
            ]),
          ])),
      ])),
    );
  }

  // ── Activity: Today / This Week / This Month filter beans ──────────────
  Widget _activityCard() {
    final hasVisits = _visitEvents.isNotEmpty;
    final hasAudits = _surveyEvents.any((e) => e['kind'] == 'audit');
    final hasSpots = _surveyEvents.any((e) => e['kind'] == 'spotting');
    if (!hasVisits && !hasAudits && !hasSpots) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = switch (_activityPeriod) {
      'week' => today.subtract(Duration(days: now.weekday - 1)), // Monday
      'month' => DateTime(now.year, now.month, 1),
      _ => today,
    };

    final visits =
        _visitEvents.where((e) => !(e['t'] as DateTime).isBefore(cutoff)).length;
    final amount = _visitEvents
        .where((e) => !(e['t'] as DateTime).isBefore(cutoff))
        .fold(0, (s, e) => s + (e['amount'] as int));
    int survey(String kind) => _surveyEvents
        .where((e) => e['kind'] == kind && !(e['t'] as DateTime).isBefore(cutoff))
        .length;

    Widget bean(String label, String key) => ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: _activityPeriod == key,
          visualDensity: VisualDensity.compact,
          selectedColor: AppTheme.primary.withOpacity(0.15),
          labelStyle: TextStyle(
              color: _activityPeriod == key
                  ? AppTheme.primary
                  : AppTheme.textSecondary,
              fontWeight:
                  _activityPeriod == key ? FontWeight.w700 : FontWeight.w500),
          onSelected: (_) => setState(() => _activityPeriod = key),
        );

    Widget stat(String label, String value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label.toUpperCase(),
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5)),
            const SizedBox(height: 3),
            Text(value,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: color ?? AppTheme.textPrimary)),
          ],
        );

    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('ACTIVITY',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary,
                letterSpacing: 0.5)),
        const Spacer(),
        bean('Today', 'today'),
        const SizedBox(width: 6),
        bean('This Week', 'week'),
        const SizedBox(width: 6),
        bean('This Month', 'month'),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 28, runSpacing: 12, children: [
        if (hasVisits) stat('Visits', '$visits'),
        if (hasVisits) stat('Collected', 'Rs $amount', color: AppTheme.success),
        if (hasAudits) stat('Shelf checks', '${survey('audit')}'),
        if (hasSpots) stat('Spottings', '${survey('spotting')}'),
      ]),
    ]));
  }

  // ── App-usage behavior ───────────────────────────────────────────────────
  /// A conversational, admin-facing read of HOW this member uses the app —
  /// derived purely from their visit records. Surfaces the patterns we used
  /// to hunt collection gaps by hand: GPS-verified vs recorded-away-from-shop,
  /// live entry vs after-hours bulk typing, and skipped receipt numbers.
  Widget _behaviorCard() {
    final ev = _visitEvents;
    final total = ev.length;
    if (total == 0) return const SizedBox.shrink();

    // GPS quality — verified out of visits where a location was attempted.
    // A skipped shop is a single tap (not a mark-visit event), so it is excluded
    // from the bulk / after-hours reads and reported on its own line instead.
    int verified = 0, located = 0, afterHours = 0, skippedVisits = 0;
    final times = <DateTime>[]; // actual visits only (skips excluded from bulk)
    for (final e in ev) {
      final st = (e['status'] as String?) ?? '';
      final isSkipped = st == 'skipped';
      if (isSkipped) skippedVisits++;
      if (st == 'verified') {
        verified++;
        located++;
      } else if (st == 'outside' || st == 'noLocation') {
        located++;
      }
      final t = e['t'] as DateTime;
      if (!isSkipped) {
        times.add(t);
        if (t.hour >= 20 || t.hour < 6) afterHours++;
      }
    }
    final realVisits = total - skippedVisits;
    final verifiedPct = located == 0 ? null : (verified / located * 100);

    // Burst entry: ACTUAL visits logged within 90s of the previous one.
    times.sort();
    int burst = 0;
    for (var i = 1; i < times.length; i++) {
      if (times[i].difference(times[i - 1]).inSeconds.abs() < 90) burst++;
    }
    final burstPct = times.length < 2 ? 0.0 : burst / (times.length - 1) * 100;

    // Receipt gaps — skips in sequence, ignoring big jumps (= new book).
    final nums = <int>[];
    for (final e in ev) {
      nums.addAll(receiptSlipNumbers((e['receipt'] as String?) ?? ''));
    }
    nums.sort();
    final missing = <int>[];
    for (var i = 1; i < nums.length; i++) {
      final gap = nums[i] - nums[i - 1];
      if (gap > 1 && gap <= 20) {
        for (var n = nums[i - 1] + 1; n < nums[i]; n++) missing.add(n);
      }
    }
    final skipped = missing.length;

    // Recency & active days.
    final now = DateTime.now();
    DateTime? last;
    final days = <String>{};
    for (final e in ev) {
      final t = e['t'] as DateTime;
      if (last == null || t.isAfter(last)) last = t;
      days.add('${t.year}-${t.month}-${t.day}');
    }
    final daysSince = last == null ? null : now.difference(last).inDays;

    final amber = Colors.amber.shade800;
    // 4th element = skipped receipt numbers to reveal via "View Receipts" (null = no action).
    final notes = <(IconData, Color, String, List<int>?)>[];
    if (verifiedPct != null) {
      if (verifiedPct >= 70) {
        notes.add((Icons.verified, AppTheme.success,
            '${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified at the shop — locations are trustworthy.', null));
      } else if (verifiedPct >= 40) {
        notes.add((Icons.location_searching, amber,
            'Only ${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified — many are logged outside the shop geofence.', null));
      } else {
        notes.add((Icons.location_off, AppTheme.danger,
            'Just ${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified — most are recorded away from the shop, so locations can\'t be trusted.', null));
      }
    }
    if (burstPct >= 40) {
      notes.add((Icons.bolt, AppTheme.danger,
          'Often logs in bulk — ${burstPct.toStringAsFixed(0)}% of actual visits are entered within 90 seconds of the previous one, a sign of after-the-fact entry rather than live at each shop.', null));
    }
    if (skippedVisits > 0) {
      notes.add((Icons.skip_next, amber,
          'Skipped $skippedVisits of $total shops on the route — marked skipped, not visited.', null));
    }
    if (afterHours > 0 && realVisits > 0 && afterHours / realVisits >= 0.3) {
      notes.add((Icons.nightlight_round, amber,
          '$afterHours of $realVisits visits were entered late at night (after 8 PM) — suggesting a day\'s collections keyed in one sitting.', null));
    }
    if (skipped > 0) {
      notes.add((Icons.receipt_long, amber,
          '$skipped receipt number${skipped == 1 ? '' : 's'} skipped in sequence — collections may have been made but not entered.', missing));
    } else if (nums.length >= 3) {
      notes.add((Icons.receipt_long, AppTheme.success,
          'Receipt numbers run in clean sequence — no obvious missed entries.', null));
    }
    if (daysSince != null && daysSince >= 3) {
      notes.add((Icons.event_busy, Colors.orange,
          'No visits entered in the last $daysSince days — the newest visit on record is $daysSince days old, so nothing has been logged since.', null));
    }
    if (notes.isEmpty) {
      notes.add((Icons.thumb_up, AppTheme.success,
          'Records visits live at the shop with receipts in order — good app discipline.', null));
    }

    final concerns = notes.where((n) => n.$2 == AppTheme.danger).length;
    final warns =
        notes.where((n) => n.$2 == amber || n.$2 == Colors.orange).length;
    final (IconData, Color, String) head = concerns > 0
        ? (Icons.warning_amber_rounded, AppTheme.danger, 'Needs attention')
        : warns > 0
            ? (Icons.info_outline, amber, 'A few habits to watch')
            : (Icons.check_circle, AppTheme.success, 'Healthy app usage');

    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('HOW THEY USE THE APP',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary,
                letterSpacing: 0.5)),
        const Spacer(),
        Icon(head.$1, size: 16, color: head.$2),
        const SizedBox(width: 4),
        Text(head.$3,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: head.$2)),
      ]),
      const SizedBox(height: 4),
      Text(
          'Based on $total recent visit records${daysSince != null ? ' · last entry ${daysSince == 0 ? 'today' : '$daysSince d ago'}' : ''} · active on ${days.length} day${days.length == 1 ? '' : 's'}',
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      for (final n in notes) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(n.$1, size: 16, color: n.$2),
          const SizedBox(width: 8),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.$3, style: const TextStyle(fontSize: 13, height: 1.35)),
            if (n.$4 != null && n.$4!.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _showSkippedReceipts(n.$4!),
                  icon: const Icon(Icons.visibility_outlined, size: 15),
                  label: const Text('View Receipts', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
              ),
          ])),
        ]),
        const SizedBox(height: 8),
      ],
    ]));
  }

  // Lists the receipt numbers missing from this member's sequence so an admin
  // can physically check whether a collection was made but never entered.
  void _showSkippedReceipts(List<int> missing) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.receipt_long, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text('${missing.length} skipped receipt${missing.length == 1 ? '' : 's'}'),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'These receipt numbers fall between ones this person entered but were never logged. Check the physical books — a gap can mean a collection was made but not entered (or a voided/torn slip).',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final n in missing)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          border: Border.all(color: Colors.amber.shade300),
                          borderRadius: BorderRadius.circular(4)),
                      child: Text('$n', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                ]),
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _chip(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );

  // ── Placement tab: customer-wise score (searchable, expandable) ────────
  Widget _placementTab() {
    if (_audit.isEmpty) {
      return const Center(
          child: Text('No placement audits attributed to this member.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    final q = _placeSearchCtrl.text.trim().toLowerCase();
    final rows = <Map<String, dynamic>>[];
    _audit.forEach((cid, m) {
      if (!_matchesCustomer(cid, q)) return;
      var present = 0;
      String? last;
      m.forEach((_, a) {
        if (a['is_present'] == true) present++;
        final s = a['surveyed_at'] as String?;
        if (s != null && (last == null || s.compareTo(last!) > 0)) last = s;
      });
      rows.add({
        'cid': cid,
        'present': present,
        'total': m.length,
        'last': last,
      });
    });
    rows.sort((a, b) {
      final sa = (a['present'] as int) / (a['total'] as int);
      final sb = (b['present'] as int) / (b['total'] as int);
      return sb.compareTo(sa);
    });
    return Column(children: [
      _searchBox(_placeSearchCtrl, 'Search shop name or code...'),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No shops match your search.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                padding: EdgeInsets.all(context.isMobile ? 12 : 24),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final r = rows[i];
                  final cid = r['cid'] as String;
                  final score = (r['present'] as int) / (r['total'] as int);
                  final color = score >= 0.75
                      ? AppTheme.success
                      : score >= 0.5
                          ? Colors.amber.shade800
                          : AppTheme.danger;
                  final expanded = _expandedPlacement.contains(cid);
                  // Per-SKU detail rows, sorted: missing first, then by name.
                  final skus = _audit[cid]!.entries.toList()
                    ..sort((a, b) {
                      final pa = a.value['is_present'] == true ? 1 : 0;
                      final pb = b.value['is_present'] == true ? 1 : 0;
                      if (pa != pb) return pa.compareTo(pb);
                      return (_productNames[a.key] ?? '')
                          .compareTo(_productNames[b.key] ?? '');
                    });
                  return _card(Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => setState(() {
                            if (expanded) {
                              _expandedPlacement.remove(cid);
                            } else {
                              _expandedPlacement.add(cid);
                            }
                          }),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(_custName(cid),
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14)),
                                          Text(
                                              '${_custCode(cid)}${r['last'] != null ? ' · last audit ${_fmtDate(r['last'] as String?)}' : ''}',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      AppTheme.textSecondary)),
                                        ]),
                                  ),
                                  Text('${r['present']}/${r['total']}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 10),
                                  Text('${(score * 100).toStringAsFixed(0)}%',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w800,
                                          color: color)),
                                  const SizedBox(width: 6),
                                  Icon(
                                      expanded
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 20,
                                      color: AppTheme.textSecondary),
                                ]),
                                const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: score,
                                    minHeight: 6,
                                    backgroundColor: color.withOpacity(0.12),
                                    valueColor:
                                        AlwaysStoppedAnimation<Color>(color),
                                  ),
                                ),
                              ]),
                        ),
                        if (expanded) ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 14,
                            runSpacing: 6,
                            children: [
                              for (final e in skus)
                                SizedBox(
                                  width: context.isMobile
                                      ? double.infinity
                                      : 320,
                                  child: Row(children: [
                                    Icon(
                                        e.value['is_present'] == true
                                            ? Icons.check_circle
                                            : Icons.cancel,
                                        size: 16,
                                        color: e.value['is_present'] == true
                                            ? AppTheme.success
                                            : AppTheme.danger),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                          _productNames[e.key] ?? e.key,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w600,
                                              color: e.value['is_present'] ==
                                                      true
                                                  ? AppTheme.textPrimary
                                                  : AppTheme.danger)),
                                    ),
                                    Text(
                                        _fmtDate(e.value['surveyed_at']
                                            as String?),
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            color: AppTheme.textSecondary)),
                                  ]),
                                ),
                            ],
                          ),
                        ],
                      ]));
                },
              ),
      ),
    ]);
  }

  // ── Spotting tab ───────────────────────────────────────────────────────
  Widget _spottingTab() {
    if (_spot.isEmpty) {
      return const Center(
          child: Text('No competitor spottings attributed to this member.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    final q = _spotSearchCtrl.text.trim().toLowerCase();
    final cids = _spot.keys.where((cid) => _matchesCustomer(cid, q)).toList()
      ..sort((a, b) => _custName(a).compareTo(_custName(b)));
    return Column(children: [
      _searchBox(_spotSearchCtrl, 'Search shop name or code...'),
      Expanded(
        child: cids.isEmpty
            ? const Center(
                child: Text('No shops match your search.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
      padding: EdgeInsets.all(context.isMobile ? 12 : 24),
      itemCount: cids.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final cid = cids[i];
        final byCat = _spot[cid]!;
        return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${_custName(cid)}  ${_custCode(cid)}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in byCat.entries)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: AppTheme.primary.withOpacity(0.2))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_categoryNames[e.key] ?? '-',
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.textSecondary)),
                      Text(
                          '${e.value['brand_name'] ?? '-'}${e.value['price'] != null ? ' · Rs ${e.value['price']}' : ''}',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primary)),
                    ]),
              ),
          ]),
        ]));
      },
    ),
      ),
    ]);
  }

  // ── Shared range + search filtering for Visits/Reports ─────────────────
  bool _inVisitRange(DateTime t) {
    final d = DateTime(t.year, t.month, t.day);
    return !d.isBefore(_visitsFrom) && !d.isAfter(_visitsTo);
  }

  List<Map<String, dynamic>> _tripsFiltered() {
    final q = _visitsSearchCtrl.text.trim().toLowerCase();
    return _trips.where((t) {
      final s = DateTime.tryParse(t['started_at'] as String? ?? '')?.toLocal();
      if (s == null || !_inVisitRange(s)) return false;
      if (q.isNotEmpty && !matchesQuery('${t['route_name'] ?? ''}', q)) {
        return false;
      }
      return true;
    }).toList();
  }

  List<Map<String, dynamic>> _surveyEventsFiltered() {
    final q = _visitsSearchCtrl.text.trim().toLowerCase();
    return _surveyEvents.where((e) {
      if (!_inVisitRange(e['t'] as DateTime)) return false;
      if (q.isNotEmpty && !_matchesCustomer(e['cid'] as String, q)) return false;
      return true;
    }).toList();
  }

  // ── Visit-type buckets (verified / outside / no-location / skipped /
  // recorded). Used by the Visits & Reports tabs to show every visit type
  // and to power the filter pills.
  static String _visitTypeKey(String status) {
    switch (status) {
      case 'verified':
        return 'verified';
      case 'outside':
        return 'outside';
      case 'noLocation':
        return 'noLocation';
      case 'skipped':
        return 'skipped';
      default:
        return 'recorded';
    }
  }

  static const List<String> _visitTypeOrder = [
    'verified',
    'outside',
    'noLocation',
    'skipped',
    'recorded',
  ];

  (String, Color, IconData) _visitTypeMeta(String key) {
    switch (key) {
      case 'verified':
        return ('Verified', AppTheme.success, Icons.verified_outlined);
      case 'outside':
        return ('Outside geofence', Colors.amber.shade800,
            Icons.location_searching);
      case 'noLocation':
        return ('No location', AppTheme.danger, Icons.location_off_outlined);
      case 'skipped':
        return ('Skipped', Colors.orange, Icons.skip_next_outlined);
      default:
        return ('Recorded', AppTheme.textSecondary, Icons.store_outlined);
    }
  }

  /// Visit records inside the selected date range + search, BEFORE the
  /// visit-type pill filter (so pill counts reflect the full range).
  List<Map<String, dynamic>> _visitRecordsInRange() {
    final q = _visitsSearchCtrl.text.trim().toLowerCase();
    return _visitRecords.where((v) {
      if (!_inVisitRange(v['t'] as DateTime)) return false;
      if (q.isNotEmpty) {
        final cid = v['cid'] as String?;
        final hay =
            '${_custName(cid)} ${_custCode(cid)} ${v['route_name'] ?? ''}';
        if (!matchesQuery(hay, q)) return false;
      }
      return true;
    }).toList();
  }

  /// Apply the current visit-type pill to a range-filtered list.
  List<Map<String, dynamic>> _applyVisitTypeFilter(
      List<Map<String, dynamic>> records) {
    if (_visitTypeFilter == 'all') return records;
    return records
        .where((v) =>
            _visitTypeKey((v['status'] as String?) ?? '') == _visitTypeFilter)
        .toList();
  }

  Map<String, int> _visitTypeCounts(List<Map<String, dynamic>> records) {
    final m = <String, int>{};
    for (final v in records) {
      final k = _visitTypeKey((v['status'] as String?) ?? '');
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  /// Filter pill row: All + one pill per visit-type present in the range.
  Widget _visitTypePills(List<Map<String, dynamic>> rangeRecords) {
    final counts = _visitTypeCounts(rangeRecords);
    final total = rangeRecords.length;

    Widget pill(String key, String label, int count, Color color) {
      final selected = _visitTypeFilter == key;
      return Padding(
        padding: const EdgeInsets.only(right: 6, bottom: 6),
        child: ChoiceChip(
          label: Text('$label · $count', style: const TextStyle(fontSize: 12)),
          selected: selected,
          visualDensity: VisualDensity.compact,
          selectedColor: color.withOpacity(0.15),
          backgroundColor: Colors.white,
          side: BorderSide(
              color: selected ? color : AppTheme.border,
              width: selected ? 1.4 : 1),
          labelStyle: TextStyle(
              color: selected ? color : AppTheme.textSecondary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
          onSelected: (_) => setState(() => _visitTypeFilter = key),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.isMobile ? 12 : 24, 10, context.isMobile ? 12 : 24, 0),
      child: Wrap(children: [
        pill('all', 'All', total, AppTheme.primary),
        for (final key in _visitTypeOrder)
          if ((counts[key] ?? 0) > 0)
            pill(key, _visitTypeMeta(key).$1, counts[key]!,
                _visitTypeMeta(key).$2),
      ]),
    );
  }

  /// One visit row for the Visits tab (shop, type badge, time, amount).
  /// Outside-geofence and no-location visits also surface the captured GPS
  /// coordinates as a clickable link that opens the spot in Google Maps —
  /// so an admin can see exactly where the entry was actually made.
  Widget _visitRecordCard(Map<String, dynamic> v) {
    final cid = v['cid'] as String?;
    final key = _visitTypeKey((v['status'] as String?) ?? '');
    final (label, color, icon) = _visitTypeMeta(key);
    final t = v['t'] as DateTime;
    final amount = (v['amount'] as int?) ?? 0;
    final lat = v['lat'] as double?;
    final lng = v['lng'] as double?;
    final showCoords = key == 'outside' || key == 'noLocation';
    return _card(Row(children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_custName(cid),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 2),
          Text(
              '${_custCode(cid).isNotEmpty ? '${_custCode(cid)} · ' : ''}${v['route_name'] ?? '—'} · ${DateFormat('d MMM yyyy · HH:mm').format(t)}',
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
          if (showCoords) ...[
            const SizedBox(height: 3),
            if (lat != null && lng != null)
              InkWell(
                onTap: () => html.window.open(
                    'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
                    '_blank'),
                borderRadius: BorderRadius.circular(4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.place_outlined, size: 13, color: color),
                  const SizedBox(width: 3),
                  Text(
                      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: color,
                          decoration: TextDecoration.underline,
                          decorationColor: color)),
                  const SizedBox(width: 3),
                  Icon(Icons.open_in_new, size: 11, color: color),
                ]),
              )
            else
              const Text('No coordinates recorded',
                  style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: AppTheme.textSecondary)),
          ],
        ]),
      ),
      const SizedBox(width: 8),
      _chip(label, color),
      const SizedBox(width: 10),
      Text(amount > 0 ? 'Rs $amount' : '—',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: amount > 0 ? AppTheme.success : AppTheme.textSecondary)),
    ]));
  }

  Future<void> _pickVisitsDate(bool isFrom) async {
    final p = await showDatePicker(
        context: context,
        initialDate: isFrom ? _visitsFrom : _visitsTo,
        firstDate: DateTime(2024, 1, 1),
        lastDate: DateTime.now());
    if (p == null) return;
    setState(() {
      if (isFrom) {
        _visitsFrom = DateTime(p.year, p.month, p.day);
        if (_visitsTo.isBefore(_visitsFrom)) _visitsTo = _visitsFrom;
      } else {
        _visitsTo = DateTime(p.year, p.month, p.day);
        if (_visitsFrom.isAfter(_visitsTo)) _visitsFrom = _visitsTo;
      }
    });
    _load(); // refetch in case the range extends beyond the loaded window
  }

  Widget _rangeSearchBar(String searchHint) {
    final df = DateFormat('d MMM yy');
    Widget chip(String label, DateTime d, bool isFrom) => InkWell(
          onTap: () => _pickVisitsDate(isFrom),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: AppTheme.border),
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('$label: ',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
              Text(df.format(d),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Icon(Icons.calendar_today_outlined,
                  size: 13, color: AppTheme.textSecondary),
            ]),
          ),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.isMobile ? 12 : 24, 12, context.isMobile ? 12 : 24, 0),
      child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            chip('From', _visitsFrom, true),
            chip('To', _visitsTo, false),
            SizedBox(
              width: context.isMobile ? double.infinity : 280,
              child: TextField(
                controller: _visitsSearchCtrl,
                decoration: InputDecoration(
                  hintText: searchHint,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  suffixIcon: _visitsSearchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () =>
                              setState(() => _visitsSearchCtrl.clear())),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
    );
  }

  // ── Visits tab ─────────────────────────────────────────────────────────
  Widget _visitsTab() {
    // Surveyors don't run trips — show their field activity (audits +
    // spottings per shop, day by day) instead. Also used for any member with
    // no trips but survey activity.
    final isSurveyor = (widget.user['role'] as String?) == 'surveyor';
    if (isSurveyor || (_trips.isEmpty && _surveyEvents.isNotEmpty)) {
      return _surveyActivityFeed();
    }
    final inRange = _visitRecordsInRange()
      ..sort((a, b) => (b['t'] as DateTime).compareTo(a['t'] as DateTime));
    final shown = _applyVisitTypeFilter(inRange);
    final fCollected =
        shown.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));
    return Column(children: [
      _rangeSearchBar('Search shop, code or route...'),
      _visitTypePills(inRange),
      Padding(
        padding: EdgeInsets.fromLTRB(
            context.isMobile ? 12 : 24, 8, context.isMobile ? 12 : 24, 0),
        child: Row(children: [
          Expanded(
            child: Text('${shown.length} visits · Rs $fCollected collected',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SalespersonHistoryScreen(
                    userId: _uid, userName: _uname))),
            icon: const Icon(Icons.history, size: 16),
            label: const Text('Full history'),
          ),
        ]),
      ),
      Expanded(
        child: shown.isEmpty
            ? const Center(
                child: Text('No visits match this range/type/search.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                padding: EdgeInsets.all(context.isMobile ? 12 : 24),
                itemCount: shown.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _visitRecordCard(shown[i]),
              ),
      ),
    ]);
  }

  // ── Surveyor field-activity feed ───────────────────────────────────────
  Widget _surveyActivityFeed() {
    final events = _surveyEventsFiltered();
    // day -> customer -> {audits, spottings, first, last}
    final byDay = <String, Map<String, Map<String, dynamic>>>{};
    for (final e in events) {
      final t = e['t'] as DateTime;
      final day = DateFormat('yyyy-MM-dd').format(t);
      final cid = e['cid'] as String;
      final m = byDay.putIfAbsent(day, () => {}).putIfAbsent(
          cid, () => {'audits': 0, 'spottings': 0, 'first': t, 'last': t});
      if (e['kind'] == 'audit') {
        m['audits'] = (m['audits'] as int) + 1;
      } else {
        m['spottings'] = (m['spottings'] as int) + 1;
      }
      if (t.isBefore(m['first'] as DateTime)) m['first'] = t;
      if (t.isAfter(m['last'] as DateTime)) m['last'] = t;
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final tf = DateFormat('HH:mm');
    return Column(children: [
      _rangeSearchBar('Search shop name or code...'),
      Expanded(
        child: events.isEmpty
            ? const Center(
                child: Text('No field activity in this range/search.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView(
      padding: EdgeInsets.all(context.isMobile ? 12 : 24),
      children: [
        for (final d in days) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 4),
            child: Text(
                '${DateFormat('EEEE, d MMM yyyy').format(DateTime.parse(d))} · ${byDay[d]!.length} shops',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary)),
          ),
          for (final entry in (byDay[d]!.entries.toList()
            ..sort((a, b) => (a.value['first'] as DateTime)
                .compareTo(b.value['first'] as DateTime))))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _card(Row(children: [
                const Icon(Icons.fact_check_outlined,
                    size: 18, color: AppTheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_custName(entry.key),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13)),
                        Text(
                            '${_custCode(entry.key)} · ${tf.format(entry.value['first'] as DateTime)}'
                            '${entry.value['first'] != entry.value['last'] ? ' – ${tf.format(entry.value['last'] as DateTime)}' : ''}',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSecondary)),
                      ]),
                ),
                if ((entry.value['audits'] as int) > 0)
                  _chip('${entry.value['audits']} shelf checks',
                      AppTheme.success),
                if ((entry.value['spottings'] as int) > 0) ...[
                  const SizedBox(width: 6),
                  _chip('${entry.value['spottings']} spottings',
                      AppTheme.primary),
                ],
              ])),
            ),
          const SizedBox(height: 8),
        ],
      ],
    ),
      ),
    ]);
  }

  // ── Reports tab ────────────────────────────────────────────────────────
  bool get _isSurveyMode =>
      (widget.user['role'] as String?) == 'surveyor' ||
      (_trips.isEmpty && _surveyEvents.isNotEmpty);

  String _tripStatus(Map<String, dynamic> t) {
    if (t['ended_at'] == null) return 'Active';
    return (t['close_reason'] as String?) == 'cutoff' ? 'Cutoff' : 'Completed';
  }

  /// Per-day survey summary rows for the surveyor report:
  /// [{day, shops, audits, spottings}] sorted desc.
  List<Map<String, dynamic>> _surveyDayRows() {
    final byDay = <String, Map<String, dynamic>>{};
    for (final e in _surveyEventsFiltered()) {
      final day = DateFormat('yyyy-MM-dd').format(e['t'] as DateTime);
      final m = byDay.putIfAbsent(
          day, () => {'day': day, 'shops': <String>{}, 'audits': 0, 'spottings': 0});
      (m['shops'] as Set<String>).add(e['cid'] as String);
      if (e['kind'] == 'audit') {
        m['audits'] = (m['audits'] as int) + 1;
      } else {
        m['spottings'] = (m['spottings'] as int) + 1;
      }
    }
    final rows = byDay.values.toList()
      ..sort((a, b) => (b['day'] as String).compareTo(a['day'] as String));
    return rows;
  }

  Widget _reportsTab() {
    final isSurvey = _isSurveyMode;
    final df = DateFormat('d MMM yyyy');
    // Salesperson reports gain the visit-type pills so every visit type
    // (verified / outside / no-location / skipped / recorded) is reportable.
    final inRange = isSurvey ? const <Map<String, dynamic>>[] : _visitRecordsInRange();
    final byType = !isSurvey && _visitTypeFilter != 'all';
    return Column(children: [
      _rangeSearchBar(
          isSurvey ? 'Search shop name or code...' : 'Search shop, code or route...'),
      if (!isSurvey) _visitTypePills(inRange),
      Padding(
        padding: EdgeInsets.fromLTRB(
            context.isMobile ? 12 : 24, 10, context.isMobile ? 12 : 24, 0),
        child: Row(children: [
          Expanded(
            child: Text(
                '${df.format(_visitsFrom)} – ${df.format(_visitsTo)}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          OutlinedButton.icon(
            onPressed: _printReport,
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Print / PDF'),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Expanded(
          child: isSurvey
              ? _surveyReportTable()
              : byType
                  ? _visitTypeReportTable(_applyVisitTypeFilter(inRange))
                  : _tripReportTable()),
    ]);
  }

  /// Visit-level report table shown in the Reports tab when a specific visit
  /// type is selected via the pills (Date · Shop · Type · Collected).
  Widget _visitTypeReportTable(List<Map<String, dynamic>> records) {
    if (records.isEmpty) {
      return const Center(
          child: Text('No visits of this type in this range.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    final sorted = List<Map<String, dynamic>>.from(records)
      ..sort((a, b) => (b['t'] as DateTime).compareTo(a['t'] as DateTime));
    final totAmt =
        sorted.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));
    final df = DateFormat('d MMM yyyy');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.isMobile ? 12 : 24, 0, context.isMobile ? 12 : 24, 16),
      child: Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
            child: Row(children: [
              _reportHeaderCell('Date', flex: 2),
              _reportHeaderCell('Shop', flex: 4),
              _reportHeaderCell('Type', flex: 2),
              _reportHeaderCell('Collected', flex: 2, align: TextAlign.right),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: sorted.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final v = sorted[i];
                final cid = v['cid'] as String?;
                final (label, color, _) =
                    _visitTypeMeta(_visitTypeKey((v['status'] as String?) ?? ''));
                final amount = (v['amount'] as int?) ?? 0;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(
                        flex: 2,
                        child: Text(df.format(v['t'] as DateTime),
                            style: const TextStyle(fontSize: 12.5))),
                    Expanded(
                        flex: 4,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_custName(cid),
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600)),
                              if (_custCode(cid).isNotEmpty)
                                Text(_custCode(cid),
                                    style: const TextStyle(
                                        fontSize: 10.5,
                                        color: AppTheme.textSecondary)),
                            ])),
                    Expanded(
                        flex: 2,
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: color))),
                    Expanded(
                        flex: 2,
                        child: Text(amount > 0 ? 'Rs $amount' : '—',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: amount > 0
                                    ? AppTheme.success
                                    : AppTheme.textSecondary))),
                  ]),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Expanded(
                  flex: 8,
                  child: Text('TOTAL',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textSecondary))),
              Expanded(
                  flex: 2,
                  child: Text('Rs $totAmt',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.success))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _reportHeaderCell(String t, {int flex = 2, TextAlign align = TextAlign.left}) =>
      Expanded(
          flex: flex,
          child: Text(t,
              textAlign: align,
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  color: AppTheme.textSecondary)));

  Widget _tripReportTable() {
    final rows = _tripsFiltered();
    if (rows.isEmpty) {
      return const Center(
          child: Text('Nothing to report for this range.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    final totVisits =
        rows.fold<int>(0, (s, t) => s + ((t['_visits'] as int?) ?? 0));
    final totAmt =
        rows.fold<int>(0, (s, t) => s + ((t['_amount'] as int?) ?? 0));
    final df = DateFormat('d MMM yyyy');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.isMobile ? 12 : 24, 0, context.isMobile ? 12 : 24, 16),
      child: Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
            child: Row(children: [
              _reportHeaderCell('Date'),
              _reportHeaderCell('Route', flex: 4),
              _reportHeaderCell('Visits', align: TextAlign.right),
              _reportHeaderCell('Collected', align: TextAlign.right),
              _reportHeaderCell('Status', flex: 2, align: TextAlign.right),
              const SizedBox(width: 44),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = rows[i];
                final s = DateTime.tryParse(t['started_at'] as String? ?? '')
                    ?.toLocal();
                final status = _tripStatus(t);
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(
                        flex: 2,
                        child: Text(s == null ? '—' : df.format(s),
                            style: const TextStyle(fontSize: 12.5))),
                    Expanded(
                        flex: 4,
                        child: Text(t['route_name'] as String? ?? '—',
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600))),
                    Expanded(
                        flex: 2,
                        child: Text('${t['_visits'] ?? 0}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5))),
                    Expanded(
                        flex: 2,
                        child: Text('Rs ${t['_amount'] ?? 0}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.success))),
                    Expanded(
                        flex: 2,
                        child: Text(status,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: status == 'Active'
                                    ? AppTheme.warning
                                    : status == 'Cutoff'
                                        ? AppTheme.danger
                                        : AppTheme.success))),
                    SizedBox(
                      width: 44,
                      child: IconButton(
                        icon: const Icon(Icons.picture_as_pdf_outlined,
                            size: 18, color: AppTheme.primary),
                        tooltip: 'Market Visit Report',
                        onPressed: () => _marketVisitReport(t),
                      ),
                    ),
                  ]),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Expanded(
                  flex: 6,
                  child: Text('TOTAL',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textSecondary))),
              Expanded(
                  flex: 2,
                  child: Text('$totVisits',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800))),
              Expanded(
                  flex: 2,
                  child: Text('Rs $totAmt',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.success))),
              const Expanded(flex: 2, child: SizedBox.shrink()),
              const SizedBox(width: 44),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _surveyReportTable() {
    final rows = _surveyDayRows();
    if (rows.isEmpty) {
      return const Center(
          child: Text('Nothing to report for this range.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    final totShops = <String>{};
    var totAudits = 0, totSpots = 0;
    for (final r in rows) {
      totShops.addAll(r['shops'] as Set<String>);
      totAudits += r['audits'] as int;
      totSpots += r['spottings'] as int;
    }
    final df = DateFormat('d MMM yyyy');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          context.isMobile ? 12 : 24, 0, context.isMobile ? 12 : 24, 16),
      child: Container(
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
            child: Row(children: [
              _reportHeaderCell('Date', flex: 3),
              _reportHeaderCell('Shops', align: TextAlign.right),
              _reportHeaderCell('Shelf Checks', align: TextAlign.right),
              _reportHeaderCell('Spottings', align: TextAlign.right),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(
                        flex: 3,
                        child: Text(
                            df.format(DateTime.parse(r['day'] as String)),
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600))),
                    Expanded(
                        flex: 2,
                        child: Text('${(r['shops'] as Set).length}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5))),
                    Expanded(
                        flex: 2,
                        child: Text('${r['audits']}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5))),
                    Expanded(
                        flex: 2,
                        child: Text('${r['spottings']}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5))),
                  ]),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Expanded(
                  flex: 3,
                  child: Text('TOTAL',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textSecondary))),
              Expanded(
                  flex: 2,
                  child: Text('${totShops.length}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800))),
              Expanded(
                  flex: 2,
                  child: Text('$totAudits',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800))),
              Expanded(
                  flex: 2,
                  child: Text('$totSpots',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800))),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _printReport() async {
    try {
      final df = DateFormat('d MMM yyyy');
      // When a specific visit type is selected, export the visit-level list so
      // the PDF matches what's on screen; otherwise the trip/survey summary.
      if (!_isSurveyMode && _visitTypeFilter != 'all') {
        final shown = _applyVisitTypeFilter(_visitRecordsInRange())
          ..sort((a, b) => (b['t'] as DateTime).compareTo(a['t'] as DateTime));
        final typeLabel = _visitTypeMeta(_visitTypeFilter).$1;
        final vbytes = await TeamReportPdf.visitTypeReport(
          orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
          memberName: _uname,
          period: '${df.format(_visitsFrom)} \u2013 ${df.format(_visitsTo)}',
          typeLabel: typeLabel,
          rows: [
            for (final v in shown)
              {
                't': v['t'],
                'shop': _custName(v['cid'] as String?),
                'code': _custCode(v['cid'] as String?),
                'route': v['route_name'],
                'amount': (v['amount'] as int?) ?? 0,
                'receipt': v['receipt'],
              }
          ],
        );
        await Printing.layoutPdf(
          onLayout: (_) async => vbytes,
          name:
              'team_visits_${_visitTypeFilter}_${_uname.replaceAll(' ', '_')}_${DateFormat('yyyyMMdd').format(_visitsTo)}.pdf',
        );
        return;
      }
      final bytes = await TeamReportPdf.periodReport(
        orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
        memberName: _uname,
        period: '${df.format(_visitsFrom)} \u2013 ${df.format(_visitsTo)}',
        surveyMode: _isSurveyMode,
        trips: _isSurveyMode ? const [] : _tripsFiltered(),
        surveyDays: _isSurveyMode ? _surveyDayRows() : const [],
      );
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name:
            'team_report_${_uname.replaceAll(' ', '_')}_${DateFormat('yyyyMMdd').format(_visitsTo)}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Report failed: $e')));
      }
    }
  }

  /// Detailed Market Visit Report for one trip (per-row button).
  Future<void> _marketVisitReport(Map<String, dynamic> t) async {
    try {
      final client = Supabase.instance.client;
      final vRes = await client
          .from('visits')
          .select()
          .eq('trip_id', t['id'] as String)
          .order('timestamp', ascending: true);
      final visits = List<Map<String, dynamic>>.from(vRes);
      final custIds = {
        for (final v in visits)
          if (v['customer_id'] != null) v['customer_id'] as String
      }.toList();
      final custs = <String, Map<String, dynamic>>{};
      for (var i = 0; i < custIds.length; i += 400) {
        final chunk =
            custIds.sublist(i, i + 400 > custIds.length ? custIds.length : i + 400);
        final rows = await client
            .from('customers')
            .select('id, shop_name, code')
            .inFilter('id', chunk);
        for (final c in rows) {
          custs[c['id'] as String] = Map<String, dynamic>.from(c);
        }
      }
      final bytes = await TeamReportPdf.marketVisitReport(
        orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
        salesperson: _uname,
        trip: t,
        visits: visits,
        customers: custs,
      );
      final dateStr =
          (t['started_at'] as String? ?? '').split('T').first.replaceAll('-', '');
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'market_visit_report_$dateStr.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Report failed: $e')));
      }
    }
  }

  // ── Routes tab ─────────────────────────────────────────────────────────
  Widget _routesTab() {
    if (_routes.isEmpty) {
      return const Center(
          child: Text('No routes assigned.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return ListView.separated(
      padding: EdgeInsets.all(context.isMobile ? 12 : 24),
      itemCount: _routes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final r = _routes[i];
        final rid = r['id'] as String;
        final active = r['is_active'] as bool? ?? true;
        final expanded = _expandedRoutes.contains(rid);
        final custIds = List<String>.from(_routeStops[rid] ?? const [])
          ..sort((a, b) => _custName(a).compareTo(_custName(b)));
        return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expandedRoutes.remove(rid);
              } else {
                _expandedRoutes.add(rid);
              }
            }),
            child: Row(children: [
              const Icon(Icons.alt_route, size: 20, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r['name'] as String? ?? '—',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  Text(
                      '${(r['kind'] as String? ?? 'recurring') == 'recurring' ? 'Recurring' : 'One-time'}${active ? '' : ' · Inactive'}',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              ),
              Text('${_routeStopCount[rid] ?? 0} shops',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: AppTheme.textSecondary),
            ]),
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 6),
            if (custIds.isEmpty)
              const Text('No shops on this route.',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary))
            else
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  for (final cid in custIds)
                    SizedBox(
                      width: context.isMobile ? double.infinity : 320,
                      child: Row(children: [
                        const Icon(Icons.storefront_outlined,
                            size: 14, color: AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_custName(cid),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        Text(_custCode(cid),
                            style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.textSecondary)),
                      ]),
                    ),
                ],
              ),
          ],
        ]));
      },
    );
  }

  // ── Tasks tab ──────────────────────────────────────────────────────────
  Widget _tasksTab() {
    if (_tasks.isEmpty) {
      return const Center(
          child: Text('No open tasks for this member\'s customers.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return ListView.separated(
      padding: EdgeInsets.all(context.isMobile ? 12 : 24),
      itemCount: _tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final t = _tasks[i];
        final status = (t['status'] as String? ?? 'open');
        final due = t['due_date'] as String?;
        final overdue = due != null &&
            (DateTime.tryParse(due)?.isBefore(DateTime.now()) ?? false);
        final title = (t['title'] ?? t['subject'] ?? t['activity_type'] ?? 'Task').toString();
        final note = (t['note'] ?? t['notes'] ?? t['description'] ?? '').toString();
        return _card(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.task_alt,
              size: 18,
              color: overdue ? AppTheme.danger : AppTheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13)),
              if (note.isNotEmpty)
                Text(note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textSecondary)),
              const SizedBox(height: 3),
              Text(
                  '${_custName(t['customer_id'] as String?)}${due != null ? ' · due ${_fmtDate(due)}' : ''}',
                  style: TextStyle(
                      fontSize: 11,
                      color:
                          overdue ? AppTheme.danger : AppTheme.textSecondary)),
            ]),
          ),
          _chip(status, overdue ? AppTheme.danger : Colors.orange),
        ]));
      },
    );
  }
}
