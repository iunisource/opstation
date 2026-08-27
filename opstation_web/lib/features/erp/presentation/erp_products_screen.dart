// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'package:barcode/barcode.dart' as bc;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart' as xls;
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/storage/catalog_image_uploader.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/utils/friendly_error.dart';

class ErpProductsScreen extends ConsumerStatefulWidget {
  const ErpProductsScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpProductsScreen> createState() => _ErpProductsScreenState();
}

class _ErpProductsScreenState extends ConsumerState<ErpProductsScreen> {
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _filtered = [];
  Map<String, List<Map<String, dynamic>>> _taxonomies = {};
  List<Map<String, dynamic>> _uoms = [];
  bool _loading = true;
  bool _consignmentEnabled = false;   // org.consignment_enabled — gates the is_consignment checkbox
  List<Map<String, dynamic>> _branches = [];
  final _searchCtrl = TextEditingController();
  final Set<String> _selected = {};
  Set<String> _posProductIds = {};   // product_ids in ANY branch's pos_catalog (drives the POS icon + filter)
  Map<String, Set<String>> _posByBranch = {};   // branch_id -> product_ids in that branch (drives the duplicate check)
  String _posFilter = 'all';         // all | in | out
  String? _fMain;                    // product_main_group filter (null = all)
  String? _fGroup;                   // product_group filter (null = all)
  String? _fSub;                     // product_sub_group filter (null = all)
  // Cascading is learned from the products themselves — the group hierarchy is
  // not stored as parent→child, so we use which (main, group, sub) values
  // actually co-occur to narrow the child dropdowns.
  final Map<String, Set<String>> _mainToGroups = {};
  final Map<String, Set<String>> _mainToSubs = {};
  final Map<String, Set<String>> _groupToSubs = {};
  bool _hideGroupsEnabled = false;                 // org.hide_main_groups_by_branch
  Map<String, Set<String>> _hiddenByBranch = {};   // branchId -> hidden main_groups
  bool _productSuperviseEnabled = false;           // org.product_supervise_flow
  bool _superviseFilter = false;                   // show only supervision-pending

  bool get _canDelete {
    final r = ref.read(currentUserProvider)?.role.name;
    return r == 'masterAdmin' || r == 'admin';
  }

  @override
  void initState() {
    super.initState();
    _load().then((_) => _maybeFocus());
    _searchCtrl.addListener(_runFilter);
  }

  /// If opened from global search with ?focus=<id>, open that product's
  /// edit dialog once the list has loaded.
  void _maybeFocus() {
    final id = widget.focusId;
    if (id == null || !mounted) return;
    Map<String, dynamic>? row;
    for (final p in _products) {
      if (p['id']?.toString() == id) { row = p; break; }
    }
    if (row != null) _showDialog(context, row);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      // Which products already sit in each branch's POS catalog. Paginated past
      // the 5000 max-rows cap. posIds = any-branch (drives icon/filter);
      // posByBranch = per-branch (drives the duplicate check on push).
      Future<Map<String, dynamic>> posFut() async {
        final posIds = <String>{};
        final posByBranch = <String, Set<String>>{};
        for (var from = 0; ; from += 1000) {
          final rows = await client.from('pos_catalog').select('product_id, branch_id')
              .eq('org_id', orgId).order('id').range(from, from + 999);
          final batch = List<Map<String, dynamic>>.from(rows as List);
          for (final r in batch) {
            final pid = r['product_id'] as String?;
            final bid = r['branch_id'] as String?;
            if (pid == null) continue;
            posIds.add(pid);
            if (bid != null) (posByBranch[bid] ??= <String>{}).add(pid);
          }
          if (batch.length < 1000) break;
        }
        return {'ids': posIds, 'byBranch': posByBranch};
      }

      // Fire every independent query at once instead of one-after-another —
      // this is the load-time win. The three config flags are collapsed into a
      // single app_config read.
      final res = await Future.wait<dynamic>([
        client.from('products').select('*, uoms(name, abbreviation)').eq('org_id', orgId).order('name'),
        client.from('product_taxonomies').select().eq('org_id', orgId).order('name'),
        client.from('uoms').select().eq('org_id', orgId).order('name'),
        client.from('branches').select('id, name').eq('org_id', orgId!).eq('is_active', true).order('name'),
        client.from('app_config').select('key, value').eq('org_id', orgId)
            .inFilter('key', ['org.consignment_enabled', 'org.product_supervise_flow', 'org.hide_main_groups_by_branch']),
        client.from('branch_hidden_main_groups').select('branch_id, main_group').eq('org_id', orgId),
        posFut(),
      ]);
      final products = res[0] as List;
      final taxonomies = res[1] as List;
      final uoms = res[2] as List;
      final branches = res[3] as List;
      final cfgRows = res[4] as List;
      final hiddenRows = res[5] as List;
      final pos = res[6] as Map;
      final posIds = pos['ids'] as Set<String>;
      final posByBranch = pos['byBranch'] as Map<String, Set<String>>;

      final cfg = <String, String>{
        for (final r in cfgRows) (r['key'] as String): ((r['value'] as String?) ?? '')
      };
      final consignmentOn = cfg['org.consignment_enabled'] == 'true';
      final superviseOn = cfg['org.product_supervise_flow'] == 'true';
      final hideGroupsOn = cfg['org.hide_main_groups_by_branch'] == 'true';
      final Map<String, Set<String>> hiddenByBranch = {};
      if (hideGroupsOn) {
        for (final r in hiddenRows) {
          (hiddenByBranch[r['branch_id'] as String] ??= <String>{})
              .add(r['main_group'] as String);
        }
      }
      final Map<String, List<Map<String, dynamic>>> grouped = {};
      for (final t in taxonomies as List) {
        final type = t['taxonomy_type'] as String;
        grouped.putIfAbsent(type, () => []).add(Map<String, dynamic>.from(t));
      }
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
        _posProductIds = posIds;
        _posByBranch = posByBranch;
        _products = List<Map<String, dynamic>>.from(products);
        _buildCascadeMaps();
        _hideGroupsEnabled = hideGroupsOn;
        _hiddenByBranch = hiddenByBranch;
        _filtered = _filterList(List<Map<String, dynamic>>.from(products),
            _searchCtrl.text.toLowerCase(), _posFilter, posIds);
        _taxonomies = grouped;
        _uoms = List<Map<String, dynamic>>.from(uoms);
        _consignmentEnabled = consignmentOn;
        _productSuperviseEnabled = superviseOn;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _filterList(
      List<Map<String, dynamic>> src, String q, String posFilter, Set<String> posIds) {
    return src.where((p) {
      if (_hideGroupsEnabled) {
        final bid = ref.read(selectedBranchProvider)?['id'] as String?;
        if (bid != null &&
            (_hiddenByBranch[bid]?.contains(p['product_main_group']) ?? false)) {
          return false;
        }
      }
      if (posFilter == 'in' && !posIds.contains(p['id'])) return false;
      if (posFilter == 'out' && posIds.contains(p['id'])) return false;
      if (_superviseFilter && p['supervised_at'] != null) return false;
      if (_fMain != null && p['product_main_group'] != _fMain) return false;
      if (_fGroup != null && p['product_group'] != _fGroup) return false;
      if (_fSub != null && p['product_sub_group'] != _fSub) return false;
      return matchesQuery('${p['name'] ?? ''} ${p['sku'] ?? ''} ${p['barcode'] ?? ''}', q);
    }).toList();
  }

  // Learn the group hierarchy from co-occurring (main, group, sub) values on
  // products, so the child dropdowns can cascade.
  void _buildCascadeMaps() {
    _mainToGroups.clear();
    _mainToSubs.clear();
    _groupToSubs.clear();
    for (final p in _products) {
      final mg = (p['product_main_group'] as String?)?.trim() ?? '';
      final pg = (p['product_group'] as String?)?.trim() ?? '';
      final sg = (p['product_sub_group'] as String?)?.trim() ?? '';
      if (mg.isNotEmpty && pg.isNotEmpty) (_mainToGroups[mg] ??= {}).add(pg);
      if (mg.isNotEmpty && sg.isNotEmpty) (_mainToSubs[mg] ??= {}).add(sg);
      if (pg.isNotEmpty && sg.isNotEmpty) (_groupToSubs[pg] ??= {}).add(sg);
    }
  }

  // The taxonomy option names, optionally narrowed by a chosen parent. `main`
  // narrows the group list; `main`+`group` narrow the sub-group list.
  List<String> _groupChoices({String? main, String? group}) {
    final all = (_taxonomies['group'] ?? []).map((t) => t['name'] as String).toList();
    if (main == null) return all;
    final allowed = _mainToGroups[main] ?? const <String>{};
    return all.where(allowed.contains).toList();
  }

  List<String> _subChoices({String? main, String? group}) {
    final all = (_taxonomies['sub_group'] ?? []).map((t) => t['name'] as String).toList();
    Set<String>? allowed;
    if (main != null) allowed = {...(_mainToSubs[main] ?? const {})};
    if (group != null) {
      final byGroup = {...(_groupToSubs[group] ?? const {})};
      allowed = allowed == null ? byGroup : allowed.intersection(byGroup);
    }
    if (allowed == null) return all;
    return all.where(allowed.contains).toList();
  }

  // Export to Excel. Exports the checkbox-selected products if any are ticked;
  // otherwise exports exactly what the current filters/search show.
  Future<void> _exportExcel() async {
    final source = _selected.isNotEmpty
        ? _products.where((p) => _selected.contains('${p['id']}')).toList()
        : _filtered;
    if (source.isEmpty) { _showSnack('Nothing to export'); return; }
    try {
      double numOf(dynamic v) => (v as num?)?.toDouble() ?? 0;
      final excel = xls.Excel.createExcel();
      const sheetName = 'Products';
      final sheet = excel[sheetName];
      final def = excel.getDefaultSheet();
      if (def != null && def != sheetName) excel.delete(def);
      // MASTER import format — same columns/order as the import template and
      // the full-catalog export, so a selection export round-trips: export ->
      // edit prices -> save as CSV -> re-import in "Update existing" mode.
      // opening_qty is left blank so a re-import can never post opening stock.
      sheet.appendRow([
        xls.TextCellValue('name'), xls.TextCellValue('sku'), xls.TextCellValue('barcode'),
        xls.TextCellValue('uom'), xls.TextCellValue('product_type'),
        xls.TextCellValue('main_group'), xls.TextCellValue('group'), xls.TextCellValue('sub_group'),
        xls.TextCellValue('class'), xls.TextCellValue('movement_category'),
        xls.TextCellValue('selling_price'), xls.TextCellValue('cost_price'),
        xls.TextCellValue('low_stock_limit'), xls.TextCellValue('opening_qty'),
      ]);
      for (final p in source) {
        sheet.appendRow([
          xls.TextCellValue('${p['name'] ?? ''}'),
          xls.TextCellValue('${p['sku'] ?? ''}'),
          xls.TextCellValue('${p['barcode'] ?? ''}'),
          xls.TextCellValue('${p['uoms']?['abbreviation'] ?? p['uoms']?['name'] ?? ''}'),
          xls.TextCellValue('${p['product_type'] ?? ''}'),
          xls.TextCellValue('${p['product_main_group'] ?? ''}'),
          xls.TextCellValue('${p['product_group'] ?? ''}'),
          xls.TextCellValue('${p['product_sub_group'] ?? ''}'),
          xls.TextCellValue('${p['product_class'] ?? ''}'),
          xls.TextCellValue('${p['product_movement_category'] ?? ''}'),
          xls.DoubleCellValue(numOf(p['selling_price'])),
          xls.DoubleCellValue(numOf(p['cost_price'])),
          xls.DoubleCellValue(numOf(p['low_stock_limit'])),
          xls.TextCellValue(''), // opening_qty intentionally blank
        ]);
      }
      excel.save(fileName:
          'products-${DateTime.now().toIso8601String().split('T').first}.xlsx');
      _showSnack('Exported ${source.length} product${source.length == 1 ? '' : 's'} (Excel)');
    } catch (e) {
      _showSnack('Export failed: $e');
    }
  }

  // Same scope/columns as the filtered Excel export, but as CSV. (Distinct from
  // the full-catalog import-template _exportCsv used by the top-right button.)
  void _exportFilteredCsv() {
    final source = _selected.isNotEmpty
        ? _products.where((p) => _selected.contains('${p['id']}')).toList()
        : _filtered;
    if (source.isEmpty) { _showSnack('Nothing to export'); return; }
    String esc(Object? v) {
      final s = (v ?? '').toString();
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"' + s.replaceAll('"', '""') + '"';
      }
      return s;
    }
    double numOf(dynamic v) => (v as num?)?.toDouble() ?? 0;
    // MASTER import format — identical header/order to the import template and
    // the full-catalog export, so this file round-trips straight back through
    // "Import CSV -> Update existing". opening_qty left blank on purpose.
    final sb = StringBuffer();
    sb.writeln('name,sku,barcode,uom,product_type,main_group,group,sub_group,class,movement_category,selling_price,cost_price,low_stock_limit,opening_qty');
    for (final p in source) {
      sb.writeln([
        p['name'] ?? '', p['sku'] ?? '', p['barcode'] ?? '',
        p['uoms']?['abbreviation'] ?? p['uoms']?['name'] ?? '',
        p['product_type'] ?? '',
        p['product_main_group'] ?? '', p['product_group'] ?? '', p['product_sub_group'] ?? '',
        p['product_class'] ?? '', p['product_movement_category'] ?? '',
        numOf(p['selling_price']), numOf(p['cost_price']), numOf(p['low_stock_limit']),
        '', // opening_qty intentionally blank
      ].map(esc).join(','));
    }
    final content = '\u{FEFF}' + sb.toString(); // BOM so Excel reads UTF-8
    final blob = html.Blob([content], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)
      ..download = 'products-${DateTime.now().toIso8601String().split('T').first}.csv';
    html.document.body!.append(a);
    a.click();
    a.remove();
    html.Url.revokeObjectUrl(url);
    _showSnack('Exported ${source.length} product${source.length == 1 ? '' : 's'} (CSV)');
  }

