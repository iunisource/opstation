// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Inventory Integrity Check — two different questions, deliberately separate.
///
/// PRODUCTS tab (rpc_inventory_integrity): is the stock DATA sane right now?
/// Missing cost price, stock<>layers, negative layers, zero-cost layers. This is
/// a check on STATE.
///
/// DOCUMENTS tab (rpc_inventory_gl_reconciliation): did each transaction POST
/// consistently? For every document that moved stock, does the value the General
/// Ledger recorded equal the value the inventory cost ledger recorded? This is a
/// check on FLOW, and it should always be empty.
///
/// The distinction matters. On 14 July two bugs cost real money, and BOTH left
/// every product looking perfectly healthy on the Products tab:
///
///   - POS sales posted COGS to the GL twice while consuming inventory once.
///     Product state: clean. The P&L: overstated by the duplicate.
///   - Purchase returns moved inventory correctly but posted the offset to an
///     expense account instead of Accounts Payable. Layers: consistent.
///     Accounts Payable: overstated by Rs 214,270.
///
/// Neither appeared in any total. Both were found only because a human noticed a
/// single number looked wrong. The Documents tab is the check that should have
/// caught them.
class ErpInventoryIntegrityScreen extends ConsumerStatefulWidget {
  const ErpInventoryIntegrityScreen({super.key});
  @override
  ConsumerState<ErpInventoryIntegrityScreen> createState() => _State();
}

