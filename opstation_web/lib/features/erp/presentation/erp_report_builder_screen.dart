import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/permissions/access_control.dart';
import 'dart:html' as html;

class ErpReportBuilderScreen extends ConsumerStatefulWidget {
  const ErpReportBuilderScreen({super.key});
  @override
  ConsumerState<ErpReportBuilderScreen> createState() => _State();
}

class _State extends ConsumerState<ErpReportBuilderScreen> {
  List<Map<String, dynamic>> _allMeta = [];
  List<Map<String, dynamic>> _sources = [];
  bool _loadingMeta = true;

  String _source = 'sales';
  final List<String> _rows = [];
  final List<String> _cols = [];
  final List<String> _values = [];
  final Map<String, _Cond> _filters = {};
  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _view = 'table'; // table | pivot | chart
  String _chartType = 'bar'; // bar | line | pie
  String _userName = '';
  String _fieldSearch = ''; // filters the Dimensions/Measures field lists

  List<Map<String, dynamic>> _result = [];
  bool _running = false;
  String? _error;

  List<Map<String, dynamic>> _templates = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isAdmin => ref.read(accessSyncProvider)?.isAdmin ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadSources(); _loadMeta(); _loadTemplates(); _loadUserName(); });
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadUserName() async {
    final uid = ref.read(currentUserProvider)?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client.from('users').select('name').eq('id', uid).maybeSingle();
      if (mounted && row != null) setState(() => _userName = (row['name'] as String?) ?? '');
    } catch (_) {}
  }

  Future<void> _loadSources() async {
    try {
      final rows = await Supabase.instance.client.from('report_sources').select().order('ord');
      if (!mounted) return;
      final list = List<Map<String, dynamic>>.from(rows);
      setState(() {
        _sources = list;
        if (list.isNotEmpty && !list.any((s) => s['source_key'] == _source)) {
          _source = list.first['source_key'] as String;
        }
      });
    } catch (_) {}
  }

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

  static const Map<String, String> _opLabels = {
    'in': 'is any of', 'notin': 'is none of', 'eq': 'equals', 'ne': 'not equals',
    'contains': 'contains', 'gt': '>', 'ge': '≥', 'lt': '<', 'le': '≤',
    'between': 'between', 'blank': 'is blank', 'notblank': 'is not blank',
  };
  static bool _opIsList(String op) => op == 'in' || op == 'notin';
  static bool _opNoValue(String op) => op == 'blank' || op == 'notblank';
  static bool _opTwoValues(String op) => op == 'between';

  // For master-backed dimensions, the source view only contains values that
  // appear in transactions. Returns {table, column} so the picker can union
  // the full directory in, making every record selectable. (product/sku share
  // the products master; extend here for customer/supplier once confirmed.)
  Map<String, String>? _masterFor(String field) {
    final f = field.toLowerCase();
    final lbl = _label(field).toLowerCase();
    if (f == 'product' || f == 'product_name' || lbl == 'product') return {'table': 'products', 'column': 'name'};
    if (f == 'sku' || lbl == 'sku') return {'table': 'products', 'column': 'sku'};
    if (f == 'customer' || f == 'customer_name' || lbl == 'customer') return {'table': 'customers', 'column': 'shop_name'};
    if (f == 'supplier' || f == 'supplier_name' || f == 'vendor' || lbl == 'supplier' || lbl == 'vendor') return {'table': 'suppliers', 'column': 'name'};
    return null;
  }

  Future<void> _addFilter(String field) async {
    final orgId = _orgId;
    final isMeasure = _measures.any((m) => (m['field'] as String) == field);
    List<String> values = [];
    if (orgId != null && !isMeasure) {
      try {
        final res = await Supabase.instance.client.rpc('rpc_report_distinct', params: {
          'p_org': orgId, 'p_source': _source, 'p_field': field,
        });
        values = List<String>.from(((res as List?) ?? const []).map((e) => e.toString()));
      } catch (_) {}
      // Union the full master directory for master-backed dimensions so records
      // with no rows in the current source are still selectable.
      final ml = _masterFor(field);
      if (ml != null) {
        try {
          final rows = await Supabase.instance.client.from(ml['table']!).select(ml['column']!).eq('org_id', orgId).limit(20000);
          final masterVals = List<Map<String, dynamic>>.from(rows)
              .map((r) => (r[ml['column']] ?? '').toString()).where((s) => s.isNotEmpty);
          values = <String>{...values, ...masterVals}.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        } catch (_) {}
      }
    }
    if (!mounted) return;
    final existing = _filters[field];
    String op = existing?.op ?? (isMeasure ? 'gt' : 'in');
    final selected = <String>{...?(existing != null && _opIsList(existing.op) ? existing.vals : null)};
    final v1Ctrl = TextEditingController(text: (existing != null && !_opIsList(existing.op) && existing.vals.isNotEmpty) ? existing.vals[0] : '');
    final v2Ctrl = TextEditingController(text: (existing != null && existing.op == 'between' && existing.vals.length > 1) ? existing.vals[1] : '');
    final searchCtrl = TextEditingController();

    final result = await showDialog<_FilterResult>(context: context, builder: (ctx) => StatefulBuilder(builder: (c, setS) {
      final q = searchCtrl.text.toLowerCase();
      final shown = (q.isEmpty ? values : values.where((v) => v.toLowerCase().contains(q)).toList());
      return AlertDialog(
        title: Text('Condition: ${_label(field)}'),
        content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Where it', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(width: 10),
            DropdownButton<String>(value: op, isDense: true,
              items: _opLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 13)))).toList(),
              onChanged: (v) => setS(() => op = v ?? 'in')),
          ]),
          const SizedBox(height: 10),
          if (_opNoValue(op))
            const Text('No value needed for this condition.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          else if (_opIsList(op)) ...[
            if (values.isEmpty)
              TextField(controller: v1Ctrl, autofocus: true, decoration: const InputDecoration(hintText: 'Comma-separated values…', isDense: true))
            else ...[
              Row(children: [
                Expanded(child: Text('${values.length} value${values.length == 1 ? '' : 's'} — tick any:', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                if (selected.isNotEmpty) Text('${selected.length} selected', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
              ]),
              const SizedBox(height: 6),
              TextField(controller: searchCtrl, decoration: const InputDecoration(hintText: 'Search values…', isDense: true, prefixIcon: Icon(Icons.search, size: 16)), onChanged: (_) => setS(() {})),
              Row(children: [
                TextButton(onPressed: () => setS(() => selected.addAll(shown)),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero),
                  child: Text(q.isEmpty ? 'Select all' : 'Select all shown', style: const TextStyle(fontSize: 11))),
                TextButton(onPressed: () => setS(() => selected.clear()),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero),
                  child: const Text('Clear', style: TextStyle(fontSize: 11))),
              ]),
              SizedBox(height: 230, child: shown.isEmpty
                ? const Center(child: Text('No match', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                : ListView.builder(itemCount: shown.length > 800 ? 800 : shown.length, itemBuilder: (_, i) {
                    final v = shown[i]; final sel = selected.contains(v);
                    return InkWell(onTap: () => setS(() { if (sel) { selected.remove(v); } else { selected.add(v); } }), child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      color: sel ? AppTheme.primary.withOpacity(0.08) : null,
                      child: Row(children: [
                        Icon(sel ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: sel ? AppTheme.primary : AppTheme.textSecondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(v, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                      ]),
                    ));
                  })),
            ],
          ] else if (_opTwoValues(op)) ...[
            Row(children: [
              Expanded(child: TextField(controller: v1Ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'From', isDense: true))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: v2Ctrl, decoration: const InputDecoration(labelText: 'To', isDense: true))),
            ]),
            if (values.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${values.length} known values exist for reference.', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))),
          ] else ...[
            TextField(controller: v1Ctrl, autofocus: true, decoration: InputDecoration(hintText: op == 'contains' ? 'Text to match…' : 'Value…', isDense: true), onChanged: (_) => setS(() {})),
            if (values.isNotEmpty && (op == 'eq' || op == 'ne')) ...[
              const SizedBox(height: 8),
              TextField(controller: searchCtrl, decoration: const InputDecoration(hintText: 'Or search known values…', isDense: true, prefixIcon: Icon(Icons.search, size: 16)), onChanged: (_) => setS(() {})),
              SizedBox(height: 150, child: ListView.builder(itemCount: shown.length > 400 ? 400 : shown.length, itemBuilder: (_, i) {
                final v = shown[i]; final sel = v1Ctrl.text == v;
                return InkWell(onTap: () => setS(() => v1Ctrl.text = v), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Text(v, style: TextStyle(fontSize: 13, color: sel ? AppTheme.primary : AppTheme.textPrimary, fontWeight: sel ? FontWeight.w700 : FontWeight.w400), overflow: TextOverflow.ellipsis))); })),
            ],
          ],
        ])),
        actions: [
          if (_filters.containsKey(field)) TextButton(onPressed: () => Navigator.pop(ctx, const _FilterResult(clear: true)),
            style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () {
            List<String>? vals;
            if (_opNoValue(op)) {
              vals = [];
            } else if (_opIsList(op)) {
              vals = values.isEmpty
                ? v1Ctrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
                : selected.toList();
              if (vals.isEmpty) vals = null;
            } else if (_opTwoValues(op)) {
              final a = v1Ctrl.text.trim(); final b = v2Ctrl.text.trim();
              vals = (a.isNotEmpty && b.isNotEmpty) ? [a, b] : null;
            } else {
              final a = v1Ctrl.text.trim(); vals = a.isNotEmpty ? [a] : null;
            }
            if (vals == null) { Navigator.pop(ctx, const _FilterResult(clear: true)); return; }
            Navigator.pop(ctx, _FilterResult(op: op, vals: vals));
          }, style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Apply')),
        ],
      );
    }));

    if (result == null) return;
    setState(() {
      if (result.clear || result.vals == null) {
        _filters.remove(field);
      } else {
        _rows.remove(field); _cols.remove(field); _filters[field] = _Cond(result.op!, result.vals!);
      }
    });
  }

  Future<void> _run() async {
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    final dims = [..._rows, ..._cols];
    final measureFields = _measures.map((m) => m['field'] as String).toSet();
    if (dims.isEmpty && _values.isEmpty) { _snack('Add at least one field to Rows, Columns, or Values'); return; }
    setState(() { _running = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('rpc_report_query', params: {
        'p_org': orgId, 'p_source': _source,
        'p_dims': dims, 'p_measures': _values,
        'p_filters': <String, dynamic>{},
        'p_conditions': _filters.entries.where((e) => !measureFields.contains(e.key)).map((e) => {'field': e.key, 'op': e.value.op, 'vals': e.value.vals}).toList(),
        'p_having': _filters.entries.where((e) => measureFields.contains(e.key)).map((e) => {'measure': e.key, 'op': e.value.op, 'vals': e.value.vals}).toList(),
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
    if (!_isAdmin) { _snack('Only admins can save reports'); return; }
    final orgId = _orgId;
    if (orgId == null) { _snack('Not authenticated'); return; }

    // Load the org's users once, for the "Selected users" audience picker.
    List<Map<String, dynamic>> users = [];
    try {
      final rows = await Supabase.instance.client
          .from('users').select('id, name').eq('org_id', orgId).order('name');
      users = List<Map<String, dynamic>>.from(rows);
    } catch (_) {}

    final nameCtrl = TextEditingController();
    String scope = 'admins'; // admins | all | selected
    final picked = <String>{};

    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (c, setS) => AlertDialog(
      title: const Text('Save report'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: 'Report name')),
        const SizedBox(height: 12),
        const Text('Who can see this report?', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        RadioListTile<String>(contentPadding: EdgeInsets.zero, dense: true, value: 'admins', groupValue: scope,
          onChanged: (v) => setS(() => scope = v!), title: const Text('Admins only', style: TextStyle(fontSize: 13))),
        RadioListTile<String>(contentPadding: EdgeInsets.zero, dense: true, value: 'all', groupValue: scope,
          onChanged: (v) => setS(() => scope = v!), title: const Text('All users', style: TextStyle(fontSize: 13))),
        RadioListTile<String>(contentPadding: EdgeInsets.zero, dense: true, value: 'selected', groupValue: scope,
          onChanged: (v) => setS(() => scope = v!), title: const Text('Selected users', style: TextStyle(fontSize: 13))),
        if (scope == 'selected') ...[
          const SizedBox(height: 4),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
            child: users.isEmpty
                ? const Padding(padding: EdgeInsets.all(12), child: Text('No other users found', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                : ListView(shrinkWrap: true, children: [
                    for (final u in users)
                      CheckboxListTile(
                        dense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        value: picked.contains(u['id'] as String),
                        onChanged: (v) => setS(() { final id = u['id'] as String; if (v == true) picked.add(id); else picked.remove(id); }),
                        title: Text((u['name'] as String?) ?? (u['id'] as String), style: const TextStyle(fontSize: 13)),
                      ),
                  ]),
          ),
        ],
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary), child: const Text('Save')),
      ],
    )));
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    if (scope == 'selected' && picked.isEmpty) { _snack('Pick at least one user, or choose another audience'); return; }

    final id = 'rpt_${DateTime.now().millisecondsSinceEpoch}';
    try {
      await Supabase.instance.client.from('report_templates').insert({
        'id': id, 'org_id': orgId, 'name': nameCtrl.text.trim(), 'source': _source,
        // is_shared kept for backward-compat: true when everyone can see it.
        'is_shared': scope == 'all', 'share_scope': scope,
        'created_by': ref.read(currentUserProvider)?.id,
        'config': {
          'rows': _rows, 'cols': _cols, 'values': _values, 'filters': _filters.map((k, v) => MapEntry(k, {'op': v.op, 'vals': v.vals})), 'view': _view,
          'date_from': _dateFrom != null ? DateFormat('yyyy-MM-dd').format(_dateFrom!) : null,
          'date_to': _dateTo != null ? DateFormat('yyyy-MM-dd').format(_dateTo!) : null,
        },
      });
      if (scope == 'selected' && picked.isNotEmpty) {
        await Supabase.instance.client.from('report_template_shares').insert([
          for (final uid in picked) {'template_id': id, 'user_id': uid, 'org_id': orgId},
        ]);
      }
      _snack('Report saved');
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
      _filters.clear();
      final rawF = cfg['filters'];
      if (rawF is Map) {
        rawF.forEach((k, v) {
          if (v is Map) {
            final op = (v['op'] as String?) ?? 'in';
            final vals = (v['vals'] is List) ? List<String>.from((v['vals'] as List).map((e) => e.toString())) : <String>[];
            _filters[k.toString()] = _Cond(op, vals);
          } else if (v is List) {
            _filters[k.toString()] = _Cond('in', v.map((e) => e.toString()).toList());
          } else if (v != null) {
            _filters[k.toString()] = _Cond('eq', [v.toString()]);
          }
        });
      }
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
        DropdownButton<String>(value: _sources.any((s) => s['source_key'] == _source) ? _source : null, underline: const SizedBox(),
          hint: const Text('Source'),
          items: _sources.map((s) => DropdownMenuItem(value: s['source_key'] as String, child: Text(s['label'] as String))).toList(),
          onChanged: (v) { if (v != null) _resetForSource(v); }),
        _dateBtn('From', _dateFrom, () => _pickDate(true), () => setState(() => _dateFrom = null)),
        _dateBtn('To', _dateTo, () => _pickDate(false), () => setState(() => _dateTo = null)),
        PopupMenuButton<String>(
          tooltip: 'Quick date range',
          onSelected: (v) => setState(() {
            final now = DateTime.now();
            switch (v) {
              case 'l7': _dateTo = now; _dateFrom = now.subtract(const Duration(days: 7)); break;
              case 'l30': _dateTo = now; _dateFrom = now.subtract(const Duration(days: 30)); break;
              case 'l90': _dateTo = now; _dateFrom = now.subtract(const Duration(days: 90)); break;
              case 'mtd': _dateFrom = DateTime(now.year, now.month, 1); _dateTo = now; break;
              case 'ytd': _dateFrom = DateTime(now.year, 1, 1); _dateTo = now; break;
              case 'clear': _dateFrom = null; _dateTo = null; break;
            }
          }),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'l7', child: Text('Last 7 days')),
            PopupMenuItem(value: 'l30', child: Text('Last 30 days')),
            PopupMenuItem(value: 'l90', child: Text('Last 90 days')),
            PopupMenuItem(value: 'mtd', child: Text('This month')),
            PopupMenuItem(value: 'ytd', child: Text('This year')),
            PopupMenuItem(value: 'clear', child: Text('Clear dates')),
          ],
          child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.history, size: 14, color: AppTheme.textSecondary), SizedBox(width: 4), Icon(Icons.arrow_drop_down, size: 16, color: AppTheme.textSecondary)])),
        ),
        ElevatedButton.icon(onPressed: _running ? null : _run,
          icon: _running ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.play_arrow, size: 18),
          label: const Text('Run'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
        ToggleButtons(isSelected: [_view == 'table', _view == 'pivot', _view == 'chart'],
          onPressed: (i) => setState(() => _view = i == 0 ? 'table' : i == 1 ? 'pivot' : 'chart'),
          borderRadius: BorderRadius.circular(8), constraints: const BoxConstraints(minHeight: 34, minWidth: 58),
          children: const [Text('Table'), Text('Pivot'), Text('Chart')]),
        if (_view == 'chart') DropdownButton<String>(value: _chartType, underline: const SizedBox(),
          items: const [DropdownMenuItem(value: 'bar', child: Text('Bar')), DropdownMenuItem(value: 'line', child: Text('Line')), DropdownMenuItem(value: 'pie', child: Text('Pie'))],
          onChanged: (v) { if (v != null) setState(() => _chartType = v); }),
        if (_isAdmin) OutlinedButton.icon(onPressed: _saveTemplate, icon: const Icon(Icons.bookmark_add_outlined, size: 16), label: const Text('Save')),
        OutlinedButton.icon(onPressed: _result.isEmpty ? null : _export, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
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
    final q = _fieldSearch.trim().toLowerCase();
    final dims = q.isEmpty ? _dims : _dims.where((m) => (m['label'] as String).toLowerCase().contains(q)).toList();
    final measures = q.isEmpty ? _measures : _measures.where((m) => (m['label'] as String).toLowerCase().contains(q)).toList();
    return Container(
      decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
      child: SingleChildScrollView(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _zone('Rows', _rows, AppTheme.primary, 'Group results down the page'),
        _zone('Columns', _cols, Colors.teal, 'Spread results across the page'),
        _zone('Values', _values, Colors.deepPurple, 'Numbers to total'),
        _filterZone(),
        const Divider(height: 24),
        // Field search — the lists can be long; this narrows them fast.
        TextField(
          decoration: const InputDecoration(hintText: 'Search fields…', prefixIcon: Icon(Icons.search, size: 16), isDense: true),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) => setState(() => _fieldSearch = v),
        ),
        const SizedBox(height: 6),
        // Legend so the R / C / Σ / filter buttons aren't cryptic.
        Wrap(spacing: 10, runSpacing: 2, children: const [
          _LegendChip('R', 'Rows'), _LegendChip('C', 'Columns'),
          _LegendChip('Σ', 'Values'), _LegendChip('⏷', 'Filter'),
        ]),
        const SizedBox(height: 10),
        const Text('Dimensions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        if (dims.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('No matching fields', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        ...dims.map((m) => _dimRow(m['field'] as String, m['label'] as String)),
        const SizedBox(height: 14),
        const Text('Measures', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        if (measures.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text('No matching fields', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        ...measures.map((m) => _measureRow(m['field'] as String, m['label'] as String)),
      ])),
    );
  }

  Widget _zone(String title, List<String> items, Color c, [String? hint]) {
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      const SizedBox(height: 4),
      Container(width: double.infinity, constraints: const BoxConstraints(minHeight: 36), padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: c.withOpacity(0.05), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.25))),
        child: items.isEmpty ? Text(hint ?? '—', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))
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
          : Wrap(spacing: 4, runSpacing: 4, children: _filters.entries.map((e) {
              final cond = e.value;
              final opl = _opLabels[cond.op] ?? cond.op;
              final valStr = _opNoValue(cond.op) ? '' : (cond.vals.length <= 2 ? cond.vals.join(cond.op == 'between' ? ' – ' : ', ') : '${cond.vals.length} selected');
              return Chip(
                label: Text('${_label(e.key)} $opl${valStr.isEmpty ? '' : ' $valStr'}', style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onDeleted: () => setState(() => _filters.remove(e.key)),
              );
            }).toList())),
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
      IconButton(icon: const Icon(Icons.filter_alt_outlined, size: 16), tooltip: 'Filter measure (after totals)', visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 26, minHeight: 26), onPressed: () => _addFilter(field)),
    ]));
  }

  Widget _miniBtn(String t, String tip, VoidCallback onTap) => Tooltip(message: tip, child: InkWell(onTap: onTap,
    child: Container(margin: const EdgeInsets.only(left: 2), width: 24, height: 24, alignment: Alignment.center,
      decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(5), border: Border.all(color: AppTheme.border)),
      child: Text(t, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))));

  Widget _resultsPanel() {
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Query error:\n$_error', style: const TextStyle(color: Colors.red))));
    if (_result.isEmpty) return _emptyState();
    return Padding(padding: const EdgeInsets.all(16), child: _view == 'pivot' ? _pivot() : _view == 'chart' ? _chart() : _table());
  }

  // Guided empty state: a short how-to plus one-click "quick starts" that fill
  // Rows + Values and run, so a new user gets a real report without knowing the
  // cube model. Quick starts adapt to whatever fields the source actually has.
  Widget _emptyState() {
    final presets = _presetButtons();
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.insights_outlined, size: 40, color: AppTheme.textSecondary),
      const SizedBox(height: 12),
      const Text('Build a report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const SizedBox(width: 420, child: Text(
        'Pick a field to group by (add it to Rows), a number to total (Values), then press Run. '
        'Use Columns to break the numbers out sideways, and Filters to narrow the data.',
        textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))),
      if (presets.isNotEmpty) ...[
        const SizedBox(height: 20),
        const Text('Quick starts', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        SizedBox(width: 460, child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: presets)),
      ],
    ])));
  }

  // Preferred measure for a quick start: the most "headline" number available.
  String? _preferredMeasure() {
    if (_measures.isEmpty) return null;
    const pri = ['net', 'sales', 'amount', 'total', 'value', 'qty', 'quantity'];
    for (final p in pri) {
      final m = _measures.firstWhere((x) => (x['label'] as String).toLowerCase().contains(p), orElse: () => <String, dynamic>{});
      if (m.isNotEmpty) return m['field'] as String;
    }
    return _measures.first['field'] as String;
  }

  List<Widget> _presetButtons() {
    final mf = _preferredMeasure();
    if (mf == null) return [];
    const wanted = ['Customer', 'Product', 'Branch', 'Supplier', 'Date', 'Group'];
    final out = <Widget>[];
    for (final label in wanted) {
      final d = _dims.firstWhere((x) => (x['label'] as String).toLowerCase() == label.toLowerCase(), orElse: () => <String, dynamic>{});
      if (d.isEmpty) continue;
      final df = d['field'] as String;
      out.add(OutlinedButton.icon(
        icon: const Icon(Icons.bolt_outlined, size: 15),
        label: Text('${_label(mf)} by $label', style: const TextStyle(fontSize: 12)),
        onPressed: () => _applyPreset(df, mf),
      ));
    }
    return out;
  }

  void _applyPreset(String dimField, String measureField) {
    setState(() {
      _rows..clear()..add(dimField);
      _cols.clear();
      _values..clear()..add(measureField);
      _view = 'table';
    });
    _run();
  }

  num _sumMeasure(Iterable<Map<String, dynamic>> rows, String m) {
    num s = 0;
    for (final r in rows) {
      final v = r[m];
      if (v is num) s += v;
    }
    return s;
  }

  Widget _table() {
    final dims = [..._rows, ..._cols];
    final cols = [...dims, ..._values];

    // Sort a display copy by the dimensions so each group is contiguous — that
    // lets us drop a subtotal row after every group, plus a grand total.
    final data = [..._result];
    if (dims.isNotEmpty) {
      data.sort((a, b) {
        for (final d in dims) {
          final c = (a[d]?.toString() ?? '').compareTo(b[d]?.toString() ?? '');
          if (c != 0) return c;
        }
        return 0;
      });
    }

    DataRow dataRow(Map<String, dynamic> r) => DataRow(cells: cols.map((c) {
          final isMeasure = _values.contains(c);
          final v = r[c];
          return DataCell(Text(isMeasure ? _fmt(v as num?) : (v?.toString() ?? '(none)'), style: const TextStyle(fontSize: 12)));
        }).toList());

    DataRow totalRow(String label, Iterable<Map<String, dynamic>> group, {required bool grand}) {
      final weight = grand ? FontWeight.w800 : FontWeight.w700;
      final cells = <DataCell>[];
      for (var i = 0; i < dims.length; i++) {
        cells.add(DataCell(Text(i == 0 ? label : '', style: TextStyle(fontSize: 12, fontWeight: weight))));
      }
      if (dims.isEmpty) {
        cells.add(DataCell(Text(label, style: TextStyle(fontSize: 12, fontWeight: weight))));
      }
      for (var j = 0; j < _values.length; j++) {
        final m = _values[j];
        // When there are no dimension columns, the label already used the first
        // measure cell — keep alignment by leaving that first measure blank.
        if (dims.isEmpty && j == 0) { cells.add(const DataCell(Text(''))); continue; }
        cells.add(DataCell(Text(_fmt(_sumMeasure(group, m)), style: TextStyle(fontSize: 12, fontWeight: weight))));
      }
      return DataRow(
        color: MaterialStateProperty.all(grand ? AppTheme.background : AppTheme.background.withOpacity(0.45)),
        cells: cells,
      );
    }

    final rows = <DataRow>[];
    final groupDim = _rows.isNotEmpty ? _rows.first : (dims.isNotEmpty ? dims.first : null);
    if (groupDim != null && _values.isNotEmpty) {
      final groups = <String, List<Map<String, dynamic>>>{};
      final order = <String>[];
      for (final r in data) {
        final k = r[groupDim]?.toString() ?? '(none)';
        (groups[k] ??= []).add(r);
        if (!order.contains(k)) order.add(k);
      }
      final showSub = order.length > 1; // one group == subtotal duplicates grand
      for (final k in order) {
        final g = groups[k]!;
        for (final r in g) rows.add(dataRow(r));
        if (showSub) rows.add(totalRow('$k  ·  subtotal', g, grand: false));
      }
    } else {
      for (final r in data) rows.add(dataRow(r));
    }
    if (_values.isNotEmpty) rows.add(totalRow('Grand total', data, grand: true));

    return SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: DataTable(
        headingRowHeight: 42, dataRowMinHeight: 38, dataRowMaxHeight: 48,
        columns: cols.map((c) => DataColumn(label: Text(_label(c), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), numeric: _values.contains(c))).toList(),
        rows: rows,
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

  // ---------- chart ----------
  List<MapEntry<String, double>> _chartSeries() {
    final all = [..._rows, ..._cols];
    final catDim = _rows.isNotEmpty ? _rows.first : (all.isNotEmpty ? all.first : null);
    final measure = _values.isNotEmpty ? _values.first : null;
    if (catDim == null || measure == null) return [];
    final Map<String, double> agg = {};
    for (final r in _result) {
      final cat = r[catDim]?.toString() ?? '(none)';
      agg[cat] = (agg[cat] ?? 0) + ((r[measure] as num?)?.toDouble() ?? 0);
    }
    final list = agg.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  static const _palette = [Color(0xFF4F46E5), Color(0xFF059669), Color(0xFFD97706), Color(0xFFDC2626), Color(0xFF0891B2), Color(0xFF7C3AED), Color(0xFFDB2777), Color(0xFF65A30D)];

  Widget _chart() {
    final all = [..._rows, ..._cols];
    final catDim = _rows.isNotEmpty ? _rows.first : (all.isNotEmpty ? all.first : null);
    final measure = _values.isNotEmpty ? _values.first : null;
    if (catDim == null || measure == null) {
      return const Center(child: Text('Charts need at least one Row (category) and one Value.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary)));
    }
    final series = _chartSeries();
    if (series.isEmpty) return const Center(child: Text('No data to chart.', style: TextStyle(color: AppTheme.textSecondary)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_label(measure)} by ${_label(catDim)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Expanded(child: Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        child: _chartType == 'pie' ? _pie(series) : _chartType == 'line' ? _line(series) : _bars(series))),
    ]);
  }

  Widget _bars(List<MapEntry<String, double>> series) {
    final shown = series.take(25).toList();
    final maxV = shown.fold<double>(0, (m, e) => e.value > m ? e.value : m);
    return ListView(children: shown.map((e) {
      final frac = maxV > 0 ? (e.value / maxV) : 0.0;
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
        SizedBox(width: 160, child: Text(e.key, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
        Expanded(child: Stack(children: [
          Container(height: 18, decoration: BoxDecoration(color: const Color(0xFFEDEFF2), borderRadius: BorderRadius.circular(4))),
          FractionallySizedBox(widthFactor: frac <= 0 ? 0.001 : frac, child: Container(height: 18, decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(4)))),
        ])),
        SizedBox(width: 96, child: Text(_fmt(e.value), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
      ]));
    }).toList());
  }

  Widget _line(List<MapEntry<String, double>> series) => CustomPaint(painter: _LinePainter(series.take(40).toList()), child: const SizedBox.expand());

  Widget _pie(List<MapEntry<String, double>> series) {
    final sorted = [...series];
    List<MapEntry<String, double>> slices;
    if (sorted.length > 8) {
      final other = sorted.skip(7).fold<double>(0, (s, e) => s + e.value);
      slices = [...sorted.take(7), MapEntry('Other', other)];
    } else { slices = sorted; }
    final total = slices.fold<double>(0, (s, e) => s + e.value);
    return Row(children: [
      Expanded(flex: 2, child: CustomPaint(painter: _PiePainter(slices, total, _palette), child: const SizedBox.expand())),
      const SizedBox(width: 16),
      Expanded(flex: 1, child: ListView(children: [
        for (var i = 0; i < slices.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
          Container(width: 12, height: 12, color: _palette[i % _palette.length]), const SizedBox(width: 6),
          Expanded(child: Text(slices[i].key, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis)),
          Text(total > 0 ? '${(slices[i].value / total * 100).toStringAsFixed(1)}%' : '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ])),
      ])),
    ]);
  }

  // ---------- export / print ----------
  String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _export() {
    final sourceLabel = (_sources.firstWhere((s) => s['source_key'] == _source, orElse: () => {'label': _source})['label']) as String;
    final dims = [..._rows, ..._cols];
    final buf = StringBuffer();
    buf.write('<!doctype html><html><head><meta charset="utf-8"><title>Report — ${_esc(sourceLabel)}</title>');
    buf.write('<style>body{font-family:Arial,Helvetica,sans-serif;margin:24px;color:#1a1a1a}'
        'h1{font-size:18px;margin:0 0 4px}.meta{font-size:12px;color:#555;margin-bottom:14px}'
        'table{border-collapse:collapse;width:100%;font-size:12px}'
        'th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}th{background:#f3f4f6}'
        'td.num,th.num{text-align:right}tr.total td{font-weight:700;background:#fafafa}'
        '.foot{margin-top:18px;font-size:11px;color:#666;border-top:1px solid #eee;padding-top:8px}'
        '.no-print{margin-bottom:14px}@media print{.no-print{display:none}}</style></head><body>');
    buf.write('<div class="no-print"><button onclick="window.print()">&#x1F5A8; Print / Save as PDF</button></div>');
    buf.write('<h1>${_esc(sourceLabel)} Report</h1>');
    final parts = <String>[];
    if (_rows.isNotEmpty) parts.add('Rows: ${_rows.map(_label).join(', ')}');
    if (_cols.isNotEmpty) parts.add('Columns: ${_cols.map(_label).join(', ')}');
    if (_values.isNotEmpty) parts.add('Values: ${_values.map(_label).join(', ')}');
    if (_filters.isNotEmpty) parts.add('Filters: ${_filters.entries.map((e) {
      final opl = _opLabels[e.value.op] ?? e.value.op;
      final vs = _opNoValue(e.value.op) ? '' : ' ${e.value.vals.join(', ')}';
      return '${_label(e.key)} $opl$vs';
    }).join('; ')}');
    if (_dateFrom != null || _dateTo != null) parts.add('Period: ${_dateFrom != null ? DateFormat('d MMM yyyy').format(_dateFrom!) : '…'} – ${_dateTo != null ? DateFormat('d MMM yyyy').format(_dateTo!) : '…'}');
    buf.write('<div class="meta">${_esc(parts.join('  •  '))}</div>');

    if (_view == 'pivot' && _rows.isNotEmpty && _values.isNotEmpty) {
      buf.write(_crosstabHtml());
    } else {
      final cols = [...dims, ..._values];
      // Sort by dimensions so groups are contiguous for subtotals (mirrors the
      // on-screen Table view).
      final data = [..._result];
      if (dims.isNotEmpty) {
        data.sort((a, b) {
          for (final d in dims) {
            final c = (a[d]?.toString() ?? '').compareTo(b[d]?.toString() ?? '');
            if (c != 0) return c;
          }
          return 0;
        });
      }
      void totalTr(String label, Iterable<Map<String, dynamic>> group) {
        buf.write('<tr class="total">');
        for (var i = 0; i < dims.length; i++) {
          buf.write('<td>${i == 0 ? _esc(label) : ''}</td>');
        }
        if (dims.isEmpty) buf.write('<td>${_esc(label)}</td>');
        for (var j = 0; j < _values.length; j++) {
          if (dims.isEmpty && j == 0) { buf.write('<td class="num"></td>'); continue; }
          buf.write('<td class="num">${_esc(_fmt(_sumMeasure(group, _values[j])))}</td>');
        }
        buf.write('</tr>');
      }

      buf.write('<table><thead><tr>');
      for (final c in cols) buf.write('<th class="${_values.contains(c) ? 'num' : ''}">${_esc(_label(c))}</th>');
      buf.write('</tr></thead><tbody>');
      final groupDim = _rows.isNotEmpty ? _rows.first : (dims.isNotEmpty ? dims.first : null);
      void writeRow(Map<String, dynamic> r) {
        buf.write('<tr>');
        for (final c in cols) {
          final isM = _values.contains(c);
          buf.write('<td class="${isM ? 'num' : ''}">${_esc(isM ? _fmt(r[c] as num?) : (r[c]?.toString() ?? '(none)'))}</td>');
        }
        buf.write('</tr>');
      }
      if (groupDim != null && _values.isNotEmpty) {
        final groups = <String, List<Map<String, dynamic>>>{};
        final order = <String>[];
        for (final r in data) {
          final k = r[groupDim]?.toString() ?? '(none)';
          (groups[k] ??= []).add(r);
          if (!order.contains(k)) order.add(k);
        }
        final showSub = order.length > 1;
        for (final k in order) {
          for (final r in groups[k]!) writeRow(r);
          if (showSub) totalTr('$k  ·  subtotal', groups[k]!);
        }
      } else {
        for (final r in data) writeRow(r);
      }
      if (_values.isNotEmpty) totalTr('Grand total', data);
      buf.write('</tbody></table>');
    }

    final ts = DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());
    buf.write('<div class="foot">Created by ${_esc(_userName.isEmpty ? '—' : _userName)} &nbsp;•&nbsp; Created at $ts</div>');
    buf.write('</body></html>');

    final blob = html.Blob([buf.toString()], 'text/html;charset=utf-8');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  String _crosstabHtml() {
    final measure = _values.first;
    final rowKeys = <String>[]; final colKeys = <String>[];
    final Map<String, List<String>> rowParts = {};
    final Map<String, Map<String, num>> cell = {};
    for (final r in _result) {
      final rk = _rows.map((d) => (r[d]?.toString() ?? '(none)')).toList();
      final ck = _cols.map((d) => (r[d]?.toString() ?? '(none)')).toList();
      final rKey = rk.join('\u0001'); final cKey = ck.join('\u0001');
      if (!rowKeys.contains(rKey)) { rowKeys.add(rKey); rowParts[rKey] = rk; }
      if (!colKeys.contains(cKey)) colKeys.add(cKey);
      (cell[rKey] ??= {})[cKey] = ((cell[rKey]?[cKey]) ?? 0) + ((r[measure] as num?) ?? 0);
    }
    rowKeys.sort(); colKeys.sort();
    String colLabel(String c) => _cols.isEmpty ? _label(measure) : c.split('\u0001').join(' / ');
    final b = StringBuffer('<table><thead><tr>');
    for (final d in _rows) b.write('<th>${_esc(_label(d))}</th>');
    for (final ck in colKeys) b.write('<th class="num">${_esc(colLabel(ck))}</th>');
    b.write('<th class="num">Total</th></tr></thead><tbody>');
    num grand = 0; final Map<String, num> colTot = {for (final ck in colKeys) ck: 0};
    for (final rKey in rowKeys) {
      num rt = 0; b.write('<tr>');
      for (final p in rowParts[rKey]!) b.write('<td>${_esc(p)}</td>');
      for (final ck in colKeys) {
        final v = cell[rKey]?[ck];
        if (v != null) { rt += v; colTot[ck] = (colTot[ck] ?? 0) + v; }
        b.write('<td class="num">${v == null ? '–' : _esc(_fmt(v))}</td>');
      }
      b.write('<td class="num">${_esc(_fmt(rt))}</td></tr>'); grand += rt;
    }
    b.write('<tr class="total">');
    for (var i = 0; i < _rows.length; i++) b.write('<td>${i == 0 ? 'Total' : ''}</td>');
    for (final ck in colKeys) b.write('<td class="num">${_esc(_fmt(colTot[ck]))}</td>');
    b.write('<td class="num">${_esc(_fmt(grand))}</td></tr></tbody></table>');
    return b.toString();
  }
}

class _Cond {
  String op;
  List<String> vals;
  _Cond(this.op, this.vals);
}

/// Tiny legend entry explaining a field-row action button (R / C / Σ / filter).
class _LegendChip extends StatelessWidget {
  final String symbol;
  final String meaning;
  const _LegendChip(this.symbol, this.meaning);
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 18, height: 18, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppTheme.border),
        ),
        child: Text(symbol, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
      ),
      const SizedBox(width: 4),
      Text(meaning, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
    ]);
  }
}

