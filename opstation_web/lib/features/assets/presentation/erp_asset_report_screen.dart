// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Asset Report (Management ▸ Asset Report, permission /assets/report).
/// Search + filter the register by category, custodian, condition, branch and
/// status; optionally group by any of them (with counts and cost sub-totals);
/// print / save as PDF exactly what is on screen.
class ErpAssetReportScreen extends ConsumerStatefulWidget {
  const ErpAssetReportScreen({super.key});
  @override
  ConsumerState<ErpAssetReportScreen> createState() => _State();
}

class _State extends ConsumerState<ErpAssetReportScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _assets = [];
  final Map<String, String> _cat = {}, _branch = {}, _cust = {};
  List<String> _statusOrder = [], _condOrder = [];

  final _search = TextEditingController();
  String _fCat = 'all', _fCust = 'all', _fCond = 'all', _fBranch = 'all', _fStatus = 'all', _fMaint = 'all';

  static const _maintOpts = {
    'all': 'All maintenance',
    'overdue': 'Overdue',
    'due14': 'Due in 14 days (incl. overdue)',
    'due30': 'Due in 30 days (incl. overdue)',
    'later': 'Due after 30 days',
    'scheduled': 'Any date scheduled',
    'none': 'Not scheduled',
  };

  /// Days from today to next_maintenance_due (negative = overdue), or null.
  int? _maintDays(Map a) {
    final d = DateTime.tryParse('${a['next_maintenance_due'] ?? ''}');
    if (d == null) return null;
    final now = DateTime.now();
    return DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  }

  bool _maintMatch(Map a) {
    if (_fMaint == 'all') return true;
    final n = _maintDays(a);
    switch (_fMaint) {
      case 'overdue': return n != null && n < 0;
      case 'due14': return n != null && n <= 14;
      case 'due30': return n != null && n <= 30;
      case 'later': return n != null && n > 30;
      case 'scheduled': return n != null;
      case 'none': return n == null;
    }
    return true;
  }
  String _group = 'category'; // none | category | custodian | condition | branch | status

  static const _groups = {
    'none': 'No grouping',
    'category': 'Category',
    'custodian': 'Custodian',
    'condition': 'Condition',
    'branch': 'Branch',
    'status': 'Status',
  };

  final _money = NumberFormat('#,##0');

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static String _label(String? s) {
    final t = (s ?? '').replaceAll('_', ' ').trim();
    return t.isEmpty ? '—' : t[0].toUpperCase() + t.substring(1);
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = Supabase.instance.client;
      final res = await Future.wait([
        c.from('assets').select().eq('org_id', orgId).eq('is_active', true).order('asset_code'),
        c.from('asset_categories').select('id, name').eq('org_id', orgId),
        c.from('branches').select('id, name').eq('org_id', orgId),
        c.from('asset_custodians').select('id, name').eq('org_id', orgId),
        c.from('app_config').select('key, value').eq('org_id', orgId)
            .inFilter('key', ['org.asset_statuses', 'org.asset_conditions']),
      ]);
      _assets = List<Map<String, dynamic>>.from(res[0] as List);
      _cat..clear()..addEntries((res[1] as List).map((r) => MapEntry('${r['id']}', '${r['name'] ?? ''}')));
      _branch..clear()..addEntries((res[2] as List).map((r) => MapEntry('${r['id']}', '${r['name'] ?? ''}')));
      _cust..clear()..addEntries((res[3] as List).map((r) => MapEntry('${r['id']}', '${r['name'] ?? ''}')));
      _statusOrder = [];
      _condOrder = [];
      for (final r in res[4] as List) {
        try {
          final l = List<String>.from(jsonDecode('${r['value']}') as List);
          if (r['key'] == 'org.asset_statuses') _statusOrder = l;
          if (r['key'] == 'org.asset_conditions') _condOrder = l;
        } catch (_) {}
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().split('\n').first;
        });
      }
    }
  }

  // ── derived ────────────────────────────────────────────────────────────
  String _catOf(Map a) => _cat[a['category_id']] ?? 'Uncategorised';
  String _branchOf(Map a) => _branch[a['branch_id']] ?? 'No branch';
  String _custOf(Map a) => _cust[a['assigned_to']] ?? 'Unassigned';
  String _condOf(Map a) => a['condition'] == null ? 'Not set' : _label(a['condition'] as String?);
  String _statusOf(Map a) => _label(a['status'] as String?);

  List<Map<String, dynamic>> get _rows {
    final q = _search.text.trim().toLowerCase();
    return _assets.where((a) {
      if (_fCat != 'all' && '${a['category_id']}' != _fCat) return false;
      if (_fCust != 'all' && (_fCust == '__none' ? a['assigned_to'] != null : '${a['assigned_to']}' != _fCust)) return false;
      if (_fCond != 'all' && (_fCond == '__none' ? a['condition'] != null : '${a['condition']}' != _fCond)) return false;
      if (_fBranch != 'all' && (_fBranch == '__none' ? a['branch_id'] != null : '${a['branch_id']}' != _fBranch)) return false;
      if (_fStatus != 'all' && '${a['status']}' != _fStatus) return false;
      if (!_maintMatch(a)) return false;
      if (q.isEmpty) return true;
      final hay = [a['asset_code'], a['name'], a['serial_no'], a['model'], a['manufacturer'], a['notes'],
              a['location_text'], _catOf(a), _custOf(a), _branchOf(a)]
          .whereType<Object>()
          .join(' ')
          .toLowerCase();
      return q.split(RegExp(r'\s+')).every(hay.contains);
    }).toList();
  }

  String _groupKey(Map a) {
    switch (_group) {
      case 'category': return _catOf(a);
      case 'custodian': return _custOf(a);
      case 'condition': return _condOf(a);
      case 'branch': return _branchOf(a);
      case 'status': return _statusOf(a);
      default: return '';
    }
  }

  /// Groups in a sensible order: configured order for status / condition,
  /// alphabetical otherwise, "none"-type buckets last.
  List<MapEntry<String, List<Map<String, dynamic>>>> _grouped(List<Map<String, dynamic>> rows) {
    final m = <String, List<Map<String, dynamic>>>{};
    for (final a in rows) {
      m.putIfAbsent(_groupKey(a), () => []).add(a);
    }
    int rank(String k) {
      final order = _group == 'status' ? _statusOrder : _group == 'condition' ? _condOrder : const <String>[];
      final i = order.map(_label).toList().indexOf(k);
      return i < 0 ? 999 : i;
    }
    bool last(String k) => k == 'Unassigned' || k == 'No branch' || k == 'Uncategorised' || k == 'Not set';
    final keys = m.keys.toList()
      ..sort((a, b) {
        if (last(a) != last(b)) return last(a) ? 1 : -1;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.toLowerCase().compareTo(b.toLowerCase());
      });
    return [for (final k in keys) MapEntry(k, m[k]!)];
  }

  double _cost(Iterable<Map<String, dynamic>> rows) =>
      rows.fold(0.0, (s, a) => s + ((a['purchase_cost'] as num?)?.toDouble() ?? 0));

  String _date(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : DateFormat('d MMM yyyy').format(d);
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  Widget _dd(String label, String value, Map<String, String> items, ValueChanged<String> on, {double w = 190}) {
    return SizedBox(
      width: w,
      child: DropdownButtonFormField<String>(
        value: items.containsKey(value) ? value : 'all',
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => on(v ?? 'all'),
      ),
    );
  }

  Map<String, String> _sorted(Map<String, String> m) {
    final e = m.entries.toList()..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return {for (final x in e) x.key: x.value};
  }

  List<String> _present(String field, List<String> order) {
    final vals = {for (final a in _assets) if (a[field] != null) '${a[field]}'};
    return [...order.where(vals.contains), ...vals.where((v) => !order.contains(v))];
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    final rows = _rows;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Asset Report', style: TextStyle(fontSize: narrow ? 22 : 28, fontWeight: FontWeight.w800)),
          if (!_loading)
            Text('${rows.length} of ${_assets.length} assets · Rs ${_money.format(_cost(rows))}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          ElevatedButton.icon(
            onPressed: _loading || rows.isEmpty ? null : () => _print(rows),
            icon: const Icon(Icons.print_outlined, size: 16),
            label: const Text('Print / PDF'),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.end, children: [
          SizedBox(
            width: narrow ? double.infinity : 280,
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search code, name, serial, notes…', isDense: true),
            ),
          ),
          _dd('Category', _fCat, {'all': 'All categories', ..._sorted(_cat)}, (v) => setState(() => _fCat = v)),
          _dd('Custodian', _fCust, {'all': 'All custodians', '__none': 'Unassigned', ..._sorted(_cust)}, (v) => setState(() => _fCust = v)),
          _dd('Condition', _fCond, {'all': 'All conditions', '__none': 'Not set', for (final c in _present('condition', _condOrder)) c: _label(c)},
              (v) => setState(() => _fCond = v), w: 160),
          _dd('Branch', _fBranch, {'all': 'All branches', '__none': 'No branch', ..._sorted({
                for (final a in _assets) if (a['branch_id'] != null) '${a['branch_id']}': _branchOf(a)})},
              (v) => setState(() => _fBranch = v)),
          _dd('Status', _fStatus, {'all': 'All statuses', for (final s in _present('status', _statusOrder)) s: _label(s)},
              (v) => setState(() => _fStatus = v), w: 160),
          _dd('Maintenance', _fMaint, _maintOpts, (v) => setState(() => _fMaint = v), w: 220),
          _dd('Group by', _group, _groups, (v) => setState(() => _group = v), w: 160),
          if (_search.text.isNotEmpty || [_fCat, _fCust, _fCond, _fBranch, _fStatus, _fMaint].any((x) => x != 'all'))
            TextButton.icon(
              onPressed: () => setState(() {
                _search.clear();
                _fCat = _fCust = _fCond = _fBranch = _fStatus = _fMaint = 'all';
              }),
              icon: const Icon(Icons.clear, size: 16),
              label: const Text('Clear'),
            ),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Could not load: $_error', style: const TextStyle(color: Colors.red)))
                  : rows.isEmpty
                      ? const Center(child: Text('No assets match', style: TextStyle(color: AppTheme.textSecondary)))
                      : _table(rows),
        ),
      ]),
    );
  }

  static const _cols = <(String, double, bool)>[
    ('Code', 90, false), ('Asset', 280, false), ('Category', 150, false), ('Branch', 140, false),
    ('Custodian', 150, false), ('Status', 120, false), ('Condition', 110, false),
    ('Serial / Model', 150, false), ('Cost', 100, true), ('Next service', 110, false),
  ];

  Widget _cell(String t, double w, {bool right = false, bool bold = false, Color? color}) => SizedBox(
        width: w,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(t,
              textAlign: right ? TextAlign.right : TextAlign.left,
              style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color)),
        ),
      );

  Widget _row(Map<String, dynamic> a) {
    final cost = (a['purchase_cost'] as num?)?.toDouble();
    final sm = [a['serial_no'], a['model']].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ');
    final vals = [
      '${a['asset_code'] ?? ''}', '${a['name'] ?? ''}', _catOf(a), _branchOf(a), _custOf(a), _statusOf(a), _condOf(a),
      sm, cost == null ? '' : _money.format(cost), _date(a['next_maintenance_due']),
    ];
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
      child: Row(children: [
        for (var i = 0; i < _cols.length; i++)
          _cell(vals[i], _cols[i].$2, right: _cols[i].$3, bold: i == 0, color: i == 0 ? AppTheme.primary : null),
      ]),
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) {
    final width = _cols.fold<double>(0, (s, c) => s + c.$2);
    final body = <Widget>[];
    if (_group == 'none') {
      body.addAll(rows.map(_row));
    } else {
      for (final g in _grouped(rows)) {
        body.add(Container(
          width: width,
          color: AppTheme.primary.withOpacity(0.07),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Text(g.key, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(width: 10),
            Text('${g.value.length} asset${g.value.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const Spacer(),
            if (_cost(g.value) > 0)
              Text('Rs ${_money.format(_cost(g.value))}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ));
        body.addAll(g.value.map(_row));
      }
    }
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(children: [
              Container(
                color: const Color(0xFFF5F5F5),
                child: Row(children: [for (final c in _cols) _cell(c.$1, c.$2, right: c.$3, bold: true)]),
              ),
              Expanded(child: ListView(children: body)),
              Container(
                color: const Color(0xFFF5F5F5),
                child: Row(children: [
                  _cell('Total', _cols[0].$2, bold: true),
                  _cell('${rows.length} assets', _cols[1].$2, bold: true),
                  for (var i = 2; i < 8; i++) _cell('', _cols[i].$2),
                  _cell(_money.format(_cost(rows)), _cols[8].$2, right: true, bold: true),
                  _cell('', _cols[9].$2),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── print / PDF ────────────────────────────────────────────────────────
  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  void _print(List<Map<String, dynamic>> rows) {
    final org = ref.read(currentUserProvider)?.orgName ?? '';
    final gen = DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());
    final filters = <String>[
      if (_search.text.trim().isNotEmpty) 'Search: “${_search.text.trim()}”',
      if (_fCat != 'all') 'Category: ${_cat[_fCat] ?? _fCat}',
      if (_fCust != 'all') 'Custodian: ${_fCust == '__none' ? 'Unassigned' : (_cust[_fCust] ?? _fCust)}',
      if (_fCond != 'all') 'Condition: ${_fCond == '__none' ? 'Not set' : _label(_fCond)}',
      if (_fBranch != 'all') 'Branch: ${_fBranch == '__none' ? 'No branch' : (_branch[_fBranch] ?? _fBranch)}',
      if (_fStatus != 'all') 'Status: ${_label(_fStatus)}',
      if (_fMaint != 'all') 'Maintenance: ${_maintOpts[_fMaint]}',
      if (_group != 'none') 'Grouped by ${_groups[_group]}',
    ];
    String tr(Map<String, dynamic> a) {
      final cost = (a['purchase_cost'] as num?)?.toDouble();
      final sm = [a['serial_no'], a['model']].whereType<String>().where((s) => s.trim().isNotEmpty).join(' · ');
      return '<tr><td class="code">${_esc('${a['asset_code'] ?? ''}')}</td><td>${_esc('${a['name'] ?? ''}')}'
          '${(a['notes'] as String?)?.trim().isNotEmpty == true ? '<div class="note">${_esc(a['notes'] as String)}</div>' : ''}</td>'
          '<td>${_esc(_catOf(a))}</td><td>${_esc(_branchOf(a))}</td><td>${_esc(_custOf(a))}</td>'
          '<td>${_esc(_statusOf(a))}</td><td>${_esc(_condOf(a))}</td><td>${_esc(sm)}</td>'
          '<td class="num">${cost == null ? '' : _money.format(cost)}</td><td>${_esc(_date(a['next_maintenance_due']))}</td></tr>';
    }

    final b = StringBuffer();
    if (_group == 'none') {
      for (final a in rows) {
        b.write(tr(a));
      }
    } else {
      for (final g in _grouped(rows)) {
        final c = _cost(g.value);
        b.write('<tr class="grp"><td colspan="8">${_esc(g.key)} <span>· ${g.value.length} asset${g.value.length == 1 ? '' : 's'}</span></td>'
            '<td class="num">${c > 0 ? _money.format(c) : ''}</td><td></td></tr>');
        for (final a in g.value) {
          b.write(tr(a));
        }
      }
    }
    final doc = '''<!doctype html><html><head><meta charset="utf-8"><title>Asset Report</title>
<style>
@page { size: A4 landscape; margin: 12mm; }
* { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: -apple-system, Segoe UI, Roboto, Arial, sans-serif; color: #0F1729; font-size: 10.5px; margin: 0; }
.head { display: flex; justify-content: space-between; align-items: flex-end; border-bottom: 2px solid #2F6FED; padding-bottom: 6px; margin-bottom: 8px; }
.org { font-size: 11px; color: #2F6FED; font-weight: 800; letter-spacing: 1px; text-transform: uppercase; }
h1 { font-size: 20px; margin: 2px 0 0; }
.meta { text-align: right; color: #6B7280; }
.filters { color: #374151; margin: 0 0 8px; }
table { width: 100%; border-collapse: collapse; }
th { background: #F3F4F6; text-align: left; padding: 5px 6px; font-size: 9.5px; text-transform: uppercase; letter-spacing: .4px; color: #374151; }
td { padding: 4px 6px; border-bottom: 1px solid #EEE; vertical-align: top; }
td.code { color: #2F6FED; font-weight: 700; white-space: nowrap; }
.num { text-align: right; white-space: nowrap; }
.note { color: #6B7280; font-size: 9px; }
tr.grp td { background: #EEF3FD; font-weight: 800; font-size: 11px; border-top: 1px solid #C7D7FB; }
tr.grp span { font-weight: 400; color: #6B7280; }
tr.tot td { background: #F3F4F6; font-weight: 800; }
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
.foot { margin-top: 10px; display: flex; justify-content: space-between; color: #9CA3AF; font-size: 9px; }
</style></head><body>
<div class="head"><div><div class="org">${_esc(org)}</div><h1>Asset Report</h1></div>
<div class="meta">${rows.length} assets · Rs ${_money.format(_cost(rows))}<br>Printed $gen</div></div>
${filters.isEmpty ? '' : '<div class="filters">${_esc(filters.join('  ·  '))}</div>'}
<table><thead><tr><th>Code</th><th>Asset</th><th>Category</th><th>Branch</th><th>Custodian</th><th>Status</th><th>Condition</th><th>Serial / Model</th><th class="num">Cost</th><th>Next service</th></tr></thead>
<tbody>$b
<tr class="tot"><td>Total</td><td colspan="7">${rows.length} assets</td><td class="num">${_money.format(_cost(rows))}</td><td></td></tr>
</tbody></table>
<div class="foot"><span>Opstation ERP · Asset Report</span><span>Printed $gen</span></div>
</body></html>''';

    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst('</body>',
          '<script>window.onload=function(){setTimeout(function(){try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }
}
