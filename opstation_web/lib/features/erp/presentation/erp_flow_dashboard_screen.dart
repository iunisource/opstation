import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Document states that count as "done" for a PO/SO — anything else is pending.
const _terminalStatuses = {
  'completed', 'complete', 'closed', 'received', 'delivered', 'fulfilled',
  'invoiced', 'cancelled', 'canceled', 'void', 'voided', 'done', 'rejected',
  'converted',
};

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
  final String noun; // singular, for list header
  final String table;
  final String route; // screen to open
  final int step; // 1=order, 2=grn/do, 3=invoice
  const _Stage(this.key, this.label, this.noun, this.table, this.route, this.step);
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

  List<_Stage> get _stages => widget.purchase
      ? const [
          _Stage('po', 'Pending POs', 'Purchase Order', 'purchase_orders', '/erp/purchase', 1),
          _Stage('grn', 'Pending GRNs', 'GRN', 'purchase_grns', '/erp/grn', 2),
          _Stage('pi', 'Pending Invoices', 'Purchase Invoice', 'purchase_invoices', '/erp/purchase-invoices', 3),
        ]
      : const [
          _Stage('so', 'Pending Orders', 'Sales Order', 'sales_orders', '/erp/sales', 1),
          _Stage('do', 'Pending Deliveries', 'Delivery Order', 'delivery_orders', '/erp/delivery-orders', 2),
          _Stage('si', 'Pending Invoices', 'Sales Invoice', 'sales_invoices', '/erp/sales-invoices', 3),
        ];

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

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  double _d(dynamic v) => v == null ? 0.0 : (v as num).toDouble();

  int? _ageDays(dynamic date) {
    if (date == null || '$date'.isEmpty) return null;
    try {
      final d = DateTime.parse('$date');
      return DateTime.now().difference(d).inDays;
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
      // reference data
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

      // invoiced links to detect stage-2 completion
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
      for (final st in _stages) {
        var q = c.from(st.table).select().eq('org_id', orgId);
        if (st.step != 1) q = q.eq('is_voided', false);
        if (_branch != 'all') q = q.eq('branch_id', _branch);
        final rows = List<Map<String, dynamic>>.from(await q);

        final pending = <Map<String, dynamic>>[];
        for (final r in rows) {
          if (st.step == 1 &&
              (r['is_voided'] == true || r['voided_at'] != null)) {
            continue; // order tables: no is_voided column, void = voided_at set
          }
          final keep = switch (st.step) {
            1 => !_terminalStatuses
                .contains('${r['status'] ?? ''}'.toLowerCase()),
            2 => !invoicedLinks.contains('${r['id']}'),
            _ => r['is_locked'] != true, // step 3: not yet locked
          };
          if (!keep) continue;
          pending.add({
            'id': r['id'],
            'voucher': r['voucher_number'] ?? r['id'],
            'date': r['voucher_date'],
            'party': _partyNames[r[partyId]] ?? '—',
            'amount': r.containsKey('grand_total') ? _d(r['grand_total']) : null,
            'age': _ageDays(r['voucher_date']),
          });
        }
        pending.sort((a, b) => (b['age'] ?? -1).compareTo(a['age'] ?? -1));
        _stageDocs[st.key] = pending;
      }

      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  List<Map<String, dynamic>> get _visible {
    final list = _stageDocs[_selected] ?? const [];
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list
        .where((d) =>
            '${d['voucher']}'.toLowerCase().contains(q) ||
            '${d['party']}'.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.purchase ? 'Purchase Dashboard' : 'Sales Dashboard';
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(width: 16),
          SizedBox(
            width: 200,
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
        const SizedBox(height: 4),
        Text(
            widget.purchase
                ? 'What is pending across PO → GRN → Purchase Invoice'
                : 'What is pending across Order → Delivery → Sales Invoice',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 18),
        Row(children: [for (final st in _stages) _stageCard(st)]),
        const SizedBox(height: 18),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _stageList(),
        ),
      ]),
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
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selected = st.key),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.only(right: 14),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: selected ? color : AppTheme.border, width: selected ? 1.5 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(st.label,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              Icon(Icons.chevron_right,
                  size: 16, color: selected ? color : AppTheme.textSecondary),
            ]),
            const SizedBox(height: 8),
            Text('${_loading ? '—' : docs.length}',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 4),
            Text(
              _loading
                  ? ' '
                  : hasAmount
                      ? 'Value ${_money.format(total)}'
                      : oldest == null
                          ? 'Nothing pending'
                          : 'Oldest ${oldest}d',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _stageList() {
    final st = _stages.firstWhere((s) => s.key == _selected);
    final rows = _visible;
    final hasAmount = st.step == 3;
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
        const Spacer(),
        TextButton.icon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text('Open ${st.noun}s'),
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
                child: Text('No pending ${st.noun.toLowerCase()}s.',
                    style: const TextStyle(color: AppTheme.textSecondary)))
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
              child: Text('${d['party']}',
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
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
