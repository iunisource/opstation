import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/permissions/access_control.dart';
import '../../auth/auth_controller.dart';

/// A single report tile in the Center. `route` is the existing screen the tile
/// opens; visibility is gated by the SAME permission the menu uses
/// (access.canAccessRoute), so a tile can never expose a report the user
/// couldn't already reach.
class _Card {
  final String label;
  final String route;
  final IconData icon;
  final String desc;
  const _Card(this.label, this.route, this.icon, this.desc);
}

class _Cat {
  final String title;
  final IconData icon;
  final List<_Card> cards;
  const _Cat(this.title, this.icon, this.cards);
}

// Curated, QuickBooks-style grouping. These all mirror reports that already
// live in their own menus — the Center is a second, browsable way in; nothing
// is moved. Cards the user isn't permitted to see are hidden at render time.
const List<_Cat> _kCatalog = [
  _Cat('Sales & Customers', Icons.trending_up, [
    _Card('Sales Report', '/erp/sales-report', Icons.assessment_outlined, 'Sales by product, customer or period'),
    _Card('Sales Dashboard', '/erp/sales-dashboard', Icons.space_dashboard_outlined, 'Headline sales KPIs at a glance'),
    _Card('Customer Ledger', '/erp/customer-ledger', Icons.menu_book_outlined, 'Every transaction for a customer'),
    _Card('Customer Aging', '/erp/customer-aging', Icons.hourglass_bottom_outlined, 'Receivables by age bucket'),
    _Card('Customer Balance', '/reports/customer-balance', Icons.account_balance_wallet_outlined, 'Outstanding balance per customer'),
    _Card('Margin Report', '/reports/margin', Icons.percent_outlined, 'Gross margin by product / sale'),
  ]),
  _Cat('Purchases & Suppliers', Icons.shopping_cart_outlined, [
    _Card('Purchase Report', '/erp/purchase-report', Icons.summarize_outlined, 'Purchases by supplier or period'),
    _Card('Purchase Dashboard', '/erp/purchase-dashboard', Icons.space_dashboard_outlined, 'Headline purchasing KPIs'),
    _Card('Supplier Ledger', '/erp/supplier-ledger', Icons.menu_book_outlined, 'Every transaction for a supplier'),
    _Card('Supplier Aging', '/erp/supplier-aging', Icons.hourglass_bottom_outlined, 'Payables by age bucket'),
    _Card('Supplier Balance', '/reports/supplier-balance', Icons.account_balance_outlined, 'Outstanding balance per supplier'),
  ]),
  _Cat('Inventory', Icons.inventory_2_outlined, [
    _Card('Stock Levels', '/erp/stock', Icons.inventory_outlined, 'Live on-hand by product & branch'),
    _Card('Low Stock', '/erp/low-stock-report', Icons.warning_amber_outlined, 'Items at or below reorder point'),
    _Card('Stock Value', '/erp/stock-value-report', Icons.payments_outlined, 'Inventory valuation'),
    _Card('Stock Balance', '/erp/stock-balance-report', Icons.balance_outlined, 'Opening / in / out / closing'),
    _Card('Stock Aging', '/erp/stock-aging-report', Icons.hourglass_bottom_outlined, 'How long stock has been held'),
    _Card('Inventory Ledger', '/erp/inventory-ledger', Icons.menu_book_outlined, 'Every movement for a product'),
    _Card('Inventory Integrity', '/erp/inventory-integrity', Icons.verified_outlined, 'Stock vs. ledger reconciliation'),
    _Card('Demand Planner', '/erp/demand-plan', Icons.insights_outlined, 'Projected demand & reorder'),
  ]),
  _Cat('Financials', Icons.account_balance_outlined, [
    _Card('Profit & Loss', '/financials/profit-loss', Icons.trending_up, 'Income statement for a period'),
    _Card('Balance Sheet', '/financials/balance-sheet', Icons.account_balance_outlined, 'Assets, liabilities & equity'),
    _Card('Trial Balance', '/financials/trial-balance', Icons.table_rows_outlined, 'All account balances'),
    _Card('Cash Book', '/financials/cash-book', Icons.menu_book_outlined, 'Cash & bank movements'),
    _Card('Account Activity', '/financials/account-activity', Icons.receipt_long_outlined, 'Ledger detail for an account'),
  ]),
  _Cat('POS', Icons.storefront_outlined, [
    _Card('POS Customer History', '/erp/pos-customer-history', Icons.history_outlined, 'A POS customer’s past bills'),
    _Card('Bills on Hold', '/erp/pos-held-bills', Icons.pause_circle_outline, 'Parked / held POS bills'),
  ]),
  _Cat('Manufacturing', Icons.precision_manufacturing_outlined, [
    _Card('Production Floor', '/manufacturing/production-floor', Icons.space_dashboard_outlined, 'Live production status'),
    _Card('Production Planner', '/manufacturing/production-plan', Icons.account_tree_outlined, 'Material planning for runs'),
    _Card('Production Waste', '/manufacturing/production-waste-report', Icons.recycling_outlined, 'Scrap & waste by run'),
    _Card('Overheads Summary', '/manufacturing/overheads-summary', Icons.summarize_outlined, 'Applied labour & overhead'),
  ]),
  _Cat('HR', Icons.badge_outlined, [
    _Card('Attendance Board', '/hr/attendance-board', Icons.event_available_outlined, 'Team attendance overview'),
  ]),
];

