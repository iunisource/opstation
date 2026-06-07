import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpProductionWasteReportScreen extends ConsumerStatefulWidget {
  const ErpProductionWasteReportScreen({super.key});
  @override
  ConsumerState<ErpProductionWasteReportScreen> createState() => _State();
}

class _State extends ConsumerState<ErpProductionWasteReportScreen> {
  bool _loading = true;

  Map<String, String> _prodLabel = {};
  Map<String, String> _branchName = {};
  Map<String, Map<String, dynamic>> _bomMap = {};                 // bomId -> {out, name}
  Map<String, List<Map<String, dynamic>>> _bomWasteMap = {};      // bomId -> [{pid, qty}]
  List<Map<String, dynamic>> _rawRuns = [];                       // posted production_vouchers
  List<Map<String, dynamic>> _branches = [];

  // filters
  DateTime? _from; DateTime? _to; String _branchFilter = '__all__';

  // computed
  int _runCount = 0; double _totalWaste = 0; int _wasteItems = 0; int _fgCount = 0;
  List<Map<String, dynamic>> _byItem = [];
  List<Map<String, dynamic>> _runRows = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }
  static String _trim(double v) { final r = (v * 100).roundToDouble() / 100; if (r == r.roundToDouble()) return r.toStringAsFixed(0); return r.toString(); }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _load(); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;

      // products (labels)
      final List<Map<String, dynamic>> prods = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await client.from('products').select('id, name, sku').eq('org_id', orgId).order('name').range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        prods.addAll(list);
        if (list.length < page) break; from += page; if (from > 100000) break;
      }
      _prodLabel = {for (final p in prods) p['id'] as String: "${p['sku'] != null && (p['sku'] as String).isNotEmpty ? '${p['sku']} \u2014 ' : ''}${p['name'] ?? ''}"};

      // branches
      final br = await client.from('branches').select('id, name').eq('org_id', orgId).order('name');
      _branches = List<Map<String, dynamic>>.from(br);
      _branchName = {for (final b in _branches) b['id'] as String: b['name'] as String? ?? ''};

      // bom headers
      final bh = await client.from('bom_headers').select('id, name, output_qty').eq('org_id', orgId);
      _bomMap = {for (final b in (bh as List)) b['id'] as String: {'out': b['output_qty'], 'name': b['name']}};

      // bom waste
      final bw = await client.from('bom_waste').select('bom_id, product_id, quantity');
      _bomWasteMap = {};
      for (final w in (bw as List)) {
        final bid = w['bom_id'] as String?;
        if (bid == null) continue;
        (_bomWasteMap[bid] ??= []).add({'pid': w['product_id'], 'qty': (w['quantity'] as num?)?.toDouble() ?? 0});
      }

      // posted production runs
      final pv = await client.from('production_vouchers')
          .select('id, voucher_number, voucher_date, branch_id, bom_id, product_id, output_qty, status')
          .eq('org_id', orgId).eq('status', 'posted').order('voucher_date', ascending: false);
      _rawRuns = List<Map<String, dynamic>>.from(pv);

      _recompute();
      if (mounted) setState(() => _loading = false);
    } catch (e) { if (mounted) { _snack('Load error: $e'); setState(() => _loading = false); } }
  }

  void _recompute() {
    final byItemQty = <String, double>{}; final byItemRuns = <String, Set<String>>{};
    double total = 0; final wasteItemSet = <String>{}; final fgSet = <String>{};
    final rows = <Map<String, dynamic>>[]; int runCount = 0;

    for (final v in _rawRuns) {
      final d = v['voucher_date'] != null ? DateTime.tryParse(v['voucher_date'] as String) : null;
      if (_from != null && (d == null || d.isBefore(_from!))) continue;
      if (_to != null && (d == null || d.isAfter(_to!))) continue;
      if (_branchFilter != '__all__' && v['branch_id'] != _branchFilter) continue;
      runCount++;

      final bom = _bomMap[v['bom_id']];
      final bomOut = (bom?['out'] as num?)?.toDouble() ?? 0;
      final runOut = (v['output_qty'] as num?)?.toDouble() ?? 0;
      final batches = bomOut > 0 ? runOut / bomOut : runOut;        // guard divide-by-zero

      final wl = _bomWasteMap[v['bom_id']] ?? [];
      final lines = <Map<String, dynamic>>[]; double runWaste = 0;
      for (final w in wl) {
        final pid = w['pid'] as String? ?? '__none__';
        final per = (w['qty'] as num?)?.toDouble() ?? 0;
        final exp = per * batches;
        runWaste += exp; total += exp;
        byItemQty[pid] = (byItemQty[pid] ?? 0) + exp; (byItemRuns[pid] ??= <String>{}).add(v['id'] as String);
        wasteItemSet.add(pid);
        lines.add({'label': _prodLabel[pid] ?? pid, 'qty': exp});
      }
      if (v['product_id'] != null) fgSet.add(v['product_id'] as String);
      rows.add({
        'voucher': v['voucher_number'] ?? '', 'date': v['voucher_date'] ?? '',
        'branch': _branchName[v['branch_id']] ?? '', 'fg': _prodLabel[v['product_id']] ?? (v['product_id'] ?? ''),
        'output': runOut, 'waste': runWaste, 'lines': lines,
      });
    }

    final byItem = byItemQty.entries.map((e) => {'label': _prodLabel[e.key] ?? e.key, 'qty': e.value, 'runs': (byItemRuns[e.key]?.length ?? 0)}).toList()
      ..sort((a, b) => (b['qty'] as double).compareTo(a['qty'] as double));

    setState(() {
      _runCount = runCount; _totalWaste = total; _wasteItems = wasteItemSet.length; _fgCount = fgSet.length;
      _byItem = byItem; _runRows = rows;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(color: AppTheme.background, child: Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: [
          const Text('Production Waste Report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)),
            child: const Text('BOM-derived \u00b7 posted runs', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
          const Spacer(),
          _dateBtn('From', _from, (d) { setState(() => _from = d); _recompute(); }),
          const SizedBox(width: 6),
          _dateBtn('To', _to, (d) { setState(() => _to = d); _recompute(); }),
          if (_from != null || _to != null) ...[
            const SizedBox(width: 2),
            IconButton(icon: const Icon(Icons.clear, size: 16), tooltip: 'Clear dates', onPressed: () { setState(() { _from = null; _to = null; }); _recompute(); }),
          ],
          const SizedBox(width: 8),
          _branchDropdown(),
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: const Icon(Icons.refresh, size: 15), label: const Text('Refresh', style: TextStyle(fontSize: 12)), onPressed: _load),
        ])),
      Expanded(child: _loading
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _sumCard('Production runs', _runCount.toString(), AppTheme.primary),
            const SizedBox(width: 12),
            _sumCard('Expected waste qty', _trim(_totalWaste), Colors.red.shade600),
            const SizedBox(width: 12),
            _sumCard('Waste items', _wasteItems.toString(), Colors.teal),
            const SizedBox(width: 12),
            _sumCard('Finished goods', _fgCount.toString(), Colors.indigo),
          ]),
          const SizedBox(height: 22),
          const Text('Expected waste by item', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _byItemTable(),
          const SizedBox(height: 22),
          const Text('By production run', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _runsTable(),
          const SizedBox(height: 30),
        ]))),
    ]));
  }

  Widget _dateBtn(String label, DateTime? value, void Function(DateTime) onPick) => OutlinedButton.icon(
    icon: const Icon(Icons.date_range, size: 15),
    label: Text(value != null ? DateFormat('d MMM yyyy').format(value) : label, style: const TextStyle(fontSize: 12)),
    onPressed: () async {
      final d = await showDatePicker(context: context, initialDate: value ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
      if (d != null) onPick(d);
    });

  Widget _branchDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)),
      child: DropdownButtonHideUnderline(child: DropdownButton<String>(
        value: _branchFilter, isDense: true,
        style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
        items: [
          const DropdownMenuItem(value: '__all__', child: Text('All branches', style: TextStyle(fontSize: 12))),
          ..._branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '', style: const TextStyle(fontSize: 12)))),
        ],
        onChanged: (v) { setState(() => _branchFilter = v ?? '__all__'); _recompute(); })),
    );
  }

  Widget _sumCard(String label, String value, Color color) => Expanded(child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
    ])));

  Widget _byItemTable() {
    final maxQty = _byItem.fold<double>(0, (m, r) => (r['qty'] as double) > m ? r['qty'] as double : m);
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: _byItem.isEmpty
        ? const Padding(padding: EdgeInsets.all(16), child: Text('No expected waste for this selection.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
        : Column(children: [
            for (var i = 0; i < _byItem.length; i++)
              Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(border: i == _byItem.length - 1 ? null : Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
                child: Row(children: [
                  SizedBox(width: 260, child: Text(_byItem[i]['label'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 12),
                  Expanded(child: Container(height: 8, decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(4)),
                    child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: maxQty > 0 ? ((_byItem[i]['qty'] as double) / maxQty).clamp(0.02, 1.0) : 0.0,
                      child: Container(decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(4)))))),
                  const SizedBox(width: 12),
                  SizedBox(width: 70, child: Text(_trim(_byItem[i]['qty'] as double), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  SizedBox(width: 78, child: Text('${_byItem[i]['runs']} run(s)', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                ])),
          ]),
    );
  }

  Widget _runsTable() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
          child: Row(children: const [
            SizedBox(width: 120, child: Text('Voucher', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
            SizedBox(width: 100, child: Text('Date', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
            SizedBox(width: 130, child: Text('Branch', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
            Expanded(child: Text('Finished good', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
            SizedBox(width: 70, child: Text('Output', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
            SizedBox(width: 90, child: Text('Exp. waste', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w700))),
          ])),
        if (_runRows.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('No posted production runs for this selection.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
        else
          for (var i = 0; i < _runRows.length; i++) ...[
            Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(border: Border(top: i == 0 ? BorderSide.none : BorderSide(color: AppTheme.border.withOpacity(0.5)))),
              child: Row(children: [
                SizedBox(width: 120, child: Text(_runRows[i]['voucher'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                SizedBox(width: 100, child: Text(_runRows[i]['date'] as String? ?? '', style: const TextStyle(fontSize: 12))),
                SizedBox(width: 130, child: Text(_runRows[i]['branch'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                Expanded(child: Text(_runRows[i]['fg'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                SizedBox(width: 70, child: Text(_trim(_runRows[i]['output'] as double), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                SizedBox(width: 90, child: Text(_trim(_runRows[i]['waste'] as double), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: (_runRows[i]['waste'] as double) > 0 ? Colors.red.shade600 : AppTheme.textSecondary))),
              ])),
            // waste-line breakdown
            ...(_runRows[i]['lines'] as List).map((l) => Container(
              padding: const EdgeInsets.fromLTRB(28, 3, 14, 3),
              child: Row(children: [
                const Icon(Icons.subdirectory_arrow_right, size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text(l['label'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                SizedBox(width: 90, child: Text(_trim(l['qty'] as double), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
              ]))),
            if ((_runRows[i]['lines'] as List).isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(28, 2, 14, 6), child: Text('No waste defined on this BOM', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontStyle: FontStyle.italic))),
            const SizedBox(height: 4),
          ],
      ]),
    );
  }
}
