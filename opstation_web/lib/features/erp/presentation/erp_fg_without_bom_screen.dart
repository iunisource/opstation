import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Finished Goods without BOM — products that ought to be produced (grouped as
/// finished goods) but have no *active* Product Assembly (BOM). Such an item
/// can't be produced or drive raw-material planning, and its stock can only
/// arrive via manual adjustment — the same reason a PO's "FG on-hand" figure
/// goes blank.
///
/// Products can be narrowed by the full product hierarchy — Main group
/// (product_main_group), Group (product_group) and Sub group
/// (product_sub_group) — each a multi-select (pick 1..N values), and the three
/// cascade (Group options reflect the chosen Main groups, Sub group options the
/// chosen Groups). Raw-material groups are excluded from the finished-goods view
/// — raws don't need a BOM.
class ErpFgWithoutBomScreen extends ConsumerStatefulWidget {
  const ErpFgWithoutBomScreen({super.key});
  @override
  ConsumerState<ErpFgWithoutBomScreen> createState() => _ErpFgWithoutBomScreenState();
}

class _Row {
  final String id;
  final String name;
  final String sku;
  final String mainGroup; // product_main_group
  final String group; // product_group
  final String subGroup; // product_sub_group
  final double stock;
  final bool isRaw; // raw material / pre-production input
  _Row(this.id, this.name, this.sku, this.mainGroup, this.group, this.subGroup,
      this.stock, this.isRaw);
}

class _ErpFgWithoutBomScreenState extends ConsumerState<ErpFgWithoutBomScreen> {
  bool _loading = true;
  String? _error;
  List<_Row> _rows = [];
  // Multi-select filters (empty set == "All"). They cascade top→bottom.
  final Set<String> _mainSel = {};
  final Set<String> _groupSel = {};
  final Set<String> _subSel = {};
  String _type = 'finished'; // 'finished' | 'raw' | 'all'
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

  // A raw material / pre-production input never needs a BOM, so it's excluded
  // from this finished-goods report. Detected by the group or class label.
  bool _isRaw(String cls, String grp) {
    final s = '$cls $grp'.toLowerCase();
    return s.contains('raw') || s.contains('pre-produc') || s.contains('pre produc');
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

      final prods = await _pageAll((f, t) => c.from('products')
          .select(
              'id, name, sku, product_class, product_main_group, product_group, product_sub_group')
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

      final rows = <_Row>[];
      for (final p in prods) {
        final id = p['id'] as String;
        if (withBom.contains(id)) continue; // has an assembly — fine
        final cls = (p['product_class'] as String?)?.trim() ?? '';
        final mg = (p['product_main_group'] as String?)?.trim() ?? '';
        final g = (p['product_group'] as String?)?.trim() ?? '';
        final sg = (p['product_sub_group'] as String?)?.trim() ?? '';
        rows.add(_Row(
          id,
          (p['name'] as String?) ?? '(unnamed)',
          (p['sku'] as String?) ?? '',
          mg.isEmpty ? '—' : mg,
          g.isEmpty ? '—' : g,
          sg.isEmpty ? '—' : sg,
          stock[id] ?? 0,
          _isRaw(cls, mg),
        ));
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        // Drop any stale selections not present for the current type filter.
        _pruneSelections();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().split('\n').first; _loading = false; });
    }
  }

  String _typeLabel() =>
      _type == 'finished' ? 'Finished Goods' : (_type == 'raw' ? 'Raw Materials' : 'All Goods');

  // Whether a row passes the current Finished / Raw / All type filter.
  bool _matchesType(_Row r) {
    if (_type == 'finished') return !r.isRaw;
    if (_type == 'raw') return r.isRaw;
    return true; // all
  }

  // Cascading option lists. Each level respects the type filter and the
  // selections made at the levels above it, so the choices always make sense.
  List<String> get _mainGroupOptions {
    final set = <String>{};
    for (final r in _rows) {
      if (!_matchesType(r)) continue;
      if (r.mainGroup != '—') set.add(r.mainGroup);
    }
    return set.toList()..sort();
  }

  List<String> get _groupOptions {
    final set = <String>{};
    for (final r in _rows) {
      if (!_matchesType(r)) continue;
      if (_mainSel.isNotEmpty && !_mainSel.contains(r.mainGroup)) continue;
      if (r.group != '—') set.add(r.group);
    }
    return set.toList()..sort();
  }

  List<String> get _subGroupOptions {
    final set = <String>{};
    for (final r in _rows) {
      if (!_matchesType(r)) continue;
      if (_mainSel.isNotEmpty && !_mainSel.contains(r.mainGroup)) continue;
      if (_groupSel.isNotEmpty && !_groupSel.contains(r.group)) continue;
      if (r.subGroup != '—') set.add(r.subGroup);
    }
    return set.toList()..sort();
  }

  // Remove any selected value that is no longer a valid option (after a type
  // change or a change in a higher level of the hierarchy). Prune top→bottom so
  // a narrowed parent correctly narrows its children.
  void _pruneSelections() {
    _mainSel.retainWhere(_mainGroupOptions.contains);
    _groupSel.retainWhere(_groupOptions.contains);
    _subSel.retainWhere(_subGroupOptions.contains);
  }

  List<_Row> get _visible {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _rows.where((r) {
      if (!_matchesType(r)) return false;
      if (_mainSel.isNotEmpty && !_mainSel.contains(r.mainGroup)) return false;
      if (_groupSel.isNotEmpty && !_groupSel.contains(r.group)) return false;
      if (_subSel.isNotEmpty && !_subSel.contains(r.subGroup)) return false;
      return matchesQuery('${r.name} ${r.sku}', q);
    }).toList()
      ..sort((a, b) {
        final byStock = b.stock.compareTo(a.stock);
        if (byStock != 0) return byStock;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  String _selLabel(Set<String> s) => s.isEmpty ? 'All' : (s.toList()..sort()).join(', ');

  // Compact "group · sub" line for a row (drops empty levels).
  String _subPath(_Row r) =>
      [if (r.group != '—') r.group, if (r.subGroup != '—') r.subGroup].join(' · ');

  Future<void> _print() async {
    final rows = _visible;
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final doc = pw.Document();
    final meta = <String>[
      'Type: ${_typeLabel()}',
      if (_mainSel.isNotEmpty) 'Main group: ${_selLabel(_mainSel)}',
      if (_groupSel.isNotEmpty) 'Group: ${_selLabel(_groupSel)}',
      if (_subSel.isNotEmpty) 'Sub group: ${_selLabel(_subSel)}',
      '${rows.length} item(s)',
      DateFormat('d MMM y').format(DateTime.now()),
    ].join('     |     ');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => [
        if (org.isNotEmpty)
          pw.Text(org, style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
        pw.Text('Goods without BOM',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 2),
        pw.Text(meta, style: pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: const ['#', 'Product', 'SKU', 'Main Group', 'Group / Sub', 'In Stock'],
          data: [
            for (var i = 0; i < rows.length; i++)
              [
                '${i + 1}', rows[i].name, rows[i].sku, rows[i].mainGroup,
                _subPath(rows[i]), _qty.format(rows[i].stock),
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
            child: Text('Goods without BOM',
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
            'Products with no active Product Assembly (BOM). Use the Type filter to view Finished Goods, Raw Materials, or all goods, and narrow by Main group, Group and Sub group (each takes multiple values). Until an assembly is set up these items can\'t be produced or planned, and their stock can only come from manual adjustments.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),

        // Filters
        Row(children: [
          Expanded(
            child: Wrap(spacing: 12, runSpacing: 8, children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  value: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Type', isDense: true, border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'finished', child: Text('Finished Goods')),
                    DropdownMenuItem(value: 'raw', child: Text('Raw Materials')),
                    DropdownMenuItem(value: 'all', child: Text('All Goods')),
                  ],
                  onChanged: (v) => setState(() {
                    _type = v ?? 'finished';
                    _pruneSelections();
                  }),
                ),
              ),
              _MultiSelectField(
                label: 'Main group',
                width: 240,
                options: _mainGroupOptions,
                selected: _mainSel,
                onChanged: (s) => setState(() {
                  _mainSel
                    ..clear()
                    ..addAll(s);
                  _pruneSelections();
                }),
              ),
              _MultiSelectField(
                label: 'Group',
                width: 240,
                options: _groupOptions,
                selected: _groupSel,
                onChanged: (s) => setState(() {
                  _groupSel
                    ..clear()
                    ..addAll(s);
                  _pruneSelections();
                }),
              ),
              _MultiSelectField(
                label: 'Sub group',
                width: 240,
                options: _subGroupOptions,
                selected: _subSel,
                onChanged: (s) => setState(() {
                  _subSel
                    ..clear()
                    ..addAll(s);
                }),
              ),
              SizedBox(
                width: 280,
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
            ]),
          ),
          const SizedBox(width: 8),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 20), tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 12),

        if (!_loading && _error == null)
          Wrap(spacing: 18, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _kv('Missing BOM', '${rows.length}'),
            _kv('Of which hold stock', '$withStock'),
            if (_mainSel.isNotEmpty || _groupSel.isNotEmpty || _subSel.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() {
                  _mainSel.clear();
                  _groupSel.clear();
                  _subSel.clear();
                }),
                icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                label: const Text('Clear filters'),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
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
                            child: Text('Nothing here — every item in this selection has an active BOM.',
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
        Expanded(flex: 3, child: Text('Group', style: s)),
        Expanded(flex: 2, child: Text('In Stock', style: s, textAlign: TextAlign.right)),
      ]),
    );
  }

  Widget _row(int n, _Row r) {
    final sub = _subPath(r);
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
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.mainGroup,
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            if (sub.isNotEmpty)
              Text(sub,
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
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

/// A dropdown-styled field that lets the user pick multiple values. Shows "All"
/// when nothing is picked, the single value when one is picked, or "N selected"
/// otherwise; tapping opens a checklist with Select all / Clear.
class _MultiSelectField extends StatelessWidget {
  final String label;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final double width;
  const _MultiSelectField({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.width = 240,
  });

  @override
  Widget build(BuildContext context) {
    final count = selected.length;
    final summary = count == 0
        ? 'All'
        : (count == 1 ? selected.first : '$count selected');
    final enabled = options.isNotEmpty;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: enabled ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          isEmpty: false,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
            enabled: enabled,
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          child: Text(
            summary,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: count == 0 ? AppTheme.textSecondary : Colors.black87),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final temp = {...selected}..retainWhere(options.contains);
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(label),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                TextButton(
                    onPressed: () => setLocal(() => temp
                      ..clear()
                      ..addAll(options)),
                    child: const Text('Select all')),
                TextButton(
                    onPressed: () => setLocal(() => temp.clear()),
                    child: const Text('Clear')),
              ]),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in options)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: temp.contains(o),
                        title: Text(o),
                        onChanged: (v) => setLocal(() {
                          if (v == true) {
                            temp.add(o);
                          } else {
                            temp.remove(o);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, temp),
                child: const Text('Apply')),
          ],
        );
      }),
    );
    if (result != null) onChanged(result);
  }
}