  // A compact searchable filter for the group hierarchy. Reuses _SearchSelect
  // (type-to-filter). `value` shows as All if it isn't in the current cascaded
  // [options]. The key includes the option count so it rebuilds on cascade.
  Widget _grpFilter(String label, String? value, List<String> options,
      void Function(String?) onChanged) {
    final val = (value != null && options.contains(value)) ? value : null;
    return SizedBox(
      width: 190,
      child: _SearchSelect(
        key: ValueKey('filt_${label}_${options.length}'),
        label: label,
        hint: 'All',
        value: val,
        items: [for (final n in options) <String, String>{'value': n, 'label': n}],
        onChanged: onChanged,
      ),
    );
  }

  void _runFilter() {
    setState(() {
      _filtered = _filterList(
          _products, _searchCtrl.text.toLowerCase(), _posFilter, _posProductIds);
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _toggleActive(Map<String, dynamic> p) async {
    final newVal = !(p['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('products')
          .update({'is_active': newVal, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', p['id']);
      _showSnack(newVal ? 'Product activated' : 'Product deactivated');
      _load();
    } catch (e) {
      _showSnack(friendlyError('That did not save', e));
    }
  }

  // Mark a newly-created product as supervised (admin / master admin only).
  // Clears it from the Inventory → Products pendency counter.
  Future<void> _superviseProduct(Map<String, dynamic> p) async {
    final user = ref.read(currentUserProvider);
    try {
      await Supabase.instance.client.from('products').update({
        'supervised_by': user?.id,
        'supervised_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', p['id']);
      ref.invalidate(productSupervisePendingProvider);
      _showSnack('Product supervised');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _superviseAllPending() async {
    final user = ref.read(currentUserProvider);
    final pending = _products.where((p) => p['supervised_at'] == null).toList();
    if (pending.isEmpty) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Supervise all pending?'),
      content: Text('Mark all ${pending.length} unsupervised product(s) as supervised?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supervise all')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('products').update({
        'supervised_by': user?.id,
        'supervised_at': DateTime.now().toUtc().toIso8601String(),
      }).filter('supervised_at', 'is', null).eq('org_id', user?.orgId ?? '');
      ref.invalidate(productSupervisePendingProvider);
      _showSnack('Supervised ${pending.length} product(s)');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _pushToPOS(BuildContext context, Map<String, dynamic> product) async {
    if (_branches.isEmpty) { _showSnack('No branches found'); return; }
    // Cost-price guard: a product with no cost basis must not enter POS, or its
    // sales would book zero/estimated COGS. Consignment items are exempt.
    final _isConsign = product['is_consignment'] == true;
    if (!_isConsign && ((product['cost_price'] as num?)?.toDouble() ?? 0) <= 0) {
      _showSnack('"${product['name']}" has no cost price — set a cost price before adding to POS');
      return;
    }
    final picked = await showDialog<Map<String, dynamic>?>(context: context, builder: (_) => _BranchPickerDialog(branches: _branches, productName: product['name'] as String? ?? '-'));
    if (picked == null) return;
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    final branchId = picked['id'] as String;
    final productId = product['id'] as String;
    // Duplicate guard: the pos_catalog is per-branch, so block only if it's
    // already in the branch that was picked (still allows adding to others).
    if ((_posByBranch[branchId] ?? const <String>{}).contains(productId)) {
      _showSnack('"${product['name']}" is already in ${picked['name']}\'s POS catalog');
      return;
    }
    try {
      final catalogId = 'posc_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('pos_catalog').upsert({
        'id': catalogId,
        'org_id': orgId,
        'branch_id': picked['id'],
        'product_id': product['id'],
        'name': product['name'],
        'sku': product['sku'],
        'price': (product['selling_price'] as num?)?.toDouble() ?? 0,
        'uom_id': product['base_uom_id'],
        'is_active': true,
      }, onConflict: 'org_id,branch_id,product_id');
      if (mounted) setState(() {
        _posProductIds.add(productId);
        (_posByBranch[branchId] ??= <String>{}).add(productId);
        _filtered = _filterList(
            _products, _searchCtrl.text.toLowerCase(), _posFilter, _posProductIds);
      });
      _showSnack('"${product['name']}" pushed to POS catalog for ${picked['name']}');
    } catch (e) { _showSnack(friendlyError('That did not save', e)); }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Product'),
        content: const Text('Delete this product? If it has stock or transaction history this will be blocked.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('products').delete().eq('id', id);
      _showSnack('Product deleted');
      _load();
    } catch (_) {
      _showSnack('Could not delete: this product has linked records (stock or transactions).');
    }
  }

  /// Bulk-delete selected products, per-id so one blocked by linked records
  /// (FK / stock / transactions) does not stop the rest. Reports the outcome.
  Future<void> _bulkDelete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Products'),
        content: Text('Delete ${ids.length} selected product(s)? Products with stock or transaction history will be skipped.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: Text('Delete ${ids.length}'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    int ok = 0, blocked = 0;
    for (final id in ids) {
      try {
        await Supabase.instance.client.from('products').delete().eq('id', id);
        ok++;
      } catch (_) { blocked++; }
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    _showSnack(blocked == 0
        ? '$ok product(s) deleted'
        : '$ok deleted · $blocked skipped (have stock or transactions)');
    _load();
  }

  // ── Barcode labels ───────────────────────────────────────────────────────
  /// Print barcode labels for one or many products. Asks copies-per-product,
  /// then opens a print page: a grid of self-contained labels (name, SKU,
  /// EAN-13 barcode — Code-128 for legacy non-EAN values from imports).
  Future<void> _printBarcodeLabels(List<Map<String, dynamic>> prods) async {
    final withCode = prods
        .where((p) => ('${p['barcode'] ?? ''}').trim().isNotEmpty)
        .toList();
    if (withCode.isEmpty) {
      _showSnack('No barcodes yet — save the product once (barcodes are auto-generated).');
      return;
    }
    final copiesCtrl = TextEditingController(text: '1');
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Print barcode labels · ${withCode.length} product${withCode.length == 1 ? '' : 's'}'),
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Copies per product:'),
          const SizedBox(width: 12),
          SizedBox(
            width: 70,
            child: TextField(
              controller: copiesCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Print')),
        ],
      ),
    );
    if (go != true) return;
    final copies = (int.tryParse(copiesCtrl.text.trim()) ?? 1).clamp(1, 500);
    if (withCode.length < prods.length) {
      _showSnack('${prods.length - withCode.length} product(s) skipped — no barcode yet.');
    }

    String esc(Object? v) => '$v'
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final labels = StringBuffer();
    for (final p in withCode) {
      final code = '${p['barcode']}'.trim();
      String svg;
      try {
        // Our generated codes are EAN-13; legacy imported values fall back to
        // Code-128, which encodes any ASCII.
        final isEan13 = code.length == 13 && RegExp(r'^\d{13}$').hasMatch(code);
        final symbology = isEan13 ? bc.Barcode.ean13() : bc.Barcode.code128();
        svg = symbology.toSvg(code, width: 200, height: 58, fontHeight: 14);
      } catch (_) {
        continue; // unencodable value — skip this label
      }
      final one = '<div class="label">'
          '<div class="name">${esc(p['name'] ?? '')}</div>'
          '<div class="sku">${esc(p['sku'] ?? '')}</div>'
          '<div class="bars">$svg</div>'
          '</div>';
      for (var i = 0; i < copies; i++) {
        labels.write(one);
      }
    }

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Barcode Labels</title>'
        '<style>@page{margin:0}'
        '*{box-sizing:border-box}'
        'body{font-family:Arial,sans-serif;margin:0;padding:8mm}'
        '.no-print{margin-bottom:10px}.no-print button{padding:6px 14px;font-size:13px;cursor:pointer}'
        '@media print{.no-print{display:none}}'
        '.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:4mm}'
        '.label{border:1px dashed #bbb;border-radius:4px;padding:6px 8px;text-align:center;'
        'break-inside:avoid;page-break-inside:avoid}'
        '@media print{.label{border-color:transparent}}'
        '.name{font-size:11px;font-weight:700;line-height:1.2;overflow:hidden;'
        'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;min-height:26px}'
        '.sku{font-size:9.5px;color:#555;margin:1px 0 3px}'
        '.bars svg{width:100%;height:auto;max-height:70px}'
        '</style></head><body>'
        '<div class="no-print"><button onclick="window.print()">Print</button>'
        '<span style="font-size:12px;color:#666;margin-left:10px">'
        '${withCode.length} product(s) x $copies label(s). Dashed borders do not print.</span></div>'
        '<div class="grid">$labels</div>'
        '</body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
    Future.delayed(const Duration(seconds: 30), () { try { html.Url.revokeObjectUrl(url); } catch (_) {} });
  }

  Future<void> _bulkPushToPOS(BuildContext context) async {
    if (_branches.isEmpty) { _showSnack('No branches found'); return; }
    final picked = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (_) => _BranchPickerDialog(branches: _branches, productName: '${_selected.length} products'),
    );
    if (picked == null) return;
    final orgId = ref.read(currentUserProvider)?.orgId; if (orgId == null) return;
    final branchId = picked['id'] as String;
    final selected = _filtered.where((p) => _selected.contains(p['id'])).toList();
    final already = _posByBranch[branchId] ?? const <String>{};
    int success = 0; int failed = 0; int dup = 0; int noCost = 0;
    final pushedIds = <String>[];
    for (var i = 0; i < selected.length; i++) {
      final product = selected[i];
      final productId = product['id'] as String;
      // Skip anything already in this branch's catalog (duplicate guard).
      if (already.contains(productId) || pushedIds.contains(productId)) { dup++; continue; }
      // Cost-price guard: don't push costless products (except consignment).
      final isConsign = product['is_consignment'] == true;
      if (!isConsign && ((product['cost_price'] as num?)?.toDouble() ?? 0) <= 0) { noCost++; continue; }
      try {
        await Supabase.instance.client.from('pos_catalog').upsert({
          'id': 'posc_${DateTime.now().millisecondsSinceEpoch}_$i',
          'org_id': orgId,
          'branch_id': picked['id'],
          'product_id': product['id'],
          'name': product['name'],
          'sku': product['sku'],
          'price': (product['selling_price'] as num?)?.toDouble() ?? 0,
          'uom_id': product['base_uom_id'],
          'is_active': true,
        }, onConflict: 'org_id,branch_id,product_id');
        pushedIds.add(productId);
        success++;
      } catch (_) { failed++; }
    }
    if (mounted) setState(() {
      _selected.clear();
      _posProductIds.addAll(pushedIds);
      (_posByBranch[branchId] ??= <String>{}).addAll(pushedIds);
      _filtered = _filterList(
          _products, _searchCtrl.text.toLowerCase(), _posFilter, _posProductIds);
    });
    _showSnack('Pushed $success product${success == 1 ? "" : "s"} to ${picked['name']} POS'
        '${dup > 0 ? " — $dup already there" : ""}'
        '${noCost > 0 ? " — $noCost skipped (no cost price)" : ""}'
        '${failed > 0 ? " — $failed failed" : ""}');
  }

  // Export current products to CSV using the SAME columns as the import
  // template, so the file round-trips: export -> edit prices in Excel ->
  // re-import in "Update existing" mode. opening_qty is intentionally left
  // blank on export so a re-import can never post opening stock / GL.
  void _exportCsv() {
    String esc(Object? v) {
      final s = (v ?? '').toString();
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"' + s.replaceAll('"', '""') + '"';
      }
      return s;
    }
    final buf = StringBuffer();
    buf.writeln('name,sku,barcode,uom,product_type,main_group,group,sub_group,class,movement_category,selling_price,cost_price,low_stock_limit,opening_qty');
    for (final p in _products) {
      final uomAbbr = (p['uoms']?['abbreviation'] as String?) ?? (p['uoms']?['name'] as String?) ?? '';
      final cells = [
        p['name'], p['sku'], p['barcode'], uomAbbr, p['product_type'],
        p['product_main_group'], p['product_group'], p['product_sub_group'],
        p['product_class'], p['product_movement_category'],
        p['selling_price'], p['cost_price'], p['low_stock_limit'],
        '', // opening_qty intentionally blank
      ];
      buf.writeln(cells.map(esc).join(','));
    }
    final blob = html.Blob([buf.toString()], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final stamp = DateTime.now().toIso8601String().split('T').first;
    html.AnchorElement(href: url)..setAttribute('download', 'products_export_$stamp.csv')..click();
    Future.delayed(const Duration(seconds: 2), () => html.Url.revokeObjectUrl(url));
    _showSnack('Exported ${_products.length} products');
  }

  void _showCsvImport(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _CsvImportDialog(
        uoms: _uoms,
        branches: _branches,
        existingSkus: _products.map((p) => (p['sku'] as String?) ?? '').where((s) => s.isNotEmpty).toSet(),
        existingProducts: _products,
        onImport: _doCsvImport,
      ),
    );
  }

  Future<void> _doCsvImport(List<Map<String, dynamic>> rows, List<String> branchIds, String? openingBranchId, bool updateMode, DateTime openingDate, {void Function(int done, int total)? onProgress}) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final userId = ref.read(currentUserProvider)?.id ?? '';
    final client = Supabase.instance.client;
    int success = 0; int failed = 0; int allocFailed = 0;
    final totalRows = rows.length;
    onProgress?.call(0, totalRows);

    // Opening-stock lines collected across the batch, posted as ONE voucher.
    final openingLines = <Map<String, dynamic>>[];

    if (updateMode) {
      // ── UPDATE path ──────────────────────────────────────────────────────
      // Overwrite existing products' fields. Never creates products, never
      // touches stock or the GL. Batched: one upsert per chunk instead of one
      // update per row (1345 round-trips → a handful).
      // Per-row UPDATE with only the fields present in the CSV (Interpretation
      // B): null/blank cells are stripped so existing values are preserved.
      // upsert can't express "update only these columns" reliably across a
      // heterogeneous batch, so we update per row — but run them concurrently
      // in chunks so it stays fast (well under the old sequential cost).
      const chunk = 40; // concurrent updates per wave
      final tasks = <Map<String, dynamic>>[];
      for (final r in rows) {
        final matchId = r['_match_id'] as String?;
        if (matchId == null) { failed++; continue; }
        final data = Map<String, dynamic>.from(r)..remove('_opening_qty')..remove('_match_id');
        // Strip null fields → don't overwrite existing values with blanks.
        data.removeWhere((k, v) => v == null);
        data['updated_at'] = DateTime.now().toUtc().toIso8601String();
        tasks.add({'id': matchId, 'data': data});
      }
      var done = 0;
      for (var start = 0; start < tasks.length; start += chunk) {
        final end = (start + chunk < tasks.length) ? start + chunk : tasks.length;
        final wave = tasks.sublist(start, end);
        final results = await Future.wait(wave.map((t) async {
          try {
            // Match by primary key only. Adding .eq('org_id', orgId) here can
            // match ZERO rows for products whose stored org_id tag differs from
            // the session org (a known data quirk), which made the update
            // silently no-op — "success" with nothing changed. RLS still scopes
            // access; the id is unique and came from this org's product list.
            await client.from('products').update(t['data'] as Map<String, dynamic>)
                .eq('id', t['id'] as String);
            return true;
          } catch (_) { return false; }
        }));
        success += results.where((ok) => ok).length;
        failed += results.where((ok) => !ok).length;
        done = end;
        onProgress?.call(done, totalRows);
      }
    } else {
      // ── INSERT path ──────────────────────────────────────────────────────
      // Batch product inserts; collect stock rows and opening-stock lines, then
      // batch the stock inserts too.
      const chunk = 200;
      final productRows = <Map<String, dynamic>>[];
      final stockRows = <Map<String, dynamic>>[];
      for (var i = 0; i < rows.length; i++) {
        final productData = Map<String, dynamic>.from(rows[i])..remove('_opening_qty')..remove('_match_id');
        // Blank cells parsed as null → drop them so the column default applies
        // on insert (rather than forcing an explicit null into a NOT-NULL col).
        productData.removeWhere((k, v) => v == null);
        final id = 'prod_${DateTime.now().millisecondsSinceEpoch}_$i';
        final openQty = ((rows[i]['_opening_qty'] as num?) ?? 0).toDouble();
        final uomId = rows[i]['base_uom_id'] as String?;
        final unitCost = ((rows[i]['cost_price'] as num?) ?? 0).toDouble();
        productRows.add({
          ...productData,
          'id': id,
          'org_id': orgId,
          'is_active': true,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
        if (openQty > 0 && openingBranchId != null && uomId != null) {
          openingLines.add({'product_id': id, 'uom_id': uomId, 'quantity': openQty, 'unit_cost': unitCost});
        }
        for (var b = 0; b < branchIds.length; b++) {
          if (branchIds[b] == openingBranchId && openQty > 0) continue;
          stockRows.add({
            'id': 'invs_${DateTime.now().millisecondsSinceEpoch}_${i}_$b',
            'org_id': orgId, 'product_id': id, 'branch_id': branchIds[b], 'quantity': 0,
          });
        }
      }
      // Insert products in chunks (progress tracks this, the main cost).
      for (var start = 0; start < productRows.length; start += chunk) {
        final end = (start + chunk < productRows.length) ? start + chunk : productRows.length;
        final slice = productRows.sublist(start, end);
        try {
          await client.from('products').insert(slice);
          success += slice.length;
        } catch (_) {
          for (final p in slice) {
            try { await client.from('products').insert(p); success++; } catch (_) { failed++; }
          }
        }
        onProgress?.call(end, totalRows);
      }
      // Insert branch stock allocations in chunks (best-effort).
      for (var start = 0; start < stockRows.length; start += 500) {
        final end = (start + 500 < stockRows.length) ? start + 500 : stockRows.length;
        try { await client.from('inventory_stock').insert(stockRows.sublist(start, end)); }
        catch (_) { allocFailed += (end - start); }
      }
    }

    // Post ONE opening-stock voucher for the whole batch, reusing the exact
    // same flow as the manual Opening Stock screen: build voucher + lines, then
    // call the RPC that handles all GL (Dr Inventory / Cr Opening Balance Equity).
    String? openingMsg;
    if (openingLines.isNotEmpty && openingBranchId != null) {
      try {
        final now = DateTime.now();
        // voucher/GL date comes from the user-chosen opening date, NOT now().
        final dateStr = '${openingDate.year.toString().padLeft(4, '0')}-${openingDate.month.toString().padLeft(2, '0')}-${openingDate.day.toString().padLeft(2, '0')}';
        final total = openingLines.fold(0.0, (s, l) => s + (l['quantity'] as double) * (l['unit_cost'] as double));
        final cnt = await client.from('opening_stock_vouchers').select('id').eq('org_id', orgId);
        final vnum = 'OPEN-${openingDate.year}-' + ((cnt as List).length + 1).toString().padLeft(4, '0');
        final vId = 'osv_' + now.millisecondsSinceEpoch.toString();
        await client.from('opening_stock_vouchers').insert({
          'id': vId, 'org_id': orgId, 'branch_id': openingBranchId, 'voucher_number': vnum,
          'voucher_date': dateStr, 'status': 'draft', 'is_locked': false, 'is_voided': false,
          'notes': 'Imported with products bulk import',
          'total_value': total, 'created_by': userId,
          'created_at': now.toIso8601String(), 'updated_at': now.toIso8601String(),
        });
        for (var i = 0; i < openingLines.length; i++) {
          final l = openingLines[i];
          await client.from('opening_stock').insert({
            'id': 'os_${now.microsecondsSinceEpoch}_$i',
            'org_id': orgId, 'branch_id': openingBranchId, 'voucher_id': vId,
            'product_id': l['product_id'], 'uom_id': l['uom_id'],
            'quantity': l['quantity'], 'unit_cost': l['unit_cost'],
            'entry_date': dateStr, 'created_by': userId,
          });
        }
        // Post: this RPC books the GL exactly like the manual Opening Stock screen.
        await client.rpc('post_opening_stock_voucher', params: {'p_id': vId});
        openingMsg = ' — opening stock $vnum posted (${openingLines.length} item${openingLines.length == 1 ? "" : "s"}, value ${money(total)})';
      } catch (e) {
        openingMsg = ' — opening stock FAILED: ${e.toString().split("\n").first}';
      }
    }

    if (updateMode) {
      _showSnack('Updated $success product${success == 1 ? "" : "s"}'
          '${failed > 0 ? " — $failed failed" : ""}');
    } else {
      _showSnack('Imported $success product${success == 1 ? "" : "s"}'
          '${branchIds.isNotEmpty ? " into ${branchIds.length} branch${branchIds.length == 1 ? "" : "es"}" : ""}'
          '${failed > 0 ? " — $failed failed" : ""}'
          '${allocFailed > 0 ? " — $allocFailed stock rows failed" : ""}'
          '${openingMsg ?? ""}');
    }
    _load();
  }

  Future<void> _showDialog(BuildContext context, Map<String, dynamic>? product) async {
    final orgIdPre = ref.read(currentUserProvider)?.orgId;
    // Load existing branch allocation (inventory_stock) for this product (edit only).
    final Map<String, double> existingStock = {}; // branch_id -> qty
    if (product != null && orgIdPre != null) {
      try {
        final rows = await Supabase.instance.client.from('inventory_stock')
            .select('branch_id, quantity').eq('org_id', orgIdPre).eq('product_id', product['id'] as String);
        for (final r in rows as List) {
          existingStock[r['branch_id'] as String] = (r['quantity'] as num?)?.toDouble() ?? 0.0;
        }
      } catch (_) {}
    }
    final Set<String> selectedBranches = {...existingStock.keys};
    if (!context.mounted) return;
    final nameCtrl = TextEditingController(text: product?['name'] ?? '');
    final skuCtrl = TextEditingController(text: product?['sku'] ?? '');
    final barcodeCtrl = TextEditingController(text: product?['barcode'] ?? '');
    final sellPriceCtrl = TextEditingController(
        text: product?['selling_price']?.toString() ?? '0');
    final costPriceCtrl = TextEditingController(
        text: product?['cost_price']?.toString() ?? '0');
    final lowStockCtrl = TextEditingController(
        text: product?['low_stock_limit']?.toString() ?? '0');
    String? uomId = product?['base_uom_id'] as String?;
    String? productType = product?['product_type'] as String?;
    String? mainGroup = product?['product_main_group'] as String?;
    String? group = product?['product_group'] as String?;
    String? subGroup = product?['product_sub_group'] as String?;
    String? productClass = product?['product_class'] as String?;
    String? movementCategory = product?['product_movement_category'] as String?;
    bool isConsignment = product?['is_consignment'] == true;
    bool isService = product?['is_service'] == true;
    bool freeText = product?['is_free_text'] == true;
    // Optional. Nullable by design — thousands of products exist with no image,
    // and every surface must render cleanly without one.
    String? imageUrl = product?['image_url'] as String?;

    Widget _taxonomyDropdown(String type, String label, String? value, void Function(String?) onChanged) {
      final items = _taxonomies[type] ?? [];
      final names = items.map((t) => t['name'] as String).toList();
      final cur = (value != null && value.isNotEmpty) ? value : null;
      if (cur != null && !names.contains(cur)) names.insert(0, cur);
      return _SearchSelect(
        key: ValueKey('sel_$label'),
        label: label,
        value: cur,
        items: [for (final n in names) <String, String>{'value': n, 'label': n}],
        onChanged: onChanged,
      );
    }

    // Visual-only helper: wraps a group of fields in a titled card with an
    // icon, so the long form reads as clear, scannable sections.
    Widget sectionCard(IconData icon, String title, List<Widget> children,
        {String? subtitle}) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              height: 30,
              width: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: AppTheme.primary),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppTheme.textPrimary)),
            ),
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(subtitle,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 12),
          ...children,
        ]),
      );
    }

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: AppTheme.background,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          title: Row(children: [
            Container(
              height: 40,
              width: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                  product == null
                      ? Icons.add_box_outlined
                      : Icons.edit_outlined,
                  color: AppTheme.primary,
                  size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(product == null ? 'Add Product' : 'Edit Product',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                        product == null
                            ? 'Create a new catalog item'
                            : 'Update catalog details',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ]),
            ),
          ]),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                sectionCard(Icons.inventory_2_outlined, 'Basic Info', [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Optional product photo. Shown to retailers only when the
                  // "Show product images" admin toggle is ON.
                  Column(children: [
                    Container(
                      height: 68,
                      width: 68,
                      decoration: BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: imageUrl == null
                          ? const Icon(Icons.inventory_2_outlined,
                              size: 24, color: AppTheme.textSecondary)
                          : Image.network(imageUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.broken_image_outlined,
                                  size: 20,
                                  color: AppTheme.textSecondary)),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 26,
                      child: TextButton(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6)),
                        onPressed: () async {
                          final orgId = ref.read(currentUserProvider)?.orgId;
                          if (orgId == null) return;
                          try {
                            final url = await CatalogImageUploader.pickAndUpload(
                              orgId: orgId,
                              folder: 'products',
                              keyHint: product?['id'] as String? ??
                                  DateTime.now().millisecondsSinceEpoch.toString(),
                            );
                            if (url != null) setS(() => imageUrl = url);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Upload failed: $e')));
                            }
                          }
                        },
                        child: Text(imageUrl == null ? 'Add photo' : 'Change',
                            style: const TextStyle(fontSize: 11)),
                      ),
                    ),
                    if (imageUrl != null)
                      SizedBox(
                        height: 22,
                        child: TextButton(
                          style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 6),
                              foregroundColor: AppTheme.textSecondary),
                          onPressed: () => setS(() => imageUrl = null),
                          child: const Text('Remove',
                              style: TextStyle(fontSize: 10)),
                        ),
                      ),
                  ]),
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                        controller: nameCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Product Name *')),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: skuCtrl,
                          decoration: const InputDecoration(labelText: 'SKU'))),
                  const SizedBox(width: 12),
                  Expanded(
                      // Barcodes are system-generated (EAN-13) and immutable —
                      // enforced by a DB trigger; this field is display-only.
                      child: TextField(
                          controller: barcodeCtrl,
                          enabled: false,
                          decoration: InputDecoration(
                              labelText: 'Barcode',
                              hintText: 'Auto-generated on save',
                              suffixIcon: Icon(Icons.lock_outline,
                                  size: 15,
                                  color: AppTheme.textSecondary.withOpacity(0.6))))),
                ]),
                const SizedBox(height: 12),
                _SearchSelect(
                  key: const ValueKey('sel_uom'),
                  label: 'Base UOM *',
                  hint: 'Select UOM',
                  value: uomId,
                  items: [for (final u in _uoms) <String, String>{'value': u['id'] as String, 'label': '${u['name']} (${u['abbreviation']})'}],
                  onChanged: (v) => setS(() => uomId = v),
                ),
                ]),
                sectionCard(Icons.category_outlined, 'Classification', [
                Row(children: [
                  Expanded(child: _taxonomyDropdown('product_type', 'Product Type', productType, (v) => setS(() => productType = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('main_group', 'Main Group', mainGroup, (v) => setS(() => mainGroup = v))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _taxonomyDropdown('group', 'Group', group, (v) => setS(() => group = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('sub_group', 'Sub Group', subGroup, (v) => setS(() => subGroup = v))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _taxonomyDropdown('class', 'Class', productClass, (v) => setS(() => productClass = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _taxonomyDropdown('movement_category', 'Movement Category', movementCategory, (v) => setS(() => movementCategory = v))),
                ]),
                ], subtitle: 'Optional — used for grouping and reports.'),
                sectionCard(Icons.payments_outlined, 'Pricing', [
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: sellPriceCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Selling Price *'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                          controller: costPriceCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Cost Price *'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: lowStockCtrl, decoration: const InputDecoration(labelText: 'Low Stock Limit', helperText: 'Flag in Low Stock Report when on-hand is at or below this'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
                  const SizedBox(width: 12),
                  const Expanded(child: SizedBox()),
                ]),
                ]),
                sectionCard(Icons.tune, 'Item Type', [
                if (_consignmentEnabled) ...[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: isConsignment,
                    onChanged: (v) => setS(() => isConsignment = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: const Text('Client-owned (consignment) item', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Tracked in stock by quantity only, at zero book value. Purchases post to Consignment Clearing (not inventory) and add no cost to production. Recover from the client via a manual journal voucher.',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: isService,
                  onChanged: (v) => setS(() {
                    isService = v ?? false;
                    if (isService) isConsignment = false; // mutually exclusive
                  }),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: const Text('Non-inventory (service / labour) item', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: const Text('Not tracked in stock at all — no on-hand quantity, no cost layers, and never shown in the Inventory Integrity check. Its Cost Price is absorbed as a per-unit charge when used in a BOM (e.g. making / labour charges). Use for services and labour lines so they stop generating negative stock.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: freeText,
                  onChanged: (v) => setS(() => freeText = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: const Text('Free-text item (custom description on PO)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: const Text('When added to a Purchase Order, a free-text description field unlocks so the buyer can type exactly what is being ordered. Use for miscellaneous, one-off, or service purchases.',
                      style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ),
                ]),
                sectionCard(Icons.store_mall_directory_outlined, 'Branch Allocation', [
                if (_branches.isEmpty)
                  const Align(alignment: Alignment.centerLeft, child: Text('No branches found.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                else
                  Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 4, children: _branches.map((b) {
                    final bid = b['id'] as String;
                    final allocated = existingStock.containsKey(bid);
                    final qty = existingStock[bid] ?? 0.0;
                    final locked = allocated && qty > 0; // protect real stock from being un-allocated
                    final checked = selectedBranches.contains(bid);
                    return FilterChip(
                      label: Text('${b['name'] ?? '-'}' + (allocated ? '  •  ${qty.toStringAsFixed(0)}' : '')),
                      selected: checked,
                      onSelected: locked ? null : (v) => setS(() { if (v) selectedBranches.add(bid); else selectedBranches.remove(bid); }),
                    );
                  }).toList())),
                ], subtitle: 'Tick the branches this product is stocked in. Newly ticked branches start at zero stock; existing stock is never changed here. Branches that already hold stock are locked.'),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Product name is required')));
                  return;
                }
                if (uomId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Base UOM is required')));
                  return;
                }
                // Cost price is required (except consignment items, which are
                // not owned so 0 cost is valid). Prevents costless products from
                // being sold and booking zero/estimated COGS.
                final _costVal = double.tryParse(costPriceCtrl.text.trim()) ?? 0;
                if (!isConsignment && !isService && _costVal <= 0) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Cost price is required (must be greater than 0)')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final data = {
                  'org_id': orgId,
                  'name': nameCtrl.text.trim(),
                  'sku': skuCtrl.text.trim().isEmpty ? null : skuCtrl.text.trim(),
                  'barcode': barcodeCtrl.text.trim().isEmpty ? null : barcodeCtrl.text.trim(),
                  'base_uom_id': uomId,
                  'product_type': productType,
                  'product_main_group': mainGroup,
                  'product_group': group,
                  'product_sub_group': subGroup,
                  'product_class': productClass,
                  'product_movement_category': movementCategory,
                  'selling_price': double.tryParse(sellPriceCtrl.text.trim()) ?? 0,
                  'cost_price': isConsignment ? 0 : (double.tryParse(costPriceCtrl.text.trim()) ?? 0),
                  'low_stock_limit': double.tryParse(lowStockCtrl.text.trim()) ?? 0,
                  'is_consignment': isConsignment,
                  'is_service': isService,
                  'is_free_text': freeText,
                  'image_url': imageUrl,
                  'updated_at': DateTime.now().toUtc().toIso8601String(),
                };
                try {
                  String pid;
                  if (product == null) {
                    pid = 'prod_${DateTime.now().millisecondsSinceEpoch}';
                    await Supabase.instance.client
                        .from('products')
                        .insert({...data, 'id': pid});
                  } else {
                    pid = product['id'] as String;
                    await Supabase.instance.client
                        .from('products')
                        .update(data)
                        .eq('id', pid);
                  }
                  // Reconcile branch allocation (inventory_stock). Add zero-stock rows for
                  // newly ticked branches; remove rows only where stock is zero. Never touch
                  // a branch's existing quantity.
                  try {
                    int allocCounter = 0;
                    for (final bid in selectedBranches) {
                      if (existingStock.containsKey(bid)) continue;
                      await Supabase.instance.client.from('inventory_stock').insert({
                        'id': 'invs_${DateTime.now().millisecondsSinceEpoch}_${allocCounter++}',
                        'org_id': orgId, 'product_id': pid, 'branch_id': bid, 'quantity': 0,
                      });
                    }
                    for (final bid in existingStock.keys) {
                      if (!selectedBranches.contains(bid) && (existingStock[bid] ?? 0) == 0) {
                        await Supabase.instance.client.from('inventory_stock')
                            .delete().eq('org_id', orgId ?? '').eq('product_id', pid).eq('branch_id', bid);
                      }
                    }
                  } catch (e) {
                    _showSnack('Product saved, but branch allocation failed: $e');
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(product == null ? 'Product added' : 'Product updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text(friendlyError('That did not save', e))));
                  }
                }
              },
              child: Text(product == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) {
      if (mounted) _runFilter();
    });
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Products',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _exportCsv,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Export CSV'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _showCsvImport(context),
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Import CSV'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () => _showDialog(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Product'),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Text('${_filtered.length} products',
                style: const TextStyle(color: AppTheme.textSecondary)),
            if (_productSuperviseEnabled && _canDelete) ...[
              () {
                final pending = _products.where((p) => p['supervised_at'] == null).length;
                if (pending == 0) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(left: 12), child: TextButton.icon(
                  onPressed: _superviseAllPending,
                  icon: Icon(Icons.verified_user_outlined, size: 16, color: Colors.amber.shade800),
                  label: Text('Supervise all pending ($pending)', style: TextStyle(fontSize: 12, color: Colors.amber.shade800)),
                ));
              }(),
            ],
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by name, SKU or barcode...',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('POS:',
                style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            for (final opt in const [
              ['all', 'All'],
              ['in', 'In POS'],
              ['out', 'Not in POS']
            ]) ...[
              ChoiceChip(
                label: Text(opt[1]),
                selected: _posFilter == opt[0],
                onSelected: (_) {
                  _posFilter = opt[0];
                  _runFilter();
                },
                selectedColor: Colors.purple.withOpacity(0.15),
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: _posFilter == opt[0]
                      ? Colors.purple
                      : AppTheme.textSecondary,
                  fontWeight: _posFilter == opt[0]
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 6),
            ],
            _grpFilter('Main Group', _fMain,
                (_taxonomies['main_group'] ?? []).map((t) => t['name'] as String).toList(),
                (v) {
              _fMain = v;
              // Cascade: drop child selections no longer valid under the new main.
              if (_fGroup != null && !_groupChoices(main: _fMain).contains(_fGroup)) _fGroup = null;
              if (_fSub != null && !_subChoices(main: _fMain, group: _fGroup).contains(_fSub)) _fSub = null;
              _runFilter();
            }),
            _grpFilter('Group', _fGroup, _groupChoices(main: _fMain), (v) {
              _fGroup = v;
              if (_fSub != null && !_subChoices(main: _fMain, group: _fGroup).contains(_fSub)) _fSub = null;
              _runFilter();
            }),
            _grpFilter('Sub Group', _fSub, _subChoices(main: _fMain, group: _fGroup), (v) {
              _fSub = v;
              _runFilter();
            }),
            if (_fMain != null || _fGroup != null || _fSub != null)
              TextButton(onPressed: () { _fMain = null; _fGroup = null; _fSub = null; _runFilter(); }, child: const Text('Clear groups')),
            if (_productSuperviseEnabled)
              ChoiceChip(
                label: const Text('Supervision pending'),
                selected: _superviseFilter,
                onSelected: (v) { setState(() => _superviseFilter = v); _runFilter(); },
                selectedColor: Colors.amber.withOpacity(0.20),
                labelStyle: TextStyle(fontSize: 12, color: _superviseFilter ? Colors.amber.shade900 : AppTheme.textSecondary, fontWeight: _superviseFilter ? FontWeight.w700 : FontWeight.w500),
              ),
            Text(_selected.isNotEmpty ? 'Export ${_selected.length} selected:' : 'Export ${_filtered.length} shown:',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            OutlinedButton.icon(
              icon: const Icon(Icons.grid_on_outlined, size: 16),
              label: const Text('Excel'),
              onPressed: _exportExcel,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.description_outlined, size: 16),
              label: const Text('CSV'),
              onPressed: _exportFilteredCsv,
            ),
          ]),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
              ),
              child: Row(children: [
                Icon(Icons.check_circle, size: 16, color: AppTheme.primary),
                const SizedBox(width: 8),
                Text('${_selected.length} selected', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _selected.clear()),
                  icon: const Icon(Icons.close, size: 14),
                  label: const Text('Clear'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _printBarcodeLabels(
                      _products.where((p) => _selected.contains('${p['id']}')).toList()),
                  icon: const Icon(Icons.qr_code_2, size: 16),
                  label: Text('Barcode labels (${_selected.length})'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _bulkPushToPOS(context),
                  icon: const Icon(Icons.point_of_sale, size: 16),
                  label: const Text('Push selected to POS'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.purple, foregroundColor: Colors.white),
                ),
                if (_canDelete) ...[
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: _bulkDelete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text('Delete selected (${_selected.length})'),
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
                  ),
                ],
              ]),
            ),
          ],
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: Row(children: [
                        SizedBox(width: 40, child: Checkbox(
                          tristate: true,
                          value: _selected.isEmpty ? false : (_selected.length == _filtered.length ? true : null),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.addAll(_filtered.map((p) => p['id'] as String));
                              } else {
                                _selected.clear();
                              }
                            });
                          },
                        )),
                        const Expanded(flex: 3, child: Text('Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('SKU', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Sub Group', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 1, child: Text('UOM', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Sell Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Purchase/Cost Price', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: _productSuperviseEnabled ? 200 : 160),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final p = _filtered[i];
                          final isActive = p['is_active'] as bool? ?? true;
                          final catName = p['product_categories'] != null
                              ? p['product_categories']['name'] as String? ?? '-'
                              : '-';
                          final uomAbbr = p['uoms'] != null
                              ? p['uoms']['abbreviation'] as String? ?? '-'
                              : '-';
                          return Opacity(
                            opacity: isActive ? 1.0 : 0.5,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              child: Row(children: [
                                SizedBox(width: 40, child: Checkbox(
                                  value: _selected.contains(p['id']),
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selected.add(p['id'] as String);
                                      } else {
                                        _selected.remove(p['id']);
                                      }
                                    });
                                  },
                                )),
                                Expanded(
                                    flex: 3,
                                    // Badge sits BELOW the name (not beside it) so a
                                    // long product name keeps the full column width;
                                    // up to 2 lines, full name on hover.
                                    child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                      Tooltip(
                                        message: p['name'] as String? ?? '',
                                        waitDuration: const Duration(milliseconds: 400),
                                        child: Text(p['name'] as String? ?? '',
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      if (_productSuperviseEnabled && p['supervised_at'] == null)
                                        Container(
                                          margin: const EdgeInsets.only(top: 3),
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                          decoration: BoxDecoration(color: Colors.amber.shade700.withOpacity(0.14), borderRadius: BorderRadius.circular(4)),
                                          child: Text('Supervision pending', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: Colors.amber.shade800)),
                                        ),
                                    ])),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['sku'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.primary,
                                            fontWeight: FontWeight.w600))),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['product_group'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13))),
                                Expanded(
                                    flex: 2,
                                    child: Text(p['product_sub_group'] as String? ?? '-',
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13))),
                                Expanded(
                                    flex: 1,
                                    child: Text(uomAbbr,
                                        style: const TextStyle(fontSize: 13))),
                                Expanded(
                                    flex: 2,
                                    child: Text(
                                        p['selling_price']?.toString() ?? '0',
                                        style: const TextStyle(fontSize: 13))),
                                Expanded(
                                    flex: 2,
                                    child: Text(
                                        p['cost_price']?.toString() ?? '0',
                                        style: const TextStyle(fontSize: 13))),
                                SizedBox(
                                  width: _productSuperviseEnabled ? 200 : 160,
                                  child: Row(children: [
                                    if (_productSuperviseEnabled && p['supervised_at'] == null && _canDelete)
                                      IconButton(
                                        icon: const Icon(Icons.verified_user_outlined, size: 18, color: AppTheme.primary),
                                        tooltip: 'Supervise (admin)',
                                        onPressed: () => _superviseProduct(p),
                                      ),
                                    Builder(builder: (_) {
                                      final inPos =
                                          _posProductIds.contains(p['id']);
                                      return IconButton(
                                        icon: Icon(Icons.point_of_sale,
                                            size: 18,
                                            color: inPos
                                                ? Colors.purple
                                                : Colors.grey.shade400),
                                        style: IconButton.styleFrom(
                                          backgroundColor: inPos
                                              ? Colors.purple.withOpacity(0.12)
                                              : null,
                                        ),
                                        tooltip: inPos
                                            ? 'In POS catalog — tap to add to another branch'
                                            : 'Not in POS — tap to push to a branch',
                                        onPressed: () => _pushToPOS(context, p),
                                      );
                                    }),
                                    IconButton(
                                      icon: const Icon(Icons.qr_code_2,
                                          size: 18, color: AppTheme.primary),
                                      tooltip: 'Print barcode label',
                                      onPressed: () =>
                                          _printBarcodeLabels([p]),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 18),
                                      onPressed: () =>
                                          _showDialog(context, p),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        isActive
                                            ? Icons.block
                                            : Icons.check_circle_outline,
                                        size: 18,
                                        color: isActive
                                            ? AppTheme.danger
                                            : AppTheme.success,
                                      ),
                                      onPressed: () => _toggleActive(p),
                                      tooltip: isActive
                                          ? 'Deactivate'
                                          : 'Activate',
                                    ),
                                    if (_canDelete)
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline,
                                            size: 18, color: AppTheme.danger),
                                        tooltip: 'Delete',
                                        onPressed: () => _delete(p['id'] as String),
                                      ),
                                  ]),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BranchPickerDialog extends StatelessWidget {
  final List<Map<String, dynamic>> branches;
  final String productName;
  const _BranchPickerDialog({required this.branches, required this.productName});
  @override Widget build(BuildContext context) => AlertDialog(
    title: Text('Push "$productName" to POS'),
    content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Select which branch POS catalog to add this product to:', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      ...branches.map((b) => ListTile(dense: true, leading: const Icon(Icons.storefront_outlined, size: 18, color: Colors.purple), title: Text(b['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)), onTap: () => Navigator.pop(context, b))),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel'))],
  );
}


