import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final orgId = user?.orgId;

    return Container(
      color: AppTheme.background,
      child: SingleChildScrollView(
        padding: context.pagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dashboard', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            const SizedBox(height: 4),
            Text('Welcome back, ${user?.name ?? ""}', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 15)),
            const SizedBox(height: 28),
            if (orgId != null)
              _DashboardStats(
                orgId: orgId,
                isMaster: user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.superAdmin,
              ),
          ],
        ),
      ),
    );
  }
}

class _DashboardStats extends StatefulWidget {
  final String orgId;
  final bool isMaster;
  const _DashboardStats({required this.orgId, required this.isMaster});

  @override
  State<_DashboardStats> createState() => _DashboardStatsState();
}

class _DashboardStatsState extends State<_DashboardStats> {
  Map<String, dynamic> _stats = {};
  bool _loading = true;
  bool _partial = false; // some rollups failed to load

  // Which day the dashboard is showing. Defaults to today; the date control
  // lets an admin look back at earlier days.
  DateTime _selectedDate = DateTime.now();
  bool get _isToday {
    final n = DateTime.now();
    return _selectedDate.year == n.year &&
        _selectedDate.month == n.month &&
        _selectedDate.day == n.day;
  }

  // ── dashboard privacy lock ────────────────────────────────────────────────
  // org.dashboard_password (sha256 hex) hides the numbers from non-master
  // admins until entered. Unlock lasts for this browser session per org.
  static final Set<String> _sessionUnlocked = {};
  String? _lockHash;

  bool get _locked =>
      _lockHash != null &&
      _lockHash!.isNotEmpty &&
      !widget.isMaster &&
      !_sessionUnlocked.contains(widget.orgId);

  String _mask(String v) => _locked ? '• • •' : v;

  Future<void> _loadLock() async {
    try {
      final row = await Supabase.instance.client
          .from('app_config')
          .select('value')
          .eq('org_id', widget.orgId)
          .eq('key', 'org.dashboard_password')
          .maybeSingle();
      if (mounted) setState(() => _lockHash = row?['value'] as String?);
    } catch (_) {}
  }

