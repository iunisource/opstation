// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/skeleton_loader.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../../core/widgets/responsive.dart';

class ErpOverheadsSummaryScreen extends ConsumerStatefulWidget {
  const ErpOverheadsSummaryScreen({super.key});
  @override
  ConsumerState<ErpOverheadsSummaryScreen> createState() => _ErpOverheadsSummaryScreenState();
}

class _ErpOverheadsSummaryScreenState extends ConsumerState<ErpOverheadsSummaryScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _branches = [];
  String? _branchId; // null = all branches
  late DateTime _from;
  late DateTime _to;
  bool _includeDrafts = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to = now;
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
      final res = await client.rpc('rpc_overheads_summary', params: {
        'p_org_id': orgId,
        'p_branch_id': _branchId,
        'p_from': _fmtDate(_from),
        'p_to': _fmtDate(_to),
        'p_include_drafts': _includeDrafts,
      });
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches as List);
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load: $e')));
    }
  }

  double _n(Map<String, dynamic> r, String k) => ((r[k]) as num?)?.toDouble() ?? 0;
  double get _totalLabor => _rows.fold(0.0, (s, r) => s + _n(r, 'labor'));
  double get _totalOverhead => _rows.fold(0.0, (s, r) => s + _n(r, 'overhead'));
  double get _grandTotal => _totalLabor + _totalOverhead;

  String _money(double v) => money(v);

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fmtDisplay(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String get _branchName => _branchId == null
      ? 'All Branches'
      : ((_branches.firstWhere((b) => b['id'] == _branchId, orElse: () => {})['name'] as String?) ?? '-');

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(context: context, initialDate: _from, firstDate: DateTime(2020), lastDate: _to);
    if (picked != null) { setState(() => _from = picked); _load(); }
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(context: context, initialDate: _to, firstDate: _from, lastDate: DateTime.now());
    if (picked != null) { setState(() => _to = picked); _load(); }
  }

  void _print() {
    final list = _rows;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    final gen = '${_fmtDisplay(now)} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      return '<tr>'
          '<td>${esc(r['doc_type'])} ${esc(r['voucher_number'])}</td>'
          '<td>${esc(r['voucher_date'])}</td>'
          '<td>${esc(r['product_name'])}</td>'
          '<td style="text-align:right">${_money(_n(r, 'labor'))}</td>'
          '<td style="text-align:right">${_money(_n(r, 'overhead'))}</td>'
          '<td style="text-align:right;font-weight:bold">${_money(_n(r, 'total'))}</td>'
          '</tr>';
    }).join();
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Overheads Summary</title>'
        '<style>@page{margin:0}'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        'tfoot td{font-weight:bold;background:#fafbfc}'
        '@page{size:landscape}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Overheads Summary</h1>'
        '<div class="muted">Branch: ${esc(_branchName)} &middot; ${_fmtDisplay(_from)} to ${_fmtDisplay(_to)}${_includeDrafts ? ' &middot; incl. drafts' : ''}</div>'
        '<div class="muted">Generated: $gen &middot; ${list.length} document(s)</div>'
        '<table><thead><tr>'
        '<th>Document</th><th>Date</th><th>Product</th>'
        '<th style="text-align:right">Labor</th><th style="text-align:right">Overhead</th><th style="text-align:right">Total</th>'
        '</tr></thead><tbody>$body</tbody>'
        '<tfoot><tr><td colspan="3" style="text-align:right">Total</td>'
        '<td style="text-align:right">${_money(_totalLabor)}</td>'
        '<td style="text-align:right">${_money(_totalOverhead)}</td>'
        '<td style="text-align:right">${_money(_grandTotal)}</td></tr></tfoot>'
        '</table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }

  Widget _summaryCard(String label, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.25))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final list = _rows;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Overheads Summary', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          OutlinedButton.icon(onPressed: list.isEmpty ? null : _print, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ]),
        const SizedBox(height: 4),
        Text('Applied labor & overhead across production vouchers and job cards. ${list.length} document${list.length == 1 ? '' : 's'}.',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 200, child: DropdownButtonFormField<String?>(
            value: _branchId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('All Branches')),
              ..._branches.map((b) => DropdownMenuItem<String?>(value: b['id'] as String, child: Text(b['name'] as String? ?? '-', overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (v) { setState(() => _branchId = v); _load(); },
          )),
          OutlinedButton.icon(onPressed: _pickFrom, icon: const Icon(Icons.calendar_today_outlined, size: 16), label: Text('From: ${_fmtDisplay(_from)}')),
          OutlinedButton.icon(onPressed: _pickTo, icon: const Icon(Icons.event_outlined, size: 16), label: Text('To: ${_fmtDisplay(_to)}')),
          FilterChip(
            label: const Text('Include drafts'),
            selected: _includeDrafts,
            onSelected: (v) { setState(() => _includeDrafts = v); _load(); },
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          _summaryCard('Total Labor', 'Rs. ${_money(_totalLabor)}', AppTheme.primary),
          const SizedBox(width: 12),
          _summaryCard('Total Overhead', 'Rs. ${_money(_totalOverhead)}', AppTheme.warning),
          const SizedBox(width: 12),
          _summaryCard('Grand Total', 'Rs. ${_money(_grandTotal)}', AppTheme.success),
        ]),
        const SizedBox(height: 16),
        Expanded(child: _loading
            ? Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: const TableSkeleton(),
              )
            : HScrollOnNarrow(minWidth: 780, child: Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                    child: const Row(children: [
                      Expanded(flex: 3, child: Text('Document', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 3, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Labor', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Overhead', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                    ]),
                  ),
                  Expanded(child: list.isEmpty
                      ? const Center(child: Text('No applied overheads in this range.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = list[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                              child: Row(children: [
                                Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(r['voucher_number'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                  Text(r['doc_type'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                ])),
                                Expanded(flex: 2, child: Text(r['voucher_date']?.toString() ?? '-', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                Expanded(flex: 3, child: Text(r['product_name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(_money(_n(r, 'labor')), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(_money(_n(r, 'overhead')), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                                Expanded(flex: 2, child: Text(_money(_n(r, 'total')), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary))),
                              ]),
                            );
                          },
                        )),
                  if (list.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(bottom: Radius.circular(12))),
                      child: Row(children: [
                        const Expanded(flex: 8, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                        Expanded(flex: 2, child: Text(_money(_totalLabor), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                        Expanded(flex: 2, child: Text(_money(_totalOverhead), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                        Expanded(flex: 2, child: Text(_money(_grandTotal), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppTheme.primary))),
                      ]),
                    ),
                ]),
              ))),
      ]),
    );
  }
}
