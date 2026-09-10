// Station Master — a rules-based, permission-scoped in-app assistant.
//
// Design notes (important):
//  * NO LLM. Every answer is produced by a deterministic intent matcher that
//    runs org-scoped, permission-checked Supabase queries. There is zero
//    "general" exposure: if the matcher doesn't recognise a system question it
//    says so and lists what it CAN answer. This keeps the assistant strictly
//    "system related", as requested.
//  * PERMISSION-SCOPED, exactly like global search: every data intent is gated
//    by the same route-permission check the navigation menu uses. If the user
//    cannot open the Products screen, Station Master will not answer stock
//    questions for them, etc.
//  * ORG-SCOPED: every query is filtered to the signed-in user's org (and,
//    where the report does, the active branch).
//  * The architecture stays LLM-ready: the UI, the permission layer and the
//    "tools" (the query functions) are separate from the matcher. Swapping the
//    rule matcher for an LLM planner later touches only `_route()`, not the
//    tools or the guardrails.
//
// The widget is a floating bubble mounted in the app shell (MainLayout). It
// only appears when the org has switched it on (app_config
// `org.station_master_enabled`) AND a user is signed in.

// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';
import '../permissions/access_control.dart';
import '../permissions/permission_registry.dart';
import '../layout/main_layout.dart'
    show
        orgModulesProvider,
        selectedBranchProvider,
        poPendingApprovalCountProvider,
        grnPendingInvoiceCountProvider,
        grnSupervisePendingProvider,
        customerSupervisePendingProvider,
        productSupervisePendingProvider,
        piReviewPendingProvider,
        priReviewPendingProvider,
        siReviewPendingProvider,
        jobAckPendingCountProvider,
        transferPendingCountProvider,
        fieldOrderPendingCountProvider,
        retailerOrderPendingCountProvider;

/// Org gate. True only when the org has an `app_config` row
/// `org.station_master_enabled` = 'true'. Default OFF.
final stationMasterEnabledProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.orgId == null) return false;
  try {
    final row = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('org_id', user.orgId!)
        .eq('key', 'org.station_master_enabled')
        .maybeSingle();
    return (row?['value']?.toString().toLowerCase() ?? 'false') == 'true';
  } catch (_) {
    return false;
  }
});

// ─── Chat message model ─────────────────────────────────────────────────────

class _Link {
  final String label;
  final String route;
  const _Link(this.label, this.route);
}

class _Msg {
  final bool fromUser;
  final String text;
  final List<_Link> links; // optional deep-links shown under the answer
  const _Msg(this.fromUser, this.text, {this.links = const []});
}

// ─── The floating bubble + panel ────────────────────────────────────────────

class StationMaster extends ConsumerStatefulWidget {
  const StationMaster({super.key});
  @override
  ConsumerState<StationMaster> createState() => _StationMasterState();
}

class _StationMasterState extends ConsumerState<StationMaster> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final enabled = ref.watch(stationMasterEnabledProvider).valueOrNull ?? false;
    // Hidden entirely unless a user is signed in AND the org enabled it.
    if (user == null || user.orgId == null || !enabled) {
      return const SizedBox.shrink();
    }
    return Positioned(
      right: 18,
      bottom: 18,
      child: _open
          ? _StationPanel(
              onClose: () => setState(() => _open = false),
            )
          : _bubble(),
    );
  }

  Widget _bubble() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () => setState(() => _open = true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.28),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Icons.hub_rounded, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Station Master',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class _StationPanel extends ConsumerStatefulWidget {
  final VoidCallback onClose;
  const _StationPanel({required this.onClose});
  @override
  ConsumerState<_StationPanel> createState() => _StationPanelState();
}

class _StationPanelState extends ConsumerState<_StationPanel> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _msgs.add(const _Msg(false,
        'Hi, I\'m Station Master — your in-system helper. Ask me about your '
        'own data: stock of a product, a customer\'s balance, today\'s sales '
        'or collection, what\'s pending approval, or where a voucher is. '
        'I only answer from areas you\'re allowed to see. Try "help" for '
        'examples.'));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() {
      _msgs.add(_Msg(true, q));
      _busy = true;
    });
    _scrollDown();
    final ctx = _buildCtx();
    _Msg reply;
    try {
      reply = await _route(q, ctx);
    } catch (_) {
      reply = const _Msg(false,
          'Sorry — something went wrong reading that. Please try rephrasing, '
          'or open the relevant screen directly.');
    }
    if (!mounted) return;
    setState(() {
      _msgs.add(reply);
      _busy = false;
    });
    _scrollDown();
  }

  /// Assemble the query context: client, org, active branch, and the SAME
  /// permission closure the menu/global-search use.
  _Ctx _buildCtx() {
    final user = ref.read(currentUserProvider);
    final modules = ref.read(orgModulesProvider).valueOrNull ?? <String>{};
    final access = ref.read(accessSyncProvider);
    final branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    bool can(String route) {
      final mod = kRouteToModule[route];
      if (mod != null && !modules.contains(mod)) return false;
      final r = user?.role;
      if (r == WebUserRole.admin ||
          r == WebUserRole.masterAdmin ||
          r == WebUserRole.superAdmin) {
        return true;
      }
      if (access == null) return false;
      return access.canAccessRouteAt(route, branchId);
    }

    return _Ctx(
      client: Supabase.instance.client,
      orgId: user?.orgId ?? '',
      branchId: branchId,
      access: access,
      can: can,
      ref: ref,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final w = size.width < 460 ? size.width - 24 : 400.0;
    final h = size.height < 640 ? size.height - 120 : 540.0;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.22),
                blurRadius: 26,
                offset: const Offset(0, 10)),
          ],
        ),
        child: Column(children: [
          _header(),
          const Divider(height: 1),
          Expanded(child: _list()),
          const Divider(height: 1),
          _input(),
        ]),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(children: [
        const Icon(Icons.hub_rounded, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        const Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Station Master',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                Text('Answers only from what you can access',
                    style: TextStyle(color: Colors.white60, fontSize: 10.5)),
              ]),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white70, size: 18),
          onPressed: widget.onClose,
          tooltip: 'Close',
        ),
      ]),
    );
  }

  Widget _list() {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _msgs.length + (_busy ? 1 : 0),
      itemBuilder: (c, i) {
        if (i >= _msgs.length) return _typing();
        return _bubbleFor(_msgs[i]);
      },
    );
  }

  Widget _typing() => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const SizedBox(
            width: 34,
            child: Text('…', style: TextStyle(fontSize: 18, height: 0.6)),
          ),
        ),
      );

  Widget _bubbleFor(_Msg m) {
    final align = m.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final bg = m.fromUser ? AppTheme.primary : const Color(0xFFF1F5F9);
    final fg = m.fromUser ? Colors.white : const Color(0xFF0F172A);
    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width < 460 ? 260 : 320),
        child: Column(
          crossAxisAlignment:
              m.fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(m.text,
                  style: TextStyle(color: fg, fontSize: 13, height: 1.35)),
            ),
            if (m.links.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final l in m.links)
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          side: const BorderSide(color: AppTheme.primary),
                        ),
                        icon: const Icon(Icons.north_east, size: 13),
                        label: Text(l.label,
                            style: const TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          widget.onClose();
                          context.go(l.route);
                        },
                      ),
                  ],
                ),
              )
            else
              const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  Widget _input() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            onSubmitted: (_) => _send(),
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Ask about your data…',
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: Color(0xFFCBD5E1))),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Material(
          color: AppTheme.primary,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _send,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.send_rounded, color: Colors.white, size: 18),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─── Query context ──────────────────────────────────────────────────────────

