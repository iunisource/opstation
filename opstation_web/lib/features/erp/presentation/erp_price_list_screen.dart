import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Price List Generator — pick Main Group / Group / Sub Group (each All or a
/// multi-select), a margin %, and a cost source (Purchase = cost price,
/// Selling = selling price, BoM = bill-of-materials roll-up). Rate = base ×
/// (1 + margin). Output: Sr# / SKU / Product / UOM / Rate as an on-screen
/// preview and a PDF (print or save).
class ErpPriceListScreen extends ConsumerStatefulWidget {
  const ErpPriceListScreen({super.key});
  @override
  ConsumerState<ErpPriceListScreen> createState() => _ErpPriceListScreenState();
}

class _P {
  final String id, sku, name, main, group, sub, uom;
  final double cost, sell;
  _P(this.id, this.sku, this.name, this.main, this.group, this.sub, this.uom, this.cost, this.sell);
}

class _ErpPriceListScreenState extends ConsumerState<ErpPriceListScreen> {
  bool _loading = true;
  String? _error;
  List<_P> _products = [];
  final Map<String, double> _bomRate = {}; // product_id -> BOM roll-up per unit
  bool _bomLoaded = false;

  final Set<String> _mains = {};
  final Set<String> _groups = {};
  final Set<String> _subs = {};
  final _searchCtrl = TextEditingController();     // brand / keyword filter (name or SKU)
  final Set<String> _pickedIds = {};               // explicit product picks (overrides the filtered set)
  final _marginCtrl = TextEditingController(); // user-entered; 15 shown only as a hint
  String _source = 'purchase'; // purchase | selling | bom
  String _method = 'markup';   // markup (× (1+m)) | margin (÷ (1−m))
  final _qty = NumberFormat('#,##0.##');

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _marginCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    try {
      final c = Supabase.instance.client;
      final uoms = await c.from('uoms').select('id, abbreviation').eq('org_id', orgId);
      final uomMap = {for (final u in uoms as List) u['id'] as String: (u['abbreviation'] as String? ?? '')};
      final rows = <_P>[];
      for (int from = 0;; from += 1000) {
        final page = List<Map<String, dynamic>>.from(await c.from('products')
            .select('id, sku, name, product_main_group, product_group, product_sub_group, cost_price, selling_price, base_uom_id, is_active')
            .eq('org_id', orgId).eq('is_active', true).order('name').range(from, from + 999));
        for (final p in page) {
          rows.add(_P(
            p['id'] as String,
            (p['sku'] as String?) ?? '',
            (p['name'] as String?) ?? '(unnamed)',
            (p['product_main_group'] as String?)?.trim() ?? '',
            (p['product_group'] as String?)?.trim() ?? '',
            (p['product_sub_group'] as String?)?.trim() ?? '',
            uomMap[p['base_uom_id']] ?? '',
            (p['cost_price'] as num?)?.toDouble() ?? 0,
            (p['selling_price'] as num?)?.toDouble() ?? 0,
          ));
        }
        if (page.length < 1000 || from > 500000) break;
      }
      if (!mounted) return;
      setState(() { _products = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().split('\n').first; _loading = false; });
    }
  }

  Future<void> _ensureBomRates() async {
    if (_bomLoaded) return;
    final orgId = _orgId;
    if (orgId == null) return;
    final c = Supabase.instance.client;
    final costById = {for (final p in _products) p.id: p.cost};
    final headers = List<Map<String, dynamic>>.from(await c.from('bom_headers')
        .select('id, product_id, output_qty').eq('org_id', orgId).eq('status', 'active'));
    final bomIds = headers.map((h) => h['id'] as String).toList();
    final comps = bomIds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
        await c.from('bom_components').select('bom_id, product_id, quantity').inFilter('bom_id', bomIds));
    final ohs = bomIds.isEmpty ? <Map<String, dynamic>>[] : List<Map<String, dynamic>>.from(
        await c.from('bom_overheads').select('bom_id, amount').inFilter('bom_id', bomIds));
    final compByBom = <String, double>{};
    for (final r in comps) {
      final bid = r['bom_id'] as String;
      final qty = (r['quantity'] as num?)?.toDouble() ?? 0;
      final cc = costById[r['product_id'] as String?] ?? 0;
      compByBom[bid] = (compByBom[bid] ?? 0) + qty * cc;
    }
    final ohByBom = <String, double>{};
    for (final r in ohs) {
      final bid = r['bom_id'] as String;
      ohByBom[bid] = (ohByBom[bid] ?? 0) + ((r['amount'] as num?)?.toDouble() ?? 0);
    }
    _bomRate.clear();
    for (final h in headers) {
      final out = (h['output_qty'] as num?)?.toDouble() ?? 1;
      if (out <= 0) continue;
      final total = (compByBom[h['id']] ?? 0) + (ohByBom[h['id']] ?? 0);
      _bomRate[h['product_id'] as String] = total / out;
    }
    _bomLoaded = true;
  }

  // ── options that cascade with the higher-level selection ──────────────────
  List<String> get _mainOptions =>
      (_products.map((p) => p.main).where((s) => s.isNotEmpty).toSet().toList()..sort());
  List<String> get _groupOptions => (_products
      .where((p) => _mains.isEmpty || _mains.contains(p.main))
      .map((p) => p.group).where((s) => s.isNotEmpty).toSet().toList()..sort());
  List<String> get _subOptions => (_products
      .where((p) => (_mains.isEmpty || _mains.contains(p.main)) && (_groups.isEmpty || _groups.contains(p.group)))
      .map((p) => p.sub).where((s) => s.isNotEmpty).toSet().toList()..sort());

  int _cmp(_P a, _P b) {
    final m = a.main.compareTo(b.main);
    if (m != 0) return m;
    final g = a.group.compareTo(b.group);
    if (g != 0) return g;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  bool _matchGroups(_P p) {
    if (_mains.isNotEmpty && !_mains.contains(p.main)) return false;
    if (_groups.isNotEmpty && !_groups.contains(p.group)) return false;
    if (_subs.isNotEmpty && !_subs.contains(p.sub)) return false;
    return true;
  }

  // Products matching the group filters + the brand/keyword search.
  List<_P> get _candidates {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _products.where((p) {
      if (!_matchGroups(p)) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q) || p.sku.toLowerCase().contains(q);
    }).toList()
      ..sort(_cmp);
  }

  // The final list: an explicit pick if the user made one, else all candidates.
  List<_P> get _rows {
    if (_pickedIds.isEmpty) return _candidates;
    return (_products.where((p) => _pickedIds.contains(p.id)).toList()..sort(_cmp));
  }

  double get _margin => (double.tryParse(_marginCtrl.text.trim()) ?? 0);

  double _base(_P p) {
    switch (_source) {
      case 'selling': return p.sell;
      case 'bom': return _bomRate[p.id] ?? p.cost; // fallback to purchase cost
      default: return p.cost;
    }
  }

  double _rate(_P p) {
    final b = _base(p);
    final m = _margin / 100;
    if (_method == 'margin') {
      // Margin on price: margin is a % OF the final price. Guard m>=100%.
      return m >= 1 ? b : b / (1 - m);
    }
    return b * (1 + m); // markup on cost
  }

  String get _sourceLabel =>
      _source == 'selling' ? 'Selling Price' : (_source == 'bom' ? 'BoM Cost' : 'Purchase Cost');

  String get _methodLabel => _method == 'margin' ? 'margin on price' : 'markup on cost';

  Future<void> _pick(String title, List<String> options, Set<String> sel) async {
    final temp = Set<String>.from(sel);
    final searchCtrl = TextEditingController();
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = searchCtrl.text.trim().toLowerCase();
        final list = q.isEmpty ? options : options.where((o) => o.toLowerCase().contains(q)).toList();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                TextButton(onPressed: () => setD(() => temp..clear()..addAll(list)), child: const Text('Select all')),
                TextButton(onPressed: () => setD(() => temp.clear()), child: const Text('Clear')),
              ]),
              TextField(
                controller: searchCtrl, autofocus: true,
                decoration: const InputDecoration(hintText: 'Search…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 8),
              Flexible(child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 340),
                child: ListView(shrinkWrap: true, children: [
                  for (final o in list)
                    CheckboxListTile(
                      dense: true, controlAffinity: ListTileControlAffinity.leading,
                      title: Text(o, style: const TextStyle(fontSize: 13.5)),
                      value: temp.contains(o),
                      onChanged: (v) => setD(() { if (v == true) temp.add(o); else temp.remove(o); }),
                    ),
                  if (list.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No options', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey))),
                ]),
              )),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Apply (${temp.length})')),
          ],
        );
      }),
    );
    if (res == true) {
      setState(() {
        sel..clear()..addAll(temp);
        // clear lower levels that no longer belong
        _groups.removeWhere((g) => !_groupOptions.contains(g));
        _subs.removeWhere((s) => !_subOptions.contains(s));
      });
    }
  }

  // Expandable popup product picker — search the whole catalogue (by brand,
  // product name or SKU) and tick the exact items to include. This is how you
  // bifurcate at brand level, e.g. "Alfa" + "Honda" air filters.
  Future<void> _pickProducts() async {
    final temp = Set<String>.from(_pickedIds);
    final searchCtrl = TextEditingController(text: _searchCtrl.text.trim());
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final q = searchCtrl.text.trim().toLowerCase();
        final matches = (q.isEmpty
                ? _products.where((p) => temp.contains(p.id))
                : _products.where((p) => p.name.toLowerCase().contains(q) || p.sku.toLowerCase().contains(q)))
            .toList()
          ..sort(_cmp);
        final shown = matches.take(400).toList();
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text('Choose products', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: searchCtrl, autofocus: true,
                decoration: const InputDecoration(hintText: 'Search brand / product / SKU…', isDense: true, prefixIcon: Icon(Icons.search, size: 18), border: OutlineInputBorder()),
                onChanged: (_) => setD(() {}),
              ),
              const SizedBox(height: 6),
              Row(children: [
                Text('${temp.length} selected', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                const Spacer(),
                if (q.isNotEmpty)
                  TextButton(onPressed: () => setD(() => temp.addAll(shown.map((p) => p.id))), child: Text('Add all ${shown.length}')),
                TextButton(onPressed: () => setD(() => temp.clear()), child: const Text('Clear')),
              ]),
              Flexible(child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: shown.isEmpty
                    ? Center(child: Padding(padding: const EdgeInsets.all(24),
                        child: Text(q.isEmpty ? 'Type a brand or product to search…' : 'No matches.',
                            style: const TextStyle(color: AppTheme.textSecondary))))
                    : ListView.builder(
                        shrinkWrap: true, itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final p = shown[i];
                          return CheckboxListTile(
                            dense: true, controlAffinity: ListTileControlAffinity.leading,
                            title: Text(p.name, style: const TextStyle(fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text([p.sku, p.main, p.group].where((s) => s.isNotEmpty).join('  ·  '),
                                style: const TextStyle(fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                            value: temp.contains(p.id),
                            onChanged: (v) => setD(() { if (v == true) temp.add(p.id); else temp.remove(p.id); }),
                          );
                        }),
              )),
              if (matches.length > shown.length)
                Padding(padding: const EdgeInsets.only(top: 6),
                    child: Text('Showing first ${shown.length} of ${matches.length} — refine the search to see the rest.',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Use ${temp.length} product(s)')),
          ],
        );
      }),
    );
    if (res == true) setState(() { _pickedIds..clear()..addAll(temp); });
  }

  Widget _filterChip(String label, Set<String> sel, List<String> options, {IconData icon = Icons.category_outlined}) {
    final txt = sel.isEmpty ? 'All' : '${sel.length} selected';
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      onPressed: () => _pick(label, options, sel),
      label: Text('$label: $txt', overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.textPrimary, alignment: Alignment.centerLeft),
    );
  }

  Future<void> _generatePdf() async {
    if (_source == 'bom') { await _ensureBomRates(); if (mounted) setState(() {}); }
    final rows = _rows;
    if (rows.isEmpty) return;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    // Customer-facing document: heading + org + generated timestamp ONLY.
    // Never print margin %, cost source, or group scope (confidential).
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty) pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Price List', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text('Generated: $stamp', style: pw.TextStyle(fontSize: 9.5, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: const ['Sr.#', 'SKU', 'Product Name', 'UOM', 'Rate'],
          data: [
            for (var i = 0; i < rows.length; i++)
              ['${i + 1}', rows[i].sku, rows[i].name, rows[i].uom, _qty.format(_rate(rows[i]))],
          ],
          headerStyle: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 9.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FixedColumnWidth(34),
            1: const pw.FixedColumnWidth(60),
            2: const pw.FlexColumnWidth(4),
            3: const pw.FixedColumnWidth(44),
            4: const pw.FixedColumnWidth(64),
          },
          cellAlignments: const {0: pw.Alignment.centerLeft, 3: pw.Alignment.center, 4: pw.Alignment.centerRight},
        ),
      ],
    ));
    await Printing.layoutPdf(
      onLayout: (f) async => doc.save(),
      name: 'price-list-${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
    );
  }

  Future<void> _exportExcel() async {
    if (_source == 'bom') { await _ensureBomRates(); if (mounted) setState(() {}); }
    final rows = _rows;
    if (rows.isEmpty) return;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final stamp = DateFormat('d MMM y, h:mm a').format(DateTime.now());
    final excel = xls.Excel.createExcel();
    const sheetName = 'Price List';
    final sheet = excel[sheetName];
    final def = excel.getDefaultSheet();
    if (def != null && def != sheetName) excel.delete(def);
    // Customer-facing: heading + timestamp only, no margin/source/scope.
    if (org.isNotEmpty) sheet.appendRow([xls.TextCellValue(org)]);
    sheet.appendRow([xls.TextCellValue('Price List')]);
    sheet.appendRow([xls.TextCellValue('Generated: $stamp')]);
    sheet.appendRow([xls.TextCellValue('')]);
    sheet.appendRow([
      xls.TextCellValue('Sr.#'), xls.TextCellValue('SKU'),
      xls.TextCellValue('Product Name'), xls.TextCellValue('UOM'), xls.TextCellValue('Rate'),
    ]);
    for (var i = 0; i < rows.length; i++) {
      final p = rows[i];
      sheet.appendRow([
        xls.IntCellValue(i + 1),
        xls.TextCellValue(p.sku),
        xls.TextCellValue(p.name),
        xls.TextCellValue(p.uom),
        xls.DoubleCellValue(double.parse(_rate(p).toStringAsFixed(2))),
      ]);
    }
    excel.save(fileName: 'price-list-${DateFormat('yyyyMMdd').format(DateTime.now())}.xlsx');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return LayoutBuilder(builder: (context, c) {
      final mobile = c.maxWidth < 640;
      return Container(
        color: AppTheme.background,
        padding: EdgeInsets.all(mobile ? 16 : 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Price List Generator', style: TextStyle(fontSize: mobile ? 22 : 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Pick the groups, a margin and a cost source, then generate a printable price list.',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(child: Center(child: Text('Failed to load: $_error', style: const TextStyle(color: AppTheme.danger))))
          else ...[
            Container(
              constraints: const BoxConstraints(maxWidth: 1040),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Main Group', _mains, _mainOptions, icon: Icons.folder_outlined)),
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Group', _groups, _groupOptions, icon: Icons.folder_open_outlined)),
                  SizedBox(width: mobile ? double.infinity : 240, child: _filterChip('Sub Group', _subs, _subOptions, icon: Icons.subdirectory_arrow_right)),
                ]),
                const SizedBox(height: 12),
                // Brand / keyword narrowing + explicit product picker
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: mobile ? double.infinity : 320, child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      labelText: 'Search brand / product / SKU',
                      hintText: 'e.g. Alfa  ·  Honda  ·  Air Filter',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true, border: const OutlineInputBorder(),
                      suffixIcon: _searchCtrl.text.isEmpty ? null
                          : IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => _searchCtrl.clear()),
                    ),
                  )),
                  OutlinedButton.icon(
                    onPressed: _pickProducts,
                    icon: const Icon(Icons.checklist_rtl, size: 18),
                    label: Text(_pickedIds.isEmpty ? 'Choose specific products…' : 'Chosen: ${_pickedIds.length}'),
                    style: OutlinedButton.styleFrom(foregroundColor: AppTheme.primary),
                  ),
                  if (_pickedIds.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _pickedIds.clear()),
                      icon: const Icon(Icons.close, size: 15),
                      label: const Text('Use all filtered instead'),
                    ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(width: 150, child: TextField(
                    controller: _marginCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Margin %', hintText: '15', isDense: true, border: OutlineInputBorder(), suffixText: '%'),
                  )),
                  SizedBox(width: 220, child: DropdownButtonFormField<String>(
                    value: _source, isDense: true,
                    decoration: const InputDecoration(labelText: 'Source of cost', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'purchase', child: Text('Purchase (cost price)')),
                      DropdownMenuItem(value: 'selling', child: Text('Selling (selling price)')),
                      DropdownMenuItem(value: 'bom', child: Text('BoM (recipe roll-up)')),
                    ],
                    onChanged: (v) => setState(() => _source = v ?? 'purchase'),
                  )),
                  SizedBox(width: 240, child: DropdownButtonFormField<String>(
                    value: _method, isDense: true,
                    decoration: const InputDecoration(labelText: 'Costing method', isDense: true, border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'markup', child: Text('Markup on cost')),
                      DropdownMenuItem(value: 'margin', child: Text('Margin on price')),
                    ],
                    onChanged: (v) => setState(() => _method = v ?? 'markup'),
                  )),
                  ElevatedButton.icon(
                    onPressed: rows.isEmpty ? null : _generatePdf,
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: const Text('PDF / Print'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
                  ),
                  OutlinedButton.icon(
                    onPressed: rows.isEmpty ? null : _exportExcel,
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('Excel'),
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1D6F42)),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Text('${rows.length} product(s)  ·  Rate = $_sourceLabel, ${_qty.format(_margin)}% ($_methodLabel)',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Expanded(child: _preview(rows, mobile)),
          ],
        ]),
      );
    });
  }

  Widget _preview(List<_P> rows, bool mobile) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 1040),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: rows.isEmpty
          ? const Center(child: Text('No products match the selected groups.', style: TextStyle(color: AppTheme.textSecondary)))
          : Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                child: Row(children: const [
                  SizedBox(width: 40, child: Text('Sr.#', style: _hs)),
                  SizedBox(width: 80, child: Text('SKU', style: _hs)),
                  Expanded(child: Text('Product Name', style: _hs)),
                  SizedBox(width: 60, child: Text('UOM', style: _hs, textAlign: TextAlign.center)),
                  SizedBox(width: 90, child: Text('Rate', style: _hs, textAlign: TextAlign.right)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(child: ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = rows[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    child: Row(children: [
                      SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      SizedBox(width: 80, child: Text(p.sku, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Expanded(child: Text(p.name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      SizedBox(width: 60, child: Text(p.uom, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), textAlign: TextAlign.center)),
                      SizedBox(width: 90, child: Text(_qty.format(_rate(p)), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
                    ]),
                  );
                },
              )),
            ]),
    );
  }
}

const _hs = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