  Future<void> _promptUnlock() async {
    final ctrl = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.lock_outline, size: 18, color: AppTheme.textSecondary),
          SizedBox(width: 8),
          Text('Dashboard is protected', style: TextStyle(fontSize: 16)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Enter the dashboard password set by your master admin.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl, autofocus: true, obscureText: true,
            decoration: InputDecoration(
              labelText: 'Password', isDense: true,
              border: const OutlineInputBorder(), errorText: error,
            ),
            onSubmitted: (_) {
              if (sha256.convert(utf8.encode(ctrl.text)).toString() == _lockHash) {
                Navigator.pop(ctx, true);
              } else { setS(() => error = 'Incorrect password'); }
            },
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (sha256.convert(utf8.encode(ctrl.text)).toString() == _lockHash) {
                Navigator.pop(ctx, true);
              } else { setS(() => error = 'Incorrect password'); }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            child: const Text('Unlock'),
          ),
        ],
      )),
    );
    if (ok == true && mounted) {
      setState(() => _sessionUnlocked.add(widget.orgId));
    }
  }
  RealtimeChannel? _channel;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    _loadLock();
    _subscribeToChanges();
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _loading = true);
        _load();
      }
    });
  }

  void _subscribeToChanges() {
    _channel = Supabase.instance.client
        .channel('dashboard_realtime')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'visits',
          callback: (_) => _scheduleReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'trips',
          callback: (_) => _scheduleReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'placement_audit',
          callback: (_) => _scheduleReload(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'competitor_spotting',
          callback: (_) => _scheduleReload(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_channel != null) Supabase.instance.client.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    final client = Supabase.instance.client;
    final d = _selectedDate;
    // Local midnight of the selected day + next day, converted to UTC for the
    // wire. Old code serialized a naive local DateTime, which Postgres read as
    // UTC — so PK-morning rows fell outside the day filter.
    final dayStart = DateTime(d.year, d.month, d.day).toUtc().toIso8601String();
    final dayEnd = DateTime(d.year, d.month, d.day)
        .add(const Duration(days: 1))
        .toUtc()
        .toIso8601String();

    // Each rollup is independent. Run them concurrently BUT isolate failures —
    // a single failing query must never zero the whole dashboard (it used to:
    // one throw dropped everything to 0). Each guarded call returns a safe
    // fallback and flips _partial so we can show a subtle "some data" hint.
    bool anyFail = false;
    Future<List<dynamic>> ql(Future<dynamic> b) async {
      try {
        final r = await b;
        return (r as List?) ?? const [];
      } catch (_) {
        anyFail = true;
        return const [];
      }
    }

    // Count-only rollups: ask Postgres for the count (HEAD, no row payload)
    // instead of fetching every row just to call .length — much less data over
    // the wire, which is the bulk of the dashboard's load time on big orgs.
    Future<int> qCount(Future<dynamic> b) async {
      try {
        final r = await b;
        return ((r as dynamic).count as int?) ?? 0;
      } catch (_) {
        anyFail = true;
        return 0;
      }
    }

    final results = await Future.wait<dynamic>([
      qCount(client.from('users').select('id').eq('org_id', widget.orgId).count(CountOption.exact)),
      qCount(client.from('customers').select('id').eq('org_id', widget.orgId).count(CountOption.exact)),
      qCount(client.from('sales_routes').select('id').eq('org_id', widget.orgId).count(CountOption.exact)),
      // Active = ended_at IS NULL, regardless of start date. Only meaningful for
      // "today"; for a back-date we show 0 (nothing is currently running "then").
      _isToday
          ? qCount(client
              .from('trips')
              .select('id')
              .eq('org_id', widget.orgId)
              .filter('ended_at', 'is', null)
              .count(CountOption.exact))
          : Future<int>.value(0),
      // Completed = a trip that STARTED on the selected day and has finished.
      // Keying off started_at (not ended_at) stops a route that actually ran on
      // a prior day — but was only closed later — from leaking into the numbers.
      qCount(client
          .from('trips')
          .select('id')
          .eq('org_id', widget.orgId)
          .gte('started_at', dayStart)
          .lt('started_at', dayEnd)
          .not('ended_at', 'is', null)
          .count(CountOption.exact)),
      // Selected day's visits — RLS scopes to the user's org. Bounded window so
      // trips that span midnight don't double-count.
      ql(client
          .from('visits')
          .select('amount, customer_id')
          .gte('timestamp', dayStart)
          .lt('timestamp', dayEnd)),
      // Intelligence rollups.
      ql(client.from('placement_audit').select('customer_id, surveyed_at').eq('org_id', widget.orgId)),
      ql(client.from('competitor_spotting').select('customer_id, brand_name, surveyed_at').eq('org_id', widget.orgId)),
      ql(client.from('competitor_brand_aliases').select('alias, canonical').eq('org_id', widget.orgId)),
    ]);
    try {
      final teamCount = results[0] as int;
      final customerCount = results[1] as int;
      final routeCount = results[2] as int;
      final activeCount = results[3] as int;
      final completedCount = results[4] as int;
      final todayVisits = results[5] as List;
      final paRows = results[6] as List;
      final csRows = results[7] as List;
      // Brand alias map (variant -> correct brand) to canonicalize spottings
      // before the distinct-brand count.
      final brandAlias = <String, String>{
        for (final a in (results[8] as List))
          (a['alias'] as String? ?? '').toLowerCase().trim():
              (a['canonical'] as String? ?? '')
      };

      int totalCollection = 0;
      // Shops visited — matches the app's admin_dashboard_stats formula:
      // unique customers collected from today (amount > 0), by visit timestamp.
      final shopsSet = <String>{};
      for (final v in todayVisits) {
        final amt = (v['amount'] as int? ?? 0);
        totalCollection += amt;
        if (amt > 0) {
          final cid = v['customer_id'] as String?;
          if (cid != null) shopsSet.add(cid);
        }
      }
      final shopsVisited = shopsSet.length;

      // === Intelligence rollups (rows fetched in the parallel batch above) ===
      final auditedShops = paRows
          .map((r) => r['customer_id'] as String)
          .toSet();
      // Distinct competitor brands. Normalize hard so the SAME brand written
      // slightly differently ("Excel", "excel ", "Excel-Lighting", "Excel  LED")
      // collapses to one: lowercase, and reduce any run of spaces/punctuation to
      // a single space. (Genuinely different spellings still count separately —
      // those are data-entry variants to clean up in competitor management.)
      final brandsTracked = csRows
          .map((r) {
            final raw = (r['brand_name'] as String? ?? '');
            // Apply the alias map first (roll typos up to the correct brand),
            // then normalise for the distinct count.
            final canon = brandAlias[raw.toLowerCase().trim()] ?? raw;
            return canon
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
                .trim();
          })
          .where((b) => b.isNotEmpty)
          .toSet();

      final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
      bool within7d(dynamic ts) {
        if (ts is! String) return false;
        final dt = DateTime.tryParse(ts);
        return dt != null && dt.isAfter(sevenDaysAgo);
      }
      final recentCount = paRows.where((r) => within7d(r['surveyed_at'])).length +
          csRows.where((r) => within7d(r['surveyed_at'])).length;

      if (!mounted) return;
      setState(() {
        _stats = {
          'team': teamCount,
          'customers': customerCount,
          'routes': routeCount,
          'activeRoutes': activeCount,
          'shopsVisited': shopsVisited,
          'collection': totalCollection,
          'completedToday': completedCount,
          'auditedShops': auditedShops.length,
          'brandsTracked': brandsTracked.length,
          'intelActivity7d': recentCount,
        };
        _partial = anyFail;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _partial = true; _loading = false; });
    }
  }

  Future<void> _changeDate(DateTime d) async {
    // Never allow the future.
    final n = DateTime.now();
    final capped = d.isAfter(DateTime(n.year, n.month, n.day)) ? DateTime(n.year, n.month, n.day) : d;
    setState(() { _selectedDate = capped; _loading = true; });
    await _load();
  }

  void _showCollectionBreakdown() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: _CollectionBreakdownView(orgId: widget.orgId, date: _selectedDate),
        ),
      ),
    );
  }

  void _showActiveRoutes() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: _ActiveRoutesView(orgId: widget.orgId, date: _selectedDate),
        ),
      ),
    );
  }

  void _showCompletedToday() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: _ActiveRoutesView(orgId: widget.orgId, completed: true, date: _selectedDate),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final cards = [
      _StatCard(
        icon: Icons.payments_outlined,
        label: _isToday ? "Today's Collection" : 'Collection',
        value: _mask('Rs ${_stats['collection'] ?? 0}'),
        color: AppTheme.primary,
        featured: true,
        onTap: _locked ? null : _showCollectionBreakdown,
      ),
      if (_isToday)
        _StatCard(
          icon: Icons.directions_walk,
          label: 'Active Routes',
          value: _mask('${_stats['activeRoutes'] ?? 0}'),
          color: AppTheme.success,
          onTap: _locked ? null : _showActiveRoutes,
        ),
      _StatCard(
        icon: Icons.check_circle_outline,
        label: _isToday ? 'Completed Today' : 'Completed',
        value: _mask('${_stats['completedToday'] ?? 0}'),
        color: AppTheme.primary,
        onTap: _locked ? null : _showCompletedToday,
      ),
      _StatCard(icon: Icons.storefront_outlined, label: 'Shops Visited', value: _mask('${_stats['shopsVisited'] ?? 0}'), color: const Color(0xFF0EA5E9)),
      _StatCard(icon: Icons.people_outline, label: 'Team Members', value: _mask('${_stats['team'] ?? 0}'), color: AppTheme.warning),
      _StatCard(icon: Icons.store_outlined, label: 'Customers', value: _mask('${_stats['customers'] ?? 0}'), color: AppTheme.danger),
      _StatCard(icon: Icons.route_outlined, label: 'Total Routes', value: _mask('${_stats['routes'] ?? 0}'), color: const Color(0xFF06B6D4)),
    ];

    final intelligenceCards = [
      _StatCard(
        icon: Icons.checklist_outlined,
        label: 'Audited Shops',
        value: _mask('${_stats['auditedShops'] ?? 0}'),
        color: const Color(0xFF14B8A6),
      ),
      _StatCard(
        icon: Icons.flag_outlined,
        label: 'Competitor Brands',
        value: _mask('${_stats['brandsTracked'] ?? 0}'),
        color: const Color(0xFFF59E0B),
      ),
      _StatCard(
        icon: Icons.history,
        label: 'Intel Activity (7d)',
        value: _mask('${_stats['intelActivity7d'] ?? 0}'),
        color: const Color(0xFFEC4899),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 5, height: 18,
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 9),
          const Text("Today's Overview", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
          if (_partial)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: 'Some figures could not load — tap refresh to retry',
                child: Icon(Icons.cloud_off_outlined, size: 15, color: AppTheme.warning),
              ),
            ),
          // Subtle lock affordance — a quiet icon, only when the numbers are hidden.
          if (_locked)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Tooltip(
                message: 'Numbers hidden — tap to unlock',
                child: InkWell(
                  onTap: _promptUnlock,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.lock_outline, size: 15, color: AppTheme.textSecondary.withOpacity(0.7)),
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (!_isToday) ...[
            TextButton(
              onPressed: () => _changeDate(DateTime.now()),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10), minimumSize: const Size(0, 32)),
              child: const Text('Today', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 2),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _changeDate(_selectedDate.subtract(const Duration(days: 1))),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.chevron_left, size: 18, color: AppTheme.textSecondary)),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) _changeDate(picked);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.calendar_today_outlined, size: 12, color: AppTheme.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      DateFormat(context.isMobile ? 'd MMM' : 'EEEE, d MMM yyyy').format(_selectedDate),
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                  ]),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _isToday ? null : () => _changeDate(_selectedDate.add(const Duration(days: 1))),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(Icons.chevron_right, size: 18,
                      color: _isToday ? AppTheme.textSecondary.withOpacity(0.3) : AppTheme.textSecondary)),
              ),
            ]),
          ),
          const SizedBox(width: 6),
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: () { setState(() => _loading = true); _load(); }),
        ]),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: cards,
        ),
        const SizedBox(height: 32),
        Row(children: [
          Container(width: 5, height: 18,
              decoration: BoxDecoration(color: const Color(0xFF14B8A6), borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 9),
          const Text('Intelligence', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
        ]),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 14),
          child: Text(
            'Surveyor-collected market data - shop coverage, competitor presence.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: intelligenceCards,
        ),
      ],
    );
  }
}


