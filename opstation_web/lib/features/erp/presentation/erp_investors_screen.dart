// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/layout/main_layout.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import '../services/investor_profit.dart';

/// Financials → Investors. Investor agreements, tranches with their
/// breakdown (Whole business / whole GRNs), period profit runs (posted as
/// journal vouchers), yearly reinvestment and the investor statement.
class ErpInvestorsScreen extends ConsumerStatefulWidget {
  const ErpInvestorsScreen({super.key});
  @override
  ConsumerState<ErpInvestorsScreen> createState() => _State();
}

class _State extends ConsumerState<ErpInvestorsScreen> {
  SupabaseClient get _db => Supabase.instance.client;
  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  final _money = const MoneyFmt();
  final _df = DateFormat('d MMM yyyy');

  bool _loading = true;
  List<Map<String, dynamic>> _investors = [];
  Map<String, dynamic>? _sel;
  List<Map<String, dynamic>> _tranches = [];
  List<Map<String, dynamic>> _lines = [];
  List<Map<String, dynamic>> _runs = [];
  Map<String, Map<String, dynamic>> _accounts = {}; // id → coa row
  bool _detailLoading = false;

  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Future<void> _load({String? keep}) async {
    final org = _orgId;
    if (org == null) return;
    setState(() => _loading = true);
    try {
      final r = await _db.from('investors').select().eq('org_id', org).order('name');
      _investors = List<Map<String, dynamic>>.from(r as List);
      final pick = keep ?? _sel?['id'];
      _sel = pick == null ? null : _investors.where((i) => i['id'] == pick).firstOrNull;
      _sel ??= _investors.isNotEmpty ? _investors.first : null;
      setState(() => _loading = false);
      if (_sel != null) await _loadDetail();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack(friendlyError('Could not load investors', e));
    }
  }

  Future<void> _loadDetail() async {
    final inv = _sel;
    if (inv == null) return;
    setState(() => _detailLoading = true);
    try {
      final t = await _db.from('investor_tranches').select().eq('investor_id', inv['id']).order('invested_on');
      final tranches = List<Map<String, dynamic>>.from(t as List);
      final ids = [for (final x in tranches) x['id']];
      final lines = ids.isEmpty ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _db.from('investor_tranche_lines').select().inFilter('tranche_id', ids).order('created_at') as List);
      final runs = List<Map<String, dynamic>>.from(await _db.from('investor_profit_runs').select()
          .eq('investor_id', inv['id']).order('period_from', ascending: false) as List);
      final accIds = [inv['investment_account_id'], inv['payable_account_id'], inv['expense_account_id']].whereType<String>().toList();
      final acc = <String, Map<String, dynamic>>{};
      if (accIds.isNotEmpty) {
        final a = await _db.from('chart_of_accounts').select('id, code, name, account_type').inFilter('id', accIds);
        for (final x in a as List) { acc[x['id'] as String] = Map<String, dynamic>.from(x); }
      }
      if (!mounted) return;
      setState(() { _tranches = tranches; _lines = lines; _runs = runs; _accounts = acc; _detailLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _detailLoading = false);
      _snack(friendlyError('Could not load the investor', e));
    }
  }

  // ── COA picker ──────────────────────────────────────────────────────────
  Future<Map<String, dynamic>?> _pickAccount(String title, {String? type}) async {
    final org = _orgId;
    if (org == null) return null;
    return showDialog<Map<String, dynamic>>(context: context,
        builder: (_) => _AccountPicker(orgId: org, title: title, type: type));
  }

