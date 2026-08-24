import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Statuses that mean the order is finished and owes nothing further.
const _terminalStatuses = {
  'completed', 'complete', 'closed', 'received', 'delivered', 'fulfilled',
  'invoiced', 'cancelled', 'canceled', 'void', 'voided', 'done', 'rejected',
  'converted',
};

/// Statuses that mean the order is not a real commitment yet. Previously these
/// fell through into the "pending" bucket (they are not terminal), so abandoned
/// drafts — most of them with no party at all — inflated the headline number and
/// made it unactionable. They are now counted separately as housekeeping.
const _draftStatuses = {'draft', 'new', ''};

class ErpSalesDashboardScreen extends StatelessWidget {
  const ErpSalesDashboardScreen({super.key});
  @override
  Widget build(BuildContext context) => const _FlowDashboard(purchase: false);
}

class ErpPurchaseDashboardScreen extends StatelessWidget {
  const ErpPurchaseDashboardScreen({super.key});
  @override
  Widget build(BuildContext context) => const _FlowDashboard(purchase: true);
}

class _Stage {
  final String key;
  final String label; // card label
  final String sub;   // what the number means, in plain words
  final String noun;  // singular, for list header
  final String table;
  final String route; // screen to open
  final int step;     // 1=order, 2=grn/do, 3=invoice
  final bool done;    // true = a completed "done" count (posted invoices),
                      // not a pending to-do bucket. Changes count + footer.
  const _Stage(this.key, this.label, this.sub, this.noun, this.table, this.route, this.step,
      {this.done = false});
}

class _FlowDashboard extends ConsumerStatefulWidget {
  final bool purchase;
  const _FlowDashboard({required this.purchase});
  @override
  ConsumerState<_FlowDashboard> createState() => _FlowDashboardState();
}

class _FlowDashboardState extends ConsumerState<_FlowDashboard> {
  bool _loading = true;
  String? _orgId;
  String _branch = 'all';
  String _selected = '';
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _branches = [];
  final Map<String, String> _partyNames = {}; // supplier/customer id -> name
  final Map<String, List<Map<String, dynamic>>> _stageDocs = {};

  final _money = NumberFormat('#,##0');

  static const _kDrafts = 'drafts';

  List<_Stage> get _stages => widget.purchase
      ? const [
          _Stage('po', 'Awaiting Receipt', 'Ordered, not yet received', 'Purchase Order', 'purchase_orders', '/erp/purchase', 1),
          _Stage('grn', 'Awaiting Invoice', 'Received, not yet billed', 'GRN', 'purchase_grns', '/erp/grn', 2),
          _Stage('pi', 'Unposted Invoices', 'Entered, not yet locked', 'Purchase Invoice', 'purchase_invoices', '/erp/purchase-invoices', 3),
        ]
      : const [
          _Stage('so', 'SOs Awaiting Delivery', 'Confirmed, not yet delivered', 'Sales Order', 'sales_orders', '/erp/sales', 1),
          _Stage('do', 'DOs Awaiting Invoice', 'Delivered, not yet billed', 'Delivery Order', 'delivery_orders', '/erp/delivery-orders', 2),
          _Stage('si', 'Invoiced', 'Billed & posted', 'Sales Invoice', 'sales_invoices', '/erp/sales-invoices', 3, done: true),
        ];

  // The drafts bucket is a housekeeping list, not a work queue — it sits
  // outside _stages so it never contributes to the headline figures.
  _Stage get _draftStage => widget.purchase
      ? const _Stage(_kDrafts, 'Drafts', 'Incomplete — finish or delete', 'Draft PO', 'purchase_orders', '/erp/purchase', 1)
      : const _Stage(_kDrafts, 'Drafts', 'Incomplete — finish or delete', 'Draft SO', 'sales_orders', '/erp/sales', 1);

  bool get _isSupplier => widget.purchase;