class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;
  final bool featured;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.onTap,
    this.featured = false,
  });

  @override
  Widget build(BuildContext context) {
    // 200px fixed fits exactly one card per row on a phone, wasting half the
    // screen. Half-width (minus the Wrap spacing) gives two per row.
    final base = context.isMobile
        ? (MediaQuery.sizeOf(context).width - 24 - 16) / 2
        : 200.0;
    final w = featured && !context.isMobile ? base * 2 + 16 : base;
    final body = Container(
      width: w,
      padding: EdgeInsets.all(context.isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: featured ? null : Colors.white,
        gradient: featured
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1B45A0), Color(0xFF2F6FED)])
            : null,
        borderRadius: BorderRadius.circular(14),
        border: featured ? null : Border.all(color: AppTheme.border),
        boxShadow: featured
            ? [BoxShadow(color: AppTheme.primary.withOpacity(0.30), blurRadius: 18, offset: const Offset(0, 6))]
            : [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
                color: featured ? Colors.white.withOpacity(0.16) : color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(11)),
            alignment: Alignment.center,
            child: Icon(icon, color: featured ? Colors.white : color, size: 20),
          ),
          const SizedBox(height: 16),
          Text(value,
              style: TextStyle(
                  fontSize: 29, fontWeight: FontWeight.w800, letterSpacing: -0.5,
                  color: featured ? Colors.white : const Color(0xFF0F172A))),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: featured ? Colors.white.withOpacity(0.75) : AppTheme.textSecondary,
                  fontSize: 12.5, fontWeight: FontWeight.w500)),
        ],
      ),
    );
    if (onTap == null) return body;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: body,
        ),
      ),
    );
  }
}