  Future<void> _settings() async {
    final org = _orgId;
    if (org == null) return;
    final cfg = await _db.from('app_config').select('key, value').eq('org_id', org)
        .inFilter('key', ['org.investor_liability_parent', 'org.investor_expense_parent']);
    final m = {for (final r in cfg as List) '${r['key']}': '${r['value'] ?? ''}'};
    Future<String> nameOf(String? id) async {
      if (id == null || id.isEmpty) return 'Not set';
      final r = await _db.from('chart_of_accounts').select('code, name').eq('id', id).maybeSingle();
      return r == null ? 'Not found' : '${r['code']}  ${r['name']}';
    }
    String liab = m['org.investor_liability_parent'] ?? '', exp = m['org.investor_expense_parent'] ?? '';
    String liabName = await nameOf(liab), expName = await nameOf(exp);
    if (!mounted) return;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Widget row(String label, String help, String value, Future<void> Function() pick) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        subtitle: Text('$value\n$help', style: const TextStyle(fontSize: 11.5)),
        isThreeLine: true,
        trailing: TextButton(onPressed: pick, child: const Text('Choose')));
      return AlertDialog(
        title: const Text('Investor settings'),
        content: SizedBox(width: 500, child: Column(mainAxisSize: MainAxisSize.min, children: [
          row('Parent for investor accounts', 'Each investor gets "Investment – Name" and "Profit payable – Name" under this (e.g. Investor Funds / Temporary Investments).', liabName, () async {
            final a = await _pickAccount('Parent for investor accounts', type: null);
            if (a == null) return;
            liab = a['id'] as String; liabName = '${a['code']}  ${a['name']}';
            setS(() {});
          }),
          row('Parent for profit expense', 'Each investor gets "Profit on investment – Name" under this (e.g. Profit on Investments).', expName, () async {
            final a = await _pickAccount('Parent for profit expense', type: 'expense');
            if (a == null) return;
            exp = a['id'] as String; expName = '${a['code']}  ${a['name']}';
            setS(() {});
          }),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () async {
            try {
              for (final e in {'org.investor_liability_parent': liab, 'org.investor_expense_parent': exp}.entries) {
                await _db.from('app_config').upsert({'key': e.key, 'value': e.value, 'org_id': org}, onConflict: 'key,org_id,branch_id');
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _snack('Investor settings saved');
            } catch (e) { _snack(friendlyError('That did not save', e)); }
          }, child: const Text('Save')),
        ],
      );
    }));
  }

  // ── investor form ───────────────────────────────────────────────────────
  Future<void> _editInvestor([Map<String, dynamic>? inv]) async {
    final name = TextEditingController(text: inv?['name'] ?? '');
    final phone = TextEditingController(text: inv?['phone'] ?? '');
    final cnic = TextEditingController(text: inv?['cnic'] ?? '');
    final notes = TextEditingController(text: inv?['notes'] ?? '');
    final share = TextEditingController(text: '${inv?['share_pct'] ?? 50}');
    final floor = TextEditingController(text: '${inv?['floor_pct'] ?? 0}');
    final cap = TextEditingController(text: '${inv?['cap_pct'] ?? 0}');
    DateTime start = DateTime.tryParse('${inv?['start_date'] ?? ''}') ?? DateTime.now();
    String freq = '${inv?['payout_frequency'] ?? 'monthly'}';
    String basis = '${inv?['limit_basis'] ?? 'annual'}';
    bool deductReturns = inv?['deduct_returns'] != false;
    final firstAmt = TextEditingController();
    DateTime? firstOn;
    String firstBasis = 'business';
    final acc = <String, Map<String, dynamic>?>{
      'investment_account_id': inv == null ? null : _accounts[inv['investment_account_id']],
      'payable_account_id': inv == null ? null : _accounts[inv['payable_account_id']],
      'expense_account_id': inv == null ? null : _accounts[inv['expense_account_id']],
    };
    bool saving = false;
    final num = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    await showDialog(context: context, barrierDismissible: false, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      Widget accRow(String key, String label, String? type) {
        final a = acc[key];
        return Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5))),
          Flexible(flex: 2, child: Text(a == null ? 'Create automatically' : '${a['code']}  ${a['name']}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: a == null ? AppTheme.textSecondary : AppTheme.textPrimary, fontWeight: FontWeight.w600))),
          TextButton(onPressed: () async {
            final x = await _pickAccount(label, type: type);
            if (x != null) setS(() => acc[key] = x);
          }, child: const Text('Use existing')),
          if (a != null) IconButton(icon: const Icon(Icons.close, size: 16), tooltip: 'Create automatically instead',
              onPressed: () => setS(() => acc[key] = null)),
        ]);
      }
      return AlertDialog(
        title: Text(inv == null ? 'Add investor' : 'Edit investor'),
        content: SizedBox(width: 560, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name *')),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: cnic, decoration: const InputDecoration(labelText: 'CNIC'))),
          ]),
          const SizedBox(height: 14),
          InkWell(
            onTap: () async {
              final d = await showDatePicker(context: ctx, initialDate: start, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setS(() => start = d);
            },
            child: InputDecorator(decoration: const InputDecoration(labelText: 'Agreement start', isDense: true),
                child: Text(_df.format(start))),
          ),
          const SizedBox(height: 18),
          const Align(alignment: Alignment.centerLeft, child: Text('Agreement', style: TextStyle(fontWeight: FontWeight.w800))),
          const SizedBox(height: 4),
          const Align(alignment: Alignment.centerLeft, child: Text(
              'Whole business or goods-specific is chosen for each amount invested: below for the first amount, '
              'and later from the investor\'s page (Add investment → Whole business / Link GRN). One investor can have both.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: TextField(controller: share, inputFormatters: num,
                decoration: const InputDecoration(labelText: 'Investor share % of profit earned'))),
            const SizedBox(width: 12),
            Expanded(child: DropdownButtonFormField<String>(value: freq, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Payout'),
                items: [for (final e in InvestorProfit.frequencies.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setS(() => freq = v ?? freq))),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: TextField(controller: floor, inputFormatters: num,
                decoration: const InputDecoration(labelText: 'Floor % (0 = none)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: cap, inputFormatters: num,
                decoration: const InputDecoration(labelText: 'Cap % (0 = none)'))),
            const SizedBox(width: 12),
            Expanded(child: DropdownButtonFormField<String>(value: basis, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Floor / cap is'),
                items: const [
                  DropdownMenuItem(value: 'annual', child: Text('% a year (scaled)')),
                  DropdownMenuItem(value: 'period', child: Text('% per period')),
                ],
                onChanged: (v) => setS(() => basis = v ?? basis))),
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero, dense: true,
            value: deductReturns,
            onChanged: (v) => setS(() => deductReturns = v),
            title: const Text('Goods-specific (GRN) parts: deduct returns', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: const Text('When goods from a linked GRN come back, their profit is taken off in the month of the return. Whole-business parts already include returns.',
                style: TextStyle(fontSize: 11.5)),
          ),
          const SizedBox(height: 6),
          const Align(alignment: Alignment.centerLeft, child: Text(
              'Loss months: nothing is posted and the result is kept on record — the policy can be set later.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
          if (inv == null) ...[
            const SizedBox(height: 18),
            const Align(alignment: Alignment.centerLeft, child: Text('First investment (optional)', style: TextStyle(fontWeight: FontWeight.w800))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: firstAmt, inputFormatters: num,
                  decoration: const InputDecoration(labelText: 'Amount (Rs)'))),
              const SizedBox(width: 12),
              Expanded(child: InkWell(
                onTap: () async {
                  final d = await showDatePicker(context: ctx, initialDate: firstOn ?? start, firstDate: DateTime(2020), lastDate: DateTime(2100));
                  if (d != null) setS(() => firstOn = d);
                },
                child: InputDecorator(decoration: const InputDecoration(labelText: 'Invested on', isDense: true),
                    child: Text(_df.format(firstOn ?? start))),
              )),
              const SizedBox(width: 12),
              Expanded(child: DropdownButtonFormField<String>(value: firstBasis, isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Basis'),
                  items: const [
                    DropdownMenuItem(value: 'business', child: Text('Whole business')),
                    DropdownMenuItem(value: 'grn', child: Text('Goods-specific (link GRNs next)')),
                  ],
                  onChanged: (v) => setS(() => firstBasis = v ?? firstBasis))),
            ]),
          ],
          const SizedBox(height: 18),
          const Align(alignment: Alignment.centerLeft, child: Text('Accounts', style: TextStyle(fontWeight: FontWeight.w800))),
          const SizedBox(height: 4),
          accRow('investment_account_id', 'Investment account', null),
          accRow('payable_account_id', 'Profit payable account', null),
          accRow('expense_account_id', 'Profit expense account', 'expense'),
          const SizedBox(height: 12),
          TextField(controller: notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
        ]))),
        actions: [
          TextButton(onPressed: saving ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: saving ? null : () async {
            if (name.text.trim().isEmpty) { _snack('Enter the investor name'); return; }
            setS(() => saving = true);
            try {
              final data = {
                'org_id': _orgId, 'name': name.text.trim(),
                'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
                'cnic': cnic.text.trim().isEmpty ? null : cnic.text.trim(),
                'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
                'start_date': DateFormat('yyyy-MM-dd').format(start),
                'share_pct': double.tryParse(share.text) ?? 50,
                'floor_pct': double.tryParse(floor.text) ?? 0,
                'cap_pct': double.tryParse(cap.text) ?? 0,
                'limit_basis': basis, 'payout_frequency': freq,
                'deduct_returns': deductReturns,
                for (final k in acc.keys) k: acc[k]?['id'],
              };
              String id;
              if (inv == null) {
                final r = await _db.from('investors').insert({...data, 'created_by': ref.read(currentUserProvider)?.id}).select('id').single();
                id = r['id'] as String;
              } else {
                id = inv['id'] as String;
                await _db.from('investors').update(data).eq('id', id);
              }
              try {
                await _db.rpc('investor_ensure_accounts', params: {'p_investor': id});
              } catch (e) {
                _snack(friendlyError('Saved, but the accounts could not be created', e));
              }
              final fa = double.tryParse(firstAmt.text) ?? 0;
              if (inv == null && fa > 0) {
                try {
                  final t = await _db.from('investor_tranches').insert({
                    'org_id': _orgId, 'investor_id': id, 'amount': fa,
                    'invested_on': DateFormat('yyyy-MM-dd').format(firstOn ?? start),
                  }).select('id').single();
                  if (firstBasis == 'business') {
                    await _db.from('investor_tranche_lines').insert(
                        {'org_id': _orgId, 'tranche_id': t['id'], 'kind': 'business', 'amount': fa});
                  } else {
                    _snack('Investor saved — now link the GRNs for this amount on their page');
                  }
                } catch (e) {
                  _snack(friendlyError('Investor saved, but the first investment did not', e));
                }
              }
              if (ctx.mounted) Navigator.pop(ctx);
              await _load(keep: id);
            } catch (e) {
              setS(() => saving = false);
              _snack(friendlyError('That did not save', e));
            }
          }, child: Text(saving ? 'Saving…' : 'Save')),
        ],
      );
    }));
  }

  // ── tranche + breakdown ─────────────────────────────────────────────────
  double _allocated(String trancheId) =>
      _lines.where((l) => l['tranche_id'] == trancheId).fold(0.0, (s, l) => s + InvestorProfit.n(l['amount']));

  Future<void> _addTranche() async {
    final inv = _sel;
    if (inv == null) return;
    final amt = TextEditingController();
    final note = TextEditingController();
    DateTime on = DateTime.now();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      title: const Text('Add investment'),
      content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: amt, autofocus: true, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Amount (Rs) *')),
        const SizedBox(height: 10),
        InkWell(
          onTap: () async {
            final d = await showDatePicker(context: ctx, initialDate: on, firstDate: DateTime(2020), lastDate: DateTime(2100));
            if (d != null) setS(() => on = d);
          },
          child: InputDecorator(decoration: const InputDecoration(labelText: 'Invested on', isDense: true), child: Text(_df.format(on))),
        ),
        TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
        const SizedBox(height: 8),
        const Text('Record the money itself with a receipt voucher to the investor\'s Investment account. Then break this amount down into Whole business and GRNs.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
      ],
    )));
    if (ok != true) return;
    final a = double.tryParse(amt.text) ?? 0;
    if (a <= 0) { _snack('Enter the amount'); return; }
    try {
      await _db.from('investor_tranches').insert({
        'org_id': _orgId, 'investor_id': inv['id'], 'amount': a,
        'invested_on': DateFormat('yyyy-MM-dd').format(on), 'note': note.text.trim().isEmpty ? null : note.text.trim(),
      });
      await _loadDetail();
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  Future<void> _addBusinessLine(Map<String, dynamic> t) async {
    final left = InvestorProfit.n(t['amount']) - _allocated(t['id']);
    final amt = TextEditingController(text: left > 0 ? left.toStringAsFixed(0) : '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Whole business'),
      content: SizedBox(width: 360, child: TextField(controller: amt, autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(labelText: 'Amount (Rs)', helperText: 'Up to Rs ${_money.format(left)} left'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
      ],
    ));
    if (ok != true) return;
    final a = double.tryParse(amt.text) ?? 0;
    if (a <= 0) return;
    if (a > left + 0.01) { _snack('That is more than the Rs ${_money.format(left)} left to allocate'); return; }
    try {
      await _db.from('investor_tranche_lines').insert({'org_id': _orgId, 'tranche_id': t['id'], 'kind': 'business', 'amount': a});
      await _loadDetail();
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  Future<void> _addGrnLine(Map<String, dynamic> t) async {
    final org = _orgId;
    if (org == null) return;
    final left = InvestorProfit.n(t['amount']) - _allocated(t['id']);
    final search = TextEditingController();
    final exp = TextEditingController(text: '0');
    List<Map<String, dynamic>> list = [];
    bool loading = true;
    Future<void> fetch(void Function(void Function()) setS) async {
      setS(() => loading = true);
      try {
        list = List<Map<String, dynamic>>.from(await _db.rpc('investor_free_grns', params: {'p_org': org, 'p_search': search.text.trim()}) as List);
      } catch (_) { list = []; }
      setS(() => loading = false);
    }
    final picked = await showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      if (loading && list.isEmpty) { Future.microtask(() => fetch(setS)); }
      return AlertDialog(
        title: const Text('Link a GRN'),
        content: SizedBox(width: 560, height: 480, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The whole GRN is linked. Rs ${_money.format(left)} left to allocate.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: search, onSubmitted: (_) => fetch(setS),
                decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'GRN number or supplier, then Enter', border: OutlineInputBorder()))),
            const SizedBox(width: 10),
            SizedBox(width: 150, child: TextField(controller: exp,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                decoration: const InputDecoration(isDense: true, labelText: 'Expense share %', border: OutlineInputBorder()))),
          ]),
          const SizedBox(height: 8),
          Expanded(child: loading
              ? const Center(child: CircularProgressIndicator())
              : list.isEmpty
                  ? const Center(child: Text('No free GRNs found', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final g = list[i];
                        final v = InvestorProfit.n(g['value']);
                        final fits = v > 0 && v <= left + 0.01;
                        return ListTile(dense: true, enabled: fits,
                          title: Text('${g['voucher_number']}  ·  ${g['supplier'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(_df.format(DateTime.parse('${g['voucher_date']}'))),
                          trailing: Text(fits ? 'Rs ${_money.format(v)}' : 'Rs ${_money.format(v)} · too big',
                              style: TextStyle(fontWeight: FontWeight.w700, color: fits ? null : AppTheme.danger)),
                          onTap: fits ? () => Navigator.pop(ctx, g) : null);
                      })),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      );
    }));
    if (picked == null) return;
    try {
      await _db.from('investor_tranche_lines').insert({
        'org_id': org, 'tranche_id': t['id'], 'kind': 'grn', 'amount': InvestorProfit.n(picked['value']),
        'grn_id': picked['id'], 'grn_number': picked['voucher_number'],
        'expense_share_pct': double.tryParse(exp.text) ?? 0,
      });
      await _loadDetail();
    } catch (e) { _snack(friendlyError('That GRN could not be linked', e)); }
  }

  bool _lineUsed(Map l) => _runs.any((r) => r['status'] != 'void' &&
      DateTime.parse('${r['period_to']}').isAfter(DateTime.parse('${_tranches.firstWhere((t) => t['id'] == l['tranche_id'])['invested_on']}')));

  Future<void> _removeLine(Map<String, dynamic> l) async {
    if (_lineUsed(l)) {
      _snack('This line was already used in a posted profit run. Void those runs first to change it.');
      return;
    }
    try {
      await _db.from('investor_tranche_lines').delete().eq('id', l['id']);
      await _loadDetail();
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  Future<void> _endTranche(Map<String, dynamic> t) async {
    DateTime on = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: on, firstDate: DateTime.parse('${t['invested_on']}'), lastDate: DateTime(2100),
        helpText: 'Withdrawn on');
    if (d == null) return;
    try {
      await _db.from('investor_tranches').update({'ended_on': DateFormat('yyyy-MM-dd').format(d)}).eq('id', t['id']);
      await _loadDetail();
      _snack('Marked withdrawn — pay it out with a payment voucher from the Investment account.');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  // ── profit run ──────────────────────────────────────────────────────────
  Future<void> _run(DateTime from, DateTime to) async {
    final inv = _sel;
    final org = _orgId;
    if (inv == null || org == null) return;
    if (inv['expense_account_id'] == null || inv['payable_account_id'] == null) {
      _snack('Set up this investor\'s accounts first (Edit investor → Save).');
      return;
    }
    final unalloc = _tranches.where((t) => t['ended_on'] == null &&
        InvestorProfit.n(t['amount']) - _allocated(t['id']) > 0.01).length;
    Map<String, dynamic>? calc;
    String? err;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(
        content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Calculating…')])));
    try {
      calc = await InvestorProfit.calculate(orgId: org, investor: inv, from: from, to: to);
    } catch (e) {
      err = friendlyError('The calculation did not work', e);
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (calc == null) { _snack(err ?? 'The calculation did not work'); return; }
    final c = calc;
    bool posting = false;
    await showDialog(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      title: Text('Profit run · ${inv['name']} · ${InvestorProfit.periodLabel(from, to)}'),
      content: SizedBox(width: 620, child: SingleChildScrollView(child: _calcView(c, unalloc))),
      actions: [
        TextButton(onPressed: posting ? null : () => Navigator.pop(ctx), child: const Text('Close')),
        ElevatedButton(
          onPressed: posting ? null : () async {
            setS(() => posting = true);
            final err2 = await _postRun(inv, c, from, to);
            if (!ctx.mounted) return;
            if (err2 != null) { setS(() => posting = false); _snack(err2); return; }
            Navigator.pop(ctx);
            await _loadDetail();
          },
          child: Text(posting ? 'Posting…' : c['status'] == 'loss' ? 'Record loss (nothing posted)' : 'Post Rs ${_money.format(InvestorProfit.n(c['amount']))}'),
        ),
      ],
    )));
  }

  Future<String?> _postRun(Map<String, dynamic> inv, Map<String, dynamic> c, DateTime from, DateTime to) async {
    final org = _orgId!;
    final u = ref.read(currentUserProvider);
    final branch = ref.read(selectedBranchProvider)?['id'] as String? ?? '';
    try {
      String? jeId, jeNo;
      final amount = InvestorProfit.n(c['amount']);
      if (c['status'] != 'loss' && amount > 0) {
        final exp = _accounts[inv['expense_account_id']];
        final pay = _accounts[inv['payable_account_id']];
        final r = await InvestorProfit.postJv(
          orgId: org, branchId: branch, userId: u?.id ?? '', date: to,
          narration: 'Profit share ${inv['name']} · ${InvestorProfit.periodLabel(from, to)}',
          debitAccount: inv['expense_account_id'], debitName: '${exp?['name'] ?? 'Profit on investment'}',
          creditAccount: inv['payable_account_id'], creditName: '${pay?['name'] ?? 'Profit payable'}',
          amount: amount,
        );
        jeId = r.$1; jeNo = r.$2;
      }
      await _db.from('investor_profit_runs').insert({
        'org_id': org, 'investor_id': inv['id'],
        'period_from': DateFormat('yyyy-MM-dd').format(from), 'period_to': DateFormat('yyyy-MM-dd').format(to),
        'status': c['status'] == 'loss' ? 'loss' : 'posted', 'amount': c['status'] == 'loss' ? 0 : amount,
        'calc': c, 'entry_id': jeId, 'entry_number': jeNo,
        'created_by': u?.id, 'created_by_name': u?.name,
      });
      _snack(jeNo == null ? 'Recorded' : 'Posted $jeNo');
      return null;
    } catch (e) {
      return friendlyError('That did not post', e);
    }
  }

  Future<void> _voidRun(Map<String, dynamic> r) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Void this profit run?'),
      content: TextField(controller: reason, autofocus: true, decoration: const InputDecoration(labelText: 'Reason *')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('Void')),
      ],
    ));
    if (ok != true || reason.text.trim().isEmpty) return;
    final u = ref.read(currentUserProvider);
    try {
      if (r['entry_id'] != null) {
        await _db.rpc('void_journal_voucher', params: {
          'p_id': r['entry_id'], 'p_reason': reason.text.trim(), 'p_user': u?.id, 'p_user_name': u?.name,
        });
      }
      await _db.from('investor_profit_runs').update({'status': 'void'}).eq('id', r['id']);
      await _loadDetail();
      _snack('Voided');
    } catch (e) { _snack(friendlyError('That did not void', e)); }
  }

  // ── reinvest (yearly) ───────────────────────────────────────────────────
  Future<void> _reinvest() async {
    final inv = _sel;
    final org = _orgId;
    if (inv == null || org == null) return;
    final start = DateTime.parse('${inv['start_date']}');
    final lastRe = _tranches.where((t) => t['source'] == 'reinvest').map((t) => DateTime.parse('${t['invested_on']}')).fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final from = lastRe ?? start;
    final due = DateTime(from.year + 1, from.month, from.day);
    if (DateTime.now().isBefore(due)) {
      _snack('Reinvestment is yearly — next one from ${_df.format(due)}.');
      return;
    }
    double bal = 0;
    try { bal = await InvestorProfit.creditBalance(inv['payable_account_id']); } catch (_) {}
    if (bal <= 0) { _snack('No profit payable to reinvest.'); return; }
    final amt = TextEditingController(text: bal.toStringAsFixed(0));
    if (!mounted) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reinvest profit'),
      content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Profit payable: Rs ${_money.format(bal)}'),
        TextField(controller: amt, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: const InputDecoration(labelText: 'Amount to reinvest')),
        const SizedBox(height: 6),
        const Text('Moves it from Profit payable to the Investment account and adds it as a new investment from today. Break it down afterwards.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reinvest')),
      ],
    ));
    if (ok != true) return;
    final a = double.tryParse(amt.text) ?? 0;
    if (a <= 0 || a > bal + 0.01) { _snack('Enter an amount up to Rs ${_money.format(bal)}'); return; }
    final u = ref.read(currentUserProvider);
    try {
      final r = await InvestorProfit.postJv(
        orgId: org, branchId: ref.read(selectedBranchProvider)?['id'] as String? ?? '', userId: u?.id ?? '',
        date: DateTime.now(), narration: 'Profit reinvested · ${inv['name']}',
        debitAccount: inv['payable_account_id'], debitName: '${_accounts[inv['payable_account_id']]?['name'] ?? 'Profit payable'}',
        creditAccount: inv['investment_account_id'], creditName: '${_accounts[inv['investment_account_id']]?['name'] ?? 'Investment'}',
        amount: a,
      );
      await _db.from('investor_tranches').insert({
        'org_id': org, 'investor_id': inv['id'], 'amount': a,
        'invested_on': DateFormat('yyyy-MM-dd').format(DateTime.now()), 'source': 'reinvest', 'note': 'Reinvested · ${r.$2}',
      });
      await _loadDetail();
      _snack('Reinvested — ${r.$2}. Now break the new investment down.');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  // ── statement ───────────────────────────────────────────────────────────
  Future<void> _statement() async {
    final inv = _sel;
    if (inv == null) return;
    double payable = 0, invested = 0;
    try {
      if (inv['payable_account_id'] != null) payable = await InvestorProfit.creditBalance(inv['payable_account_id']);
      if (inv['investment_account_id'] != null) invested = await InvestorProfit.creditBalance(inv['investment_account_id']);
    } catch (_) {}
    String esc(Object? s) => const HtmlEscape().convert('${s ?? ''}');
    final b = StringBuffer()
      ..write('<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Investor statement</title><style>'
          'body{font-family:Arial,sans-serif;padding:20px;font-size:11.5px;color:#111}h1{font-size:19px;margin:0}'
          'h2{font-size:13px;margin:18px 0 6px;border-bottom:2px solid #000;padding-bottom:3px}'
          'table{width:100%;border-collapse:collapse}td,th{padding:4px 6px;border-bottom:1px solid #ddd;text-align:left}'
          '.n{text-align:right}.muted{color:#555}</style></head><body>'
          '<button onclick="window.print()">Print</button>')
      ..write('<h1>Investor statement — ${esc(inv['name'])}</h1>')
      ..write('<div class="muted">Agreement from ${esc(_df.format(DateTime.parse('${inv['start_date']}')))} · '
          'share ${esc(inv['share_pct'])}% · payout ${esc(InvestorProfit.frequencies[inv['payout_frequency']])} · '
          'floor ${esc(inv['floor_pct'])}% · cap ${esc(inv['cap_pct'])}% (${inv['limit_basis'] == 'annual' ? 'a year' : 'per period'}) · '
          'printed ${esc(_df.format(DateTime.now()))}</div>')
      ..write('<h2>Balances</h2><table><tr><td>Investment account</td><td class="n">Rs ${esc(_money.format(invested))}</td></tr>'
          '<tr><td>Profit payable</td><td class="n">Rs ${esc(_money.format(payable))}</td></tr></table>')
      ..write('<h2>Investments</h2><table><tr><th>Date</th><th>Source</th><th>Breakdown</th><th class="n">Amount</th></tr>');
    for (final t in _tranches) {
      final ls = _lines.where((l) => l['tranche_id'] == t['id']).map((l) =>
          l['kind'] == 'grn' ? 'GRN ${l['grn_number']} Rs ${_money.format(InvestorProfit.n(l['amount']))}' : 'Whole business Rs ${_money.format(InvestorProfit.n(l['amount']))}').join('; ');
      b.write('<tr><td>${esc(_df.format(DateTime.parse('${t['invested_on']}')))}${t['ended_on'] != null ? ' → ${esc(_df.format(DateTime.parse('${t['ended_on']}')))}' : ''}</td>'
          '<td>${esc(t['source'])}</td><td>${esc(ls.isEmpty ? 'Not allocated' : ls)}</td><td class="n">Rs ${esc(_money.format(InvestorProfit.n(t['amount'])))}</td></tr>');
    }
    b.write('</table><h2>Profit</h2><table><tr><th>Period</th><th class="n">Net profit</th><th class="n">Business part</th>'
        '<th class="n">GRN part</th><th class="n">Your share</th><th>Note</th><th class="n">Posted</th></tr>');
    for (final r in _runs.where((x) => x['status'] != 'void')) {
      final c = Map<String, dynamic>.from((r['calc'] as Map?) ?? {});
      b.write('<tr><td>${esc(InvestorProfit.periodLabel(DateTime.parse('${r['period_from']}'), DateTime.parse('${r['period_to']}')))}</td>'
          '<td class="n">${esc(_money.format(InvestorProfit.n(c['net_profit'])))}</td>'
          '<td class="n">${esc(_money.format(InvestorProfit.n(c['business_profit'])))}</td>'
          '<td class="n">${esc(_money.format(InvestorProfit.n(c['grn_profit'])))}</td>'
          '<td class="n">${esc(_money.format(InvestorProfit.n(c['gross_share'])))}</td>'
          '<td>${esc(c['limit_note'] ?? '')}</td>'
          '<td class="n">Rs ${esc(_money.format(InvestorProfit.n(r['amount'])))}${r['entry_number'] != null ? ' · ${esc(r['entry_number'])}' : ''}</td></tr>');
    }
    b.write('</table></body></html>');
    final blob = html.Blob([b.toString()], 'text/html');
    html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
  }

  // ── UI ──────────────────────────────────────────────────────────────────
  Widget _calcView(Map<String, dynamic> c, int unallocTranches) {
    String m(Object? v) => 'Rs ${_money.format(InvestorProfit.n(v))}';
    Widget kv(String k, String v, {bool bold = false, Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(k, style: const TextStyle(fontSize: 12.5))),
        Text(v, style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
      ]));
    final grn = ((c['grn_lines'] as List?) ?? const []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (unallocTranches > 0)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Colors.amber.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
          child: Text('$unallocTranches investment${unallocTranches == 1 ? ' has' : 's have'} money not yet broken down — that part earns nothing.',
              style: TextStyle(fontSize: 12, color: Colors.amber.shade900))),
      const Text('Business', style: TextStyle(fontWeight: FontWeight.w800)),
      kv('Net profit (before investor profit share)', m(c['net_profit'])),
      kv('Less: profit already shared through GRN lines (all investors)', m(c['grn_profit_all_investors'])),
      kv('Business pool', m(c['business_pool']), bold: true),
      kv('Capital employed (average of ${m(c['capital_open'])} and ${m(c['capital_close'])})', m(c['capital_avg'])),
      kv('Investor\'s whole-business capital-days ÷ all capital-days',
          '${(InvestorProfit.n(c['business_fraction']) * 100).toStringAsFixed(3)}%'),
      kv('Whole-business part', m(c['business_profit']), bold: true),
      if (grn.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('GRN lines', style: TextStyle(fontWeight: FontWeight.w800)),
        for (final g in grn) ...[
          kv('${g['grn_number']}: sold ${_money.format(InvestorProfit.n(g['qty']))} · sale ${m(g['revenue'])} − cost ${m(g['cost'])}',
              m(InvestorProfit.n(g['revenue']) - InvestorProfit.n(g['cost']))),
          if (InvestorProfit.n(g['return_qty']) > 0)
            kv(g['returns_deducted'] == false
                  ? '   Returned ${_money.format(InvestorProfit.n(g['return_qty']))} (not deducted for this investor)'
                  : '   Less returns: ${_money.format(InvestorProfit.n(g['return_qty']))} back · ${m(g['return_revenue'])} − cost ${m(g['return_cost'])}',
                g['returns_deducted'] == false
                    ? '-'
                    : m(-(InvestorProfit.n(g['return_revenue']) - InvestorProfit.n(g['return_cost'])))),
          if (InvestorProfit.n(g['expense_share_pct']) > 0)
            kv('   Less expense share ${InvestorProfit.n(g['expense_share_pct']).toStringAsFixed(0)}%', m(-InvestorProfit.n(g['expense']))),
          kv('   ${g['grn_number']} profit', m(g['profit'])),
        ],
        kv('GRN part', m(c['grn_profit']), bold: true),
      ],
      const Divider(height: 20),
      kv('Investor share ${InvestorProfit.n(c['share_pct']).toStringAsFixed(1)}%', m(c['gross_share']), bold: true),
      if (InvestorProfit.n(c['floor_pct']) > 0) kv('Floor ${c['floor_pct']}% (${c['limit_basis'] == 'annual' ? 'a year, scaled' : 'per period'})', m(c['floor_amount'])),
      if (InvestorProfit.n(c['cap_pct']) > 0) kv('Cap ${c['cap_pct']}% (${c['limit_basis'] == 'annual' ? 'a year, scaled' : 'per period'})', m(c['cap_amount'])),
      if (c['limit_note'] != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text('${c['limit_note']}', style: TextStyle(fontSize: 12, color: c['status'] == 'loss' ? AppTheme.danger : AppTheme.primary))),
      const Divider(height: 20),
      kv('To post', c['status'] == 'loss' ? 'Nothing (loss)' : m(c['amount']), bold: true,
          color: c['status'] == 'loss' ? AppTheme.danger : AppTheme.success),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 900;
    final list = _listPane();
    final detail = _sel == null
        ? const Center(child: Text('Add an investor to start.', style: TextStyle(color: AppTheme.textSecondary)))
        : _detailPane();
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('Investors', style: TextStyle(fontSize: narrow ? 20 : 26, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (_isAdmin) IconButton(tooltip: 'Investor settings', icon: const Icon(Icons.settings_outlined), onPressed: _settings),
          const SizedBox(width: 6),
          ElevatedButton.icon(onPressed: () => _editInvestor(), icon: const Icon(Icons.person_add_alt_1, size: 18), label: const Text('Add investor')),
        ]),
        const SizedBox(height: 14),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : narrow
                ? (_sel == null ? list : Column(children: [
                    SizedBox(height: 56, child: DropdownButtonFormField<String>(
                      value: _sel?['id'] as String?, isExpanded: true,
                      decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                      items: [for (final i in _investors) DropdownMenuItem(value: i['id'] as String, child: Text('${i['name']}'))],
                      onChanged: (v) { setState(() => _sel = _investors.firstWhere((i) => i['id'] == v)); _loadDetail(); })),
                    const SizedBox(height: 8),
                    Expanded(child: detail),
                  ]))
                : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(width: 280, child: list),
                    const SizedBox(width: 16),
                    Expanded(child: detail),
                  ])),
      ]),
    );
  }

  Widget _listPane() => Container(
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
    child: _investors.isEmpty
        ? const Center(child: Padding(padding: EdgeInsets.all(20),
            child: Text('No investors yet.', style: TextStyle(color: AppTheme.textSecondary))))
        : ListView.separated(
            itemCount: _investors.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final v = _investors[i];
              final on = v['id'] == _sel?['id'];
              return ListTile(
                selected: on,
                selectedTileColor: AppTheme.primary.withOpacity(0.06),
                title: Text('${v['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${InvestorProfit.n(v['share_pct']).toStringAsFixed(0)}% share · ${InvestorProfit.frequencies[v['payout_frequency']] ?? ''}',
                    style: const TextStyle(fontSize: 12)),
                onTap: () { setState(() => _sel = v); _loadDetail(); },
              );
            }),
  );

  Widget _card(String title, IconData icon, List<Widget> children, {Widget? action}) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 18, color: AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
        if (action != null) action,
      ]),
      const SizedBox(height: 10),
      ...children,
    ]),
  );

  Widget _detailPane() {
    final inv = _sel!;
    String acc(String key) {
      final a = _accounts[inv[key]];
      return a == null ? 'Not set' : '${a['code']}  ${a['name']}';
    }
    final periods = InvestorProfit.periods(DateTime.parse('${inv['start_date']}'), '${inv['payout_frequency']}');
    return _detailLoading
        ? const Center(child: CircularProgressIndicator())
        : ListView(children: [
            _card('Agreement', Icons.handshake_outlined, [
              Wrap(spacing: 24, runSpacing: 8, children: [
                _fact('Investor share', '${InvestorProfit.n(inv['share_pct']).toStringAsFixed(1)}%'),
                _fact('Payout', InvestorProfit.frequencies[inv['payout_frequency']] ?? '-'),
                _fact('Floor', InvestorProfit.n(inv['floor_pct']) > 0 ? '${inv['floor_pct']}%' : 'None'),
                _fact('Cap', InvestorProfit.n(inv['cap_pct']) > 0 ? '${inv['cap_pct']}%' : 'None'),
                _fact('Floor / cap is', inv['limit_basis'] == 'annual' ? '% a year (scaled)' : '% per period'),
                _fact('Loss months', 'Decide later'),
                _fact('Returns', inv['deduct_returns'] == false ? 'Not deducted' : 'Deducted from GRN profit'),
                _fact('Since', _df.format(DateTime.parse('${inv['start_date']}'))),
              ]),
              const SizedBox(height: 10),
              Text('Investment: ${acc('investment_account_id')}\nProfit payable: ${acc('payable_account_id')}\nProfit expense: ${acc('expense_account_id')}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, height: 1.5)),
            ], action: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton.icon(onPressed: _statement, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Statement')),
              TextButton.icon(onPressed: _reinvest, icon: const Icon(Icons.autorenew, size: 16), label: const Text('Reinvest')),
              TextButton.icon(onPressed: () => _editInvestor(inv), icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Edit')),
            ])),
            _card('Investments', Icons.account_balance_wallet_outlined, [
              if (_tranches.isEmpty)
                const Text('No investments recorded yet.', style: TextStyle(color: AppTheme.textSecondary)),
              for (final t in _tranches) _trancheTile(t),
            ], action: TextButton.icon(onPressed: _addTranche, icon: const Icon(Icons.add, size: 16), label: const Text('Add investment'))),
            _card('Profit runs', Icons.calculate_outlined, [
              for (final p in periods) _periodRow(p.$1, p.$2),
            ]),
          ]);
  }

  Widget _fact(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
  ]);

  Widget _trancheTile(Map<String, dynamic> t) {
    final amount = InvestorProfit.n(t['amount']);
    final alloc = _allocated(t['id']);
    final left = amount - alloc;
    final ended = t['ended_on'] != null;
    final ls = _lines.where((l) => l['tranche_id'] == t['id']).toList();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
          border: Border.all(color: left > 0.01 && !ended ? Colors.amber.shade700 : AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('Rs ${_money.format(amount)} · ${_df.format(DateTime.parse('${t['invested_on']}'))}'
              '${t['source'] == 'reinvest' ? ' · reinvested' : ''}${ended ? ' · withdrawn ${_df.format(DateTime.parse('${t['ended_on']}'))}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w800))),
          Text(left > 0.01 ? 'Unallocated Rs ${_money.format(left)}' : 'Fully allocated',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: left > 0.01 ? Colors.amber.shade900 : AppTheme.success)),
          if (!ended) PopupMenuButton<String>(
            onSelected: (v) { if (v == 'end') _endTranche(t); },
            itemBuilder: (_) => const [PopupMenuItem(value: 'end', child: Text('Mark withdrawn'))],
          ),
        ]),
        if ((t['note'] ?? '').toString().isNotEmpty)
          Text('${t['note']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        for (final l in ls) Row(children: [
          Icon(l['kind'] == 'grn' ? Icons.inventory_2_outlined : Icons.business_outlined, size: 15, color: AppTheme.primary),
          const SizedBox(width: 6),
          Expanded(child: Text(l['kind'] == 'grn'
              ? 'GRN ${l['grn_number']}${InvestorProfit.n(l['expense_share_pct']) > 0 ? ' · expense share ${InvestorProfit.n(l['expense_share_pct']).toStringAsFixed(0)}%' : ''}'
              : 'Whole business', style: const TextStyle(fontSize: 12.5))),
          Text('Rs ${_money.format(InvestorProfit.n(l['amount']))}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          IconButton(icon: const Icon(Icons.close, size: 15), tooltip: 'Remove', onPressed: () => _removeLine(l)),
        ]),
        if (left > 0.01 && !ended) Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: () => _addBusinessLine(t), icon: const Icon(Icons.business_outlined, size: 16), label: const Text('Whole business')),
          OutlinedButton.icon(onPressed: () => _addGrnLine(t), icon: const Icon(Icons.inventory_2_outlined, size: 16), label: const Text('Link GRN')),
        ]),
      ]),
    );
  }

  Widget _periodRow(DateTime from, DateTime to) {
    final r = _runs.where((x) => x['status'] != 'void' &&
        x['period_from'] == DateFormat('yyyy-MM-dd').format(from) && x['period_to'] == DateFormat('yyyy-MM-dd').format(to)).firstOrNull;
    final complete = to.isBefore(DateTime.now());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 150, child: Text(InvestorProfit.periodLabel(from, to), style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(child: r == null
            ? Text(complete ? 'Not run' : 'In progress', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))
            : Text(r['status'] == 'loss'
                ? 'Loss — nothing posted'
                : 'Rs ${_money.format(InvestorProfit.n(r['amount']))} · ${r['entry_number'] ?? ''} · ${r['created_by_name'] ?? ''}',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                    color: r['status'] == 'loss' ? AppTheme.danger : AppTheme.success))),
        if (r == null)
          TextButton(onPressed: () => _run(from, to), child: Text(complete ? 'Calculate' : 'Preview')),
        if (r != null) ...[
          TextButton(onPressed: () => showDialog(context: context, builder: (ctx) => AlertDialog(
              title: Text('Profit run · ${InvestorProfit.periodLabel(from, to)}'),
              content: SizedBox(width: 620, child: SingleChildScrollView(child: _calcView(Map<String, dynamic>.from(r['calc'] as Map), 0))),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))])),
              child: const Text('View')),
          if (_isAdmin) TextButton(onPressed: () => _voidRun(r), child: const Text('Void', style: TextStyle(color: AppTheme.danger))),
        ],
      ]),
    );
  }
}


