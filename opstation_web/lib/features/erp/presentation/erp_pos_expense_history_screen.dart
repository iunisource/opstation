import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpPosExpenseHistoryScreen extends ConsumerStatefulWidget {
  const ErpPosExpenseHistoryScreen({super.key});
  @override ConsumerState<ErpPosExpenseHistoryScreen> createState() => _ErpPosExpenseHistoryScreenState();
}

class _ErpPosExpenseHistoryScreenState extends ConsumerState<ErpPosExpenseHistoryScreen> {
  List<Map<String, dynamic>> _expenses = [];
  bool _loading = true;
  String _search = '';
  String _filterCategory = 'All';
  DateTime? _dateFrom;
  DateTime? _dateTo;
  static const cats = ['All', 'Transport', 'Supplies', 'Food & Beverages', 'Utilities', 'Maintenance', 'Miscellaneous', 'Other'];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  @override void initState() { super.initState(); _load(); }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      var q = Supabase.instance.client.from('pos_expenses')
          .select('*, pos_sessions(opened_at, branches(name)), users:created_by(name)')
          .eq('org_id', orgId);
      final branchId = _branchId;
      if (branchId != null) q = q.eq('branch_id', branchId);
      final rows = await q.order('created_at', ascending: false).limit(1000);
      setState(() { _expenses = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _loading = false); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.toLowerCase();
    return _expenses.where((e) {
      final cat = e['category'] as String? ?? '';
      final note = e['note'] as String? ?? '';
      final branch = e['pos_sessions']?['branches']?['name'] as String? ?? '';
      final matchSearch = q.isEmpty || cat.toLowerCase().contains(q) || note.toLowerCase().contains(q) || branch.toLowerCase().contains(q);
      final matchCat = _filterCategory == 'All' || cat == _filterCategory;
      final ts = e['created_at'] != null ? DateTime.parse(e['created_at'] as String).toLocal() : null;
      final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
      final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
      return matchSearch && matchCat && matchFrom && matchTo;
    }).toList();
  }

  Map<String, double> get _byCategory {
    final map = <String, double>{};
    for (final e in _filtered) { final cat = e['category'] as String? ?? 'Other'; map[cat] = (map[cat] ?? 0) + ((e['amount'] as num?)?.toDouble() ?? 0); }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final filtered = _filtered;
    final total = filtered.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));
    final byCat = _byCategory;
    return Container(color: AppTheme.background, child: Row(children: [
      Container(width: 280, color: Colors.white, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Expense History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${filtered.length} records', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.shade100)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Total Expenses', style: TextStyle(fontSize: 11, color: Colors.red.shade700, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
              const SizedBox(height: 4),
              Text('Rs. ${total.toStringAsFixed(2)}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.red.shade700)),
            ])),
          const SizedBox(height: 16),
          const Text('By Category', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
          const SizedBox(height: 8),
          ...byCat.entries.map((e) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
            Expanded(child: Text(e.key, style: const TextStyle(fontSize: 12))),
            Text('Rs. ${e.value.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
          ]))),
        ])),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Filters', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.5)),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(value: _filterCategory, isDense: true, decoration: const InputDecoration(labelText: 'Category', isDense: true, border: OutlineInputBorder()),
            items: cats.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: (v) => setState(() => _filterCategory = v ?? 'All')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateFrom = d); }, child: Text(_dateFrom != null ? DateFormat('d MMM').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)))),
            const SizedBox(width: 6),
            Expanded(child: OutlinedButton(onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateTo = d); }, child: Text(_dateTo != null ? DateFormat('d MMM').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)))),
          ]),
          if (_dateFrom != null || _dateTo != null || _filterCategory != 'All') ...[
            const SizedBox(height: 6),
            TextButton.icon(icon: const Icon(Icons.clear, size: 14), label: const Text('Clear filters', style: TextStyle(fontSize: 12)), onPressed: () => setState(() { _dateFrom = null; _dateTo = null; _filterCategory = 'All'; })),
          ],
        ])),
      ])),
      const VerticalDivider(width: 1),
      Expanded(child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 12), child: Row(children: [
          Expanded(child: TextField(decoration: const InputDecoration(hintText: 'Search by category, note, branch...', prefixIcon: Icon(Icons.search, size: 18), isDense: true, filled: true, fillColor: Colors.white), onChanged: (v) => setState(() => _search = v))),
          const SizedBox(width: 12),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ])),
        Container(margin: const EdgeInsets.symmetric(horizontal: 20), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(color: Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(8)), border: Border.all(color: AppTheme.border)),
          child: const Row(children: [
            Expanded(flex: 2, child: Text('Date & Time', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 3, child: Text('Note', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 1, child: Text('Cashier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 1, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          ])),
        Expanded(child: Container(margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          decoration: BoxDecoration(color: Colors.white, borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)), border: Border.all(color: AppTheme.border)),
          child: _loading ? const Center(child: CircularProgressIndicator())
            : filtered.isEmpty ? const Center(child: Text('No expenses found.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = filtered[i];
                  final amt = (e['amount'] as num?)?.toDouble() ?? 0;
                  final cat = e['category'] as String? ?? '-';
                  final note = e['note'] as String? ?? '-';
                  final branch = e['pos_sessions']?['branches']?['name'] as String? ?? '-';
                  final cashier = e['users']?['name'] as String? ?? '-';
                  final ts = e['created_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '-';
                  return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Row(children: [
                    Expanded(flex: 2, child: Text(ts, style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 2, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.red.shade100)), child: Text(cat, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.red.shade700)))),
                    Expanded(flex: 3, child: Text(note, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 2, child: Text(branch, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 1, child: Text(cashier, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 1, child: Text('Rs. ${amt.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.red.shade700))),
                  ]));
                }))),
      ])),
    ]));
  }
}