// ============================================================================
// Today's Collection — drill-down modal
// ============================================================================
// Mirrors the mobile monitoring pattern: salesperson rows sum today's
// collected amounts; each row expands inline to reveal that salesperson's
// individual stops (customer, time, status, amount).

class _CollectionBreakdownView extends StatefulWidget {
  final String orgId;
  final DateTime date;
  const _CollectionBreakdownView({required this.orgId, required this.date});

  @override
  State<_CollectionBreakdownView> createState() =>
      _CollectionBreakdownViewState();
}

class _CollectionBreakdownViewState extends State<_CollectionBreakdownView> {
  bool _loading = true;
  String? _error;
  int _grandTotal = 0;
  List<_SalespersonCollection> _breakdown = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final now = widget.date;
      final todayStart = DateTime(now.year, now.month, now.day)
          .toUtc()
          .toIso8601String();
      final tomorrowStart = DateTime(now.year, now.month, now.day)
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String();

      final orgId = widget.orgId;
      // route_stops / route_assignments carry NO org_id. Fetching them unscoped
      // pulls EVERY org's route plan — which inflated "not visited" to a rep's
      // entire cross-org customer base and slowed the query. Scope them to this
      // org's own routes (sales_routes has org_id) so "not visited" is only the
      // customers on the rep's routes within this org.
      final orgRoutesRows = await client
          .from('sales_routes')
          .select('id')
          .eq('org_id', orgId);
      final orgRouteIds = (orgRoutesRows as List)
          .map((r) => (r as Map)['id'] as String)
          .toList(growable: false);