class _CsvImportDialog extends StatefulWidget {
  final List<Map<String, dynamic>> uoms;
  final List<Map<String, dynamic>> branches;
  final Set<String> existingSkus;
  final List<Map<String, dynamic>> existingProducts;
  final Future<void> Function(List<Map<String, dynamic>>, List<String>, String?, bool, DateTime, {void Function(int, int)? onProgress}) onImport;
  const _CsvImportDialog({required this.uoms, required this.branches, required this.existingSkus, required this.existingProducts, required this.onImport});
  @override
  State<_CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends State<_CsvImportDialog> {
  List<Map<String, dynamic>> _validRows = [];
  List<String> _rowErrors = [];
  final Set<String> _importBranches = {};
  String? _openingBranchId;   // single branch that receives opening stock qty + GL
  DateTime _openingDate = DateTime.now();   // date used for the opening-stock voucher + its GL
  bool _updateMode = false;   // false = Create new products; true = Update existing (by SKU, then exact name)
  String? _lastText;          // last uploaded file text, re-validated when mode flips
  int _totalParsed = 0;
  bool _importing = false;
  int _progressDone = 0;
  int _progressTotal = 0;
  String? _fileName;
  String? _fatalError;

  void _downloadTemplate() {
    const csv = 'name,sku,barcode,uom,product_type,main_group,group,sub_group,class,movement_category,selling_price,cost_price,low_stock_limit,opening_qty\n'
        'Example Product A,SKU001,8901234567890,pcs,Stock Item,Lighting,Downlights,LED,A,Fast,210,150,10,25\n'
        'Example Product B,SKU002,,box,Stock Item,Electricals,,,,Slow,1000,800,0,0\n';
    final blob = html.Blob([csv], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)..setAttribute('download', 'products_template.csv')..click();
    Future.delayed(const Duration(seconds: 2), () => html.Url.revokeObjectUrl(url));
  }

  Future<void> _pickFile() async {
    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.click();
    await input.onChange.first;
    if (input.files == null || input.files!.isEmpty) return;
    final file = input.files!.first;
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    final text = reader.result as String;
    _lastText = text;
    setState(() {
      _fileName = file.name; _fatalError = null; _validRows = []; _rowErrors = [];
    });
    _parseAndValidate(text);
  }

  List<List<String>> _parseCsv(String text) {
    final lines = <List<String>>[];
    final fields = <String>[];
    final current = StringBuffer();
    bool inQuotes = false;
    int i = 0;
    while (i < text.length) {
      final ch = text[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') { current.write('"'); i += 2; continue; }
          inQuotes = false; i++; continue;
        }
        current.write(ch); i++;
      } else {
        if (ch == '"') { inQuotes = true; i++; continue; }
        if (ch == ',') { fields.add(current.toString()); current.clear(); i++; continue; }
        if (ch == '\n' || ch == '\r') {
          fields.add(current.toString()); current.clear();
          if (fields.any((f) => f.isNotEmpty)) lines.add(List.from(fields));
          fields.clear();
          if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
          i++; continue;
        }
        current.write(ch); i++;
      }
    }
    if (current.isNotEmpty || fields.isNotEmpty) {
      fields.add(current.toString());
      if (fields.any((f) => f.isNotEmpty)) lines.add(List.from(fields));
    }
    return lines;
  }