  @override
  void initState() {
    super.initState();
    _selected = _stages.first.key;
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  int? _ageDays(dynamic date) {
    if (date == null || '$date'.isEmpty) return null;
    try {
      return DateTime.now().difference(DateTime.parse('$date')).inDays;
    } catch (_) {
      return null;
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    _orgId = orgId;
    final c = Supabase.instance.client;
    final partyId = _isSupplier ? 'supplier_id' : 'customer_id';
    try {
      _branches = List<Map<String, dynamic>>.from(await c
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId)
          .order('name'));
      _partyNames.clear();
      if (_isSupplier) {
        final sups = await c.from('suppliers').select('id, name').eq('org_id', orgId);
        for (final s in sups) {
          _partyNames[s['id'] as String] = '${s['name']}';
        }
      } else {
        final custs = await c.from('customers').select('id, shop_name, code').eq('org_id', orgId);
        for (final s in custs) {
          _partyNames[s['id'] as String] = '${s['shop_name']}';
        }
      }

      // Stage-3 links tell us which stage-2 docs are already invoiced.
      final stage3Table = _stages[2].table;
      final linkCol = _isSupplier ? 'grn_id' : 'do_id';
      final invoicedLinks = <String>{};
      final links = await c
          .from(stage3Table)
          .select(linkCol)
          .eq('org_id', orgId)
          .eq('is_voided', false);
      for (final r in links) {
        final v = r[linkCol];
        if (v != null) invoicedLinks.add('$v');
      }

      _stageDocs.clear();
      final drafts = <Map<String, dynamic>>[];

      for (final st in _stages) {
        var q = c.from(st.table).select().eq('org_id', orgId);
        if (st.step != 1) q = q.eq('is_voided', false);
        if (_branch != 'all') q = q.eq('branch_id', _branch);
        final rows = List<Map<String, dynamic>>.from(await q);

        final pending = <Map<String, dynamic>>[];
        for (final r in rows) {
          // Order tables have no is_voided column — a void sets voided_at.
          if (st.step == 1 && (r['is_voided'] == true || r['voided_at'] != null)) {
            continue;
          }
          final status = '${r['status'] ?? ''}'.toLowerCase();

          Map<String, dynamic> entry() => {
                'id': r['id'],
                'voucher': r['voucher_number'] ?? r['id'],
                'date': r['voucher_date'],
                'party': _partyNames[r[partyId]],
                'amount': r.containsKey('grand_total') ? _d(r['grand_total']) : null,
                'age': _ageDays(r['voucher_date']),
                'status': status,
              };

          if (st.step == 1) {
            // Drafts are not commitments — divert them out of the headline.
            if (_draftStatuses.contains(status)) {
              drafts.add(entry());
              continue;
            }
            if (_terminalStatuses.contains(status)) continue;
            pending.add(entry());
            continue;
          }

          final keep = st.step == 2
              ? !invoicedLinks.contains('${r['id']}')
              // Step 3: a "done" card counts posted/locked invoices (the
              // finished end of the pipeline); otherwise it's the unposted
              // to-do bucket.
              : (st.done ? r['is_locked'] == true : r['is_locked'] != true);
          if (!keep) continue;
          pending.add(entry());
        }
        pending.sort((a, b) => (b['age'] ?? -1).compareTo(a['age'] ?? -1));
        _stageDocs[st.key] = pending;
      }

      drafts.sort((a, b) => (b['age'] ?? -1).compareTo(a['age'] ?? -1));
      _stageDocs[_kDrafts] = drafts;

      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  _Stage _stageFor(String key) =>
      key == _kDrafts ? _draftStage : _stages.firstWhere((s) => s.key == key);

  List<Map<String, dynamic>> get _visible {
    final list = _stageDocs[_selected] ?? const [];
    final q = _searchCtrl.text;
    return list
        .where((d) => matchesQuery('${d['voucher']} ${d['party'] ?? ''}', q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.purchase ? 'Purchase Dashboard' : 'Sales Dashboard';
    final draftCount = (_stageDocs[_kDrafts] ?? const []).length;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
          const SizedBox(width: 18),
          SizedBox(
            width: 190,
            child: DropdownButtonFormField<String>(
              value: _branch,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Branch', isDense: true),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All branches')),
                for (final b in _branches)
                  DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}')),
              ],
              onChanged: (v) {
                setState(() => _branch = v ?? 'all');
                _load();
              },
            ),
          ),
          const Spacer(),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 2),
        Text(
            widget.purchase
                ? 'Order → Receipt → Invoice'
                : 'Order → Delivery → Invoice',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        const SizedBox(height: 20),
        Row(children: [for (final st in _stages) _stageCard(st)]),
        if (draftCount > 0) ...[
          const SizedBox(height: 12),
          _draftsBar(draftCount),
        ],
        const SizedBox(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _stageList(),
        ),
      ]),
    );
  }

  /// Muted, full-width strip. Deliberately not a headline card: drafts are
  /// housekeeping, not work owed to anyone.
  Widget _draftsBar(int count) {
    final selected = _selected == _kDrafts;
    final docs = _stageDocs[_kDrafts] ?? const [];
    final noParty = docs.where((d) => d['party'] == null).length;
    return InkWell(
      onTap: () => setState(() => _selected = _kDrafts),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppTheme.background : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? AppTheme.textSecondary : AppTheme.border,
              width: selected ? 1.4 : 1),
        ),
        child: Row(children: [
          const Icon(Icons.inbox_outlined, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          Text('$count draft${count == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(width: 8),
          Text(
            noParty > 0
                ? '· $noParty with no ${_isSupplier ? 'supplier' : 'customer'} — finish or delete'
                : '· incomplete, not yet confirmed',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const Spacer(),
          Icon(Icons.chevron_right, size: 16,
              color: selected ? AppTheme.textPrimary : AppTheme.textSecondary),
        ]),
      ),
    );
  }

  Widget _stageCard(_Stage st) {
    final docs = _stageDocs[st.key] ?? const [];
    final selected = _selected == st.key;
    final oldest = docs.isEmpty ? null : docs.first['age'] as int?;
    final hasAmount = st.step == 3;
    final total = hasAmount
        ? docs.fold<double>(0, (s, d) => s + ((d['amount'] as double?) ?? 0))
        : 0.0;
    final color = st.step == 1
        ? AppTheme.primary
        : st.step == 2
            ? Colors.orange
            : Colors.teal;
    final stale = (oldest ?? 0) >= 30;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selected = st.key),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.only(right: 14),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 15),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? color : AppTheme.border, width: selected ? 1.5 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(st.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
              ),
              Icon(Icons.chevron_right,
                  size: 16, color: selected ? color : AppTheme.textSecondary),
            ]),
            const SizedBox(height: 2),
            Text(st.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('${_loading ? '—' : docs.length}',
                      style: TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w800, color: color, height: 1.05)),
                  if (!_loading && hasAmount && total > 0) ...[
                    const SizedBox(width: 8),
                    Text('Rs. ${_money.format(total)}',
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                  ],
                ]),
            const SizedBox(height: 6),
            if (_loading)
              const Text(' ', style: TextStyle(fontSize: 11))
            else if (st.done)
              // A completed/"done" count: no to-do framing, no stale warning.
              Row(children: [
                const Icon(Icons.check_circle, size: 13, color: Colors.teal),
                const SizedBox(width: 5),
                Text(docs.isEmpty ? 'None yet' : 'Completed',
                    style: const TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.w600)),
              ])
            else if (docs.isEmpty)
              const Row(children: [
                Icon(Icons.check_circle_outline, size: 13, color: Colors.teal),
                SizedBox(width: 5),
                Text('All clear', style: TextStyle(fontSize: 11, color: Colors.teal, fontWeight: FontWeight.w600)),
              ])
            else
              Row(children: [
                Icon(stale ? Icons.warning_amber_rounded : Icons.schedule,
                    size: 13, color: stale ? AppTheme.danger : AppTheme.textSecondary),
                const SizedBox(width: 5),
                Text('Oldest ${oldest}d',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: stale ? FontWeight.w700 : FontWeight.w500,
                        color: stale ? AppTheme.danger : AppTheme.textSecondary)),
              ]),
          ]),
        ),
      ),
    );
  }

  Widget _stageList() {
    final st = _stageFor(_selected);
    final rows = _visible;
    final isDrafts = _selected == _kDrafts;
    final hasAmount = st.step == 3 && !isDrafts;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        SizedBox(
          width: 320,
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Search ${st.noun.toLowerCase()} or party…',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Text('${rows.length} ${rows.length == 1 ? 'record' : 'records'}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(isDrafts ? 'Open ${_isSupplier ? 'Purchase' : 'Sales'}' : 'Open ${st.noun}s'),
          onPressed: () => context.go(st.route),
        ),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          const Expanded(flex: 3, child: Text('Voucher', style: _hStyle)),
          const Expanded(flex: 2, child: Text('Date', style: _hStyle)),
          Expanded(flex: 4, child: Text(_isSupplier ? 'Supplier' : 'Customer', style: _hStyle)),
          if (hasAmount)
            const Expanded(flex: 2, child: Text('Amount', style: _hStyle, textAlign: TextAlign.right)),
          const Expanded(flex: 2, child: Text('Age', style: _hStyle, textAlign: TextAlign.right)),
          const SizedBox(width: 40),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: rows.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle_outline, size: 32, color: Colors.teal),
                  const SizedBox(height: 8),
                  Text(
                      isDrafts
                          ? 'No drafts.'
                          : 'Nothing ${st.label.toLowerCase()}.',
                      style: const TextStyle(color: AppTheme.textSecondary)),
                ]),
              )
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _docRow(rows[i], st, hasAmount),
              ),
      ),
    ]);
  }

  Widget _docRow(Map<String, dynamic> d, _Stage st, bool hasAmount) {
    final age = d['age'] as int?;
    final party = d['party'] as String?;
    final ageColor = age == null
        ? AppTheme.textSecondary
        : age >= 30
            ? AppTheme.danger
            : age >= 14
                ? Colors.orange
                : AppTheme.textSecondary;
    return InkWell(
      onTap: () => context.go(st.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(
              flex: 3,
              child: Text('${d['voucher']}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 2,
              child: Text(_fmtDate(d['date']),
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
          Expanded(
            flex: 4,
            // A missing party is a real defect on a draft, not a blank cell —
            // call it out so it can be fixed or the draft deleted.
            child: party == null
                ? Row(children: [
                    Icon(Icons.error_outline, size: 13, color: AppTheme.danger.withValues(alpha: 0.8)),
                    const SizedBox(width: 5),
                    Text('No ${_isSupplier ? 'supplier' : 'customer'}',
                        style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: AppTheme.danger.withValues(alpha: 0.8))),
                  ])
                : Text(party,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (hasAmount)
            Expanded(
                flex: 2,
                child: Text(
                    d['amount'] == null ? '—' : _money.format(d['amount']),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          Expanded(
            flex: 2,
            child: Text(age == null ? '—' : '${age}d',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ageColor)),
          ),
          const SizedBox(
              width: 40,
              child: Icon(Icons.chevron_right, size: 18, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }

  String _fmtDate(dynamic d) {
    if (d == null || '$d'.isEmpty) return '—';
    try {
      return DateFormat('d MMM y').format(DateTime.parse('$d'));
    } catch (_) {
      return '$d';
    }
  }
}

const _hStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