      final results = await Future.wait<dynamic>([
        client
            .from('visits')
            .select(
                'user_id, user_name, customer_id, amount, timestamp, status, customers(shop_name)')
            .gte('timestamp', todayStart)
            .lt('timestamp', tomorrowStart),
        // Standing route plan, scoped to THIS org's routes: who is assigned to
        // which route, and which customers each route carries.
        orgRouteIds.isEmpty
            ? Future<dynamic>.value(const <dynamic>[])
            : client.from('route_assignments').select('user_id, route_id').inFilter('route_id', orgRouteIds),
        orgRouteIds.isEmpty
            ? Future<dynamic>.value(const <dynamic>[])
            : client.from('route_stops').select('route_id, customer_id').inFilter('route_id', orgRouteIds),
        client.from('customers').select('id, shop_name').eq('org_id', orgId),
      ]);

      final rows = results[0] as List;
      // customer id -> name
      final custName = <String, String>{
        for (final c in (results[3] as List))
          (c['id'] as String): ((c['shop_name'] as String?) ?? 'Unknown shop')
      };
      // user -> planned customer ids (via their assigned routes)
      final routeCustomers = <String, Set<String>>{};
      for (final s in (results[2] as List)) {
        final rid = s['route_id'] as String?;
        final cid = s['customer_id'] as String?;
        if (rid == null || cid == null) continue;
        (routeCustomers[rid] ??= <String>{}).add(cid);
      }
      final userPlanned = <String, Set<String>>{};
      for (final a in (results[1] as List)) {
        final uid = a['user_id'] as String?;
        final rid = a['route_id'] as String?;
        if (uid == null || rid == null) continue;
        (userPlanned[uid] ??= <String>{}).addAll(routeCustomers[rid] ?? const {});
      }

      final collectedByUser = <String, List<_VisitRow>>{};
      final otherByUser = <String, List<_OtherStop>>{};
      final visitedByUser = <String, Set<String>>{};
      final userNames = <String, String>{};
      int grand = 0;
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r as Map);
        final uid = (m['user_id'] as String?) ?? '';
        userNames[uid] = (m['user_name'] as String?) ?? 'Unknown';
        final amount = (m['amount'] as int?) ?? 0;
        final cust = m['customers'] as Map<String, dynamic>?;
        final customerName =
            (cust != null ? cust['shop_name'] as String? : null) ?? 'Unknown shop';
        final cid = m['customer_id'] as String?;
        if (cid != null) (visitedByUser[uid] ??= <String>{}).add(cid);
        final ts = m['timestamp'] != null
            ? DateTime.parse(m['timestamp'] as String).toLocal()
            : DateTime.now();
        final status = (m['status'] as String?) ?? '';
        if (amount > 0) {
          collectedByUser.putIfAbsent(uid, () => []).add(_VisitRow(
                customerName: customerName,
                amount: amount,
                timestamp: ts,
                status: status,
              ));
          grand += amount;
        } else {
          // Visited but nothing collected, or explicitly skipped.
          otherByUser.putIfAbsent(uid, () => []).add(_OtherStop(
                customerName: customerName,
                status: status.isEmpty ? 'no_collection' : status,
              ));
        }
      }

      // Any user who did something today (collected or otherwise).
      final activeUsers = <String>{...collectedByUser.keys, ...otherByUser.keys};
      final out = activeUsers.map((uid) {
        final collected = (collectedByUser[uid] ?? [])
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final other = List<_OtherStop>.from(otherByUser[uid] ?? const []);
        // not-visited = planned customers this user did not touch today
        final visited = visitedByUser[uid] ?? const <String>{};
        for (final cid in (userPlanned[uid] ?? const <String>{})) {
          if (!visited.contains(cid)) {
            other.add(_OtherStop(
                customerName: custName[cid] ?? 'Unknown shop',
                status: 'not_visited'));
          }
        }
        other.sort((a, b) => a.customerName
            .toLowerCase()
            .compareTo(b.customerName.toLowerCase()));
        final total = collected.fold<int>(0, (s, v) => s + v.amount);
        return _SalespersonCollection(
          userId: uid,
          userName: userNames[uid] ?? 'Unknown',
          total: total,
          visits: collected,
          otherStops: other,
        );
      }).toList()
        ..sort((a, b) => b.total.compareTo(a.total));

      if (!mounted) return;
      setState(() {
        _breakdown = out;
        _grandTotal = grand;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.payments_outlined,
                    color: Color(0xFF8B5CF6), size: 18),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  "Today's Collection",
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 22),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: _loading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: CircularProgressIndicator(),
                  ),
                )
              : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('Error: $_error',
                          style:
                              const TextStyle(color: Color(0xFFDC2626))),
                    )
                  : _breakdown.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(48),
                          child: Center(
                            child: Text(
                              'No collections recorded today yet.',
                              style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 14),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding:
                              const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF8B5CF6),
                                      Color(0xFF7C3AED),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'TOTAL COLLECTION',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.2,
                                        color: Colors.white
                                            .withOpacity(0.85),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Rs ${_fmtNumber(_grandTotal)}',
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              for (final sp in _breakdown)
                                _SalespersonExpansion(sp: sp),
                            ],
                          ),
                        ),
        ),
      ],
    );
  }
}

