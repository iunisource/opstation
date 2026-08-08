import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/format/money.dart';
import '../../../core/reports/branch_scope.dart';
import '../../auth/auth_controller.dart';

class ErpTrialBalanceScreen extends ConsumerStatefulWidget {
  const ErpTrialBalanceScreen({super.key});
  @override
  ConsumerState<ErpTrialBalanceScreen> createState() => _ErpTrialBalanceScreenState();
}

class _ErpTrialBalanceScreenState extends ConsumerState<ErpTrialBalanceScreen> {
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to   = DateTime.now();
  bool _loading  = false;
  bool _allBranches = true;  // org-wide first; a TB only balances org-wide
  List<Map<String, dynamic>> _rows = [];
  // level-4 detail rows grouped by their level-3 parent code
  Map<String, List<Map<String, dynamic>>> _children = {};
  // which level-3 codes are currently expanded
  final Set<String> _expanded = {};

  @override void initState() { super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load()); }

  Future<void> _load() async {
    String? orgId = ref.read(currentUserProvider)?.orgId;
    orgId ??= ref.read(selectedBranchProvider)?['org_id'] as String?;
    if (orgId == null) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); }); return; }
    setState(() => _loading = true);
    try {
      final branch = ref.read(selectedBranchProvider);
      // p_branch_ids (array), not p_branch_id. BranchScope decides what "all"
      // means for THIS user: null (org-wide) only for an unrestricted admin; an
      // erpUser always gets their own branch ids, never null.
      final scope = await ref.read(branchScopeProvider.future);
      final params = {
        'p_org_id': orgId,
        'p_date_from': DateFormat('yyyy-MM-dd').format(_from),
        'p_date_to':   DateFormat('yyyy-MM-dd').format(_to),
        'p_branch_ids': scope.resolve(allSelected: _allBranches, selected: branch),
      };
      final client = Supabase.instance.client;
      final res = await client.rpc('rpc_trial_balance', params: params);

      // Detail is additive: if the RPC is missing or errors, the report still
      // renders as a flat level-3 summary (graceful degradation).
      List detail = [];
      try { detail = await client.rpc('rpc_trial_balance_detail', params: params) as List; } catch (_) {}
      final children = <String, List<Map<String, dynamic>>>{};
      for (final d in List<Map<String, dynamic>>.from(detail)) {
        (children[(d['parent_code'] ?? '') as String] ??= []).add(d);
      }

      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _children = children;
        _expanded.clear();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _print() async {
    final user = ref.read(currentUserProvider);
    final branch = ref.read(selectedBranchProvider);
    final fmt = const MoneyFmt();
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(20),
      build: (ctx) => [
        pw.Text(user?.orgName ?? '', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text('Trial Balance', style: pw.TextStyle(fontSize: 13, color: PdfColors.grey700)),
        if (branch != null) pw.Text('Branch: ${branch['name']}', style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        pw.Text('Period: ${DateFormat('d MMM yyyy').format(_from)} to ${DateFormat('d MMM yyyy').format(_to)}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
        pw.SizedBox(height: 10),
        pw.Table.fromTextArray(
          headers: ['Code','Account','Open Dr','Open Cr','Period Dr','Period Cr','Close Dr','Close Cr'],
          data: [for (final r in _rows) [
            r['code']??'', r['name']??'',
            fmt.format(_n(r['opening_dr'])),
            fmt.format(_n(r['opening_cr'])),
            fmt.format((r['period_dr']  as num?? 0).toDouble()),
            fmt.format((r['period_cr']  as num?? 0).toDouble()),
            fmt.format(_n(r['closing_dr'])),
            fmt.format(_n(r['closing_cr'])),
          ]],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 7),
          cellStyle: const pw.TextStyle(fontSize: 7),
          cellAlignments: {for (int i = 2; i <= 7; i++) i: pw.Alignment.centerRight},
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF1F5F9)),
        ),
      ],
    ));
    await Printing.layoutPdf(onLayout: (_) async => doc.save(), name: 'trial_balance.pdf');
  }


  static double _n(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  // Flatten summary + expanded children into a single render list.
  List<_Line> _display() {
    final out = <_Line>[];
    for (final r in _rows) {
      final code = (r['code'] ?? '') as String;
      final kids = _children[code] ?? const [];
      out.add(_Line(r, hasChildren: kids.isNotEmpty, code: code));
      if (kids.isNotEmpty && _expanded.contains(code)) {
        for (final k in kids) out.add(_Line(k, isChild: true));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedBranchProvider, (_, __) => _load());
    final branch = ref.watch(selectedBranchProvider);
    final scope = ref.watch(branchScopeProvider).valueOrNull ??
        const BranchScope(restricted: false, allowed: []);
    final fmt = const MoneyFmt();
    double tDr = _rows.fold(0.0, (s, r) => s + (r['closing_dr'] as num? ?? 0));
    double tCr = _rows.fold(0.0, (s, r) => s + (r['closing_cr'] as num? ?? 0));
    final balanced = (tDr - tCr).abs() < 0.01;
    final lines = _display();

    return Container(
      color: AppTheme.background, padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Trial Balance', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          IconButton(onPressed: _print, icon: const Icon(Icons.print_outlined), tooltip: 'Print / PDF'),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
        const SizedBox(height: 4),
        Text(scope.label(allSelected: _allBranches, selected: branch), style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Row(children: [
          _datePicker('From', _from, (d) { setState(() => _from = d); _load(); }, maxDate: _to),
          const SizedBox(width: 12),
          _datePicker('To', _to, (d) { setState(() => _to = d); _load(); }, minDate: _from),
          const SizedBox(width: 12),
          // A trial balance is an org-level statement; a single-branch view won't
          // balance when stock has moved between branches (in-transit accounts).
          // This toggle flips to the exact organization-wide view.
          // "All" means different things to different people: org-wide for an
          // admin, but only the user's OWN branches for an erpUser — which is why
          // BranchScope resolves it rather than passing null blindly. A user with
          // exactly one branch gets no toggle; there is nothing to consolidate.
          if (scope.canToggleAll) OutlinedButton.icon(
            icon: Icon(_allBranches ? Icons.account_tree : Icons.store, size: 16),
            label: Text(_allBranches
                ? (scope.restricted ? 'All My Branches' : 'All Branches')
                : 'This Branch'),
            onPressed: () { setState(() => _allBranches = !_allBranches); _load(); },
          ),
        ]),
        if (!_loading && _rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            _card('Accounts', '${_rows.length}', AppTheme.primary),
            const SizedBox(width: 12),
            _card('Total Debit', fmt.format(tDr), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Total Credit', fmt.format(tCr), AppTheme.primary),
            const SizedBox(width: 12),
            _card('Status', balanced ? 'Balanced ✓' : 'Unbalanced ✗', balanced ? AppTheme.success : AppTheme.danger),
          ]),
          if (!balanced && !_allBranches && branch != null) Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(child: Text(
                'A single-branch view may not balance when stock has moved between branches (in-transit accounts). Switch to "All Branches" for the organization-wide check.',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Expanded(child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: _loading ? const Center(child: CircularProgressIndicator())
            : _rows.isEmpty ? const Center(child: Text('No data for period.', style: TextStyle(color: AppTheme.textSecondary)))
            : Column(children: [
                _hdr(),
                const Divider(height: 1),
                Expanded(child: ListView.separated(
                  itemCount: lines.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    if (i == lines.length) return _totals(fmt, tDr, tCr);
                    return _line(fmt, lines[i]);
                  },
                )),
              ]),
        )),
      ]),
    );
  }

  Widget _datePicker(String label, DateTime date, void Function(DateTime) onPick, {DateTime? minDate, DateTime? maxDate}) =>
    OutlinedButton.icon(
      icon: const Icon(Icons.calendar_today, size: 16),
      label: Text('$label: ${DateFormat('d MMM yyyy').format(date)}'),
      onPressed: () async {
        final d = await showDatePicker(context: context, initialDate: date,
          firstDate: minDate ?? DateTime(2020), lastDate: maxDate ?? DateTime(2100));
        if (d != null) onPick(d);
      },
    );

  Widget _hdr() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    child: Row(children: [
      const SizedBox(width: 56, child: Text('Code', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
      // 22px lead reserves space for the expand chevron so the header aligns with rows.
      const SizedBox(width: 22),
      const Expanded(flex: 3, child: Text('Account', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
      for (final l in ['Open Dr','Open Cr','Period Dr','Period Cr','Close Dr','Close Cr'])
        Expanded(child: Text(l, textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.textSecondary))),
    ]),
  );

  Widget _line(MoneyFmt fmt, _Line ln) {
    final r = ln.row;
    if (ln.isChild) {
      return Container(
        color: AppTheme.background.withOpacity(0.35),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          SizedBox(width: 56, child: Text(r['code']??'', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))),
          const SizedBox(width: 22),
          Expanded(flex: 3, child: Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Row(children: [
              const Icon(Icons.subdirectory_arrow_right, size: 13, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(child: Text(r['name']??'', style: const TextStyle(fontSize: 11))),
            ]),
          )),
          for (final k in ['opening_dr','opening_cr','period_dr','period_cr','closing_dr','closing_cr'])
            Expanded(child: _amt(fmt, r[k])),
        ]),
      );
    }

    final expanded = _expanded.contains(ln.code);
    final inner = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        SizedBox(width: 56, child: Text(r['code']??'', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
        SizedBox(width: 22, child: ln.hasChildren
          ? Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 18, color: AppTheme.textSecondary)
          : null),
        Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r['name']??'', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          Text(r['account_group']??'', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ])),
        for (final k in ['opening_dr','opening_cr','period_dr','period_cr','closing_dr','closing_cr'])
          Expanded(child: _amt(fmt, r[k])),
      ]),
    );
    if (!ln.hasChildren) return inner;
    return InkWell(
      onTap: () => setState(() {
        if (expanded) { _expanded.remove(ln.code); } else { _expanded.add(ln.code); }
      }),
      child: inner,
    );
  }

  Widget _totals(MoneyFmt fmt, double dr, double cr) => Container(
    color: AppTheme.background,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(children: [
      const SizedBox(width: 56),
      const SizedBox(width: 22),
      const Expanded(flex: 3, child: Text('TOTALS', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
      for (final v in [
        _rows.fold(0.0, (s, r) => s + (r['opening_dr'] as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['opening_cr'] as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['period_dr']  as num?? 0)),
        _rows.fold(0.0, (s, r) => s + (r['period_cr']  as num?? 0)),
        dr, cr,
      ])
        Expanded(child: Text(fmt.format(v), textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppTheme.primary))),
    ]),
  );

  Widget _amt(MoneyFmt fmt, dynamic v) {
    final d = (v as num? ?? 0).toDouble();
    return Text(d > 0.005 ? fmt.format(d) : '-', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11));
  }

  Widget _card(String label, String value, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
    ]),
  );
}

// A single render line: either a level-3 summary (parent) or a level-4 detail (child).
class _Line {
  final Map row;
  final bool isChild;
  final bool hasChildren;
  final String code;
  _Line(this.row, {this.isChild = false, this.hasChildren = false, this.code = ''});
}