class _Ctx {
  final SupabaseClient client;
  final String orgId;
  final String? branchId;
  final AccessControl? access;
  final bool Function(String route) can;
  final WidgetRef ref;
  const _Ctx({
    required this.client,
    required this.orgId,
    required this.branchId,
    required this.access,
    required this.can,
    required this.ref,
  });

  bool get isAdmin => access?.isAdmin ?? false;
}

// ─── Small helpers ──────────────────────────────────────────────────────────

String _money(num v) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  final whole = parts[0];
  final buf = StringBuffer();
  for (int i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return '${neg ? '-' : ''}Rs ${buf.toString()}.${parts[1]}';
}

String _qty(num v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// A resolved reporting period: a label plus a [start, end) window in UTC ISO
/// (built from local-day boundaries so it matches the dashboard's convention).
class _Period {
  final String label;
  final String startIso;
  final String endIso;
  final String d1; // yyyy-MM-dd of the last day (inclusive) — for date-string cols
  final String d2; // yyyy-MM-dd of the first day (inclusive)
  const _Period(this.label, this.startIso, this.endIso, this.d1, this.d2);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _monthNames = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december'
];

_Period _period(String q) {
  final now = DateTime.now();
  DateTime startDay, endDay; // local-day, endDay inclusive
  String label;

  // Named month, e.g. "in july" / "july 2025". Defaults to the most recent
  // occurrence of that month (this year, or last year if it hasn't happened yet).
  int? mIdx;
  for (var i = 0; i < _monthNames.length; i++) {
    if (RegExp('\\b${_monthNames[i]}\\b').hasMatch(q)) {
      mIdx = i + 1;
      break;
    }
  }
  if (mIdx != null) {
    final yr = RegExp(r'\b(20\d{2})\b').firstMatch(q);
    int year = yr != null ? int.parse(yr.group(1)!) : now.year;
    if (yr == null && mIdx > now.month) year -= 1; // month not reached yet this year
    startDay = DateTime(year, mIdx, 1);
    endDay = DateTime(year, mIdx + 1, 1).subtract(const Duration(days: 1));
    label = '${_monthNames[mIdx - 1][0].toUpperCase()}${_monthNames[mIdx - 1].substring(1)} $year';
    final startIso2 = startDay.toUtc().toIso8601String();
    final endIso2 = endDay.add(const Duration(days: 1)).toUtc().toIso8601String();
    return _Period(label, startIso2, endIso2, _ymd(endDay), _ymd(startDay));
  }

  if (q.contains('yesterday')) {
    final y = now.subtract(const Duration(days: 1));
    startDay = DateTime(y.year, y.month, y.day);
    endDay = startDay;
    label = 'yesterday';
  } else if (q.contains('this week') || q.contains('week')) {
    final monday = now.subtract(Duration(days: now.weekday - 1));
    startDay = DateTime(monday.year, monday.month, monday.day);
    endDay = DateTime(now.year, now.month, now.day);
    label = 'this week';
  } else if (q.contains('last month')) {
    final firstThis = DateTime(now.year, now.month, 1);
    final lastPrev = firstThis.subtract(const Duration(days: 1));
    startDay = DateTime(lastPrev.year, lastPrev.month, 1);
    endDay = lastPrev;
    label = 'last month';
  } else if (q.contains('this month') || q.contains('month')) {
    startDay = DateTime(now.year, now.month, 1);
    endDay = DateTime(now.year, now.month, now.day);
    label = 'this month';
  } else if (q.contains('this year') || q.contains('year')) {
    startDay = DateTime(now.year, 1, 1);
    endDay = DateTime(now.year, now.month, now.day);
    label = 'this year';
  } else {
    startDay = DateTime(now.year, now.month, now.day);
    endDay = startDay;
    label = 'today';
  }
  final startIso = startDay.toUtc().toIso8601String();
  final endIso =
      endDay.add(const Duration(days: 1)).toUtc().toIso8601String();
  return _Period(label, startIso, endIso, _ymd(endDay), _ymd(startDay));
}

/// Strip trigger/period/filler words so what remains is a search term
/// (e.g. a product or customer name).
String _term(String q, List<String> triggers) {
  var s = q.toLowerCase();
  for (final t in triggers) {
    s = s.replaceAll(t, ' ');
  }
  const filler = [
    'today',
    'yesterday',
    'this week',
    'this month',
    'last month',
    'this year',
    'the',
    'of',
    'for',
    'in',
    'do we have',
    'do i have',
    'how much',
    'how many',
    'what is',
    'what\'s',
    'whats',
    'please',
    'show me',
    'tell me',
    '?',
    '.',
  ];
  for (final f in filler) {
    s = s.replaceAll(f, ' ');
  }
  return s.replaceAll(RegExp(r'[%,()]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Break a search phrase into meaningful tokens: drop punctuation, single
/// letters, and common noise words ("sb", "c/o", "and"…). This is what makes
/// "Imran sb C/O Zexel" match a customer stored as "Imran Traders — Zexel".
const _noiseWords = {
  'sb', 'co', 'and', 'the', 'of', 'for', 'in', 'ltd', 'pvt', 'llc',
  'company', 'traders', 'trader', 'store', 'stores', 'shop',
};
List<String> _tokens(String term) {
  return term
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.length >= 2 && !_noiseWords.contains(t))
      .toList();
}

/// Smart, order-independent lookup. Every token must appear in at least one of
/// [cols] (AND across tokens, OR within a token). If nothing matches all
/// tokens, falls back to matching ANY token so we still surface candidates.
Future<List<Map<String, dynamic>>> _smartSearch(
  _Ctx c, {
  required String table,
  required String select,
  required List<String> cols,
  required String term,
  int limit = 6,
}) async {
  final tokens = _tokens(term);
  if (tokens.isEmpty) return const [];
  // Pass 1: AND across tokens.
  var q = c.client.from(table).select(select).eq('org_id', c.orgId);
  for (final t in tokens) {
    q = q.or(cols.map((col) => '$col.ilike.%$t%').join(','));
  }
  var rows = (await q.limit(limit) as List).cast<Map<String, dynamic>>();
  if (rows.isNotEmpty || tokens.length == 1) return rows;
  // Pass 2: OR across every token (broader net).
  final ors = <String>[];
  for (final t in tokens) {
    for (final col in cols) {
      ors.add('$col.ilike.%$t%');
    }
  }
  final q2 = c.client
      .from(table)
      .select(select)
      .eq('org_id', c.orgId)
      .or(ors.join(','));
  rows = (await q2.limit(limit) as List).cast<Map<String, dynamic>>();
  return rows;
}

const _noPerm =
    'You don\'t have access to that area, so I can\'t answer it. Ask an admin '
    'if you think you should.';

// ─── Navigation catalog: "where does X live?" ───────────────────────────────
// A compact map of the screens people ask to find, each with its menu location
// and (permission-checked) deep link. This is what lets Station Master answer
// "where is the sales order screen" conversationally instead of hunting for a
// voucher number.
class _Feature {
  final String name;
  final String menu; // menu trail, e.g. "Sales" or "ERP ▸ Administration"
  final String? route;
  final List<String> aliases;
  const _Feature(this.name, this.menu, this.route, this.aliases);
}

const List<_Feature> _features = [
  // Sales
  _Feature('Sales Orders', 'Sales', '/erp/sales', ['sale order', 'sales order', 'so', 'order']),
  _Feature('Sales Invoices', 'Sales', '/erp/sales-invoices', ['sale invoice', 'sales invoice', 'si', 'invoice', 'bill']),
  _Feature('Quotation', 'Sales', '/erp/quotation', ['quote', 'quotation']),
  _Feature('Delivery Orders', 'Sales', '/erp/delivery-orders', ['delivery order', 'do', 'dispatch note']),
  _Feature('Customers', 'Sales', '/customers', ['customer', 'shop', 'client']),
  _Feature('Field Orders', 'Sales', '/erp/field-orders', ['field order', 'booking']),
  _Feature('Retailer Orders', 'Sales', '/erp/retailer-orders', ['retailer order']),
  _Feature('Customer Ledger', 'Sales', '/erp/customer-ledger', ['customer ledger']),
  _Feature('Customer Aging', 'Sales', '/erp/customer-aging', ['customer aging', 'receivable aging']),
  _Feature('Sales Report', 'Sales', '/erp/sales-report', ['sales report']),
  _Feature('Sales Returns', 'Sales', '/erp/sales-returns', ['sales return', 'sale return']),
  // Purchase
  _Feature('Purchase Orders', 'Purchase', '/erp/purchase', ['purchase order', 'po']),
  _Feature('GRN (Goods Receipt Note)', 'Purchase', '/erp/grn', ['grn', 'goods receipt', 'receipt note']),
  _Feature('Purchase Invoices', 'Purchase', '/erp/purchase-invoices', ['purchase invoice', 'pi', 'supplier bill']),
  _Feature('Suppliers', 'Purchase', '/erp/suppliers', ['supplier', 'vendor']),
  _Feature('Supplier Ledger', 'Purchase', '/erp/supplier-ledger', ['supplier ledger']),
  _Feature('Purchase Returns', 'Purchase', '/erp/purchase-returns', ['purchase return']),
  _Feature('Purchase Report', 'Purchase', '/erp/purchase-report', ['purchase report']),
  // Inventory
  _Feature('Products', 'Inventory', '/erp/products', ['product', 'item', 'sku']),
  _Feature('Stock Levels', 'Inventory', '/erp/stock', ['stock', 'stock level', 'on hand', 'inventory']),
  _Feature('Stock Transfers', 'Inventory', '/erp/stock-transfers', ['stock transfer', 'transfer']),
  _Feature('Stock Adjustment', 'Inventory', '/erp/stock-adjustment', ['stock adjustment', 'adjustment']),
  _Feature('Opening Stock', 'Inventory', '/erp/opening-stock', ['opening stock']),
  _Feature('Inventory Ledger', 'Inventory', '/erp/inventory-ledger', ['inventory ledger', 'stock ledger', 'movement']),
  _Feature('Low Stock Report', 'Inventory', '/erp/low-stock-report', ['low stock', 'reorder']),
  _Feature('Inventory Integrity', 'Inventory', '/erp/inventory-integrity', ['integrity', 'reconcile']),
  _Feature('Units of Measure', 'Inventory', '/erp/uoms', ['uom', 'unit of measure', 'units']),
  // POS
  _Feature('POS Terminal', 'POS', '/erp/pos', ['pos', 'terminal', 'counter', 'till']),
  _Feature('POS Catalog', 'POS', '/erp/pos-catalog', ['pos catalog']),
  // Manufacturing
  _Feature('Production Voucher', 'Manufacturing', '/manufacturing/production-voucher', ['production voucher', 'production']),
  _Feature('Job Card', 'Manufacturing', '/manufacturing/job-card', ['job card', 'work order']),
  _Feature('Product Assembly (BOM)', 'Manufacturing', '/manufacturing/product-assembly', ['bom', 'assembly', 'recipe']),
  _Feature('Production Floor', 'Manufacturing', '/manufacturing/production-floor', ['production floor', 'shop floor', 'floor']),
  _Feature('Production Inverse (Disassembly)', 'Manufacturing', '/manufacturing/production-inverse-voucher', ['disassembly', 'inverse', 'production inverse']),
  _Feature('Damage Stock Voucher', 'Manufacturing', '/manufacturing/damage-stock-voucher', ['damage stock', 'damage', 'write off']),
  // Financials
  _Feature('Chart of Accounts', 'Financials', '/erp/chart-of-accounts', ['chart of accounts', 'coa', 'accounts']),
  _Feature('Journal Vouchers', 'Financials', '/financials/journal-vouchers', ['journal', 'journal voucher', 'jv']),
  _Feature('Payment Vouchers (CPV)', 'Financials', '/erp/payment-vouchers', ['payment voucher', 'cpv', 'payment']),
  _Feature('Receipt Vouchers (CRV)', 'Financials', '/erp/receipt-vouchers', ['receipt voucher', 'crv', 'receipt']),
  _Feature('Trial Balance', 'Financials', '/financials/trial-balance', ['trial balance']),
  _Feature('Profit & Loss', 'Financials', '/financials/profit-loss', ['profit', 'loss', 'p&l', 'profit and loss', 'income statement']),
  _Feature('Balance Sheet', 'Financials', '/financials/balance-sheet', ['balance sheet']),
  _Feature('Cash Book', 'Financials', '/financials/cash-book', ['cash book', 'cashbook']),
  _Feature('Opening Journal', 'Financials', '/financials/opening-journal', ['opening journal', 'opening balance']),
  _Feature('PDC Voucher', 'Financials', '/erp/pdc-voucher', ['pdc', 'post dated cheque', 'cheque']),
  // Reports
  _Feature('Customer Balance Report', 'Reports', '/reports/customer-balance', ['customer balance']),
  _Feature('Supplier Balance Report', 'Reports', '/reports/supplier-balance', ['supplier balance']),
  _Feature('Margin Report', 'Reports', '/reports/margin', ['margin']),
  _Feature('Reports Center', 'Reports', '/reports/center', ['reports center', 'report builder', 'reports']),
  _Feature('Skipped Receipts Report', 'Reports', '/reports/skipped-receipts', ['skipped receipt', 'skipped receipts']),
  // HR
  _Feature('Employee Directory', 'HR', '/hr/employees', ['employee', 'staff', 'directory']),
  _Feature('Attendance', 'HR', '/hr/attendance', ['attendance']),
  _Feature('Attendance Kiosk', 'HR', '/hr/attendance-kiosk', ['kiosk', 'check in']),
  _Feature('Leave', 'HR', '/hr/leave', ['leave', 'time off']),
  // Operations
  _Feature('Dashboard', 'Operations', '/dashboard', ['dashboard']),
  _Feature('Routes', 'Operations', '/routes', ['route']),
  _Feature('Live Map', 'Operations', '/live-map', ['live map', 'map']),
  _Feature('Deliveries', 'Operations', '/deliveries', ['delivery', 'deliveries']),
  _Feature('Team', 'Operations', '/team', ['team']),
  // Admin
  _Feature('Admin Settings', 'ERP', '/erp/admin-settings', ['admin settings', 'settings', 'configuration']),
  _Feature('Branches', 'ERP', '/erp/branches', ['branch', 'warehouse', 'location']),
  _Feature('ERP Users & Permissions', 'ERP ▸ Administration', '/erp/users', ['user', 'permission', 'erp users', 'access']),
  _Feature('Audit Trail', 'ERP ▸ Administration', '/erp/audit-log', ['audit', 'audit trail', 'log', 'history']),
  _Feature('Onboarding Guide', 'ERP', '/erp/onboarding', ['onboarding', 'guide', 'manual', 'help']),
];

/// True when the query is asking where something IS / how to reach it, rather
/// than asking for a data value.
bool _isNavQuery(String q) {
  return q.startsWith('where') ||
      q.contains('where is') ||
      q.contains('where do i') ||
      q.contains('where can i') ||
      q.contains('how do i find') ||
      q.contains('how to find') ||
      q.contains('how do i open') ||
      q.contains('how to open') ||
      q.contains('how do i get to') ||
      q.contains('take me to') ||
      q.contains('go to ') ||
      q.contains('open the ') ||
      q.contains('navigate') ||
      q.contains('which menu') ||
      q.contains('find the ');
}

_Feature? _findFeature(String term) {
  final toks = _tokens(term);
  if (toks.isEmpty) return null;
  final t = term.toLowerCase().trim();
  _Feature? best;
  int bestScore = 0;
  for (final f in _features) {
    final hay = ('${f.name} ${f.aliases.join(' ')}').toLowerCase();
    final nameWords = f.name
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.isNotEmpty)
        .toSet();
    int s = 0;
    for (final tok in toks) {
      if (hay.contains(tok)) s += 1;
      if (nameWords.contains(tok)) s += 2;
    }
    if (f.aliases.contains(t)) s += 4;
    if (f.name.toLowerCase() == t) s += 6;
    if (s > bestScore) {
      bestScore = s;
      best = f;
    }
  }
  return bestScore >= 2 ? best : null;
}

Future<_Msg?> _navigate(String raw, _Ctx c) async {
  final term = _term(raw, [
    'where is', 'where do i find', 'where do i', 'where can i find', 'where can i',
    'how do i find', 'how to find', 'how do i open', 'how to open',
    'how do i get to', 'take me to', 'go to', 'open the', 'navigate to',
    'navigate', 'which menu', 'find the', 'located in', 'located',
    'lives', 'live',
  ]);
  final f = _findFeature(term.isEmpty ? raw : term);
  if (f == null) return null;
  final canOpen = f.route != null && c.can(f.route!);
  final trail = '${f.menu}  ▸  ${f.name}';
  if (canOpen) {
    return _Msg(
      false,
      'You\'ll find ${f.name} under $trail. Want me to open it? Tap below.',
      links: [_Link('Open ${f.name}', f.route!)],
    );
  }
  // Known screen, but this user can't reach it.
  return _Msg(
    false,
    '${f.name} lives under $trail — but your access doesn\'t include it, so I '
    'can\'t open it for you. An admin can grant it.',
  );
}

// ─── Intent router ──────────────────────────────────────────────────────────

Future<_Msg> _route(String raw, _Ctx c) async {
  final q = raw.toLowerCase().trim();

  // Greetings / help / capabilities.
  if (RegExp(r'^(hi|hello|hey|salam|assalam|help|what can you do|what can i ask|menu)\b')
          .hasMatch(q) ||
      q == 'help' ||
      q.contains('what can you')) {
    return _help();
  }

  // Small talk — keep it human without wandering off-system.
  if (RegExp(r'^(thanks|thank you|thankyou|thx|shukriya|ok|okay|great|cool|nice|good job|got it)\b')
      .hasMatch(q)) {
    return const _Msg(false,
        'Anytime! Ask me whenever you need a number or want to find a screen. 🙂');
  }
  if (q.contains('who are you') ||
      q.contains('what are you') ||
      q.contains('your name')) {
    return const _Msg(false,
        'I\'m Station Master — a built-in helper for Opstation. I answer from '
        'your own data (stock, balances, sales, approvals) and help you find any '
        'screen, and I only show what you\'re allowed to see. Try "sales today" '
        'or "where is the sales order screen".');
  }

  // Navigation — "where is the sales order screen", "take me to GRN".
  if (_isNavQuery(q) && !q.contains('stock of') && !q.contains('balance of')) {
    final nav = await _navigate(raw, c);
    if (nav != null) return nav;
    // Not a known screen — it might be a voucher number instead.
    if (_voucherToken(raw) != null) return _voucherLookup(raw, c);
    // Otherwise fall through to the normal intents below.
  }

  // Pending approvals / what needs my attention.
  if (q.contains('pending') ||
      q.contains('approval') ||
      q.contains('to approve') ||
      q.contains('needs approval') ||
      q.contains('waiting') ||
      q.contains('attention')) {
    return _pending(c);
  }

  // Collection (field cash collected) — sensitive, admin-gated like dashboard.
  if (q.contains('collection') ||
      q.contains('collected') ||
      (q.contains('collect') && !q.contains('recollect'))) {
    return _collection(q, c);
  }

  // Active routes / trips running.
  if ((q.contains('route') || q.contains('trip')) &&
      (q.contains('active') ||
          q.contains('running') ||
          q.contains('open') ||
          q.contains('on road') ||
          q.contains('out'))) {
    return _activeRoutes(c);
  }

  // Voucher activity by a user — "how many vouchers did Ammar create today".
  if ((q.contains('how many') || q.contains('number of') || q.contains('count')) &&
      (q.contains('voucher') ||
          q.contains('invoice') ||
          q.contains('document') ||
          q.contains('entries') ||
          q.contains('created') ||
          q.contains('booked') ||
          q.contains('posted') ||
          q.contains('made') ||
          q.contains('entered'))) {
    return _voucherActivity(q, c);
  }

  // Top-selling products / best sellers.
  if (q.contains('best sell') ||
      q.contains('best-sell') ||
      q.contains('top sell') ||
      q.contains('top-sell') ||
      q.contains('highest sell') ||
      q.contains('most sold') ||
      q.contains('most selling') ||
      q.contains('best seller') ||
      q.contains('top product') ||
      q.contains('top sku') ||
      ((q.contains('top ') || q.contains('highest')) &&
          (q.contains('sell') || q.contains('sold') || q.contains('sku') ||
              q.contains('product') || q.contains('item')))) {
    return _topProducts(q, c);
  }

  // Sales summary.
  if (q.contains('sale') || q.contains('sales') || q.contains('revenue')) {
    if (_looksLikeSummary(q)) return _salesSummary(q, c);
  }

  // Purchase summary.
  if (q.contains('purchase') || q.contains('bought') || q.contains('buying')) {
    if (_looksLikeSummary(q)) return _purchaseSummary(q, c);
  }

  // Supplier balance / payable.
  if (q.contains('supplier') ||
      q.contains('vendor') ||
      q.contains('payable') ||
      q.contains('we owe') ||
      q.contains('to pay')) {
    if (q.contains('balance') ||
        q.contains('payable') ||
        q.contains('owe') ||
        q.contains('outstanding')) {
      return _supplierBalance(q, c);
    }
  }

  // Customer balance / receivable.
  if (q.contains('balance') ||
      q.contains('receivable') ||
      q.contains('owes') ||
      q.contains('owe us') ||
      q.contains('outstanding')) {
    return _customerBalance(q, c);
  }

  // Voucher lookup — "where is INV-2026-0041", "find CRV-2026-16", "status of …"
  // Skip when the query is clearly a stock/inventory question that merely
  // contains a code-looking token.
  final bool stockish = q.contains('stock') ||
      q.contains('inventory') ||
      q.contains('how much') ||
      q.contains('how many');
  if (q.contains('status of') ||
      q.contains('look up') ||
      q.contains('lookup') ||
      (q.contains('find ') && !stockish) ||
      (!stockish && _voucherToken(raw) != null)) {
    return _voucherLookup(raw, c);
  }

  // Stock / product lookup (default for "stock of…", "how much X"). Skip when
  // the question is really about documents/people (handled above).
  final bool docWord = q.contains('voucher') ||
      q.contains('invoice') ||
      q.contains('document') ||
      q.contains('created') ||
      q.contains('booked') ||
      q.contains('posted');
  if (!docWord &&
      (q.contains('stock') ||
          q.contains('inventory') ||
          q.contains('quantity') ||
          q.contains('qty') ||
          q.contains('available') ||
          q.contains('on hand') ||
          q.contains('how much') ||
          q.contains('how many'))) {
    return _stock(q, c);
  }

  return _fallback();
}

bool _looksLikeSummary(String q) =>
    q.contains('today') ||
    q.contains('yesterday') ||
    q.contains('week') ||
    q.contains('month') ||
    q.contains('year') ||
    q.contains('total') ||
    q.contains('how much') ||
    q.contains('summary') ||
    q.contains('so far');

_Msg _help() {
  return const _Msg(
    false,
    'Here are things I can look up for you (only where you have access):\n\n'
    '• Stock — "stock of GM Cable", "how many boxes of X"\n'
    '• Customer balance — "balance of Ali Traders", "who owes us"\n'
    '• Supplier balance — "how much do we owe Umar Steel"\n'
    '• Sales — "sales today", "sales this month"\n'
    '• Top sellers — "best selling product in July", "top SKUs this month"\n'
    '• Purchases — "purchases this month"\n'
    '• Collection — "collection today" (admins)\n'
    '• Active routes — "which routes are running now" (admins)\n'
    '• Pending approvals — "what\'s pending approval"\n'
    '• Find a voucher — "where is INV-2026-0041"\n'
    '• Find a screen — "where is the sales order screen", "take me to GRN"\n\n'
    'I only answer from your own system data — nothing general.',
  );
}

_Msg _fallback() {
  return const _Msg(
    false,
    'I can only answer questions about your Opstation data, and I didn\'t '
    'catch a match for that. Try one of these:\n\n'
    '• "stock of <product>"\n'
    '• "balance of <customer>"\n'
    '• "sales today" / "sales this month"\n'
    '• "what\'s pending approval"\n'
    '• "where is <voucher number>"\n\n'
    'Type "help" for the full list.',
  );
}

// ─── Intent: voucher activity by a user ─────────────────────────────────────
// "How many vouchers did Ammar create today?" — counts documents booked by a
// named user in a period. Admin-only (it reveals another person's activity).

const List<List<String>> _activityTables = [
  ['sales_invoices', 'sales invoice', 'voucher_date'],
  ['purchase_invoices', 'purchase invoice', 'voucher_date'],
  ['purchase_grns', 'GRN', 'voucher_date'],
  ['sales_orders', 'sales order', 'voucher_date'],
  ['purchase_orders', 'purchase order', 'voucher_date'],
  ['stock_transfers', 'stock transfer', 'transfer_date'],
];

Future<_Msg> _voucherActivity(String q, _Ctx c) async {
  if (!c.isAdmin) {
    return const _Msg(false,
        'Counting another person\'s activity is restricted. Please ask an admin.');
  }
  final term = _term(q, [
    'how many', 'number of', 'count', 'vouchers', 'voucher', 'invoices',
    'invoice', 'documents', 'document', 'entries', 'entry', 'did', 'has',
    'have', 'create', 'created', 'creates', 'make', 'made', 'makes', 'book',
    'booked', 'post', 'posted', 'enter', 'entered', 'by', 'user', 'total',
    'so far',
  ]);
  var name = term;
  for (final m in _monthNames) {
    name = name.replaceAll(m, ' ');
  }
  name = name
      .replaceAll(RegExp(r'\b(this|last|month|week|year|today|yesterday|day|days|period|the)\b'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length < 2) {
    return const _Msg(false,
        'Whose activity? e.g. "how many vouchers did Ammar create today".');
  }
  final users = await _smartSearch(c,
      table: 'users', select: 'id, name', cols: ['name'], term: name);
  if (users.isEmpty) {
    return _Msg(false, 'I couldn\'t find a user named "$name".');
  }
  final user = users.first;
  final uid = user['id'] as String;
  final uname = (user['name'] ?? name) as String;
  final p = _period(q);

  int total = 0;
  final parts = <String>[];
  for (final t in _activityTables) {
    try {
      final rows = await c.client
          .from(t[0])
          .select('id')
          .eq('org_id', c.orgId)
          .eq('created_by', uid)
          .gte(t[2], p.d2)
          .lte(t[2], p.d1);
      final n = (rows as List).length;
      if (n > 0) {
        total += n;
        parts.add('$n ${t[1]}${n == 1 ? '' : 's'}');
      }
    } catch (_) {
      // table has no created_by / different date column — skip quietly
    }
  }
  if (total == 0) {
    return _Msg(false, '$uname booked no documents ${p.label}.');
  }
  return _Msg(
    false,
    '$uname booked $total document${total == 1 ? '' : 's'} ${p.label}:\n\n'
    '${parts.map((e) => '• $e').join('\n')}',
  );
}

// ─── Intent: stock ──────────────────────────────────────────────────────────

Future<_Msg> _stock(String q, _Ctx c) async {
  if (!c.can('/erp/products') && !c.can('/erp/stock')) {
    return const _Msg(false, _noPerm);
  }
  final term = _term(q, ['stock', 'inventory', 'quantity', 'qty', 'available',
    'on hand', 'left', 'remaining', 'boxes', 'pieces', 'units']);
  if (term.length < 2) {
    return const _Msg(false,
        'Which product? e.g. "stock of GM Cable" or "how much 2-Stroke oil".');
  }
  final list = await _smartSearch(c,
      table: 'products',
      select: 'id, name, sku',
      cols: ['name', 'sku'],
      term: term);
  if (list.isEmpty) {
    return _Msg(false, 'I couldn\'t find a product matching "$term".');
  }
  // For each match, sum stock across branches (respect active branch if set).
  final ids = list.map((p) => p['id'] as String).toList();
  var sq = c.client
      .from('inventory_stock')
      .select('product_id, quantity, branch_id, branches(name)')
      .eq('org_id', c.orgId)
      .inFilter('product_id', ids);
  if (c.branchId != null) sq = sq.eq('branch_id', c.branchId!);
  final stockRows = (await sq as List).cast<Map<String, dynamic>>();
  final byProd = <String, double>{};
  final byProdBranch = <String, Map<String, double>>{};
  for (final r in stockRows) {
    final pid = r['product_id'] as String;
    final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
    byProd[pid] = (byProd[pid] ?? 0) + qty;
    final bn = (r['branches']?['name'] as String?) ?? 'Branch';
    (byProdBranch[pid] ??= {})[bn] = ((byProdBranch[pid]?[bn]) ?? 0) + qty;
  }
  final buf = StringBuffer();
  final scopeNote =
      c.branchId != null ? ' (current branch only)' : ' (all branches)';
  for (final p in list) {
    final pid = p['id'] as String;
    final total = byProd[pid] ?? 0;
    final name = (p['name'] ?? '') as String;
    final sku = (p['sku'] ?? '').toString();
    buf.writeln('${name}${sku.isNotEmpty ? ' ($sku)' : ''}: ${_qty(total)} in stock');
    final br = byProdBranch[pid];
    if (br != null && br.length > 1 && c.branchId == null) {
      final parts = br.entries.map((e) => '${e.key}: ${_qty(e.value)}').join(', ');
      buf.writeln('   $parts');
    }
  }
  return _Msg(
    false,
    'Stock$scopeNote:\n\n${buf.toString().trimRight()}',
    links: [_Link('Open Stock', '/erp/stock')],
  );
}

// ─── Intent: customer balance ───────────────────────────────────────────────

Future<_Msg> _customerBalance(String q, _Ctx c) async {
  if (!c.can('/reports/customer-balance') && !c.can('/erp/customer-ledger')) {
    return const _Msg(false, _noPerm);
  }
  final term = _term(q, ['balance', 'receivable', 'owes', 'owe us', 'owe',
    'outstanding', 'customer', 'client', 'shop', 'due from', 'due']);
  if (term.length < 2) {
    return const _Msg(false,
        'Which customer? e.g. "balance of Ali Traders".');
  }
  final list = await _smartSearch(c,
      table: 'customers',
      select: 'id, shop_name, code',
      cols: ['shop_name', 'code'],
      term: term);
  if (list.isEmpty) {
    return _Msg(false, 'I couldn\'t find a customer matching "$term".');
  }
  final today = _ymd(DateTime.now());
  final branchIds = c.isAdmin
      ? null
      : (c.access?.branchIds.isNotEmpty ?? false
          ? c.access!.branchIds.toList()
          : null);
  final res = await c.client.rpc('rpc_customer_balance_report', params: {
    'p_org_id': c.orgId,
    'p_d1': today,
    'p_d2': today,
    'p_d3': today,
    'p_branch_ids': branchIds,
  });
  final byId = <String, num>{};
  for (final r in (res as List)) {
    byId[r['customer_id'] as String] = (r['bal3'] as num?) ?? 0;
  }
  final buf = StringBuffer();
  for (final cust in list) {
    final id = cust['id'] as String;
    final name = (cust['shop_name'] ?? '') as String;
    final bal = byId[id] ?? 0;
    if (bal > 0) {
      buf.writeln('$name owes ${_money(bal)}');
    } else if (bal < 0) {
      buf.writeln('$name is in advance/credit ${_money(bal.abs())}');
    } else {
      buf.writeln('$name has a clear balance (Rs 0.00)');
    }
  }
  return _Msg(
    false,
    'As of today:\n\n${buf.toString().trimRight()}',
    links: [_Link('Customer balances', '/reports/customer-balance')],
  );
}

// ─── Intent: supplier balance ───────────────────────────────────────────────

Future<_Msg> _supplierBalance(String q, _Ctx c) async {
  if (!c.can('/reports/supplier-balance') && !c.can('/erp/supplier-ledger')) {
    return const _Msg(false, _noPerm);
  }
  final term = _term(q, ['balance', 'payable', 'we owe', 'owe', 'outstanding',
    'supplier', 'vendor', 'to pay', 'due to']);
  if (term.length < 2) {
    return const _Msg(false,
        'Which supplier? e.g. "how much do we owe Umar Steel".');
  }
  final list = await _smartSearch(c,
      table: 'suppliers',
      select: 'id, name',
      cols: ['name'],
      term: term);
  if (list.isEmpty) {
    return _Msg(false, 'I couldn\'t find a supplier matching "$term".');
  }
  final today = _ymd(DateTime.now());
  final res = await c.client.rpc('rpc_supplier_balance_report', params: {
    'p_org_id': c.orgId,
    'p_d1': today,
    'p_d2': today,
    'p_d3': today,
    'p_branch_ids': null,
  });
  // RPC returns credit - debit (payable positive). We keep that: payable > 0.
  // Some deployments return `supplier_id`, others only `name`, so index both.
  final byId = <String, num>{};
  final byName = <String, num>{};
  for (final r in (res as List)) {
    final bal = (r['bal3'] as num?) ?? 0;
    final sid = r['supplier_id'] as String?;
    if (sid != null) byId[sid] = bal;
    final nm = (r['name'] as String?)?.trim().toLowerCase();
    if (nm != null && nm.isNotEmpty) byName[nm] = bal;
  }
  final buf = StringBuffer();
  for (final s in list) {
    final id = s['id'] as String;
    final name = (s['name'] ?? '') as String;
    final bal = byId[id] ?? byName[name.trim().toLowerCase()] ?? 0;
    if (bal > 0) {
      buf.writeln('We owe $name ${_money(bal)}');
    } else if (bal < 0) {
      buf.writeln('$name: we\'re in advance ${_money(bal.abs())}');
    } else {
      buf.writeln('$name: nothing outstanding (Rs 0.00)');
    }
  }
  return _Msg(
    false,
    'AP control, as of today (advances not folded in):\n\n'
    '${buf.toString().trimRight()}',
    links: [_Link('Supplier balances', '/reports/supplier-balance')],
  );
}

// ─── Intent: sales summary ──────────────────────────────────────────────────

/// Strip every generic "sales summary" word (and the period words / month
/// names) so that whatever remains is the entity the user named — a customer
/// or a product — if any.
String _entityTerm(String q) {
  var s = _term(q, [
    'total', 'totals', 'sale', 'sales', 'revenue', 'sold', 'sell', 'selling',
    'purchase', 'purchases', 'bought', 'buying', 'summary', 'so far', 'made',
    'did', 'do', 'does', 'we', 'our', 'my', 'value', 'worth', 'amount',
    'figure', 'figures', 'number', 'numbers', 'report', 'builder', 'show',
    'tell', 'give', 'all', 'net', 'gross', 'to', 'from', 'much', 'many',
  ]);
  for (final m in _monthNames) {
    s = s.replaceAll(m, ' ');
  }
  s = s
      .replaceAll(RegExp(r'\b(this|last|month|week|year|today|yesterday|day|days|period|the)\b'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s;
}

Future<_Msg> _salesSummary(String q, _Ctx c) async {
  if (!c.can('/erp/sales-report') && !c.can('/erp/sales-invoices')) {
    return const _Msg(false, _noPerm);
  }
  final p = _period(q);
  final scope = c.branchId != null ? ' (current branch)' : '';
  final entity = _entityTerm(q);

  // ── Named entity: a specific customer, or a specific product ──
  if (entity.length >= 2) {
    // 1) Customer?
    final custs = await _smartSearch(c,
        table: 'customers',
        select: 'id, shop_name',
        cols: ['shop_name', 'code'],
        term: entity);
    if (custs.isNotEmpty) {
      final ids = custs.map((e) => e['id'] as String).toList();
      var cq = c.client
          .from('sales_invoices')
          .select('grand_total, branch_id')
          .eq('org_id', c.orgId)
          .eq('is_voided', false)
          .inFilter('customer_id', ids)
          .gte('voucher_date', p.d2)
          .lte('voucher_date', p.d1);
      if (c.branchId != null) cq = cq.eq('branch_id', c.branchId!);
      final rows = (await cq as List).cast<Map<String, dynamic>>();
      double total = 0;
      for (final r in rows) {
        total += (r['grand_total'] as num?)?.toDouble() ?? 0;
      }
      final who = custs.length == 1
          ? (custs.first['shop_name'] ?? 'that customer') as String
          : '${custs.length} matching customers';
      return _Msg(
        false,
        'Sales to $who ${p.label}$scope: ${_money(total)} across ${rows.length} '
        'invoice${rows.length == 1 ? '' : 's'}.',
        links: [_Link('Sales report', '/erp/sales-report')],
      );
    }
    // 2) Product? (sum invoice-line value for that item)
    final prods = await _smartSearch(c,
        table: 'products',
        select: 'id, name',
        cols: ['name', 'sku'],
        term: entity);
    if (prods.isNotEmpty) {
      final ids = prods.map((e) => e['id'] as String).toList();
      var pq = c.client
          .from('sales_invoice_items')
          .select(
              'qty_delivered, line_total, sales_invoices!inner(org_id, is_voided, voucher_date, branch_id)')
          .eq('sales_invoices.org_id', c.orgId)
          .eq('sales_invoices.is_voided', false)
          .inFilter('product_id', ids)
          .gte('sales_invoices.voucher_date', p.d2)
          .lte('sales_invoices.voucher_date', p.d1);
      if (c.branchId != null) {
        pq = pq.eq('sales_invoices.branch_id', c.branchId!);
      }
      final rows = (await pq as List).cast<Map<String, dynamic>>();
      double total = 0, units = 0;
      for (final r in rows) {
        total += (r['line_total'] as num?)?.toDouble() ?? 0;
        units += (r['qty_delivered'] as num?)?.toDouble() ?? 0;
      }
      final who = prods.length == 1
          ? (prods.first['name'] ?? 'that product') as String
          : '${prods.length} matching products';
      return _Msg(
        false,
        'Sales of $who ${p.label}$scope: ${_money(total)} '
        '(${_qty(units)} sold).',
        links: [_Link('Sales report', '/erp/sales-report')],
      );
    }
    // Named something we couldn't match — say so rather than silently returning
    // the org-wide figure.
    return _Msg(
      false,
      'I couldn\'t find a customer or product called "$entity". For the '
      'whole-company figure, ask e.g. "total sales ${p.label}".',
    );
  }

  // ── No entity: org-wide total ──
  var query = c.client
      .from('sales_invoices')
      .select('grand_total, branch_id')
      .eq('org_id', c.orgId)
      .eq('is_voided', false)
      .gte('voucher_date', p.d2)
      .lte('voucher_date', p.d1);
  if (c.branchId != null) query = query.eq('branch_id', c.branchId!);
  final rows = (await query as List).cast<Map<String, dynamic>>();
  double total = 0;
  for (final r in rows) {
    total += (r['grand_total'] as num?)?.toDouble() ?? 0;
  }
  return _Msg(
    false,
    'Total sales ${p.label}$scope: ${_money(total)} across ${rows.length} '
    'invoice${rows.length == 1 ? '' : 's'}.',
    links: [_Link('Sales report', '/erp/sales-report')],
  );
}

// ─── Intent: top-selling products ───────────────────────────────────────────

Future<_Msg> _topProducts(String q, _Ctx c) async {
  if (!c.can('/erp/sales-report') && !c.can('/erp/sales-invoices')) {
    return const _Msg(false, _noPerm);
  }
  final p = _period(q);
  final byUnits = q.contains('unit') ||
      q.contains('quantity') ||
      q.contains('qty') ||
      q.contains('volume') ||
      q.contains('most sold');

  // Inner-join the parent invoice so we can filter by org/date/branch without a
  // giant id list. Only posted (non-voided) invoices count.
  var query = c.client
      .from('sales_invoice_items')
      .select(
          'product_id, qty_delivered, line_total, sales_invoices!inner(org_id, is_voided, voucher_date, branch_id)')
      .eq('sales_invoices.org_id', c.orgId)
      .eq('sales_invoices.is_voided', false)
      .gte('sales_invoices.voucher_date', p.d2)
      .lte('sales_invoices.voucher_date', p.d1);
  if (c.branchId != null) {
    query = query.eq('sales_invoices.branch_id', c.branchId!);
  }
  final rows = (await query as List).cast<Map<String, dynamic>>();
  if (rows.isEmpty) {
    return _Msg(false, 'No sales found for ${p.label}.');
  }
  final val = <String, double>{};
  final units = <String, double>{};
  for (final r in rows) {
    final pid = r['product_id'] as String?;
    if (pid == null) continue;
    val[pid] = (val[pid] ?? 0) + ((r['line_total'] as num?)?.toDouble() ?? 0);
    units[pid] =
        (units[pid] ?? 0) + ((r['qty_delivered'] as num?)?.toDouble() ?? 0);
  }
  final ids = val.keys.toList()
    ..sort((a, b) => byUnits
        ? (units[b] ?? 0).compareTo(units[a] ?? 0)
        : (val[b] ?? 0).compareTo(val[a] ?? 0));
  final topIds = ids.take(5).toList();
  final prods = (await c.client
          .from('products')
          .select('id, name, sku')
          .eq('org_id', c.orgId)
          .inFilter('id', topIds) as List)
      .cast<Map<String, dynamic>>();
  final info = {for (final pr in prods) pr['id'] as String: pr};

  final buf = StringBuffer();
  for (var i = 0; i < topIds.length; i++) {
    final id = topIds[i];
    final pr = info[id];
    final name = (pr?['name'] ?? 'Product') as String;
    final sku = (pr?['sku'] ?? '').toString();
    buf.writeln('${i + 1}. $name${sku.isNotEmpty ? ' ($sku)' : ''} — '
        '${_qty(units[id] ?? 0)} sold, ${_money(val[id] ?? 0)}');
  }
  final basis = byUnits ? 'by units sold' : 'by sales value';
  final scope = c.branchId != null ? ', current branch' : '';
  return _Msg(
    false,
    'Top sellers — ${p.label} ($basis$scope):\n\n${buf.toString().trimRight()}',
    links: [_Link('Sales report', '/erp/sales-report')],
  );
}

// ─── Intent: purchase summary ───────────────────────────────────────────────

Future<_Msg> _purchaseSummary(String q, _Ctx c) async {
  if (!c.can('/erp/purchase-report') && !c.can('/erp/purchase-invoices')) {
    return const _Msg(false, _noPerm);
  }
  final p = _period(q);
  var query = c.client
      .from('purchase_invoices')
      .select('grand_total, branch_id')
      .eq('org_id', c.orgId)
      .gte('voucher_date', p.d2)
      .lte('voucher_date', p.d1);
  if (c.branchId != null) query = query.eq('branch_id', c.branchId!);
  List rows;
  try {
    rows = await query as List;
  } catch (_) {
    // Some schemas name the total differently; retry with a permissive select.
    var q2 = c.client
        .from('purchase_invoices')
        .select('*')
        .eq('org_id', c.orgId)
        .gte('voucher_date', p.d2)
        .lte('voucher_date', p.d1);
    if (c.branchId != null) q2 = q2.eq('branch_id', c.branchId!);
    rows = await q2 as List;
  }
  double total = 0;
  for (final r in rows.cast<Map<String, dynamic>>()) {
    total += ((r['grand_total'] ?? r['total'] ?? r['total_amount'] ??
                r['net_amount']) as num?)
            ?.toDouble() ??
        0;
  }
  final scope = c.branchId != null ? ' (current branch)' : '';
  return _Msg(
    false,
    'Purchases ${p.label}$scope: ${_money(total)} across ${rows.length} '
    'invoice${rows.length == 1 ? '' : 's'}.',
    links: [_Link('Purchase report', '/erp/purchase-report')],
  );
}

// ─── Intent: collection (field cash) — admin only ───────────────────────────

Future<_Msg> _collection(String q, _Ctx c) async {
  if (!c.isAdmin) {
    return const _Msg(false,
        'Collection figures are restricted. Please ask an admin.');
  }
  final p = _period(q);
  // Mirrors the dashboard: field visits with an amount, in the period window.
  final rows = (await c.client
          .from('visits')
          .select('amount, customer_id')
          .gte('timestamp', p.startIso)
          .lt('timestamp', p.endIso) as List)
      .cast<Map<String, dynamic>>();
  double total = 0;
  final shops = <String>{};
  for (final v in rows) {
    final amt = (v['amount'] as num?)?.toDouble() ?? 0;
    total += amt;
    if (amt > 0 && v['customer_id'] != null) shops.add(v['customer_id'] as String);
  }
  return _Msg(
    false,
    'Collection ${p.label}: ${_money(total)} from ${shops.length} '
    'shop${shops.length == 1 ? '' : 's'}.',
  );
}

// ─── Intent: active routes — admin only ─────────────────────────────────────

Future<_Msg> _activeRoutes(_Ctx c) async {
  if (!c.isAdmin) {
    return const _Msg(false, 'Route status is restricted. Please ask an admin.');
  }
  final rows = (await c.client
          .from('trips')
          .select('id, route_id')
          .eq('org_id', c.orgId)
          .filter('ended_at', 'is', null) as List)
      .cast<Map<String, dynamic>>();
  if (rows.isEmpty) {
    return const _Msg(false, 'No routes are running right now.');
  }
  // Resolve route names in one follow-up query (avoids depending on an embed
  // relationship name).
  final routeIds =
      rows.map((r) => r['route_id'] as String?).whereType<String>().toSet();
  final nameById = <String, String>{};
  if (routeIds.isNotEmpty) {
    final rr = (await c.client
            .from('sales_routes')
            .select('id, name')
            .eq('org_id', c.orgId)
            .inFilter('id', routeIds.toList()) as List)
        .cast<Map<String, dynamic>>();
    for (final r in rr) {
      nameById[r['id'] as String] = (r['name'] as String?) ?? '(route)';
    }
  }
  final names = rows
      .map((r) => nameById[r['route_id']] ?? '(route)')
      .toList();
  final show = names.take(10).join(', ');
  final more = names.length > 10 ? ' …and ${names.length - 10} more' : '';
  return _Msg(
    false,
    '${rows.length} route${rows.length == 1 ? '' : 's'} running now: $show$more.',
  );
}

// ─── Intent: pending approvals ──────────────────────────────────────────────

Future<_Msg> _pending(_Ctx c) async {
  final items = <String>[];
  Future<int> read(provider) async {
    try {
      return await c.ref.read(provider.future) as int;
    } catch (_) {
      return 0;
    }
  }

  // Only surface a queue the user can actually act on.
  if (c.can('/erp/purchase')) {
    final n = await read(poPendingApprovalCountProvider);
    if (n > 0) items.add('$n purchase order${n == 1 ? '' : 's'} to approve');
  }
  if (c.can('/erp/grn')) {
    final n = await read(grnPendingInvoiceCountProvider);
    if (n > 0) items.add('$n GRN${n == 1 ? '' : 's'} not yet invoiced');
    final s = await read(grnSupervisePendingProvider);
    if (s > 0) items.add('$s GRN${s == 1 ? '' : 's'} awaiting supervision');
  }
  if (c.can('/erp/purchase-invoices')) {
    final n = await read(piReviewPendingProvider);
    if (n > 0) items.add('$n purchase invoice${n == 1 ? '' : 's'} to review');
  }
  if (c.can('/erp/purchase-return-vouchers')) {
    final n = await read(priReviewPendingProvider);
    if (n > 0) items.add('$n purchase return${n == 1 ? '' : 's'} to review');
  }
  if (c.can('/erp/sales-invoices')) {
    final n = await read(siReviewPendingProvider);
    if (n > 0) items.add('$n sales invoice${n == 1 ? '' : 's'} to review');
  }
  if (c.can('/erp/products')) {
    final n = await read(productSupervisePendingProvider);
    if (n > 0) items.add('$n product${n == 1 ? '' : 's'} awaiting supervision');
  }
  if (c.can('/customers') || c.can('/erp/customer-ledger')) {
    final n = await read(customerSupervisePendingProvider);
    if (n > 0) items.add('$n customer${n == 1 ? '' : 's'} awaiting supervision');
  }
  if (c.isAdmin) {
    final j = await read(jobAckPendingCountProvider);
    if (j > 0) items.add('$j job card${j == 1 ? '' : 's'} to acknowledge');
    final t = await read(transferPendingCountProvider);
    if (t > 0) items.add('$t stock transfer${t == 1 ? '' : 's'} to receive');
    final f = await read(fieldOrderPendingCountProvider);
    if (f > 0) items.add('$f field order${f == 1 ? '' : 's'} pending');
    final r = await read(retailerOrderPendingCountProvider);
    if (r > 0) items.add('$r retailer order${r == 1 ? '' : 's'} pending');
  }

  if (items.isEmpty) {
    return const _Msg(false,
        'Nothing is pending your approval right now. All clear ✅');
  }
  return _Msg(
    false,
    'Pending for you:\n\n${items.map((e) => '• $e').join('\n')}',
  );
}

// ─── Intent: voucher lookup ─────────────────────────────────────────────────

/// A token that looks like a voucher number: letters/digits with a dash, or a
/// long digit run. Loose on purpose.
String? _voucherToken(String raw) {
  final m = RegExp(r'([A-Za-z]{2,4}-?\d{2,4}-?\d{2,6}|\b\d{4,}\b)')
      .firstMatch(raw);
  return m?.group(0);
}

class _VTable {
  final String table;
  final String label;
  final String route;
  final String dateCol;
  final String? permRoute;
  const _VTable(this.table, this.label, this.route, this.dateCol, this.permRoute);
}

Future<_Msg> _voucherLookup(String raw, _Ctx c) async {
  final token = _voucherToken(raw) ??
      _term(raw, ['where is', 'find', 'status of', 'look up', 'lookup',
        'voucher', 'invoice']);
  if (token.trim().length < 2) {
    return const _Msg(false,
        'Which voucher? Give me its number, e.g. "where is INV-2026-0041".');
  }
  final t = token.trim();
  const tables = [
    _VTable('sales_invoices', 'Sales Invoice', '/erp/sales-invoices',
        'voucher_date', '/erp/sales-invoices'),
    _VTable('purchase_invoices', 'Purchase Invoice', '/erp/purchase-invoices',
        'voucher_date', '/erp/purchase-invoices'),
    _VTable('purchase_orders', 'Purchase Order', '/erp/purchase',
        'voucher_date', '/erp/purchase'),
    _VTable('sales_orders', 'Sales Order', '/erp/sales', 'voucher_date',
        '/erp/sales'),
    _VTable('purchase_grns', 'GRN', '/erp/grn', 'voucher_date', '/erp/grn'),
    _VTable('crv_vouchers', 'Receipt (CRV)', '/erp/receipt-vouchers',
        'voucher_date', '/erp/receipt-vouchers'),
    _VTable('cpv_vouchers', 'Payment (CPV)', '/erp/payment-vouchers',
        'voucher_date', '/erp/payment-vouchers'),
    _VTable('stock_transfers', 'Stock Transfer', '/erp/stock-transfers',
        'transfer_date', '/erp/stock-transfers'),
    _VTable('production_vouchers', 'Production', '/manufacturing/production-voucher',
        'voucher_date', '/manufacturing/production-voucher'),
  ];
  final hits = <_Msg>[];
  final links = <_Link>[];
  final buf = StringBuffer();
  int found = 0;
  for (final vt in tables) {
    if (vt.permRoute != null && !c.can(vt.permRoute!)) continue;
    try {
      final rows = await c.client
          .from(vt.table)
          .select('id, voucher_number, status, ${vt.dateCol}')
          .eq('org_id', c.orgId)
          .ilike('voucher_number', '%$t%')
          .limit(3);
      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        found++;
        final vn = (r['voucher_number'] ?? '') as String;
        final st = (r['status'] ?? '').toString();
        final dt = (r[vt.dateCol] ?? '').toString();
        buf.writeln('${vt.label} $vn'
            '${st.isNotEmpty ? ' — $st' : ''}'
            '${dt.isNotEmpty ? ' ($dt)' : ''}');
        links.add(_Link('Open $vn', '${vt.route}?focus=${r['id']}'));
      }
    } catch (_) {
      // table/column mismatch — skip quietly
    }
  }
  if (found == 0) {
    return _Msg(false,
        'Hmm, I couldn\'t find a voucher matching "$t" in the areas you can '
        'access. If you meant a screen (like "Sales Orders"), try "where is the '
        'sales order screen".');
  }
  return _Msg(
    false,
    'Found:\n\n${buf.toString().trimRight()}',
    links: links.take(5).toList(),
  );
}