  void _parseAndValidate(String text) {
    final rows = _parseCsv(text);
    if (rows.isEmpty) { setState(() => _fatalError = 'CSV is empty'); return; }
    final header = rows.first.map((s) => s.trim().toLowerCase()).toList();
    if (!header.contains('name')) { setState(() => _fatalError = 'Required column "name" missing'); return; }
    if (!header.contains('uom')) { setState(() => _fatalError = 'Required column "uom" missing'); return; }
    int idx(String col) => header.indexOf(col);
    final iName = idx('name'); final iSku = idx('sku'); final iBarcode = idx('barcode');
    final iUom = idx('uom'); final iType = idx('product_type'); final iMain = idx('main_group');
    final iGroup = idx('group'); final iSub = idx('sub_group'); final iClass = idx('class');
    final iMov = idx('movement_category'); final iSell = idx('selling_price'); final iCost = idx('cost_price');
    final iLow = idx('low_stock_limit');
    final iQty = idx('opening_qty');

    final uomByAbbr = {for (final u in widget.uoms) (u['abbreviation'] as String? ?? '').toLowerCase(): u['id'] as String};
    final uomByName = {for (final u in widget.uoms) (u['name'] as String? ?? '').toLowerCase(): u['id'] as String};
    final seenSkus = <String>{};
    final valid = <Map<String, dynamic>>[];
    final errors = <String>[];

    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      String get(int i) => (i >= 0 && i < row.length) ? row[i].trim() : '';
      final name = get(iName);
      if (name.isEmpty) { errors.add('Row ${r + 1}: name is required'); continue; }
      final uomRaw = get(iUom).toLowerCase();
      if (uomRaw.isEmpty) { errors.add('Row ${r + 1}: uom is required'); continue; }
      final uomId = uomByAbbr[uomRaw] ?? uomByName[uomRaw];
      if (uomId == null) { errors.add('Row ${r + 1}: unknown uom "$uomRaw"'); continue; }
      final sku = iSku >= 0 ? get(iSku) : '';
      // Resolve the target product id for UPDATE mode (by SKU, then exact unique name).
      String? matchId;
      if (_updateMode) {
        if (sku.isNotEmpty) {
          final hits = widget.existingProducts.where((p) => (p['sku'] as String? ?? '') == sku).toList();
          if (hits.isEmpty) { errors.add('Row ${r + 1}: SKU "$sku" not found — skipped'); continue; }
          matchId = hits.first['id'] as String?;
        } else {
          // No SKU: fall back to EXACT, UNIQUE name match only (never guess).
          final hits = widget.existingProducts.where((p) => (p['name'] as String? ?? '') == name).toList();
          if (hits.isEmpty) { errors.add('Row ${r + 1}: no SKU and name "$name" not found — skipped'); continue; }
          if (hits.length > 1) { errors.add('Row ${r + 1}: no SKU and name "$name" matches ${hits.length} products (ambiguous) — skipped'); continue; }
          matchId = hits.first['id'] as String?;
        }
      } else {
        // CREATE mode: an existing SKU is a conflict; skip it.
        if (sku.isNotEmpty && widget.existingSkus.contains(sku)) { errors.add('Row ${r + 1}: SKU "$sku" already exists, skipped'); continue; }
      }
      if (sku.isNotEmpty && seenSkus.contains(sku)) { errors.add('Row ${r + 1}: duplicate SKU "$sku" within file'); continue; }
      if (sku.isNotEmpty) seenSkus.add(sku);
      // Interpretation B: a blank/missing cell → null (skip on update, empty on
      // insert). A typed number (including 0) → that number. This lets update
      // mode preserve existing values for blank cells instead of zeroing them.
      // Tolerant number parse: strip thousands separators, currency symbols and
      // spaces (Excel often exports prices like "1,234.50" or "Rs 1234") so a
      // valid price isn't silently dropped as null.
      double? numOf(String s) {
        final t = s.replaceAll(RegExp(r'[^0-9.\-]'), '');
        if (t.isEmpty || t == '-' || t == '.') return null;
        return double.tryParse(t);
      }
      final sellStr = iSell >= 0 ? get(iSell).trim() : '';
      final costStr = iCost >= 0 ? get(iCost).trim() : '';
      final lowStr  = iLow  >= 0 ? get(iLow).trim()  : '';
      final sell = sellStr.isEmpty ? null : numOf(sellStr);
      final cost = costStr.isEmpty ? null : numOf(costStr);
      final low  = lowStr.isEmpty  ? null : numOf(lowStr);
      final openQty = iQty >= 0 ? (numOf(get(iQty)) ?? 0) : 0;
      valid.add({
        'name': name,
        'sku': sku.isEmpty ? null : sku,
        'barcode': iBarcode >= 0 && get(iBarcode).isNotEmpty ? get(iBarcode) : null,
        'base_uom_id': uomId,
        'product_type': iType >= 0 && get(iType).isNotEmpty ? get(iType) : null,
        'product_main_group': iMain >= 0 && get(iMain).isNotEmpty ? get(iMain) : null,
        'product_group': iGroup >= 0 && get(iGroup).isNotEmpty ? get(iGroup) : null,
        'product_sub_group': iSub >= 0 && get(iSub).isNotEmpty ? get(iSub) : null,
        'product_class': iClass >= 0 && get(iClass).isNotEmpty ? get(iClass) : null,
        'product_movement_category': iMov >= 0 && get(iMov).isNotEmpty ? get(iMov) : null,
        'selling_price': sell,
        'cost_price': cost,
        'low_stock_limit': low,
        '_opening_qty': openQty,   // transient: stripped before products insert, used for opening stock
        '_match_id': matchId,      // transient: in update mode, the product id this row updates
      });
    }
    setState(() { _totalParsed = rows.length - 1; _validRows = valid; _rowErrors = errors; });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import Products from CSV'),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Mode selector — Create new vs Update existing. Update mode never
          // touches opening stock or the GL; it only overwrites product fields.
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Create new'), icon: Icon(Icons.add, size: 16)),
              ButtonSegment(value: true, label: Text('Update existing'), icon: Icon(Icons.edit, size: 16)),
            ],
            selected: {_updateMode},
            onSelectionChanged: (s) {
              setState(() => _updateMode = s.first);
              if (_lastText != null) _parseAndValidate(_lastText!);  // re-validate under new mode
            },
          ),
          const SizedBox(height: 6),
          Text(
            _updateMode
              ? 'Matches each row to an existing product by SKU (or exact unique name if no SKU) and overwrites its fields. No products are created. opening_qty is ignored — no stock or GL is posted.'
              : 'Creates new products. Rows whose SKU already exists are skipped. opening_qty (if set) posts one opening-stock voucher.',
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          const Divider(height: 22),
          if (!_updateMode) ...[
          Row(children: [
            const Icon(Icons.storefront_outlined, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            const Text('Import into branches (optional):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          if (widget.branches.isEmpty)
            const Text('No branches found.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
          else
            Wrap(spacing: 8, runSpacing: 4, children: widget.branches.map((b) {
              final bid = b['id'] as String;
              final checked = _importBranches.contains(bid);
              return FilterChip(
                label: Text(b['name'] as String? ?? '-'),
                selected: checked,
                onSelected: (v) => setState(() { if (v) _importBranches.add(bid); else _importBranches.remove(bid); }),
              );
            }).toList()),
          const SizedBox(height: 4),
          const Text('Imported products start at zero stock in the selected branches. Leave blank to import without allocating to any branch.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          if (_validRows.any((r) => ((r['_opening_qty'] as num?) ?? 0) > 0)) ...[
            const Divider(height: 22),
            const Text('Opening stock branch:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (widget.branches.isEmpty)
              const Text('No branches found.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
            else
              DropdownButtonFormField<String>(
                value: _openingBranchId,
                isExpanded: true,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'Select branch for opening stock'),
                items: widget.branches.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String? ?? '-'))).toList(),
                onChanged: (v) => setState(() => _openingBranchId = v),
              ),
            const SizedBox(height: 10),
            const Text('Opening stock date:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text('${_openingDate.year.toString().padLeft(4, '0')}-${_openingDate.month.toString().padLeft(2, '0')}-${_openingDate.day.toString().padLeft(2, '0')}'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _openingDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _openingDate = picked);
              },
            ),
            const SizedBox(height: 4),
            const Text('The voucher and its GL entry will be dated as above. Set this BEFORE importing — once posted, the date cannot be changed.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ],
          const Divider(height: 22),
          ],
          if (_fileName == null) ...[
            const Text('Upload a CSV with your products. The "name" and "uom" columns are required; everything else is optional.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            Row(children: [
              OutlinedButton.icon(onPressed: _downloadTemplate, icon: const Icon(Icons.download, size: 16), label: const Text('Download Template')),
              const SizedBox(width: 12),
              ElevatedButton.icon(onPressed: _pickFile, icon: const Icon(Icons.attach_file, size: 16), label: const Text('Choose CSV File')),
            ]),
            const SizedBox(height: 14),
            const Text('UOM matches by abbreviation (e.g. "pcs", "box") or full name.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            const Text('Duplicate SKUs (already in DB or repeated in file) are skipped.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ] else ...[
            Row(children: [
              const Icon(Icons.description_outlined, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(child: Text(_fileName!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
              TextButton(onPressed: _pickFile, child: const Text('Replace')),
            ]),
            const Divider(),
            if (_fatalError != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.08), borderRadius: BorderRadius.circular(6)),
                child: Text(_fatalError!, style: const TextStyle(color: AppTheme.danger, fontSize: 13, fontWeight: FontWeight.w600)),
              )
            else ...[
              Row(children: [
                _stat('Parsed', _totalParsed.toString(), AppTheme.textSecondary),
                const SizedBox(width: 12),
                _stat('Valid', _validRows.length.toString(), AppTheme.success),
                const SizedBox(width: 12),
                _stat('Skipped', _rowErrors.length.toString(), AppTheme.warning),
              ]),
              if (_importing) ...[
                const SizedBox(height: 14),
                LinearProgressIndicator(
                  value: _progressTotal > 0 ? _progressDone / _progressTotal : null,
                ),
                const SizedBox(height: 6),
                Text(
                  _progressTotal > 0
                      ? '${_updateMode ? "Updating" : "Importing"} $_progressDone / $_progressTotal...'
                      : 'Working...',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 12),
              if (_rowErrors.isNotEmpty) Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppTheme.warning.withOpacity(0.06), borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.warning.withOpacity(0.3))),
                child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _rowErrors.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(e, style: const TextStyle(fontSize: 11)))).toList())),
              ),
            ],
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _importing ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        if (_validRows.isNotEmpty) ElevatedButton(
          onPressed: _importing ? null : () async {
            final hasQty = !_updateMode && _validRows.any((r) => ((r['_opening_qty'] as num?) ?? 0) > 0);
            if (hasQty && _openingBranchId == null) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select an opening stock branch (your file has opening quantities).')));
              return;
            }
            setState(() { _importing = true; _progressDone = 0; _progressTotal = _validRows.length; });
            await widget.onImport(_validRows, _importBranches.toList(), _openingBranchId, _updateMode, _openingDate,
              onProgress: (done, total) {
                if (mounted) setState(() { _progressDone = done; _progressTotal = total; });
              });
            if (mounted) Navigator.pop(context);
          },
          child: Text(_importing ? (_updateMode ? 'Updating...' : 'Importing...') : (_updateMode ? 'Update ${_validRows.length} products' : 'Import ${_validRows.length} rows')),
        ),
      ],
    );
  }

  Widget _stat(String label, String val, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.25))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      Text(val, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
    ]),
  );
}