class _SalespersonExpansion extends StatelessWidget {
  final _SalespersonCollection sp;
  const _SalespersonExpansion({required this.sp});

  String _subtitle(_SalespersonCollection sp) {
    final collected = sp.visits.length;
    final skipped =
        sp.otherStops.where((o) => o.status == 'skipped').length;
    final notVisited =
        sp.otherStops.where((o) => o.status == 'not_visited').length;
    final parts = <String>[
      '$collected collected',
      if (skipped > 0) '$skipped skipped',
      if (notVisited > 0) '$notVisited not visited',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding:
              const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(
            sp.userName,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            _subtitle(sp),
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary),
          ),
          trailing: Text(
            'Rs ${_fmtNumber(sp.total)}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF8B5CF6),
            ),
          ),
          children: [
            const Divider(height: 1),
            const SizedBox(height: 8),
            for (final v in sp.visits) _VisitDetailRow(v: v),
            if (sp.otherStops.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Container(height: 1, color: AppTheme.border)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Skipped / not visited (${sp.otherStops.length})',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textSecondary),
                  ),
                ),
                Expanded(child: Container(height: 1, color: AppTheme.border)),
              ]),
              const SizedBox(height: 6),
              for (final o in sp.otherStops) _OtherStopRow(o: o),
            ],
          ],
        ),
      ),
    );
  }
}

class _VisitDetailRow extends StatefulWidget {
  final _VisitRow v;
  const _VisitDetailRow({required this.v});

  @override
  State<_VisitDetailRow> createState() => _VisitDetailRowState();
}

class _VisitDetailRowState extends State<_VisitDetailRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.v;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
                padding: const EdgeInsets.only(top: 1),
                child: _statusIcon(v.status)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.customerName,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    maxLines: _expanded ? null : 1,
                    overflow:
                        _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${DateFormat('HH:mm').format(v.timestamp)} \u00b7 ${_statusLabel(v.status)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Rs ${_fmtNumber(v.amount)}',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'verified':
        return const Icon(Icons.check_circle,
            color: AppTheme.success, size: 16);
      case 'outside':
        return const Icon(Icons.warning_amber_rounded,
            color: AppTheme.warning, size: 16);
      case 'no_location':
      case 'noLocation':
        return const Icon(Icons.location_off_outlined,
            color: AppTheme.danger, size: 16);
      case 'skipped':
        return const Icon(Icons.skip_next,
            color: AppTheme.textSecondary, size: 16);
      default:
        return const Icon(Icons.radio_button_unchecked,
            color: AppTheme.textSecondary, size: 16);
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'verified':
        return 'Verified';
      case 'outside':
        return 'Outside geofence';
      case 'no_location':
      case 'noLocation':
        return 'No location';
      case 'skipped':
        return 'Skipped';
      default:
        return status.isEmpty ? '-' : status;
    }
  }
}

class _OtherStopRow extends StatefulWidget {
  final _OtherStop o;
  const _OtherStopRow({required this.o});

