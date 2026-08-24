// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/reports/branch_scope.dart';
import '../../auth/auth_controller.dart';

/// Cash Book Report (Financials).
///
/// One row per cash movement (every posted journal line that hits Cash in
/// Hand / code 1110 or a sub-account), with the contra account shown inline
/// as "Particulars". Opening balance is carried forward as of the From date,
/// a running balance is shown after every line, and a closing balance sits in
/// the footer. Data comes from the `rpc_cash_book` RPC so branch scoping and
/// the opening-balance calculation stay on the server.
class ErpCashBookScreen extends ConsumerStatefulWidget {
  const ErpCashBookScreen({super.key});
  @override
  ConsumerState<ErpCashBookScreen> createState() => _ErpCashBookScreenState();
}

class _ErpCashBookScreenState extends ConsumerState<ErpCashBookScreen> {
  final MoneyFmt _fmt = const MoneyFmt();
  DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  bool _allBranches = false;

  bool _loading = false;
  String? _error;
  double _opening = 0;
  List<Map<String, dynamic>> _rows = []; // movement rows with computed balance
  final _searchCtrl = TextEditingController();

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final scope = await ref.read(branchScopeProvider.future);
      final selected = ref.read(selectedBranchProvider);
      final branchIds = scope.resolve(allSelected: _allBranches, selected: selected);
      final res = await Supabase.instance.client.rpc('rpc_cash_book', params: {
        'p_org_id': orgId,
        'p_branch_ids': branchIds,
        'p_date_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_date_to': DateFormat('yyyy-MM-dd').format(_to),
      });
      double opening = 0;
      final movements = <Map<String, dynamic>>[];
      for (final r in (res as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        if (m['r_kind'] == 'opening') {
          opening = _toD(m['debit']);
        } else {
          movements.add(m);
        }
      }
      double bal = opening;
      for (final m in movements) {
        final dr = _toD(m['debit']);
        final cr = _toD(m['credit']);
        m['debit'] = dr;   // normalise so downstream num casts are safe
        m['credit'] = cr;
        bal += dr - cr;
        m['balance'] = bal;
      }
      if (mounted) setState(() { _opening = opening; _rows = movements; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> get _display {
    final q = _searchCtrl.text;
    return _rows.where((e) =>
      matchesQuery('${e['voucher_no'] ?? ''} ${e['particulars'] ?? ''} ${e['narration'] ?? ''}', q)).toList();
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null && mounted) {
      setState(() { _from = picked.start; _to = picked.end; });
      _load();
    }
  }

  Future<void> _openEntry(Map<String, dynamic> e) async {
    final id = e['entry_id'] as String?;
    if (id == null || id.isEmpty) return;
    final refType = e['ref_type'] as String? ?? '';
    List<Map<String, dynamic>> lines = [];
    try {
      final rows = await Supabase.instance.client
          .from('journal_lines')
          .select('account_name, debit, credit, description, line_order')
          .eq('entry_id', id)
          .order('line_order');
      lines = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
    if (!mounted) return;
    final isJv = refType == 'jv' || refType == 'opening_jv' || refType == 'opening_balance';
    final vno = e['voucher_no'] as String? ?? '';
    showDialog(context: context, builder: (ctx) {
      double td = 0, tc = 0;
      for (final l in lines) {
        td += _toD(l['debit']);
        tc += _toD(l['credit']);
      }
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Voucher Entry', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx).pop()),
              ]),
              Text(vno, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              const SizedBox(height: 12),
              Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: const Row(children: [
                  Expanded(flex: 4, child: Text('Account', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                  Expanded(flex: 3, child: Text('Description', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                  Expanded(flex: 2, child: Text('Debit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                  Expanded(flex: 2, child: Text('Credit', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                ])),
              Flexible(child: SingleChildScrollView(child: Column(children: [
                for (final l in lines)
                  Container(
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Row(children: [
                      Expanded(flex: 4, child: Text((l['account_name'] as String?) ?? '-', style: const TextStyle(fontSize: 12))),
                      Expanded(flex: 3, child: Text((l['description'] as String?) ?? '', style: const TextStyle(fontSize: 12))),
                      Expanded(flex: 2, child: Text(_toD(l['debit']) > 0 ? _fmt.format(_toD(l['debit'])) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                      Expanded(flex: 2, child: Text(_toD(l['credit']) > 0 ? _fmt.format(_toD(l['credit'])) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
                    ]),
                  ),
              ]))),
              const Divider(height: 1),
              Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
                const Expanded(flex: 7, child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                Expanded(flex: 2, child: Text(_fmt.format(td), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
                Expanded(flex: 2, child: Text(_fmt.format(tc), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
              ])),
              if (isJv) Align(alignment: Alignment.centerRight, child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 15),
                label: const Text('Open Journal Voucher'),
                onPressed: () {
                  final href = html.window.location.href; final hIdx = href.indexOf('#');
                  final origin = hIdx != -1 ? href.substring(0, hIdx) : href;
                  html.window.open(origin + '#/financials/journal-vouchers?id=' + vno, '_blank');
                },
              )),
            ]),
          ),
        ),
      );
    });
  }

  void _print() {
    final display = _display;
    final branch = ref.read(selectedBranchProvider);
    final branchName = _allBranches ? 'All Branches' : ((branch?['name'] as String?) ?? 'All Branches');
    final period = DateFormat('d MMM yy').format(_from) + ' to ' + DateFormat('d MMM yy').format(_to);
    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    double td = 0, tc = 0;
    for (final e in display) { td += (e['debit'] as num?)?.toDouble() ?? 0; tc += (e['credit'] as num?)?.toDouble() ?? 0; }
    final closing = _opening + td - tc;

    final rows = StringBuffer();
    rows.write('<tr class="opening"><td>' + DateFormat('d MMM yy').format(_from) + '</td><td></td><td></td><td>Opening Balance</td><td></td><td class="num">-</td><td class="num">-</td><td class="num bold">' + _fmt.format(_opening) + '</td></tr>');
    for (final e in display) {
      final d = DateTime.tryParse(e['entry_date'] as String? ?? '');
      final dateStr = d != null ? DateFormat('d MMM yy').format(d) : '-';
      final dr = (e['debit'] as num?)?.toDouble() ?? 0;
      final cr = (e['credit'] as num?)?.toDouble() ?? 0;
      final bal = (e['balance'] as num?)?.toDouble() ?? 0;
      rows.write('<tr><td>' + dateStr + '</td><td>' + _vrCode(e['ref_type'] as String?) + '</td><td>' + (e['voucher_no'] as String? ?? '') + '</td><td>' + (e['particulars'] as String? ?? '') + '</td><td>' + (e['narration'] as String? ?? '') + '</td><td class="num">' + (dr > 0 ? _fmt.format(dr) : '-') + '</td><td class="num">' + (cr > 0 ? _fmt.format(cr) : '-') + '</td><td class="num bold">' + _fmt.format(bal) + '</td></tr>');
    }

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Cash Book</title><style>'
      '@page { margin: 0.5cm; } '
      'body { font-family: Arial, sans-serif; padding: 16px; font-size: 10px; color: #000; margin: 0; } '
      '.header { border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 10px; } '
      'h1 { font-size: 18px; margin: 0 0 4px 0; } .info { font-size: 10px; margin: 2px 0; } '
      '.stats { display: flex; gap: 10px; margin: 8px 0 12px 0; } '
      '.stat { padding: 6px 10px; border: 1px solid #ddd; border-radius: 4px; } '
      '.stat-label { font-size: 8px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; } '
      '.stat-value { font-weight: 800; font-size: 12px; margin-top: 2px; } '
      'table { width: 100%; border-collapse: collapse; } '
      'th, td { padding: 4px 6px; border-bottom: 1px solid #ddd; text-align: left; font-size: 9.5px; } '
      'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
      '.num { text-align: right; white-space: nowrap; } .bold { font-weight: 800; } '
      '.opening td { background: #f0f4ff; font-weight: 700; } '
      'tfoot td { font-weight: 800; background: #f5f5f5; border-top: 2px solid #000; border-bottom: none; padding: 6px; } '
      '</style></head><body>'
      '<div class="header"><h1>Cash Book</h1>'
      '<div class="info"><strong>Account:</strong> Cash in Hand</div>'
      '<div class="info"><strong>Branch:</strong> ' + branchName + '</div>'
      '<div class="info"><strong>Period:</strong> ' + period + '</div>'
      '<div class="info">Generated: ' + gen + '</div></div>'
      '<div class="stats">'
      '<div class="stat"><div class="stat-label">Opening</div><div class="stat-value">' + _fmt.format(_opening) + '</div></div>'
      '<div class="stat"><div class="stat-label">Total Receipts</div><div class="stat-value">' + _fmt.format(td) + '</div></div>'
      '<div class="stat"><div class="stat-label">Total Payments</div><div class="stat-value">' + _fmt.format(tc) + '</div></div>'
      '<div class="stat"><div class="stat-label">Closing</div><div class="stat-value">' + _fmt.format(closing) + '</div></div>'
      '</div>'
      '<table><thead><tr><th>Date</th><th>Vr.</th><th>Voucher</th><th>Particulars</th><th>Description</th><th class="num">Receipt (Dr)</th><th class="num">Payment (Cr)</th><th class="num">Balance</th></tr></thead>'
      '<tbody>' + rows.toString() + '</tbody>'
      '<tfoot><tr><td colspan="5">' + display.length.toString() + ' entries</td><td class="num">' + _fmt.format(td) + '</td><td class="num">' + _fmt.format(tc) + '</td><td class="num">' + _fmt.format(closing) + '</td></tr></tfoot>'
      '</table></body></html>';

    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    final scopeAsync = ref.watch(branchScopeProvider);
    final canToggleAll = scopeAsync.maybeWhen(data: (s) => s.canToggleAll, orElse: () => false);
    final display = _display;
    double td = 0, tc = 0;
    for (final e in display) { td += (e['debit'] as num?)?.toDouble() ?? 0; tc += (e['credit'] as num?)?.toDouble() ?? 0; }
    final closing = _opening + td - tc;
    final branchLabel = _allBranches ? 'All Branches' : (branch == null ? 'All Branches' : 'Branch: ${branch['name']}');

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LayoutBuilder(builder: (_, cc) {
          final narrow = cc.maxWidth < 640;
          final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Cash Book', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            Text(branchLabel, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          ]);
          final actions = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (canToggleAll)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Checkbox(value: _allBranches, visualDensity: VisualDensity.compact,
                  onChanged: (v) { setState(() => _allBranches = v ?? false); _load(); }),
                const Text('All Branches', style: TextStyle(fontSize: 12)),
              ]),
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_today_outlined, size: 15),
              label: Text(DateFormat('d MMM yy').format(_from) + ' – ' + DateFormat('d MMM yy').format(_to), style: const TextStyle(fontSize: 12)),
              onPressed: _pickRange,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh', style: TextStyle(fontSize: 12)),
              onPressed: _loading ? null : _load,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.print_outlined, size: 16),
              label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
              onPressed: _rows.isEmpty ? null : _print,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
          ]);
          if (narrow) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [titleBlock, const SizedBox(height: 10), actions]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [titleBlock, const Spacer(), actions]);
        }),
        const SizedBox(height: 16),
        if (_error != null) Container(
          margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
          child: Row(children: [
            Icon(Icons.error_outline, color: Colors.red.shade700, size: 18), const SizedBox(width: 8),
            Expanded(child: Text(_error!, style: TextStyle(fontSize: 11, color: Colors.red.shade900))),
          ]),
        ),
        // KPI strip
        Row(children: [
          _kpi('Opening', _opening, AppTheme.textPrimary),
          const SizedBox(width: 10),
          _kpi('Total Receipts', td, AppTheme.primary),
          const SizedBox(width: 10),
          _kpi('Total Payments', tc, Colors.orange.shade800),
          const SizedBox(width: 10),
          _kpi('Closing', closing, closing >= 0 ? Colors.green.shade700 : AppTheme.danger),
        ]),
        const SizedBox(height: 12),
        SizedBox(width: 320, child: TextField(controller: _searchCtrl,
          decoration: const InputDecoration(hintText: 'Search voucher, particulars, narration…', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)))),
        const SizedBox(height: 12),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
              child: Column(children: [
                _headerRow(),
                Expanded(child: display.isEmpty
                  ? const Center(child: Text('No cash movements in this period.', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.builder(
                      itemCount: display.length + 1,
                      itemBuilder: (_, i) {
                        if (i == 0) return _openingRow();
                        return _dataRow(display[i - 1]);
                      },
                    )),
                _footerRow(display.length, td, tc, closing),
              ]),
            )),
      ]),
    );
  }

  Widget _kpi(String label, double value, Color color) => Expanded(child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 2),
      Text(_fmt.format(value), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
    ]),
  ));

  Widget _headerRow() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(10)), border: Border(bottom: BorderSide(color: AppTheme.border))),
    child: Row(children: const [
      SizedBox(width: 74, child: Text('Date', style: _hStyle)),
      SizedBox(width: 40, child: Text('Vr.', style: _hStyle)),
      SizedBox(width: 104, child: Text('Voucher', style: _hStyle)),
      Expanded(flex: 3, child: Text('Particulars', style: _hStyle)),
      Expanded(flex: 3, child: Text('Description', style: _hStyle)),
      SizedBox(width: 104, child: Text('Receipt (Dr)', textAlign: TextAlign.right, style: _hStyle)),
      SizedBox(width: 104, child: Text('Payment (Cr)', textAlign: TextAlign.right, style: _hStyle)),
      SizedBox(width: 116, child: Text('Balance', textAlign: TextAlign.right, style: _hStyle)),
    ]),
  );

  Widget _openingRow() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.05), border: const Border(bottom: BorderSide(color: AppTheme.border))),
    child: Row(children: [
      SizedBox(width: 74, child: Text(DateFormat('d MMM yy').format(_from), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      const SizedBox(width: 40),
      const SizedBox(width: 104),
      const Expanded(flex: 3, child: Text('Opening Balance', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
      const Expanded(flex: 3, child: SizedBox()),
      const SizedBox(width: 104, child: Text('-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.black26))),
      const SizedBox(width: 104, child: Text('-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: Colors.black26))),
      SizedBox(width: 116, child: Text(_fmt.format(_opening), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
    ]),
  );

  Widget _dataRow(Map<String, dynamic> e) {
    final d = DateTime.tryParse(e['entry_date'] as String? ?? '');
    final dateStr = d != null ? DateFormat('d MMM yy').format(d) : '-';
    final dr = (e['debit'] as num?)?.toDouble() ?? 0;
    final cr = (e['credit'] as num?)?.toDouble() ?? 0;
    final bal = (e['balance'] as num?)?.toDouble() ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 74, child: Text(dateStr, style: const TextStyle(fontSize: 12))),
        SizedBox(width: 40, child: Text(_vrCode(e['ref_type'] as String?), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
        SizedBox(width: 104, child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(
          onTap: () => _openEntry(e),
          child: Text(e['voucher_no'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline), overflow: TextOverflow.ellipsis),
        ))),
        Expanded(flex: 3, child: Text((e['particulars'] as String? ?? '').isEmpty ? '-' : e['particulars'] as String, style: const TextStyle(fontSize: 12))),
        Expanded(flex: 3, child: Text(e['narration'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        SizedBox(width: 104, child: Text(dr > 0 ? _fmt.format(dr) : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dr > 0 ? AppTheme.primary : Colors.black26))),
        SizedBox(width: 104, child: Text(cr > 0 ? _fmt.format(cr) : '-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cr > 0 ? Colors.orange.shade800 : Colors.black26))),
        SizedBox(width: 116, child: Text(_fmt.format(bal), textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: bal >= 0 ? AppTheme.textPrimary : AppTheme.danger))),
      ]),
    );
  }

  Widget _footerRow(int count, double td, double tc, double closing) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)), border: Border(top: BorderSide(color: AppTheme.border))),
    child: Row(children: [
      Expanded(child: Text('$count entries', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
      SizedBox(width: 104, child: Text(_fmt.format(td), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary))),
      SizedBox(width: 104, child: Text(_fmt.format(tc), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.orange.shade800))),
      SizedBox(width: 116, child: Text(_fmt.format(closing), textAlign: TextAlign.right, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: closing >= 0 ? Colors.green.shade700 : AppTheme.danger))),
    ]),
  );
}

const _hStyle = TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600);

/// Short voucher-type code (Vr.) shown like the old Cash Book — CP/CR/JV/OB…
String _vrCode(String? refType) {
  switch ((refType ?? '').toLowerCase()) {
    case 'crv': return 'CR';
    case 'cpv': return 'CP';
    case 'jv': return 'JV';
    case 'opening_balance':
    case 'opening_jv': return 'OB';
    case 'pos':
    case 'pos_sale':
    case 'pos_payment': return 'POS';
    case 'brv': return 'BR';
    case 'pdc': return 'PDC';
    default:
      final t = (refType ?? '').trim();
      return t.isEmpty ? '—' : t.toUpperCase();
  }
}

/// PostgREST serialises `numeric` as a JSON string to preserve precision, so a
/// plain `as num` cast would null it. This tolerates num, String, or null.
double _toD(dynamic v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}