// ── Searchable, freeze-proof dropdown ────────────────────────────────────────
// Replaces the native DropdownButtonFormField in the Add/Edit Product dialog.
// A native dropdown opened inside an AlertDialog on Flutter web can lock up (its
// menu route and the dialog route fight over focus) — that's the "dropdown is
// frozen, reopen the modal to fix it" bug. This widget never opens a native menu
// route; it expands a panel in place, so it can't freeze — and it adds
// type-to-search over the options.
class _SearchSelect extends StatefulWidget {
  final String label;
  final String hint;
  final String? value;
  final List<Map<String, String>> items;
  final ValueChanged<String?> onChanged;
  const _SearchSelect({super.key, required this.label, required this.value, required this.items, required this.onChanged, this.hint = 'Select...'});
  @override
  State<_SearchSelect> createState() => _SearchSelectState();
}

class _SearchSelectState extends State<_SearchSelect> {
  bool _open = false;
  String _q = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  String get _currentLabel {
    for (final it in widget.items) {
      if (it['value'] == widget.value) return it['label'] ?? '';
    }
    return '';
  }

  List<Map<String, String>> get _filtered {
    if (_q.isEmpty) return widget.items;
    final ql = _q.toLowerCase();
    return widget.items.where((it) => (it['label'] ?? '').toLowerCase().contains(ql)).toList();
  }