  @override
  State<_OtherStopRow> createState() => _OtherStopRowState();
}

class _OtherStopRowState extends State<_OtherStopRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.o;
    final isSkip = o.status == 'skipped';
    final isNotVisited = o.status == 'not_visited';
    final icon = isSkip
        ? Icons.skip_next
        : (isNotVisited
            ? Icons.radio_button_unchecked
            : Icons.remove_circle_outline);
    final label = isSkip
        ? 'Skipped'
        : (isNotVisited ? 'Not visited' : 'No collection');
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: AppTheme.textSecondary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.customerName,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textSecondary),
                    maxLines: _expanded ? null : 1,
                    overflow:
                        _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SalespersonCollection {
  final String userId;
  final String userName;
  final int total;
  final List<_VisitRow> visits;
  final List<_OtherStop> otherStops; // skipped / visited-no-collection / not-visited
  const _SalespersonCollection({
    required this.userId,
    required this.userName,
    required this.total,
    required this.visits,
    this.otherStops = const [],
  });
}

class _VisitRow {
  final String customerName;
  final int amount;
  final DateTime timestamp;
  final String status;
  const _VisitRow({
    required this.customerName,
    required this.amount,
    required this.timestamp,
    required this.status,
  });
}

class _OtherStop {
  final String customerName;
  final String status; // 'skipped' | 'not_visited' | 'no_collection'
  const _OtherStop({required this.customerName, required this.status});
}

String _fmtNumber(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  int count = 0;
  for (int i = s.length - 1; i >= 0; i--) {
    buf.write(s[i]);
    count++;
    if (count % 3 == 0 && i != 0) buf.write(',');
  }
  return buf.toString().split('').reversed.join();
}

// ============================================================================
// Active Routes — drill-down modal
// ============================================================================
// Mirrors the mobile "active routes" view: one collapsible card per in-progress
// trip (ended_at IS NULL), showing route name + rep, expanding to that trip's
// visits so far (customer, time, status, amount).

class _ActiveRoutesView extends StatefulWidget {
  final String orgId;
  final bool completed; // false = active (ended_at null), true = ended today
  final DateTime date;
  const _ActiveRoutesView({required this.orgId, this.completed = false, required this.date});

  @override
  State<_ActiveRoutesView> createState() => _ActiveRoutesViewState();
}

class _ActiveRoutesViewState extends State<_ActiveRoutesView> {
  bool _loading = true;
  String? _error;
  List<_ActiveRoute> _routes = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;

      // Active trips = ended_at IS NULL. Completed = STARTED today and finished
      // (same formula as the dashboard counter) — see _load() for why we key off
      // started_at, not ended_at.
      final now = widget.date;
      final todayStart =
          DateTime(now.year, now.month, now.day).toUtc().toIso8601String();
      final tomorrowStart = DateTime(now.year, now.month, now.day)
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String();
      final base = client
          .from('trips')
          .select('id, route_name, user_name, started_at, ended_at')
          .eq('org_id', widget.orgId);
      final tripRows = widget.completed
          ? await base
              .gte('started_at', todayStart)
              .lt('started_at', tomorrowStart)
              .not('ended_at', 'is', null)
          : await base.filter('ended_at', 'is', null);