class ReportsCenterScreen extends ConsumerStatefulWidget {
  const ReportsCenterScreen({super.key});
  @override
  ConsumerState<ReportsCenterScreen> createState() => _ReportsCenterScreenState();
}

class _ReportsCenterScreenState extends ConsumerState<ReportsCenterScreen> {
  List<Map<String, dynamic>> _saved = [];
  bool _loadingSaved = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadSaved());
  }

  // Saved custom reports the current user may see: admins see all; everyone
  // else sees 'all'-scope reports plus any 'selected'-scope report shared with
  // them. (The server also enforces this via RLS; this filter is the UI view.)
  Future<void> _loadSaved() async {
    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    final uid = user?.id;
    if (orgId == null) { if (mounted) setState(() => _loadingSaved = false); return; }
    // Await the resolved access so admins never race an unready permission state.
    bool isAdmin;
    try {
      isAdmin = (await ref.read(accessProvider.future)).isAdmin;
    } catch (_) {
      isAdmin = ref.read(accessSyncProvider)?.isAdmin ?? false;
    }
    try {
      final rows = await Supabase.instance.client
          .from('report_templates').select().eq('org_id', orgId).order('name');
      final tpls = List<Map<String, dynamic>>.from(rows);
      Set<String> sharedToMe = {};
      if (!isAdmin && uid != null) {
        try {
          final sh = await Supabase.instance.client
              .from('report_template_shares').select('template_id').eq('user_id', uid);
          sharedToMe = {for (final r in sh as List) r['template_id'] as String};
        } catch (_) {}
      }
      final visible = tpls.where((t) {
        if (isAdmin) return true;
        final scope = (t['share_scope'] as String?) ??
            ((t['is_shared'] == true) ? 'all' : 'admins');
        if (scope == 'all') return true;
        if (scope == 'selected') return sharedToMe.contains(t['id'] as String);
        return false; // 'admins' only
      }).toList();
      if (mounted) setState(() { _saved = visible; _loadingSaved = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingSaved = false);
    }
  }

  bool _match(String label, String desc) {
    if (_search.trim().isEmpty) return true;
    final q = _search.toLowerCase();
    return label.toLowerCase().contains(q) || desc.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(accessProvider).valueOrNull;
    if (access == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final isAdmin = access.isAdmin;

    // Only categories with at least one permitted, search-matching card.
    final cats = <_Cat>[];
    for (final c in _kCatalog) {
      final cards = c.cards
          .where((k) => access.canAccessRoute(k.route) && _match(k.label, k.desc))
          .toList();
      if (cards.isNotEmpty) cats.add(_Cat(c.title, c.icon, cards));
    }

    final savedMatched = _saved
        .where((t) => _match((t['name'] as String?) ?? '', (t['source'] as String?) ?? ''))
        .toList();

    return Container(
      color: AppTheme.background,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
        children: [
          Row(children: [
            const Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Report Center', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                SizedBox(height: 4),
                Text('Browse and open any report you have access to.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ]),
            ),
            if (isAdmin)
              ElevatedButton.icon(
                onPressed: () => context.go('/intelligence/report-builder'),
                icon: const Icon(Icons.add_chart_outlined, size: 18),
                label: const Text('New custom report'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: 420,
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search reports…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(height: 24),

          // Saved custom reports first — these are the org's own memorized views.
          if (_loadingSaved)
            const Padding(padding: EdgeInsets.only(bottom: 20),
                child: LinearProgressIndicator(minHeight: 2))
          else if (savedMatched.isNotEmpty || isAdmin) ...[
            _sectionHeader('Saved Reports', Icons.bookmark_outline),
            const SizedBox(height: 12),
            Wrap(spacing: 14, runSpacing: 14, children: [
              for (final t in savedMatched) _savedCard(t, isAdmin),
              if (isAdmin) _customTile(),
            ]),
            const SizedBox(height: 28),
          ],

          for (final c in cats) ...[
            _sectionHeader(c.title, c.icon),
            const SizedBox(height: 12),
            Wrap(spacing: 14, runSpacing: 14,
                children: [for (final k in c.cards) _prebuiltCard(k)]),
            const SizedBox(height: 28),
          ],

          if (cats.isEmpty && savedMatched.isEmpty && !_loadingSaved)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: Text('No reports match your access or search.',
                  style: TextStyle(color: AppTheme.textSecondary))),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, IconData icon) => Row(children: [
        Icon(icon, size: 18, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ]);

  Widget _cardShell({required Widget child, required VoidCallback onTap}) {
    return SizedBox(
      width: 260,
      child: Material(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _prebuiltCard(_Card k) => _cardShell(
        onTap: () => context.go(k.route),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(k.icon, size: 18, color: AppTheme.primary),
            ),
            const Spacer(),
            const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
          ]),
          const SizedBox(height: 12),
          Text(k.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(k.desc, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _savedCard(Map<String, dynamic> t, bool isAdmin) {
    final scope = (t['share_scope'] as String?) ??
        ((t['is_shared'] == true) ? 'all' : 'admins');
    final scopeLabel = scope == 'all'
        ? 'All users'
        : scope == 'selected'
            ? 'Selected users'
            : 'Admins only';
    return _cardShell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => _SavedReportViewer(template: t))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.success.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.bookmark_outline, size: 18, color: AppTheme.success),
          ),
          const Spacer(),
          const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
        ]),
        const SizedBox(height: 12),
        Text((t['name'] as String?) ?? 'Untitled report',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Source: ${(t['source'] as String?) ?? '—'}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        if (isAdmin) ...[
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.people_alt_outlined, size: 12, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(scopeLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ],
      ]),
    );
  }

  Widget _customTile() => _cardShell(
        onTap: () => context.go('/intelligence/report-builder'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.add_chart_outlined, size: 18, color: AppTheme.primary),
            ),
            const Spacer(),
            const Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary),
          ]),
          const SizedBox(height: 12),
          const Text('Custom report', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Build a report from scratch and save it for your team.',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );
}

/// Read-only runner for a saved custom report. Runs the same rpc_report_query
/// the builder uses and renders a flat table — so a user a report is shared
/// with can VIEW it without the admin-only builder.
class _SavedReportViewer extends ConsumerStatefulWidget {
  final Map<String, dynamic> template;
  const _SavedReportViewer({required this.template});
  @override
  ConsumerState<_SavedReportViewer> createState() => _SavedReportViewerState();
}

class _SavedReportViewerState extends ConsumerState<_SavedReportViewer> {
  bool _running = true;
  String? _error;
  List<Map<String, dynamic>> _result = [];
  List<String> _columns = [];
  Map<String, String> _labels = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() { _running = false; _error = 'Not authenticated'; }); return; }
    final t = widget.template;
    final source = (t['source'] as String?) ?? 'sales';
    final cfg = Map<String, dynamic>.from((t['config'] as Map?) ?? {});
    final rows = List<String>.from(cfg['rows'] ?? const []);
    final cols = List<String>.from(cfg['cols'] ?? const []);
    final values = List<String>.from(cfg['values'] ?? const []);
    final dims = [...rows, ...cols];
    final dateFrom = cfg['date_from'] as String?;
    final dateTo = cfg['date_to'] as String?;

    // Field labels + which fields are measures, so filters split into
    // conditions vs having exactly like the builder.
    final measureFields = <String>{};
    final labels = <String, String>{};
    try {
      final meta = await Supabase.instance.client
          .from('report_field_meta').select().eq('source', source);
      for (final m in meta as List) {
        final f = m['field'] as String?;
        if (f == null) continue;
        labels[f] = (m['label'] as String?) ?? f;
        if (m['kind'] == 'measure') measureFields.add(f);
      }
    } catch (_) {}

    final conditions = <Map<String, dynamic>>[];
    final having = <Map<String, dynamic>>[];
    final rawF = cfg['filters'];
    if (rawF is Map) {
      rawF.forEach((k, v) {
        String op = 'in';
        List<String> vals = [];
        if (v is Map) {
          op = (v['op'] as String?) ?? 'in';
          vals = (v['vals'] is List)
              ? List<String>.from((v['vals'] as List).map((e) => e.toString()))
              : <String>[];
        } else if (v is List) {
          vals = v.map((e) => e.toString()).toList();
        } else if (v != null) {
          op = 'eq'; vals = [v.toString()];
        }
        final key = k.toString();
        if (measureFields.contains(key)) {
          having.add({'measure': key, 'op': op, 'vals': vals});
        } else {
          conditions.add({'field': key, 'op': op, 'vals': vals});
        }
      });
    }

    try {
      final res = await Supabase.instance.client.rpc('rpc_report_query', params: {
        'p_org': orgId, 'p_source': source,
        'p_dims': dims, 'p_measures': values,
        'p_filters': <String, dynamic>{},
        'p_conditions': conditions,
        'p_having': having,
        'p_date_from': dateFrom,
        'p_date_to': dateTo,
      });
      final list = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      // Column order: dims first, then measures, then anything else present.
      final ordered = <String>[...dims, ...values];
      final seen = ordered.toSet();
      if (list.isNotEmpty) {
        for (final key in list.first.keys) {
          if (!seen.contains(key)) { ordered.add(key); seen.add(key); }
        }
      }
      if (mounted) setState(() {
        _result = list;
        _columns = ordered.where((c) => list.isEmpty || list.first.containsKey(c)).toList();
        _labels = labels;
        _running = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _running = false; });
    }
  }

  String _fmt(dynamic v) {
    if (v == null) return '';
    if (v is num) {
      final d = v.toDouble();
      return d == d.roundToDouble()
          ? NumberFormat('#,##0').format(d)
          : NumberFormat('#,##0.00').format(d);
    }
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final name = (widget.template['name'] as String?) ?? 'Report';
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(name),
        backgroundColor: AppTheme.card,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : () { setState(() => _running = true); _run(); },
          ),
        ],
      ),
      body: _running
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24),
                  child: Text('Could not run this report.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.danger))))
              : _result.isEmpty
                  ? const Center(child: Text('No data for this report.',
                      style: TextStyle(color: AppTheme.textSecondary)))
                  : _tableView(),
    );
  }

  Widget _tableView() {
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(AppTheme.background),
          columns: [
            for (final c in _columns)
              DataColumn(label: Text(_labels[c] ?? c,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          ],
          rows: [
            for (final r in _result)
              DataRow(cells: [
                for (final c in _columns)
                  DataCell(Text(_fmt(r[c]), style: const TextStyle(fontSize: 12))),
              ]),
          ],
        ),
      ),
    );
  }
}