/// Chart-of-accounts picker: searches on the server by code or name, so every
/// account is reachable however large the chart is.
class _AccountPicker extends StatefulWidget {
  const _AccountPicker({required this.orgId, required this.title, this.type});
  final String orgId;
  final String title;
  final String? type;
  @override
  State<_AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends State<_AccountPicker> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  int _seq = 0;

  @override
  void initState() { super.initState(); _fetch(); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _fetch() async {
    final my = ++_seq;
    setState(() { _loading = true; _error = null; });
    try {
      final q = _ctrl.text.trim().replaceAll(RegExp(r'[,()%*]'), ' ').trim();
      var b = Supabase.instance.client.from('chart_of_accounts')
          .select('id, code, name, account_type, level').eq('org_id', widget.orgId);
      if (widget.type != null) b = b.eq('account_type', widget.type!);
      if (q.isNotEmpty) b = b.or('code.ilike.%$q%,name.ilike.%$q%');
      final r = List<Map<String, dynamic>>.from(await b.order('code').limit(300) as List);
      if (!mounted || my != _seq) return;
      setState(() { _rows = r; _loading = false; });
    } catch (_) {
      if (!mounted || my != _seq) return;
      setState(() { _rows = []; _loading = false; _error = 'Accounts could not be loaded. Please try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            TextField(controller: _ctrl, autofocus: true, onChanged: (_) => _fetch(),
                decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Search code or name', border: OutlineInputBorder())),
            const SizedBox(height: 8),
            Flexible(child: _loading
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : _error != null
                    ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                    : _rows.isEmpty
                        ? const Padding(padding: EdgeInsets.all(24),
                            child: Text('No accounts match.', style: TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _rows.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final a = _rows[i];
                              return InkWell(
                                onTap: () => Navigator.pop(context, a),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text('${a['code'] ?? ''}  ${a['name'] ?? ''}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                    Text('${a['account_type'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                  ]),
                                ),
                              );
                            })),
            Align(alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
          ]),
        ),
      ),
    );
  }
}
