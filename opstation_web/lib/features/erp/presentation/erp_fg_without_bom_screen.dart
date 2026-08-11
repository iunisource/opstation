import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Finished Goods without BOM — lists products classed as finished goods that
/// are NOT the output of any *active* Product Assembly (BOM). Such an item
/// can't be produced or drive raw-material planning, and its stock can only
/// arrive via manual adjustment — so it usually means an assembly was never
/// set up. Mirrors the reason the PO "FG on-hand" figure goes blank.
class ErpFgWithoutBomScreen extends ConsumerStatefulWidget {
  const ErpFgWithoutBomScreen({super.key});
  @override
  ConsumerState<ErpFgWithoutBomScreen> createState() => _ErpFgWithoutBomScreenState();
}

class _Row {
  final String id;
  final String name;
  final String sku;
  final String cls;
  final String group;
  final double stock;
  _Row(this.id, this.name, this.sku, this.cls, this.group, this.stock);
}

class _ErpFgWithoutBomScreenState extends ConsumerState<ErpFgWithoutBomScreen> {
  bool _loading = true;
  String? _error;
  List<_Row> _rows = [];
  List<String> _classes = [];
  String _class = 'all';
  final _searchCtrl = TextEditingController();
  final _qty = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _pageAll(
      Future<dynamic> Function(int from, int to) build) async {
    final out = <Map<String, dynamic>>[];
    for (int from = 0;; from += 1000) {
      final page = List<Map<String, dynamic>>.from(await build(from, from + 999) as List);
      out.addAll(page);
      if (page.length < 1000 || from > 500000) break;
    }
    return out;
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final c = Supabase.instance.client;

      // All products (with their taxonomy).
      final prods = await _pageAll((f, t) => c.from('products')
          .select('id, name, sku, product_class, product_main_group')
          .eq('org_id', orgId).range(f, t));

      // Products that ARE the output of an active BOM — these are covered.
      final withBom = <String>{};
      for (final h in await _pageAll((f, t) => c.from('bom_headers')
          .select('product_id').eq('org_id', orgId).eq('status', 'active').range(f, t))) {
        final pid = h['product_id'] as String?;
        if (pid != null) withBom.add(pid);
      }

      // Current stock per product (org-wide, all branches).
      final stock = <String, double>{};
      for (final s in await _pageAll((f, t) => c.from('inventory_stock')
          .select('product_id, quantity').eq('org_id', orgId).range(f, t))) {
        final pid = s['product_id'] as String?;
        if (pid == null) continue;
        stock[pid] = (stock[pid] ?? 0) + ((s['quantity'] as num?)?.toDouble() ?? 0);
      }

      // Distinct classes, and the rows for products that lack an active BOM.
      final classes = <String>{};
      final rows = <_Row>[];
      for (final p in prods) {
        final id = p['id'] as String;
        final cls = (p['product_class'] as String?)?.trim() ?? '';
        if (cls.isNotEmpty) classes.add(cls);
        if (withBom.contains(id)) continue; // has an assembly — fine
        rows.add(_Row(
          id,
          (p['name'] as String?) ?? '(unnamed)',
          (p['sku'] as String?) ?? '',
          cls.isEmpty ? '—' : cls,
          (p['product_main_group'] as String?)?.trim() ?? '',
          stock[id] ?? 0,
        ));
      }

      final classList = classes.toList()..sort();
      // Default the class filter to the "finished"-goods class if one exists,
      // so the report opens on exactly the items that should have a BOM.
      String def = _class;
      if (def == 'all') {
        final fin = classList.firstWhere(
            (c) => c.toLowerCase().contains('finish'), orElse: () => '');
        if (fin.isNotEmpty) def = fin;
      }
      // Never leave the dropdown on a class that no longer exists (would trip
      // the DropdownButtonFormField value-must-match-an-item assertion).
      if (def != 'all' && !classList.contains(def)) def = 'all';

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _classes = classList;
        _class = def;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().split('\n').first; _loading = false; });
    }
  }

  List<_Row> get _visible {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _rows.where((r) {
      if (_class != 'all' && r.cls != _class) return false;
      if (q.isEmpty) return true;
      return r.name.toLowerCase().contains(q) || r.sku.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) {
        final byStock = b.stock.compareTo(a.stock);
        if (byStock != 0) return byStock;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  Future<void> _print() async {
    final rows = _visible;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Finished Goods without BOM',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(
            'Class: ${_class == 'all' ? 'All' : _class}     |     ${rows.length} item(s)     |     ${DateFormat('d MMM y').format(DateTime.now())}',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: const ['#', 'Product', 'SKU', 'Class', 'Group', 'In Stock'],
          data: [
            for (var i = 0; i < rows.length; i++)
              [
                '${i + 1}', rows[i].name, rows[i].sku, rows[i].cls,
                rows[i].group, _qty.format(rows[i].stock),
              ],
          ],
          headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellAlignments: const {0: pw.Alignment.centerLeft, 5: pw.Alignment.centerRight},
        ),
      ],
    ));
    await Printing.layoutPdf(
      onLayout: (f) async => doc.save(),
      name: 'fg-without-bom-${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    final withStock = rows.where((r) => r.stock.abs() > 0.005).length;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Finished Goods without BOM',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('Print / PDF'),
            onPressed: rows.isEmpty ? null : _print,
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
            'Finished-goods products with no active Product Assembly (BOM). Until one is set up they can\'t be produced or planned, and their stock can only come from manual adjustments.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),

        // Filters
        Row(children: [
          SizedBox(
            width: 240,
            child: DropdownButtonFormField<String>(
              value: _class,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Class', isDense: true, border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('All classes')),
                for (final c in _classes)
                  DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _class = v ?? 'all'),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 320,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search product / SKU…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _searchCtrl.clear()),
              ),
            ),
          ),
          const Spacer(),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 12),

        if (!_loading && _error == null)
          Wrap(spacing: 18, runSpacing: 4, children: [
            _kv('Missing BOM', '${rows.length}'),
            _kv('Of which hold stock', '$withStock'),
          ]),
        const SizedBox(height: 12),

        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('Failed to load: $_error',
                        style: const TextStyle(color: AppTheme.danger)))
                    : rows.isEmpty
                        ? const Center(
                            child: Text('Every finished good has an active BOM. Nothing to set up.',
                                style: TextStyle(color: AppTheme.textSecondary)))
                        : Column(children: [
                            _header(),
                            const Divider(height: 1),
                            Expanded(
                              child: ListView.separated(
                                itemCount: rows.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (_, i) => _row(i + 1, rows[i]),
                              ),
                            ),
                          ]),
          ),
        ),
      ]),
    );
  }

  Widget _kv(String k, String v) => RichText(
        text: TextSpan(
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            children: [
              TextSpan(text: '$k: '),
              TextSpan(text: v, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
            ]),
      );

  Widget _header() {
    const s = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: const [
        SizedBox(width: 36, child: Text('#', style: s)),
        Expanded(flex: 5, child: Text('Product', style: s)),
        Expanded(flex: 2, child: Text('Class', style: s)),
        Expanded(flex: 2, child: Text('Group', style: s)),
        Expanded(flex: 2, child: Text('In Stock', style: s, textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _row(int n, _Row r) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        SizedBox(width: 36, child: Text('$n', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
          flex: 5,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (r.sku.isNotEmpty)
              Text(r.sku, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        Expanded(flex: 2, child: Text(r.cls, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(flex: 2, child: Text(r.group.isEmpty ? '—' : r.group, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(
          flex: 2,
          child: Text(_qty.format(r.stock),
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: r.stock.abs() > 0.005 ? AppTheme.warning : AppTheme.textSecondary)),
        ),
      ]),
    );
  }
}
