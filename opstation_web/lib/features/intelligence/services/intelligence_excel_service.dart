import 'package:excel/excel.dart' as xls;

/// Excel downloads for Intelligence — Placement Audit and Competitor
/// Spotting. Rows are grouped by market (route) in the same order as the PDF;
/// a shop on two routes appears under both.
class IntelligenceExcelService {
  static xls.Sheet _sheet(xls.Excel excel, String name) {
    final sheet = excel[name];
    final def = excel.getDefaultSheet();
    if (def != null && def != name) excel.delete(def);
    return sheet;
  }

  static xls.TextCellValue _t(Object? v) => xls.TextCellValue('${v ?? ''}');

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static void _top(xls.Sheet sheet, String orgName, String title, String filters) {
    sheet.appendRow([_t(orgName)]);
    sheet.appendRow([_t(title), _t(_today())]);
    if (filters.isNotEmpty) sheet.appendRow([_t(filters)]);
    sheet.appendRow([_t('')]);
  }

  /// Market → shops (in order), skipping ids not in [customers].
  static List<MapEntry<String, List<Map<String, dynamic>>>> _groups(
    List<Map<String, dynamic>> customers,
    Map<String, List<String>> markets,
  ) {
    final byId = {for (final c in customers) c['id'] as String: c};
    return [
      for (final e in markets.entries)
        MapEntry(e.key.trim(), [
          for (final id in e.value)
            if (byId[id] != null) byId[id]!,
        ]),
    ].where((g) => g.value.isNotEmpty).toList();
  }

  static void placementAudit({
    required String orgName,
    required String filters,
    required List<Map<String, dynamic>> customers,
    required List<Map<String, dynamic>> products,
    required Map<String, Map<String, Map<String, dynamic>>> latest,
    required Map<String, List<String>> markets,
  }) {
    final excel = xls.Excel.createExcel();
    final sheet = _sheet(excel, 'Placement Audit');
    _top(sheet, orgName, 'Placement Audit', filters);
    sheet.appendRow([
      _t('Market'),
      _t('Code'),
      _t('Shop'),
      for (final p in products) _t(p['name']),
      _t('Displayed'),
    ]);
    for (final g in _groups(customers, markets)) {
      for (final c in g.value) {
        final cid = c['id'] as String;
        var shown = 0, surveyed = 0;
        final cells = <xls.CellValue>[];
        for (final p in products) {
          final a = latest[cid]?[p['id'] as String];
          if (a == null) {
            cells.add(_t('-'));
          } else {
            surveyed++;
            final yes = a['is_present'] == true;
            if (yes) shown++;
            cells.add(_t(yes ? 'Yes' : 'No'));
          }
        }
        sheet.appendRow([
          _t(g.key),
          _t(c['code']),
          _t(c['shop_name']),
          ...cells,
          _t(surveyed == 0 ? '-' : '$shown of $surveyed'),
        ]);
      }
    }
    excel.save(fileName: 'placement-audit-${_today()}.xlsx');
  }

  static void competitorSpotting({
    required String orgName,
    required String filters,
    required List<Map<String, dynamic>> customers,
    required List<Map<String, dynamic>> categories,
    required Map<String, Map<String, Map<String, dynamic>>> latest,
    required Map<String, List<String>> markets,
  }) {
    final excel = xls.Excel.createExcel();
    final sheet = _sheet(excel, 'Competitor Spotting');
    _top(sheet, orgName, 'Competitor Spotting', filters);
    sheet.appendRow([
      _t('Market'),
      _t('Code'),
      _t('Shop'),
      _t('Category'),
      _t('Brand'),
      _t('Price (PKR)'),
      _t('Specs'),
      _t('Spotted on'),
    ]);
    final catName = {for (final c in categories) c['id'] as String: '${c['name'] ?? ''}'};
    final catOrder = {for (var i = 0; i < categories.length; i++) categories[i]['id'] as String: i};
    for (final g in _groups(customers, markets)) {
      for (final c in g.value) {
        final cid = c['id'] as String;
        final byCat = latest[cid];
        if (byCat == null || byCat.isEmpty) {
          sheet.appendRow([_t(g.key), _t(c['code']), _t(c['shop_name']), _t('No spotting')]);
          continue;
        }
        final cats = byCat.keys.where(catName.containsKey).toList()
          ..sort((a, b) => (catOrder[a] ?? 0).compareTo(catOrder[b] ?? 0));
        for (final catId in cats) {
          final s = byCat[catId]!;
          final price = s['price'];
          final at = '${s['surveyed_at'] ?? ''}';
          final when = DateTime.tryParse(at)?.toLocal();
          sheet.appendRow([
            _t(g.key),
            _t(c['code']),
            _t(c['shop_name']),
            _t(catName[catId]),
            _t(s['brand_name']),
            price is num ? xls.DoubleCellValue(price.toDouble()) : _t(price ?? ''),
            _t(s['specs']),
            _t(when == null
                ? ''
                : '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}'),
          ]);
        }
      }
    }
    excel.save(fileName: 'competitor-spotting-${_today()}.xlsx');
  }
}
