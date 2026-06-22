// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_loader.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpStockBalanceReportScreen extends ConsumerStatefulWidget {
  const ErpStockBalanceReportScreen({super.key});
  @override
  ConsumerState<ErpStockBalanceReportScreen> createState() => _ErpStockBalanceReportScreenState();
}

class _ErpStockBalanceReportScreenState extends ConsumerState<ErpStockBalanceReportScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _branches = [];
  String? _branchId; // null = all branches
  DateTime _asOf = DateTime.now();
  bool _hideZero = false;
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  String? _fMain, _fGroup, _fClass, _fMov;

  @override
  void initState() {
    super.initState();
    _branchId = ref.read(selectedBranchProvider)?['id'] as String?;
    _load();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final branches = await client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name');
      final taxos = await client.from('product_taxonomies').select().eq('org_id', orgId).order('name');
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in (taxos as List)) {
        final m = Map<String, dynamic>.from(t);
        grouped.putIfAbsent(m['taxonomy_type'] as String, () => []).add(m);
      }
      final res = await client.rpc('rpc_stock_balance', params: {
        'p_org_id': orgId,
        'p_branch_id': _branchId,
        'p_as_of': _fmtDate(_asOf),
      });
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches as List);
        _taxonomies = grouped;
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load: $e')));
    }
  }

  double _qty(Map<String, dynamic> r) => ((r['on_hand']) as num?)?.toDouble() ?? 0;
  String _qtyStr(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fmtDisplay(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  List<Map<String, dynamic>> get _list => _rows.where((r) {
        if (_hideZero && _qty(r) == 0) return false;
        if (_fMain != null && r['product_main_group'] != _fMain) return false;
        if (_fGroup != null && r['product_group'] != _fGroup) return false;
        if (_fClass != null && r['product_class'] != _fClass) return false;
        if (_fMov != null && r['product_movement_category'] != _fMov) return false;
        return true;
      }).toList();

  Widget _filterDropdown(String label, String type, String? value, void Function(String?) onChanged) {
    final items = _taxonomies[type] ?? [];
    return SizedBox(width: 180, child: DropdownButtonFormField<String?>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All')),
        ...items.map((t) => DropdownMenuItem<String?>(value: t['name'] as String, child: Text(t['name'] as String, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: onChanged,
    ));
  }

  String get _branchName => _branchId == null
      ? 'All Branches'
      : ((_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {})['name'] as String?) ?? '-');

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context, initialDate: _asOf,
      firstDate: DateTime(2020), lastDate: DateTime.now(),
    );
    if (picked != null) { setState(() => _asOf = picked); _load(); }
  }

  void _print() {
    final list = _list;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    final gen = '${_fmtDisplay(now)} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      return '<tr>'
          '<td>${esc(r['product_name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['uom'])}</td>'
          '<td style="text-align:right">${_qtyStr(_qty(r))}</td>'
          '</tr>';
    }).join();
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Stock Balance Report</title>'
        '<style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Stock Balance Report</h1>'
        '<div class="muted">Branch: ${esc(_branchName)} &middot; as of ${_fmtDisplay(_asOf)}${_hideZero ? ' &middot; on-hand only' : ''}</div>'
        '<div class="muted">Generated: $gen &middot; ${list.length} item(s)</div>'
        '<table><thead><tr>'
        '<th>Product</th><th>SKU</th><th>UOM</th><th style="text-align:right">On Hand</th>'
        '</tr></thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Stock Balance Report', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          OutlinedButton.icon(onPressed: list.isEmpty ? null : _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ]),
        const SizedBox(height: 4),
        Text('On-hand quantity as of ${_fmtDisplay(_asOf)}. ${list.length} item${list.length == 1 ? '' : 's'}.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 220, child: DropdownButtonFormField<String?>(
            value: _branchId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Branches')),
              ..._branches.map((b) => DropdownMenuItem<String?>(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) { setState(() => _branchId = v); _load(); },
          )),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text('As of ${_fmtDisplay(_asOf)}'),
          ),
          _filterDropdown('Main Group', 'main_group', _fMain, (v) => setState(() => _fMain = v)),
          _filterDropdown('Group', 'group', _fGroup, (v) => setState(() => _fGroup = v)),
          _filterDropdown('Class', 'class', _fClass, (v) => setState(() => _fClass = v)),
          _filterDropdown('Movement Category', 'movement_category', _fMov, (v) => setState(() => _fMov = v)),
          if (_fMain != null || _fGroup != null || _fClass != null || _fMov != null)
            TextButton.icon(onPressed: () => setState(() { _fMain = null; _fGroup = null; _fClass = null; _fMov = null; }),
                icon: const Icon(Icons.clear, size: 16), label: const Text('Clear filters')),
          FilterChip(
            label: const Text('Hide zero-stock'),
            selected: _hideZero,
            onSelected: (v) => setState(() => _hideZero = v),
          ),
        ]),
        const SizedBox(height: 16),
        Expanded(child: _loading
            ? Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: const TableSkeleton(),
              )
            : Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('On Hand', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    ]),
                  ),
                  Expanded(child: list.isEmpty
                      ? const Center(child: Text('No products to show.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = list[i];
                            final q = _qty(r);
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                              child: Row(children: [
                                Expanded(flex: 4, child: Text(r['product_name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                                Expanded(flex: 2, child: Text(r['sku'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 1, child: Text(r['uom'] as String? ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 2, child: Text(_qtyStr(q), textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: q == 0 ? AppTheme.textSecondary : AppTheme.textPrimary))),
                              ]),
                            );
                          },
                        )),
                ]),
              )),
      ]),
    );
  }
}