      final trips = (tripRows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      if (trips.isEmpty) {
        if (!mounted) return;
        setState(() {
          _routes = const [];
          _loading = false;
        });
        return;
      }

      final tripIds =
          trips.map((t) => t['id'] as String).toList(growable: false);

      // All visits for those active trips.
      final visitRows = await client
          .from('visits')
          .select(
              'trip_id, customer_id, amount, timestamp, status, customers(shop_name)')
          .inFilter('trip_id', tripIds);

      final byTrip = <String, List<_VisitRow>>{};
      for (final r in (visitRows as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final tid = (m['trip_id'] as String?) ?? '';
        final cust = m['customers'] as Map<String, dynamic>?;
        final customerName =
            (cust != null ? cust['shop_name'] as String? : null) ??
                'Unknown shop';
        final ts = m['timestamp'] != null
            ? DateTime.parse(m['timestamp'] as String).toLocal()
            : DateTime.now();
        byTrip.putIfAbsent(tid, () => []).add(_VisitRow(
              customerName: customerName,
              amount: (m['amount'] as int?) ?? 0,
              timestamp: ts,
              status: (m['status'] as String?) ?? '',
            ));
      }

      final out = trips.map((t) {
        final id = t['id'] as String;
        final visits = (byTrip[id] ?? [])
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        final collected = visits.fold<int>(0, (s, v) => s + v.amount);
        final started = t['started_at'] != null
            ? DateTime.parse(t['started_at'] as String).toLocal()
            : null;
        final ended = t['ended_at'] != null
            ? DateTime.parse(t['ended_at'] as String).toLocal()
            : null;
        return _ActiveRoute(
          routeName: (t['route_name'] as String?) ?? 'Route',
          userName: (t['user_name'] as String?) ?? 'Unknown',
          startedAt: started,
          endedAt: ended,
          collected: collected,
          visits: visits,
        );
      }).toList()
        ..sort((a, b) => b.collected.compareTo(a.collected));

      if (!mounted) return;
      setState(() {
        _routes = out;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (widget.completed ? AppTheme.primary : AppTheme.success).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(
                    widget.completed ? Icons.check_circle_outline : Icons.directions_walk,
                    color: widget.completed ? AppTheme.primary : AppTheme.success,
                    size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.completed ? 'Completed Today' : 'Active Routes',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 22),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: _loading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(48),
                    child: CircularProgressIndicator(),
                  ),
                )
              : _error != null
                  ? Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('Error: $_error',
                          style: const TextStyle(color: Color(0xFFDC2626))),
                    )
                  : _routes.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(48),
                          child: Center(
                            child: Text(
                              widget.completed
                                  ? 'No routes have been completed today yet.'
                                  : 'No routes are active right now.',
                              style: const TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 14),
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final r in _routes) _ActiveRouteExpansion(r: r),
                            ],
                          ),
                        ),
        ),
      ],
    );
  }
}

class _ActiveRouteExpansion extends StatefulWidget {
  final _ActiveRoute r;
  const _ActiveRouteExpansion({required this.r});

  @override
  State<_ActiveRouteExpansion> createState() => _ActiveRouteExpansionState();
}

class _ActiveRouteExpansionState extends State<_ActiveRouteExpansion> {
  bool _showRemaining = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.r;
    // Marked visits (verified / no-location / outside-geofence) stay in the main
    // list, whether or not anything was collected. Only skipped / not-visited
    // stops go behind a "Show remaining" toggle for a cleaner view.
    bool isRemaining(String status) {
      final s = status.toLowerCase();
      return s == 'skipped' || s == 'not_visited' || s == 'notvisited';
    }

    final visited = r.visits.where((v) => !isRemaining(v.status)).toList();
    final remaining = r.visits.where((v) => isRemaining(v.status)).toList();
    final stopsLabel = '${visited.length} visited'
        '${remaining.isNotEmpty ? " \u00b7 ${remaining.length} remaining" : ""}';
    final timeLabel = r.endedAt != null
        ? ' \u00b7 ended ${DateFormat('HH:mm').format(r.endedAt!)}'
        : (r.startedAt != null ? ' \u00b7 since ${DateFormat('HH:mm').format(r.startedAt!)}' : '');
    final subtitle = '${r.userName} \u00b7 $stopsLabel$timeLabel';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(
            r.routeName,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            style:
                const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          trailing: Text(
            'Rs ${_fmtNumber(r.collected)}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppTheme.success,
            ),
          ),
          children: [
            const Divider(height: 1),
            const SizedBox(height: 8),
            if (r.visits.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No stops visited yet.',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              )
            else ...[
              for (final v in visited) _VisitDetailRow(v: v),
              if (visited.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text('No visits on this route yet.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ),
              if (remaining.isNotEmpty) ...[
                const SizedBox(height: 6),
                InkWell(
                  onTap: () => setState(() => _showRemaining = !_showRemaining),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Icon(_showRemaining ? Icons.expand_less : Icons.expand_more,
                          size: 18, color: AppTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        _showRemaining
                            ? 'Hide remaining'
                            : 'Show remaining (${remaining.length})',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary),
                      ),
                    ]),
                  ),
                ),
                if (_showRemaining)
                  for (final v in remaining) _VisitDetailRow(v: v),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ActiveRoute {
  final String routeName;
  final String userName;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final int collected;
  final List<_VisitRow> visits;
  const _ActiveRoute({
    required this.routeName,
    required this.userName,
    required this.startedAt,
    this.endedAt,
    required this.collected,
    required this.visits,
  });
}