  void _close() { setState(() { _open = false; _q = ''; _searchCtrl.clear(); }); }

  @override
  Widget build(BuildContext context) {
    final selLabel = _currentLabel;
    final hasValue = selLabel.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      InkWell(
        onTap: () => setState(() { _open = !_open; if (!_open) { _q = ''; _searchCtrl.clear(); } }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(color: _open ? AppTheme.primary : AppTheme.border),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Expanded(child: Text(hasValue ? selLabel : widget.hint, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: hasValue ? AppTheme.textPrimary : Colors.grey))),
            if (hasValue) InkWell(
              onTap: () { widget.onChanged(null); _close(); },
              child: const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.clear, size: 16, color: AppTheme.textSecondary)),
            ),
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.textSecondary),
          ]),
        ),
      ),
      if (_open) Container(
        margin: const EdgeInsets.only(top: 2),
        constraints: const BoxConstraints(maxHeight: 240),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search...', isDense: true, prefixIcon: Icon(Icons.search, size: 16), contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 8), border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Flexible(
            child: _filtered.isEmpty
              ? const Padding(padding: EdgeInsets.all(12), child: Text('No results', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView(shrinkWrap: true, children: _filtered.map((it) {
                  final selected = it['value'] == widget.value;
                  return InkWell(
                    onTap: () { widget.onChanged(it['value']); _close(); },
                    child: Container(
                      color: selected ? AppTheme.primary.withOpacity(0.06) : null,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      child: Row(children: [
                        Expanded(child: Text(it['label'] ?? '', style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w400))),
                        if (selected) const Icon(Icons.check, size: 15, color: AppTheme.primary),
                      ]),
                    ),
                  );
                }).toList()),
          ),
        ]),
      ),
    ]);
  }
}