class _State extends ConsumerState<ErpInventoryIntegrityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  String _filter = 'ALL';
  String _search = '';

  // Documents tab
  bool _docLoading = true;
  List<Map<String, dynamic>> _docRows = [];
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadDocs();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadDocs() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _docLoading = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'rpc_inventory_gl_reconciliation_active',
        params: {
          'p_org_id': orgId,
          'p_from': _d(_from),
          'p_to': _d(_to),
          'p_branch_id': null,
        },
      );
      if (!mounted) return;
      setState(() {
        _docRows = List<Map<String, dynamic>>.from(res as List);
        _docLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _docLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Reconciliation error: $e')));
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r != null && mounted) {
      setState(() { _from = r.start; _to = r.end; });
      _loadDocs();
    }
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('rpc_inventory_integrity', params: {'p_org': orgId});
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Load error: $e')));
    }
  }

  List<Map<String, dynamic>> get _visible {
    final q = _search.trim().toLowerCase();
    return _rows.where((r) {
      if (_filter != 'ALL' && r['issue'] != _filter) return false;
      if (q.isEmpty) return true;
      final n = (r['name'] as String? ?? '').toLowerCase();
      final s = (r['sku'] as String? ?? '').toLowerCase();
      return n.contains(q) || s.contains(q);
    }).toList();
  }

  int _count(String issue) => _rows.where((r) => r['issue'] == issue).length;

  void _print() {
    final list = _visible;
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final gen = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';
    String esc(Object? v) => (v ?? '').toString().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final body = list.map((r) {
      return '<tr>'
          '<td>${esc(r['name'])}</td>'
          '<td>${esc(r['sku'])}</td>'
          '<td>${esc(r['issue'])}</td>'
          '<td style="text-align:right">${_fmt(r['cost_price'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(r['stock_qty'] as num?)}</td>'
          '<td style="text-align:right">${_fmt(r['layer_qty'] as num?)}</td>'
          '</tr>';
    }).join();
    final htmlStr = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Inventory Integrity</title>'
        '<style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#222;margin:24px}'
        'h1{font-size:18px;margin:0 0 2px}'
        '.muted{color:#666;font-size:12px;margin:2px 0}'
        'table{border-collapse:collapse;width:100%;margin-top:14px;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}'
        'th{background:#f4f5f7}'
        '</style></head><body>'
        '<h1>$orgName &mdash; Inventory Integrity Check</h1>'
        '<div class="muted">Generated: $gen &middot; ${list.length} product(s) flagged</div>'
        '<table><thead><tr>'
        '<th>Product</th><th>SKU</th><th>Issue</th>'
        '<th style="text-align:right">Cost</th>'
        '<th style="text-align:right">Stock</th>'
        '<th style="text-align:right">Layers</th>'
        '</tr></thead><tbody>$body</tbody></table>'
        '<script>window.onload=function(){window.print();}</script>'
        '</body></html>';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 4), () => html.Url.revokeObjectUrl(url));
  }


  Color _issueColor(String? issue) {
    switch (issue) {
      case 'NO COST PRICE': return Colors.red;
      case 'STOCK <> LAYERS': return Colors.orange;
      case 'NEGATIVE LAYERS': return Colors.deepPurple;
      case 'ZERO-COST LAYERS': return Colors.brown;
      default: return Colors.grey;
    }
  }

  String _fmt(num? v) {
    final d = (v ?? 0).toDouble();
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d.toStringAsFixed(2);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Row(children: [
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Inventory Integrity Check', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            SizedBox(height: 2),
            Text('Products at risk: missing cost, stock/layer mismatch, negative or zero-cost layers',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          ])),
          IconButton(icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF',
              onPressed: _rows.isEmpty ? null : _print),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () { _load(); _loadDocs(); }),
        ])),
      Container(
        color: Colors.white,
        child: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          indicatorColor: AppTheme.primary,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          tabs: [
            Tab(text: 'Products (${_rows.length})'),
            Tab(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Documents'),
                if (_docRows.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: AppTheme.danger, borderRadius: BorderRadius.circular(8)),
                    child: Text('${_docRows.length}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white, fontWeight: FontWeight.w800)),
                  ),
                ],
              ]),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _productsTab(),
          _documentsTab(),
        ]),
      ),
    ]);
  }

  // ── Tab 2: does the GL agree with the inventory ledger, document by document?
  Widget _documentsTab() {
    if (_docLoading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range, size: 16),
            label: Text('${_d(_from)}  \u2192  ${_d(_to)}',
                style: const TextStyle(fontSize: 12)),
            onPressed: _pickRange,
          ),
          const Spacer(),
        ]),
        const SizedBox(height: 14),
        if (_docRows.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green.withOpacity(0.30)),
            ),
            child: const Row(children: [
              Icon(Icons.verified_outlined, color: Colors.green),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('General Ledger and inventory ledger agree',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text(
                      'Every document that moved stock posted the same value to both. '
                      'This is what you want to see.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
            ]),
          )
        else ...[
          // Loud on purpose. A control report that is normally empty is a report
          // nobody opens — and both of the bugs this exists to catch were
          // invisible precisely because nothing anywhere raised its voice.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.danger.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.danger.withOpacity(0.40)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppTheme.danger, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      '${_docRows.length} document${_docRows.length == 1 ? '' : 's'} '
                      'where the General Ledger and the inventory ledger disagree',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.danger)),
                  const SizedBox(height: 3),
                  const Text(
                      'Each of these posted one value to the GL and a different value to the '
                      'cost ledger. One of your reports is wrong for every row below.',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
                child: const Row(children: [
                  Expanded(flex: 2, child: Text('Document', style: _h)),
                  Expanded(flex: 2, child: Text('Voucher', style: _h)),
                  Expanded(flex: 2, child: Text('Date', style: _h)),
                  Expanded(flex: 2, child: Text('GL value', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text('Ledger value', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 2, child: Text('Difference', style: _h, textAlign: TextAlign.right)),
                  Expanded(flex: 4, child: Text('What it means', style: _h)),
                ]),
              ),
              const Divider(height: 1),
              ..._docRows.map((r) {
                final diff = (r['difference'] as num?)?.toDouble() ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(flex: 2, child: Text('${r['doc_type'] ?? '-'}',
                        style: const TextStyle(fontSize: 12))),
                    Expanded(flex: 2, child: Text('${r['voucher_no'] ?? '-'}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    Expanded(flex: 2, child: Text('${r['voucher_date'] ?? '-'}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                    Expanded(flex: 2, child: Text(_fmt(r['gl_value'] as num?),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text(_fmt(r['ledger_value'] as num?),
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    Expanded(flex: 2, child: Text(_fmt(diff),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.danger))),
                    Expanded(flex: 4, child: Text('${r['note'] ?? ''}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                  ]),
                );
              }),
            ]),
          ),
        ],
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _productsTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return SingleChildScrollView(padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Summary chips
            Wrap(spacing: 10, runSpacing: 10, children: [
              _summaryChip('ALL', 'All issues', _rows.length),
              _summaryChip('NO COST PRICE', 'No cost price', _count('NO COST PRICE')),
              _summaryChip('STOCK <> LAYERS', 'Stock \u2260 layers', _count('STOCK <> LAYERS')),
              _summaryChip('NEGATIVE LAYERS', 'Negative layers', _count('NEGATIVE LAYERS')),
              _summaryChip('ZERO-COST LAYERS', 'Zero-cost layers', _count('ZERO-COST LAYERS')),
            ]),
            const SizedBox(height: 16),
            SizedBox(width: 320, child: TextField(
              decoration: const InputDecoration(
                labelText: 'Search product (name or SKU)', isDense: true,
                prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _search = v),
            )),
            const SizedBox(height: 12),
            if (_rows.isEmpty)
              Container(padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
                child: const Row(children: [
                  Icon(Icons.check_circle, color: Colors.green),
                  SizedBox(width: 10),
                  Text('No integrity issues found. Inventory is clean.', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ]))
            else
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: const BoxDecoration(color: Color(0xFFF8F9FA)),
                    child: const Row(children: [
                      Expanded(flex: 4, child: Text('Product', style: _h)),
                      Expanded(flex: 2, child: Text('SKU', style: _h)),
                      Expanded(flex: 2, child: Text('Issue', style: _h)),
                      Expanded(flex: 1, child: Text('Cost', style: _h, textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('Stock', style: _h, textAlign: TextAlign.right)),
                      Expanded(flex: 1, child: Text('Layers', style: _h, textAlign: TextAlign.right)),
                    ])),
                  const Divider(height: 1),
                  ..._visible.map((r) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text(r['name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(r['sku'] as String? ?? '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _issueColor(r['issue'] as String?).withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                        child: Text(r['issue'] as String? ?? '-', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _issueColor(r['issue'] as String?))),
                      ))),
                      Expanded(flex: 1, child: Text(_fmt(r['cost_price'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(_fmt(r['stock_qty'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 1, child: Text(_fmt(r['layer_qty'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                    ]),
                  )),
                ]),
              ),
            const SizedBox(height: 24),
          ]));
  }

  static const _h = TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary);

  Widget _summaryChip(String key, String label, int count) {
    final active = _filter == key;
    final color = key == 'ALL' ? AppTheme.primary : _issueColor(key);
    return InkWell(
      onTap: () => setState(() => _filter = key),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.12) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? color : AppTheme.border, width: active ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$count', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}