class _FilterResult {
  final String? op;
  final List<String>? vals;
  final bool clear;
  const _FilterResult({this.op, this.vals, this.clear = false});
}

class _LinePainter extends CustomPainter {
  final List<MapEntry<String, double>> data;
  _LinePainter(this.data);
  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final maxV = data.fold<double>(0, (m, e) => e.value > m ? e.value : m);
    const padL = 8.0, padR = 8.0, padT = 8.0, padB = 8.0;
    final w = size.width - padL - padR, h = size.height - padT - padB;
    canvas.drawLine(Offset(padL, padT + h), Offset(padL + w, padT + h), Paint()..color = const Color(0xFFE0E0E0)..strokeWidth = 1);
    final n = data.length;
    Offset pt(int i) {
      final x = padL + (n == 1 ? w / 2 : w * i / (n - 1));
      final y = padT + h - (maxV > 0 ? data[i].value / maxV * h : 0);
      return Offset(x, y);
    }
    final path = Path();
    for (var i = 0; i < n; i++) { final p = pt(i); if (i == 0) path.moveTo(p.dx, p.dy); else path.lineTo(p.dx, p.dy); }
    canvas.drawPath(path, Paint()..color = const Color(0xFF4F46E5)..strokeWidth = 2..style = PaintingStyle.stroke);
    final dot = Paint()..color = const Color(0xFF4F46E5);
    for (var i = 0; i < n; i++) canvas.drawCircle(pt(i), 3, dot);
  }
  @override
  bool shouldRepaint(covariant _LinePainter o) => o.data != data;
}

class _PiePainter extends CustomPainter {
  final List<MapEntry<String, double>> slices; final num total; final List<Color> palette;
  _PiePainter(this.slices, this.total, this.palette);
  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final r = (size.shortestSide / 2) - 6;
    final c = Offset(size.width / 2, size.height / 2);
    double start = -1.5708;
    for (var i = 0; i < slices.length; i++) {
      final sweep = (slices[i].value / total) * 6.28318;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, true, Paint()..color = palette[i % palette.length]..style = PaintingStyle.fill);
      start += sweep;
    }
  }
  @override
  bool shouldRepaint(covariant _PiePainter o) => o.slices != slices;
}
