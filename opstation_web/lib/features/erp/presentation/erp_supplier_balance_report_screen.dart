// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';
import '../../auth/auth_controller.dart';

/// Supplier Balance Report — the payables mirror of the Customer Balance
/// Report. Lists suppliers with their net Accounts-Payable balance at three
/// period-ends (3 months / 3 weeks; rightmost = current). Balances come from
/// the GL via rpc_supplier_balance_report (sums journal_lines posted to the AP
/// control account, credit − debit per supplier), exactly paralleling how the
/// customer report derives AR from the AR control account. Filters: Status
/// (Active / Inactive / All) and a name/code search. Ledgers are cross-branch,
/// so this report is org-wide (no branch scoping), matching the Supplier Ledger.
class ErpSupplierBalanceReportScreen extends ConsumerStatefulWidget {
  const ErpSupplierBalanceReportScreen({super.key});
  @override
  ConsumerState<ErpSupplierBalanceReportScreen> createState() =>
      _ErpSupplierBalanceReportScreenState();
}

class _ErpSupplierBalanceReportScreenState
    extends ConsumerState<ErpSupplierBalanceReportScreen> {
  DateTime _asOf = DateTime.now();
  String _span = '3M'; // '3M' | '3W'
  String _statusFilter = 'all'; // all | active | inactive
  String _search = '';

  bool _loading = false;
  bool _loaded = false;
  List<String> _periodLabels = [];
  List<Map<String, dynamic>> _items = [];
  // Raw supplier rows retained so sort, search and the zero-balance toggle
  // re-render instantly without re-querying.
  List<Map<String, dynamic>> _rawRows = [];
  String _sortKey = 'default'; // default | name | bal1 | bal2 | bal3
  bool _sortAsc = true;
  bool _showZero = true;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  List<DateTime> _periodEnds() {
    final a = DateTime(_asOf.year, _asOf.month, _asOf.day);
    if (_span == '3W') {
      return [
        a.subtract(const Duration(days: 14)),
        a.subtract(const Duration(days: 7)),
        a,
      ];
    }
    final d2 = DateTime(a.year, a.month, 0);
    final d1 = DateTime(a.year, a.month - 1, 0);
    return [d1, d2, a];
  }

  List<String> _labelsFor(List<DateTime> ends) {
    if (_span == '3W') {
      return [
        'Wk to ${DateFormat('d MMM').format(ends[0])}',
        'Wk to ${DateFormat('d MMM').format(ends[1])}',
        'Current',
      ];
    }
    return [
      DateFormat('MMM yyyy').format(ends[0]),
      DateFormat('MMM yyyy').format(ends[1]),
      '${DateFormat('MMM yyyy').format(ends[2])} (current)',
    ];
  }

  bool _passesStatus(Map<String, dynamic> row) {
    final active = row['is_active'] != false;
    if (_statusFilter == 'active') return active;
    if (_statusFilter == 'inactive') return !active;
    return true;
  }

  Future<void> _loadReport() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final ends = _periodEnds();
      final res = await client.rpc('rpc_supplier_balance_report', params: {
        'p_org_id': orgId,
        'p_d1': DateFormat('yyyy-MM-dd').format(ends[0]),
        'p_d2': DateFormat('yyyy-MM-dd').format(ends[1]),
        'p_d3': DateFormat('yyyy-MM-dd').format(ends[2]),
        // Supplier ledgers are cross-branch, so this report is org-wide.
        'p_branch_ids': null,
      });
      final rows = <Map<String, dynamic>>[
        for (final r in res as List) Map<String, dynamic>.from(r as Map)
      ];
      // The RPC returns credit - debit (payable positive). Flip the sign so a
      // PAYABLE shows NEGATIVE and an ADVANCE shows POSITIVE, matching the old
      // ERP convention used across the supplier screens.
      for (final r in rows) {
        for (final k in const ['bal1', 'bal2', 'bal3']) {
          final v = r[k];
          if (v is num) r[k] = -v.toDouble();
        }
      }
      // TRUE NET POSITION: the AP control alone hides prepayments (a supplier
      // with a 1.15M advance showed as a small payable). Fold each supplier's
      // balance on the "Advances to Suppliers" account into every period
      // column, so the report matches the Supplier Ledger's bottom line.
      try {
        String? advId;
        final byCode = await client
            .from('chart_of_accounts')
            .select('id')
            .eq('org_id', orgId)
            .eq('code', '1420')
            .maybeSingle();
        advId = byCode?['id'] as String?;
        if (advId == null) {
          final byName = await client
              .from('chart_of_accounts')
              .select('id')
              .eq('org_id', orgId)
              .ilike('name', '%advance%supplier%')
              .limit(1);
          if ((byName as List).isNotEmpty) {
            advId = (byName.first as Map)['id'] as String?;
          }
        }
        if (advId != null) {
          final lines = await client
              .from('journal_lines')
              .select('party_id, debit, credit, journal_entries!inner(entry_date, status)')
              .eq('org_id', orgId)
              .eq('account_id', advId)
              .not('party_id', 'is', null)
              .limit(20000);
          final adv = <String, List<double>>{}; // party -> [asOf d1, d2, d3]
          for (final l in lines as List) {
            final m = l as Map;
            final je = m['journal_entries'] as Map?;
            if (je == null || (je['status'] as String?) == 'draft') continue;
            final d = DateTime.tryParse('${je['entry_date']}');
            if (d == null) continue;
            final net = ((m['debit'] as num?)?.toDouble() ?? 0) -
                ((m['credit'] as num?)?.toDouble() ?? 0);
            final a = adv.putIfAbsent(
                m['party_id'] as String, () => [0.0, 0.0, 0.0]);
            for (var i = 0; i < 3; i++) {
              if (!d.isAfter(ends[i])) a[i] += net;
            }
          }
          if (adv.isNotEmpty) {
            // RPC rows may not carry the supplier id — resolve by name.
            final sups = await client
                .from('suppliers')
                .select('id, name')
                .eq('org_id', orgId)
                .limit(10000);
            final idByName = {
              for (final s in sups as List)
                ((s as Map)['name'] as String? ?? '').trim().toLowerCase():
                    s['id'] as String
            };
            for (final r in rows) {
              final sid = (r['supplier_id'] as String?) ??
                  idByName[(r['name'] as String? ?? '').trim().toLowerCase()];
              final a = sid == null ? null : adv[sid];
              if (a == null) continue;
              r['bal1'] = ((r['bal1'] as num?)?.toDouble() ?? 0) + a[0];
              r['bal2'] = ((r['bal2'] as num?)?.toDouble() ?? 0) + a[1];
              r['bal3'] = ((r['bal3'] as num?)?.toDouble() ?? 0) + a[2];
              r['has_advance'] = true;
            }
          }
        }
      } catch (_) {/* advances are best-effort; AP-only is still a valid report */}
      if (mounted) {
        _rawRows = rows;
        _periodLabels = _labelsFor(ends);
        _loaded = true;
        _loading = false;
        _rebuildItems();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Report error: $e')));
      }
    }
  }

  void _rebuildItems() {
    final q = _search.trim().toLowerCase();
    final rows = <Map<String, dynamic>>[];
    for (final r in _rawRows) {
      if (!_passesStatus(r)) continue;
      if (!_showZero && ((r['bal3'] as num?)?.toDouble() ?? 0) == 0) continue;
      if (q.isNotEmpty) {
        final nm = (r['name'] as String? ?? '').toLowerCase();
        final cd = (r['code'] as String? ?? '').toLowerCase();
        if (!nm.contains(q) && !cd.contains(q)) continue;
      }
      rows.add(r);
    }
    _sortRows(rows);
    final items = <Map<String, dynamic>>[];
    double t1 = 0, t2 = 0, t3 = 0;
    int dataRow = 0;
    for (final r in rows) {
      t1 += (r['bal1'] as num?)?.toDouble() ?? 0;
      t2 += (r['bal2'] as num?)?.toDouble() ?? 0;
      t3 += (r['bal3'] as num?)?.toDouble() ?? 0;
      items.add({'type': 'row', 'stripe': dataRow % 2 == 1, ...r});
      dataRow++;
    }
    if (rows.isNotEmpty) {
      items.add({'type': 'footer', 'count': rows.length, 't1': t1, 't2': t2, 't3': t3});
    }
    setState(() => _items = items);
  }

  void _sortRows(List<Map<String, dynamic>> rows) {
    if (_sortKey == 'default') return; // keep RPC (name) order
    final dir = _sortAsc ? 1 : -1;
    double n(Map<String, dynamic> r, String k) => (r[k] as num?)?.toDouble() ?? 0;
    rows.sort((a, b) {
      switch (_sortKey) {
        case 'name':
          return dir *
              (a['name'] as String? ?? '')
                  .toLowerCase()
                  .compareTo((b['name'] as String? ?? '').toLowerCase());
        case 'bal1':
          return dir * n(a, 'bal1').compareTo(n(b, 'bal1'));
        case 'bal2':
          return dir * n(a, 'bal2').compareTo(n(b, 'bal2'));
        case 'bal3':
          return dir * n(a, 'bal3').compareTo(n(b, 'bal3'));
      }
      return 0;
    });
  }

  void _onSort(String key) {
    if (_sortKey != key) {
      _sortKey = key;
      _sortAsc = true;
    } else if (_sortAsc) {
      _sortAsc = false;
    } else {
      _sortKey = 'default';
      _sortAsc = true;
    }
    _rebuildItems();
  }

  String _money(num v) => money(v);

  // ── Print / PDF (hidden iframe srcdoc; Safari prints blob: URLs blank) ─────
  void _print() {
    if (!_loaded || _items.isEmpty) return;
    final buf = StringBuffer();
    for (final it in _items) {
      if (it['type'] == 'footer') {
        buf.write('<tr class="tot"><td>Total (${it['count']} suppliers)</td>'
            '<td class="num">${_money(it['t1'] as num)}</td>'
            '<td class="num">${_money(it['t2'] as num)}</td>'
            '<td class="num">${_money(it['t3'] as num)}</td></tr>');
      } else {
        final code = (it['code'] as String?) ?? '';
        final name = (it['name'] as String?) ?? '';
        final disp = code.isNotEmpty ? '$code — $name' : name;
        buf.write('<tr><td>$disp</td>'
            '<td class="num">${_money((it['bal1'] as num?) ?? 0)}</td>'
            '<td class="num">${_money((it['bal2'] as num?) ?? 0)}</td>'
            '<td class="num">${_money((it['bal3'] as num?) ?? 0)}</td></tr>');
      }
    }

    final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final spanLabel = _span == '3W' ? '3 Weeks' : '3 Months';
    final statusLabel = _statusFilter == 'active'
        ? 'Active'
        : _statusFilter == 'inactive'
            ? 'Inactive'
            : 'All';
    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Supplier Balance Report</title>'
        '<style>'
        '@page { size: A4 landscape; margin: 0.6cm; } '
        '* { -webkit-print-color-adjust: exact; print-color-adjust: exact; } '
        'body { font-family: Arial, sans-serif; padding: 4px; font-size: 10px; color: #000; } '
        'h1 { font-size: 15px; margin: 0 0 2px 0; } '
        '.info { font-size: 9.5px; color: #444; margin-bottom: 8px; } '
        'table { width: 100%; border-collapse: collapse; table-layout: fixed; } '
        'th, td { padding: 3px 6px; border: 1px solid #888; text-align: left; font-size: 9px; word-break: break-word; } '
        'td:first-child, th:first-child { width: 40%; } '
        'th { background: #f0f4ff; font-weight: 700; } '
        '.num { text-align: right; } '
        '.tot td { background: #f3f6ff; font-weight: 700; border-top: 2px solid #333; } '
        '</style></head><body>'
        '<h1>Supplier Balance Report</h1>'
        '<div class="info">Span: $spanLabel &nbsp;|&nbsp; As on: ${DateFormat('d MMM yyyy').format(_asOf)} &nbsp;|&nbsp; Status: $statusLabel &nbsp;|&nbsp; Generated: $genTime</div>'
        '<table><thead><tr><th>Supplier</th>'
        '<th class="num">${_periodLabels.isNotEmpty ? _periodLabels[0] : ''}</th>'
        '<th class="num">${_periodLabels.length > 1 ? _periodLabels[1] : ''}</th>'
        '<th class="num">${_periodLabels.length > 2 ? _periodLabels[2] : ''}</th>'
        '</tr></thead><tbody>${buf.toString()}</tbody></table>'
        '<script>window.onload=function(){setTimeout(function(){window.focus();window.print();},350);};</script>'
        '</body></html>';

    final iframe = html.IFrameElement()
      ..style.position = 'fixed'
      ..style.right = '0'
      ..style.bottom = '0'
      ..style.width = '0'
      ..style.height = '0'
      ..style.border = '0';
    html.document.body!.append(iframe);
    iframe.srcdoc = doc;
    Future.delayed(const Duration(minutes: 2), () {
      try {
        iframe.remove();
      } catch (_) {}
    });
  }

  // ── UI ──────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Row(children: [
            const Text('Supplier Balance Report',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Net position: payables + supplier advances (negative = we owe, positive = advance)',
                style: TextStyle(fontSize: 11.5, color: Colors.black54),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_loaded)
              OutlinedButton.icon(
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print / PDF'),
                  onPressed: _print),
          ]),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border)),
          child: Wrap(
            spacing: 18,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _field('As On', SizedBox(
                width: 150,
                child: InkWell(
                  onTap: () async {
                    final p = await showDatePicker(
                        context: context,
                        initialDate: _asOf,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100));
                    if (p != null) setState(() => _asOf = p);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFBDBDBD)),
                        borderRadius: BorderRadius.circular(6)),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(DateFormat('dd MMM yyyy').format(_asOf),
                              style: const TextStyle(fontSize: 13)),
                          const Icon(Icons.calendar_today,
                              size: 13, color: AppTheme.textSecondary),
                        ]),
                  ),
                ),
              )),
              _field('Span', ToggleButtons(
                isSelected: [_span == '3M', _span == '3W'],
                onPressed: (i) => setState(() => _span = i == 0 ? '3M' : '3W'),
                borderRadius: BorderRadius.circular(6),
                constraints: const BoxConstraints(minHeight: 38, minWidth: 84),
                children: const [Text('3 Months'), Text('3 Weeks')],
              )),
              _field('Status', _dropdown<String>(
                width: 130,
                value: _statusFilter,
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
                ],
                onChanged: (v) {
                  setState(() => _statusFilter = v ?? 'all');
                  if (_loaded) _rebuildItems();
                },
              )),
              _field('Search', SizedBox(
                width: 200,
                child: TextField(
                  decoration: const InputDecoration(
                      hintText: 'Name or code…',
                      prefixIcon: Icon(Icons.search, size: 16),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 11),
                      border: OutlineInputBorder()),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (v) {
                    _search = v;
                    if (_loaded) _rebuildItems();
                  },
                ),
              )),
              _field('Zero Balances', Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(
                  value: _showZero,
                  onChanged: (v) {
                    setState(() => _showZero = v);
                    if (_loaded) _rebuildItems();
                  },
                ),
                Text(_showZero ? 'Shown' : 'Hidden',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ])),
              ElevatedButton.icon(
                icon: _loading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('Load Report'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                onPressed: _loading ? null : _loadReport,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: !_loaded
              ? const Center(
                  child: Text('Choose options and Load Report',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : _items.isEmpty
                  ? const Center(
                      child: Text('No suppliers found',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : Container(
                      margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.border)),
                      child: Column(children: [
                        _tableHeader(),
                        const Divider(height: 1),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _items.length,
                            itemBuilder: (_, i) => _buildItem(_items[i]),
                          ),
                        ),
                      ]),
                    ),
        ),
      ]),
    );
  }

  Widget _dropdown<T>({
    required double width,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<T>(
        value: value,
        isExpanded: true,
        decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder()),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  Widget _field(String label, Widget child) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      child,
    ]);
  }

  Widget _tableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
      child: Row(children: [
        Expanded(flex: 3, child: _sortCell('Supplier', 'name', alignRight: false)),
        SizedBox(
            width: 120,
            child: _sortCell(
                _periodLabels.isNotEmpty ? _periodLabels[0] : '', 'bal1',
                alignRight: true)),
        SizedBox(
            width: 120,
            child: _sortCell(
                _periodLabels.length > 1 ? _periodLabels[1] : '', 'bal2',
                alignRight: true)),
        SizedBox(
            width: 130,
            child: _sortCell(
                _periodLabels.length > 2 ? _periodLabels[2] : '', 'bal3',
                alignRight: true)),
      ]),
    );
  }

  Widget _sortCell(String label, String key, {required bool alignRight}) {
    const st = TextStyle(
        fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
    final active = _sortKey == key;
    final labelWidget = Flexible(
      child: Text(label,
          style: active ? st.copyWith(color: AppTheme.primary) : st,
          textAlign: alignRight ? TextAlign.right : TextAlign.left,
          overflow: TextOverflow.ellipsis),
    );
    final arrow = active
        ? Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12, color: AppTheme.primary)
        : const SizedBox(width: 12);
    return InkWell(
      onTap: () => _onSort(key),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment:
              alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: alignRight
              ? [arrow, const SizedBox(width: 2), labelWidget]
              : [labelWidget, const SizedBox(width: 2), arrow],
        ),
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> it) {
    if (it['type'] == 'footer') {
      return Container(
        decoration: const BoxDecoration(
            color: Color(0xFFF3F6FF),
            border: Border(top: BorderSide(color: Color(0xFF8894C4)))),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          Expanded(
              flex: 3,
              child: Text('Total  (${it['count']} suppliers)',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
                  overflow: TextOverflow.ellipsis)),
          _amt(it['t1'] as num, 120, bold: true),
          _amt(it['t2'] as num, 120, bold: true),
          _amt(it['t3'] as num, 130, bold: true),
        ]),
      );
    }
    final code = (it['code'] as String?) ?? '';
    final name = (it['name'] as String?) ?? '';
    final disp = code.isNotEmpty ? '$code — $name' : name;
    final stripe = it['stripe'] == true;
    final inactive = it['is_active'] == false;
    return Container(
      color: stripe ? const Color(0xFFF4F5F7) : Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(children: [
        Expanded(
            flex: 3,
            child: Row(children: [
              Flexible(
                  child: Text(disp,
                      style: const TextStyle(fontSize: 12.5),
                      overflow: TextOverflow.ellipsis)),
              if (inactive) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(3)),
                  child: const Text('Inactive',
                      style: TextStyle(
                          fontSize: 9, color: Colors.grey, fontWeight: FontWeight.w700)),
                ),
              ],
            ])),
        _amt((it['bal1'] as num?) ?? 0, 120),
        _amt((it['bal2'] as num?) ?? 0, 120),
        _amt((it['bal3'] as num?) ?? 0, 130, bold: true),
      ]),
    );
  }

  Widget _amt(num v, double w, {bool bold = false}) {
    final adv = v.toDouble() > 0; // positive = advance (we prepaid the supplier)
    return SizedBox(
      width: w,
      child: Text(_money(v),
          textAlign: TextAlign.right,
          style: TextStyle(
              fontSize: 12.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
              // Advance (positive) highlighted green; payable (negative) normal.
              color: adv ? Colors.green : AppTheme.textPrimary)),
    );
  }
}
