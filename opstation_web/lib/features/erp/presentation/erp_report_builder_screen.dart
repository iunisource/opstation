import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpReportBuilderScreen extends ConsumerStatefulWidget {
  const ErpReportBuilderScreen({super.key});
  @override
  ConsumerState<ErpReportBuilderScreen> createState() => _State();
}

const _sources = [
  {'key': 'sales', 'label': 'Sales'},
  {'key': 'purchases', 'label': 'Purchases'},
  {'key': 'inventory', 'label': 'Inventory'},
];

class _State extends ConsumerState<ErpReportBuilderScreen> {
  List<Map<String, dynamic>> _allMeta = [];
  bool _loadingMeta = true;

  String _source = 'sales';
  final List<String> _rows = [];
  final List<String> _cols = [];
  final List<String> _values = [];
  final Map<String, String> _filters = {};
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _view = 'table'; // table | pivot

  List<Map<String, dynamic>> _result = [];
  bool _running = false;
  String? _error;

  List<Map<String, dynamic>> _templates = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadMeta(); _loadTemplates(); });
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadMeta() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 400)); if (mounted) _loadMeta(); return; }
    try {
      final rows = await Supabase.instance.client.from('report_field_meta').select().order('ord');
      if (mounted) setState(() { _allMeta = List<Map<String, dynamic>>.from(rows); _loadingMeta = false; });
    } catch (e) { if (mounted) { _snack('Field catalog load failed: $e'); setState(() => _loadingMeta = false); } }
  }

  Future<void> _loadTemplates() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client.from('report_templates').select().eq('org_id', orgId).order('name');
      if (mounted) setState(() => _templates = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _dims => _allMeta.where((m) => m['source'] == _source && m['kind'] == 'dim').toList();
  List<Map<String, dynamic>> get _measures => _allMeta.where((m) => m['source'] == _source && m['kind'] == 'measure').toList();
  String _label(String field) {
    final m = _allMeta.firstWhere((e) => e['source'] == _source && e['field'] == field, orElse: () => {});
    return (m['label'] as String?) ?? field;
  }

  static String _fmt(num? v) {
    if (v == null) return '–';
    final d = v.toDouble();
    if (d == d.roundToDouble()) return NumberFormat('#,##0').format(d);
    return NumberFormat('#,##0.00').format(d);
  }

  void _resetForSource(String src) {
    setState(() {
      _source = src;
      _rows.clear(); _cols.clear(); _values.clear(); _filters.clear();
      _result = []; _error = null;
    });
  }

  void _assign(String field, String zone) {
    setState(() {
      _rows.remove(field); _cols.remove(field); _values.remove(field); _filters.remove(field);
      if (zone == 'rows') _rows.add(field);
      else if (zone == 'cols') _cols.add(field);
      else if (zone == 'values') _values.add(field);
    });
  }

  Future<void> _addFilter(String field) async {
    final ctrl = TextEditingController(text: _filters[field] ?? '');
    final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Filter: ${_label(field)}'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Equals…', isDense: true)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Apply')),
      ],
    ));
    if (v != null && v.isNotEmpty) setState(() { _rows.remove(field); _cols.remove(field); _filters[field] = v; });
  }

  Future<void> _run() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    final dims = [..._rows, ..._cols];
    if (dims.isEmpty && _values.isEmpty) { _snack('Add at least one field to Rows, Columns, or Values'); return; }
    setState(() { _running = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('rpc_report_query', params: {
        'p_org': orgId, 'p_source': _source,
        'p_dims': dims, 'p_measures': _values,
        'p_filters': _filters,
        'p_date_from': _dateFrom != null ? DateFormat('yyyy-MM-dd').format(_dateFrom!) : null,
        'p_date_to': _dateTo != null ? DateFormat('yyyy-MM-dd').format(_dateTo!) : null,
      });
      final list = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) setState(() { _result = list; _running = false; });
    } catch (e) { if (mounted) setState(() { _error = e.toString(); _running = false; }); }
  }

  Future<void> _pickDate(bool from) async {
    final picked = await showDatePicker(context: context, initialDate: (from ? _dateFrom : _dateTo) ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null) setState(() { if (from) _dateFrom = picked; else _dateTo = picked; });
  }

  // ---------- templates ----------
  Future<void> _saveTemplate() async {
    final nameCtrl = TextEditingController();
    bool shared = true;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (c, setS) => AlertDialog(
      title: const Text('Save as template'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: 'Template name')),
        const SizedBox(height: 8),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: shared, onChanged: (v) => setS(() => shared = v),
          title: const Text('Shared with org', style: TextStyle(fontSize: 14))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Save')),
      ],
    )));
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await Supabase.instance.client.from('report_templates').insert({
        'id': 'rpt_${DateTime.now().millisecondsSinceEpoch}', 'org_id': _orgId, 'name': nameCtrl.text.trim(), 'source': _source,
        'is_shared': shared, 'created_by': ref.read(currentUserProvider)?.id,
        'config': {
          'rows': _rows, 'cols': _cols, 'values': _values, 'filters': _filters, 'view': _view,
          'date_from': _dateFrom != null ? DateFormat('yyyy-MM-dd').format(_dateFrom!) : null,
          'date_to': _dateTo != null ? DateFormat('yyyy-MM-dd').format(_dateTo!) : null,
        },
      });
      _snack('Template saved');
      await _loadTemplates();
    } catch (e) { _snack('Save failed: $e'); }
  }

  void _loadTemplate(Map<String, dynamic> t) {
    final cfg = Map<String, dynamic>.from(t['config'] as Map? ?? {});
    setState(() {
      _source = t['source'] as String? ?? 'sales';
      _rows..clear()..addAll(List<String>.from(cfg['rows'] ?? []));
      _cols..clear()..addAll(List<String>.from(cfg['cols'] ?? []));
      _values..clear()..addAll(List<String>.from(cfg['values'] ?? []));
      _filters..clear()..addAll(Map<String, String>.from((cfg['filters'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {}));
      _view = cfg['view'] as String? ?? 'table';
      _dateFrom = cfg['date_from'] != null ? DateTime.tryParse(cfg['date_from']) : null;
      _dateTo = cfg['date_to'] != null ? DateTime.tryParse(cfg['date_to']) : null;
    });
    _run();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (_loadingMeta) return const Center(child: CircularProgressIndicator());
    return Container(color: AppTheme.background, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _header(),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 320, child: _configPanel()),
        Expanded(child: _resultsPanel()),
      ])),
    ]));
  }

  Widget _header() {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Report Builder', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        DropdownButton<String>(value: _source, underline: const SizedBox(),
          items: _sources.map((s) => DropdownMenuItem(value: s['key'], child: Text(s['label']!))).toList(),
          onChanged: (v) { if (v != null) _resetForSource(v); }),
        _dateBtn('From', _dateFrom, () => _pickDate(true), () => setState(() => _dateFrom = null)),
        _dateBtn('To', _dateTo, () => _pickDate(false), () => setState(() => _dateTo = null)),
        ElevatedButton.icon(onPressed: _running ? null : _run,
          icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.play_arrow, size: 18),
          label: const Text('Run'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
        ToggleButtons(isSelected: [_view == 'table', _view == 'pivot'], onPressed: (i) => setState(() => _view = i == 0 ? 'table' : 'pivot'),
          borderRadius: BorderRadius.circular(8), constraints: const BoxConstraints(minHeight: 34, minWidth: 64),
          children: const [Text('Table'), Text('Pivot')]),
        OutlinedButton.icon(onPressed: _saveTemplate, icon: const Icon(Icons.bookmark_add_outlined, size: 16), label: const Text('Save')),
        if (_templates.isNotEmpty) PopupMenuButton<Map<String, dynamic>>(
          tooltip: 'Load template',
          onSelected: _loadTemplate,
          itemBuilder: (_) => _templates.map((t) => PopupMenuItem(value: t, child: Text('${t['name']}  ·  ${t['source']}'))).toList(),
          child: OutlinedButton.icon(onPressed: null, icon: const Icon(Icons.folder_open_outlined, size: 16), label: const Text('Templates')),
        ),
      ]));
  }

  Widget _dateBtn(String label, DateTime? d, VoidCallback onPick, VoidCallback onClear) {
    return InkWell(onTap: onPick, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.event, size: 14, color: AppTheme.textSecondary), const SizedBox(width: 6),
        Text(d != null ? DateFormat('d MMM yyyy').format(d) : label, style: const TextStyle(fontSize: 12)),
        if (d != null) InkWell(onTap: onClear, child: const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.close, size: 13))),
      ])));
  }

  Widget _configPanel() {
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
      child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _zone('Rows', _rows, AppTheme.primary),
        _zone('Columns', _cols, Colors.teal),
        _zone('Values', _values, Colors.deepPurple),
        _filterZone(),
        const Divider(height: 24),
        const Text('Dimensions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        ..._dims.map((m) => _dimRow(m['field'] as String, m['label'] as String)),
        const SizedBox(height: 14),
        const Text('Measures', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        ..._measures.map((m) => _measureRow(m['field'] as String, m['label'] as String)),
      ])),
    );
  }

  Widget _zone(String title, List<String> items, Color c) {
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      const SizedBox(height: 4),
      Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 36), padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: c.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.25))),
        child: items.isEmpty ? const Text('—', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
          : Wrap(spacing: 4, runSpacing: 4, children: items.map((f) => Chip(
              label: Text(_label(f), style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onDeleted: () => setState(() { _rows.remove(f); _cols.remove(f); _values.remove(f); }),
            )).toList())),
    ]));
  }

  Widget _filterZone() {
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Filters', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.orange)),
      const SizedBox(height: 4),
      Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 36), padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: Colors.orange.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.withOpacity(0.25))),
        child: _filters.isEmpty ? const Text('—', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))
          : Wrap(spacing: 4, runSpacing: 4, children: _filters.entries.map((e) => Chip(
              label: Text('${_label(e.key)} = ${e.value}', style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onDeleted: () => setState(() => _filters.remove(e.key)),
            )).toList())),
    ]));
  }

  Widget _dimRow(String field, String label) {
    final used = _rows.contains(field) || _cols.contains(field);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: used ? AppTheme.textSecondary : AppTheme.textPrimary))),
      _miniBtn('R', 'Add to Rows', () => _assign(field, 'rows')),
      _miniBtn('C', 'Add to Columns', () => _assign(field, 'cols')),
      IconButton(icon: const Icon(Icons.filter_alt_outlined, size: 16), tooltip: 'Add filter', visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 26, minHeight: 26), onPressed: () => _addFilter(field)),
    ]));
  }

  Widget _measureRow(String field, String label) {
    final used = _values.contains(field);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: used ? AppTheme.textSecondary : AppTheme.textPrimary))),
      _miniBtn('Σ', 'Add to Values', () => _assign(field, 'values')),
    ]));
  }

  Widget _miniBtn(String t, String tip, VoidCallback onTap) => Tooltip(message: tip, child: InkWell(onTap: onTap,
    child: Container(margin: const EdgeInsets.only(left: 2), width: 24, height: 24, alignment: Alignment.center,
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(5), border: Border.all(color: AppTheme.border)),
      child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))));

  Widget _resultsPanel() {
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Query error:\n$_error', style: const TextStyle(color: Colors.red))));
    if (_result.isEmpty) return const Center(child: Text('Assign fields and press Run.', style: TextStyle(color: AppTheme.textSecondary)));
    return Padding(padding: const EdgeInsets.all(16), child: _view == 'pivot' ? _pivot() : _table());
  }

  Widget _table() {
    final dims = [..._rows, ..._cols];
    final cols = [...dims, ..._values];
    return SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: DataTable(
        headingRowHeight: 42, dataRowMinHeight: 38, dataRowMaxHeight: 48,
        columns: cols.map((c) => DataColumn(label: Text(_label(c), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: _values.contains(c))).toList(),
        rows: _result.map((r) => DataRow(cells: cols.map((c) {
          final isMeasure = _values.contains(c);
          final v = r[c];
          return DataCell(Text(isMeasure ? _fmt(v as num?) : (v?.toString() ?? '(none)'), style: const TextStyle(fontSize: 12)));
        }).toList())).toList(),
      ),
    )));
  }

  Widget _pivot() {
    if (_rows.isEmpty || _values.isEmpty) {
      return const Center(child: Text('Pivot needs at least one Row and one Value.\nColumns are optional.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)));
    }
    final measure = _values.first;
    // build crosstab
    final rowKeys = <String>[]; final colKeys = <String>[];
    final Map<String, List<String>> rowParts = {};
    final Map<String, Map<String, num>> cell = {};
    for (final r in _result) {
      final rk = _rows.map((d) => (r[d]?.toString() ?? '(none)')).toList();
      final ck = _cols.map((d) => (r[d]?.toString() ?? '(none)')).toList();
      final rKey = rk.join('\u0001'); final cKey = ck.join('\u0001');
      if (!rowKeys.contains(rKey)) { rowKeys.add(rKey); rowParts[rKey] = rk; }
      if (!colKeys.contains(cKey)) colKeys.add(cKey);
      final v = (r[measure] as num?) ?? 0;
      (cell[rKey] ??= {})[cKey] = ((cell[rKey]?[cKey]) ?? 0) + v;
    }
    rowKeys.sort(); colKeys.sort();
    String colLabel(String cKey) => _cols.isEmpty ? _label(measure) : cKey.split('\u0001').join(' / ');

    final columns = <DataColumn>[
      ..._rows.map((d) => DataColumn(label: Text(_label(d), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)))),
      ...colKeys.map((ck) => DataColumn(numeric: true, label: Text(colLabel(ck), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)))),
      const DataColumn(numeric: true, label: Text('Total', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
    ];

    num grand = 0;
    final Map<String, num> colTotals = {for (final ck in colKeys) ck: 0};
    final dataRows = rowKeys.map((rKey) {
      num rowTotal = 0;
      final cells = <DataCell>[
        ...rowParts[rKey]!.map((p) => DataCell(Text(p, style: const TextStyle(fontSize: 12)))),
        ...colKeys.map((ck) {
          final v = cell[rKey]?[ck];
          if (v != null) { rowTotal += v; colTotals[ck] = (colTotals[ck] ?? 0) + v; }
          return DataCell(Text(v == null ? '–' : _fmt(v), style: const TextStyle(fontSize: 12)));
        }),
        DataCell(Text(_fmt(rowTotal), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
      ];
      grand += rowTotal;
      return DataRow(cells: cells);
    }).toList();

    final totalRow = DataRow(
      color: MaterialStateProperty.all(AppTheme.background),
      cells: <DataCell>[
        DataCell(const Text('Total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
        ...List.generate(_rows.length - 1, (_) => const DataCell(Text(''))),
        ...colKeys.map((ck) => DataCell(Text(_fmt(colTotals[ck]), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))),
        DataCell(Text(_fmt(grand), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800))),
      ],
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_values.length > 1) Padding(padding: const EdgeInsets.only(bottom: 8),
        child: Text('Pivot cells show "${_label(measure)}". Switch to Table to see all ${_values.length} values.', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
      Expanded(child: SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: DataTable(headingRowHeight: 42, dataRowMinHeight: 36, dataRowMaxHeight: 46, columns: columns, rows: [...dataRows, totalRow]),
      )))),
    ]);
  }
}
