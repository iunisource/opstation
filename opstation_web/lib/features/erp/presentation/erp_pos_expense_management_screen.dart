// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpPosExpenseManagementScreen extends ConsumerStatefulWidget {
  const ErpPosExpenseManagementScreen({super.key});
  @override ConsumerState<ErpPosExpenseManagementScreen> createState() => _ErpPosExpenseManagementScreenState();
}

class _ErpPosExpenseManagementScreenState extends ConsumerState<ErpPosExpenseManagementScreen> {
  List<Map<String, dynamic>> _expenses = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _selectAll = false;
  String _search = '';
  String _filterCategory = 'All';
  DateTime? _dateFrom;
  DateTime? _dateTo;

  static const _cats = ['All', 'Transport', 'Supplies', 'Food & Beverages', 'Utilities', 'Maintenance', 'Miscellaneous', 'Other'];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override void initState() { super.initState(); _load(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      var q = Supabase.instance.client.from('pos_expenses')
          .select('*, pos_sessions(session_number, opened_at, branches(name)), users:created_by(name)')
          .eq('org_id', orgId);
      final branchId = _branchId;
      if (branchId != null) q = q.eq('branch_id', branchId);
      final rows = await q.order('created_at', ascending: false).limit(2000);
      setState(() { _expenses = List<Map<String, dynamic>>.from(rows); _loading = false; _selected.clear(); _selectAll = false; });
    } catch (e) { _snack('Error: $e'); setState(() => _loading = false); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.toLowerCase();
    return _expenses.where((e) {
      final cat = e['category'] as String? ?? '';
      final note = e['note'] as String? ?? '';
      final branch = e['pos_sessions']?['branches']?['name'] as String? ?? '';
      final cashier = e['users']?['name'] as String? ?? '';
      final matchSearch = q.isEmpty || cat.toLowerCase().contains(q) || note.toLowerCase().contains(q) || branch.toLowerCase().contains(q) || cashier.toLowerCase().contains(q);
      final matchCat = _filterCategory == 'All' || cat == _filterCategory;
      final ts = e['created_at'] != null ? DateTime.parse(e['created_at'] as String).toLocal() : null;
      final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
      final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
      return matchSearch && matchCat && matchFrom && matchTo;
    }).toList();
  }

  double get _filteredTotal => _filtered.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));
  double get _selectedTotal => _filtered.where((e) => _selected.contains(e['id'] as String)).fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));

  Map<String, double> get _byCategory {
    final map = <String, double>{};
    for (final e in _filtered) { final cat = e['category'] as String? ?? 'Other'; map[cat] = (map[cat] ?? 0) + ((e['amount'] as num?)?.toDouble() ?? 0); }
    return map;
  }

  void _toggleAll(bool? v) {
    setState(() {
      _selectAll = v ?? false;
      if (_selectAll) _selected.addAll(_filtered.map((e) => e['id'] as String));
      else _selected.clear();
    });
  }

  void _printSelected() {
    final toPrint = _selected.isEmpty ? _filtered : _filtered.where((e) => _selected.contains(e['id'] as String)).toList();
    if (toPrint.isEmpty) { _snack('No expenses to print'); return; }
    _generateHtml(toPrint, print: true);
  }

  void _exportPdf() {
    final toPrint = _selected.isEmpty ? _filtered : _filtered.where((e) => _selected.contains(e['id'] as String)).toList();
    if (toPrint.isEmpty) { _snack('No expenses to export'); return; }
    _generateHtml(toPrint, print: false);
  }

  void _generateHtml(List<Map<String, dynamic>> data, {required bool print}) {
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final branchName = ref.read(selectedBranchProvider)?['name'] as String? ?? 'All Branches';
    final total = data.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));
    final dateRange = _dateFrom != null || _dateTo != null
        ? '${_dateFrom != null ? DateFormat('d MMM yyyy').format(_dateFrom!) : ''} — ${_dateTo != null ? DateFormat('d MMM yyyy').format(_dateTo!) : 'Today'}'
        : 'All dates';
    final rows = data.map((e) {
      final amt = (e['amount'] as num?)?.toDouble() ?? 0;
      final cat = e['category'] as String? ?? '-';
      final note = e['note'] as String? ?? '-';
      final branch = e['pos_sessions']?['branches']?['name'] as String? ?? '-';
      final sess = e['pos_sessions']?['session_number'] as String? ?? '-';
      final cashier = e['users']?['name'] as String? ?? '-';
      final ts = e['created_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '-';
      return '<tr><td>$ts</td><td>$sess</td><td>$branch</td><td><span class="cat">$cat</span></td><td>$note</td><td>$cashier</td><td class="amt">Rs. ${amt.toStringAsFixed(2)}</td></tr>';
    }).join();

    // Category summary
    final catSummary = _byCategory.entries.map((e) => '<tr><td>${e.key}</td><td class="amt">Rs. ${e.value.toStringAsFixed(2)}</td></tr>').join();

    final content = '''<!DOCTYPE html><html><head><title>Expense Report</title>
<style>
  body { font-family: Arial, sans-serif; padding: 24px; font-size: 12px; color: #333; }
  h1 { font-size: 18px; margin: 0; } h2 { font-size: 13px; color: #666; margin: 2px 0 16px; }
  .meta { color: #666; font-size: 11px; margin-bottom: 20px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 24px; }
  th { background: #f5f5f5; padding: 8px 6px; text-align: left; font-size: 11px; border-bottom: 2px solid #ddd; }
  td { padding: 7px 6px; border-bottom: 1px solid #eee; vertical-align: top; }
  .amt { text-align: right; font-weight: bold; }
  .cat { background: #fff3e0; color: #e65100; padding: 2px 6px; border-radius: 4px; font-size: 11px; }
  .total-row td { font-weight: bold; font-size: 13px; border-top: 2px solid #333; background: #f9f9f9; }
  .summary { display: flex; gap: 24px; margin-bottom: 20px; }
  .stat { background: #f5f5f5; padding: 10px 16px; border-radius: 6px; }
  .stat-label { font-size: 10px; color: #888; letter-spacing: 0.5px; text-transform: uppercase; }
  .stat-value { font-size: 18px; font-weight: bold; color: #333; }
  .cat-table { width: 280px; }
  @media print { .no-print { display: none; } }
</style></head><body>
<h1>$orgName — Expense Report</h1>
<h2>$branchName</h2>
<p class="meta">Period: $dateRange &nbsp;|&nbsp; Generated: ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())} &nbsp;|&nbsp; ${data.length} entries</p>
<div class="summary">
  <div class="stat"><div class="stat-label">Total Expenses</div><div class="stat-value">Rs. ${total.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="stat-label">Entries</div><div class="stat-value">${data.length}</div></div>
</div>
<h3 style="font-size:13px;margin-bottom:8px">By Category</h3>
<table class="cat-table"><thead><tr><th>Category</th><th>Amount</th></tr></thead><tbody>$catSummary</tbody></table>
<h3 style="font-size:13px;margin-bottom:8px">Expense Details</h3>
<table><thead><tr><th>Date & Time</th><th>Session</th><th>Branch</th><th>Category</th><th>Note</th><th>Cashier</th><th>Amount</th></tr></thead>
<tbody>$rows<tr class="total-row"><td colspan="6">TOTAL</td><td class="amt">Rs. ${total.toStringAsFixed(2)}</td></tr></tbody></table>
${print ? '<script>window.print()</script>' : ''}
</body></html>''';

    final blob = html.Blob([content], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final filtered = _filtered;
    final byCat = _byCategory;

    return Container(color: AppTheme.background, child: Column(children: [
      // ── Top bar ──────────────────────────────────────────────────────────
      Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(24, 20, 24, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Expense Management', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            SizedBox(height: 2),
            Text('All POS session expenses', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ])),
          // Stats chips
          _StatChip(label: 'Total', value: 'Rs. ${_filteredTotal.toStringAsFixed(2)}', color: Colors.red.shade700),
          const SizedBox(width: 12),
          _StatChip(label: 'Entries', value: '${filtered.length}', color: AppTheme.primary),
          if (_selected.isNotEmpty) ...[
            const SizedBox(width: 12),
            _StatChip(label: 'Selected', value: 'Rs. ${_selectedTotal.toStringAsFixed(2)}', color: Colors.orange.shade700),
          ],
          const SizedBox(width: 20),
          OutlinedButton.icon(icon: const Icon(Icons.print_outlined, size: 16), label: Text(_selected.isEmpty ? 'Print All' : 'Print (${_selected.length})'), onPressed: _printSelected),
          const SizedBox(width: 8),
          ElevatedButton.icon(icon: const Icon(Icons.download_outlined, size: 16), label: Text(_selected.isEmpty ? 'Export All' : 'Export (${_selected.length})'), onPressed: _exportPdf, style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 14),
        // Filters row
        Row(children: [
          SizedBox(width: 280, child: TextField(decoration: const InputDecoration(hintText: 'Search category, note, branch, cashier…', prefixIcon: Icon(Icons.search, size: 18), isDense: true, filled: true, fillColor: Color(0xFFF8F9FA)), onChanged: (v) => setState(() => _search = v))),
          const SizedBox(width: 12),
          SizedBox(width: 160, child: DropdownButtonFormField<String>(value: _filterCategory, isDense: true, decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
            items: _cats.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: (v) => setState(() => _filterCategory = v ?? 'All'))),
          const SizedBox(width: 12),
          OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 15), label: Text(_dateFrom != null ? DateFormat('d MMM').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateFrom = d); }),
          const SizedBox(width: 6),
          OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 15), label: Text(_dateTo != null ? DateFormat('d MMM').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateTo = d); }),
          if (_dateFrom != null || _dateTo != null || _filterCategory != 'All') ...[
            const SizedBox(width: 6),
            TextButton.icon(icon: const Icon(Icons.clear, size: 14), label: const Text('Clear', style: TextStyle(fontSize: 12)), onPressed: () => setState(() { _dateFrom = null; _dateTo = null; _filterCategory = 'All'; })),
          ],
          const Spacer(),
          // Category mini-summary
          ...byCat.entries.take(4).map((e) => Padding(padding: const EdgeInsets.only(left: 12), child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: Colors.red.shade300, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text('${e.key}: Rs. ${e.value.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]))),
        ]),
      ])),
      const Divider(height: 1),
      // ── Table header ─────────────────────────────────────────────────────
      Container(color: const Color(0xFFF8F9FA), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Row(children: [
          SizedBox(width: 40, child: Checkbox(value: _selectAll, onChanged: _toggleAll, tristate: true)),
          const Expanded(flex: 2, child: Text('Date & Time', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 1, child: Text('Session', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 2, child: Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 3, child: Text('Note', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 1, child: Text('Cashier', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary))),
          const Expanded(flex: 1, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
        ])),
      const Divider(height: 1),
      // ── Table body ────────────────────────────────────────────────────────
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
        : filtered.isEmpty ? const Center(child: Text('No expenses found.', style: TextStyle(color: AppTheme.textSecondary)))
        : ListView.separated(
            itemCount: filtered.length + 1, // +1 for total row
            separatorBuilder: (_, i) => i < filtered.length - 1 ? const Divider(height: 1) : const SizedBox.shrink(),
            itemBuilder: (_, i) {
              // Total row at end
              if (i == filtered.length) {
                return Container(color: const Color(0xFFF8F9FA), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Row(children: [
                    const SizedBox(width: 40),
                    const Expanded(flex: 2, child: SizedBox()),
                    const Expanded(flex: 1, child: SizedBox()),
                    const Expanded(flex: 2, child: SizedBox()),
                    const Expanded(flex: 2, child: SizedBox()),
                    const Expanded(flex: 3, child: SizedBox()),
                    const Expanded(flex: 1, child: Text('TOTAL', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                    Expanded(flex: 1, child: Text('Rs. ${_filteredTotal.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: Colors.red.shade700))),
                  ]));
              }
              final e = filtered[i];
              final id = e['id'] as String;
              final sel = _selected.contains(id);
              final amt = (e['amount'] as num?)?.toDouble() ?? 0;
              final cat = e['category'] as String? ?? '-';
              final note = e['note'] as String? ?? '-';
              final branch = e['pos_sessions']?['branches']?['name'] as String? ?? '-';
              final sess = e['pos_sessions']?['session_number'] as String? ?? '-';
              final cashier = e['users']?['name'] as String? ?? '-';
              final ts = e['created_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '-';
              return InkWell(onTap: () => setState(() { if (sel) _selected.remove(id); else _selected.add(id); }),
                child: Container(color: sel ? AppTheme.primary.withOpacity(0.04) : Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  child: Row(children: [
                    SizedBox(width: 40, child: Checkbox(value: sel, onChanged: (v) => setState(() { if (v == true) _selected.add(id); else _selected.remove(id); }))),
                    Expanded(flex: 2, child: Text(ts, style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 1, child: Text(sess, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text(branch, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.orange.shade100)), child: Text(cat, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.orange.shade800)))),
                    Expanded(flex: 3, child: Text(note == '-' ? '' : note, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 1, child: Text(cashier, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                    Expanded(flex: 1, child: Text('Rs. ${amt.toStringAsFixed(2)}', textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.red.shade700))),
                  ])));
            })),
    ]));
  }
}

class _StatChip extends StatelessWidget {
  final String label, value; final Color color;
  const _StatChip({required this.label, required this.value, required this.color});
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.2))),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
    ]));
}
