import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Investor profit sharing — the calculation engine (SQL 397).
///
/// For one investor and one period:
///  1. Net profit of the business (P&L), leaving out investor profit expense
///     itself so the share isn't calculated on a profit it has already reduced.
///  2. GRN lines: invoiced margin on goods from each linked GRN (FIFO cost of
///     exactly those goods), less returns of those goods (if the investor's
///     "Deduct returns" is on), less the line's running-expense share.
///  3. Business pool = net profit − every investor's GRN-line profit (that
///     margin is already shared through the GRN lines).
///  4. Whole-business lines: pool × (investor's capital-days ÷ capital
///     employed-days).
///  5. × the investor's share %, then floor / cap. A loss leaves 0 and is
///     kept on record (loss policy: decide later).
class InvestorProfit {
  static SupabaseClient get _db => Supabase.instance.client;
  static final _d = DateFormat('yyyy-MM-dd');

  static const frequencies = {
    'monthly': 'Monthly',
    'quarterly': 'Quarterly',
    'half_yearly': 'Half-yearly',
    'annually': 'Annually',
  };

  static int months(String f) => switch (f) { 'quarterly' => 3, 'half_yearly' => 6, 'annually' => 12, _ => 1 };

  /// Calendar periods from the investor's start up to today (newest first).
  static List<(DateTime, DateTime)> periods(DateTime start, String freq) {
    final m = months(freq);
    var s = DateTime(start.year, ((start.month - 1) ~/ m) * m + 1, 1);
    final out = <(DateTime, DateTime)>[];
    final now = DateTime.now();
    while (!s.isAfter(now)) {
      final e = DateTime(s.year, s.month + m, 0);
      out.add((s, e));
      s = DateTime(s.year, s.month + m, 1);
    }
    return out.reversed.toList();
  }

  static String periodLabel(DateTime a, DateTime b) {
    if (a.month == b.month && a.year == b.year) return DateFormat('MMM yyyy').format(a);
    return '${DateFormat('MMM').format(a)}–${DateFormat('MMM yyyy').format(b)}';
  }

  static double n(Object? v) => (v as num?)?.toDouble() ?? double.tryParse('${v ?? ''}') ?? 0;

  /// Days a line is invested inside [from, to] (both inclusive).
  static int daysIn(DateTime invested, DateTime? ended, DateTime from, DateTime to) {
    final a = invested.isAfter(from) ? invested : from;
    final endCap = ended == null ? to : (ended.isBefore(to) ? ended : to);
    final d = endCap.difference(a).inDays + 1;
    return d < 0 ? 0 : d;
  }

  /// Full calculation. Returns the step-by-step result (stored with the run).
  static Future<Map<String, dynamic>> calculate({
    required String orgId,
    required Map<String, dynamic> investor,
    required DateTime from,
    required DateTime to,
  }) async {
    final periodDays = to.difference(from).inDays + 1;

    // All investors' tranches + lines (the pool and GRN totals need everyone).
    final invs = List<Map<String, dynamic>>.from(await _db.from('investors').select().eq('org_id', orgId) as List);
    final trs = List<Map<String, dynamic>>.from(await _db.from('investor_tranches').select().eq('org_id', orgId) as List);
    final lines = List<Map<String, dynamic>>.from(await _db.from('investor_tranche_lines').select().eq('org_id', orgId) as List);
    final trById = {for (final t in trs) t['id']: t};

    int lineDays(Map l) {
      final t = trById[l['tranche_id']];
      if (t == null) return 0;
      final inv = DateTime.parse('${t['invested_on']}');
      final end = t['ended_on'] == null ? null : DateTime.tryParse('${t['ended_on']}');
      return daysIn(inv, end, from, to);
    }

    // 1) Net profit, without investor profit expense.
    final expIds = {for (final i in invs) if (i['expense_account_id'] != null) '${i['expense_account_id']}'};
    final cfg = await _db.from('app_config').select('key, value').eq('org_id', orgId)
        .inFilter('key', ['org.investor_expense_parent', 'org.investor_liability_parent']);
    final cfgMap = {for (final r in cfg as List) '${r['key']}': '${r['value'] ?? ''}'};
    final codeRows = await _db.from('chart_of_accounts').select('id, code, account_type').eq('org_id', orgId)
        .inFilter('id', [...expIds, if ((cfgMap['org.investor_expense_parent'] ?? '').isNotEmpty) cfgMap['org.investor_expense_parent']!]);
    final excludedCodes = <String>{for (final r in codeRows as List) '${r['code']}'};
    final pnl = List<Map<String, dynamic>>.from(await _db.rpc('rpc_profit_loss', params: {
      'p_org_id': orgId, 'p_date_from': _d.format(from), 'p_date_to': _d.format(to), 'p_branch_ids': null,
    }) as List);
    double revenue = 0, expense = 0, excluded = 0;
    for (final r in pnl) {
      final code = '${r['code'] ?? ''}';
      final v = n(r['net']); // credit − debit
      final skip = excludedCodes.any((c) => c.isNotEmpty && code.startsWith(c));
      if (r['account_type'] == 'revenue') revenue += v;
      if (r['account_type'] == 'expense') {
        if (skip) { excluded += -v; continue; }
        expense += -v;
      }
    }
    final netProfit = revenue - expense;

    // 2) GRN lines active in the period (all investors).
    final grnLines = lines.where((l) => l['kind'] == 'grn' && l['grn_id'] != null && lineDays(l) > 0).toList();
    final margins = <String, Map<String, double>>{};
    if (grnLines.isNotEmpty) {
      final res = await _db.rpc('investor_grn_margin', params: {
        'p_org': orgId, 'p_grn_ids': [for (final l in grnLines) l['grn_id']],
        'p_from': _d.format(from), 'p_to': _d.format(to),
      });
      for (final r in res as List) {
        margins['${r['grn_id']}'] = {'qty': n(r['qty']), 'revenue': n(r['revenue']), 'cost': n(r['cost'])};
      }
    }
    // 2b) Returns of goods from those GRNs (SQL 398). Always taken off for the
    //     business pool (the P&L already carries them); taken off this
    //     investor's own GRN profit only when their "Deduct returns" is on.
    final returns = <String, Map<String, double>>{};
    if (grnLines.isNotEmpty) {
      try {
        final res = await _db.rpc('investor_grn_returns', params: {
          'p_org': orgId, 'p_grn_ids': [for (final l in grnLines) l['grn_id']],
          'p_from': _d.format(from), 'p_to': _d.format(to),
        });
        for (final r in res as List) {
          returns['${r['grn_id']}'] = {'qty': n(r['qty']), 'revenue': n(r['revenue']), 'cost': n(r['cost'])};
        }
      } catch (_) {
        throw Exception('Returns could not be checked. Please try again.');
      }
    }
    final deductMine = investor['deduct_returns'] != false;
    double grnProfitAll = 0;
    final myGrn = <Map<String, dynamic>>[];
    double expOf(double margin, Map l) => margin > 0 ? margin * n(l['expense_share_pct']) / 100 : 0.0;
    for (final l in grnLines) {
      const zero = {'qty': 0.0, 'revenue': 0.0, 'cost': 0.0};
      final m = margins['${l['grn_id']}'] ?? zero;
      final rt = returns['${l['grn_id']}'] ?? zero;
      final grossMargin = m['revenue']! - m['cost']!;
      final retMargin = rt['revenue']! - rt['cost']!;
      final netMargin = grossMargin - retMargin;
      grnProfitAll += netMargin - expOf(netMargin, l);
      final t = trById[l['tranche_id']];
      if (t != null && t['investor_id'] == investor['id']) {
        final margin = deductMine ? netMargin : grossMargin;
        final exp = expOf(margin, l);
        myGrn.add({
          'grn_number': l['grn_number'], 'grn_id': l['grn_id'], 'amount': n(l['amount']),
          'qty': m['qty'], 'revenue': m['revenue'], 'cost': m['cost'],
          'return_qty': rt['qty'], 'return_revenue': rt['revenue'], 'return_cost': rt['cost'],
          'returns_deducted': deductMine,
          'margin': margin,
          'expense_share_pct': n(l['expense_share_pct']), 'expense': exp, 'profit': margin - exp,
        });
      }
    }

    // 3) Business pool.
    final pool = netProfit - grnProfitAll;

    // 4) Capital employed (average of opening and closing): equity + investor
    //    money that is not already booked as equity.
    final invAccIds = {for (final i in invs) if (i['investment_account_id'] != null) '${i['investment_account_id']}'};
    final invAccCodes = <String>{};
    if (invAccIds.isNotEmpty) {
      final r = await _db.from('chart_of_accounts').select('code, account_type').inFilter('id', invAccIds.toList());
      for (final x in r as List) {
        if (x['account_type'] != 'equity') invAccCodes.add('${x['code']}');
      }
    }
    Future<double> capitalAt(DateTime d) async {
      final rows = List<Map<String, dynamic>>.from(await _db.rpc('rpc_balance_sheet', params: {
        'p_org_id': orgId, 'p_as_of': _d.format(d), 'p_branch_ids': null,
      }) as List);
      double c = 0;
      for (final r in rows) {
        final bal = -n(r['balance']); // credit-normal for equity / liabilities
        if (r['account_type'] == 'equity') c += bal;
        if (invAccCodes.contains('${r['code']}')) c += bal;
      }
      return c;
    }
    final capOpen = await capitalAt(from.subtract(const Duration(days: 1)));
    final capClose = await capitalAt(to);
    final capAvg = (capOpen + capClose) / 2;

    // 5) This investor's lines.
    final myTrIds = {for (final t in trs) if (t['investor_id'] == investor['id']) t['id']};
    final myLines = lines.where((l) => myTrIds.contains(l['tranche_id'])).toList();
    double bizCapDays = 0, allCapDays = 0;
    final bizRows = <Map<String, dynamic>>[];
    for (final l in myLines) {
      final days = lineDays(l);
      if (days <= 0) continue;
      final cd = n(l['amount']) * days;
      allCapDays += cd;
      if (l['kind'] == 'business') {
        bizCapDays += cd;
        bizRows.add({'amount': n(l['amount']), 'days': days, 'capital_days': cd});
      }
    }
    final totalCapDays = math.max(capAvg * periodDays, bizCapDays);
    final bizFraction = totalCapDays > 0 ? bizCapDays / totalCapDays : 0.0;
    final bizProfit = pool * bizFraction;
    final grnProfitMine = myGrn.fold<double>(0, (s, g) => s + (g['profit'] as double));
    final share = n(investor['share_pct']);
    final gross = (bizProfit + grnProfitMine) * share / 100;

    // 6) Floor / cap.
    final annual = (investor['limit_basis'] ?? 'annual') == 'annual';
    double limitOf(double pct) => pct <= 0 ? 0 : (annual ? pct / 100 * allCapDays / 365 : pct / 100 * allCapDays / periodDays);
    final floorAmt = limitOf(n(investor['floor_pct']));
    final capAmt = limitOf(n(investor['cap_pct']));
    String status = 'posted';
    double amount = gross;
    String? limitNote;
    if (gross < 0) {
      status = 'loss';
      amount = 0;
      limitNote = 'Loss for the period — nothing posted (loss policy: decide later).';
    } else {
      if (floorAmt > 0 && amount < floorAmt) { amount = floorAmt; limitNote = 'Raised to the floor'; }
      if (capAmt > 0 && amount > capAmt) { amount = capAmt; limitNote = 'Limited to the cap'; }
    }
    amount = (amount * 100).roundToDouble() / 100;

    return {
      'period_from': _d.format(from), 'period_to': _d.format(to), 'period_days': periodDays,
      'revenue': revenue, 'expense': expense, 'excluded_investor_expense': excluded, 'net_profit': netProfit,
      'grn_profit_all_investors': grnProfitAll, 'business_pool': pool,
      'capital_open': capOpen, 'capital_close': capClose, 'capital_avg': capAvg,
      'capital_days_total': totalCapDays, 'business_capital_days': bizCapDays, 'business_fraction': bizFraction,
      'business_lines': bizRows, 'business_profit': bizProfit,
      'grn_lines': myGrn, 'grn_profit': grnProfitMine, 'deduct_returns': deductMine,
      'share_pct': share, 'gross_share': gross,
      'invested_capital_days': allCapDays,
      'floor_pct': n(investor['floor_pct']), 'cap_pct': n(investor['cap_pct']),
      'limit_basis': annual ? 'annual' : 'period', 'floor_amount': floorAmt, 'cap_amount': capAmt,
      'limit_note': limitNote, 'status': status, 'amount': amount,
    };
  }

  static Future<String> _nextJvNumber(String orgId, DateTime date) async {
    final yr = date.year.toString();
    final ex = await _db.from('journal_entries').select('entry_number')
        .eq('org_id', orgId).eq('reference_type', 'jv').like('entry_number', 'JV-$yr-%');
    int mx = 0;
    for (final r in ex as List) {
      final k = int.tryParse('${r['entry_number'] ?? ''}'.split('-').last) ?? 0;
      if (k > mx) mx = k;
    }
    return 'JV-$yr-${(mx + 1).toString().padLeft(4, '0')}';
  }

  /// Posts a balanced two-line journal voucher; returns (id, number).
  static Future<(String, String)> postJv({
    required String orgId,
    required String branchId,
    required String userId,
    required DateTime date,
    required String narration,
    required String debitAccount,
    required String debitName,
    required String creditAccount,
    required String creditName,
    required double amount,
  }) async {
    final no = await _nextJvNumber(orgId, date);
    final id = 'jv_${DateTime.now().millisecondsSinceEpoch}';
    await _db.rpc('save_journal_entry', params: {
      'p_entry': {
        'id': id, 'org_id': orgId, 'branch_id': branchId,
        'entry_number': no, 'entry_date': _d.format(date), 'description': narration,
        'reference_type': 'jv', 'reference_id': id, 'reference_number': no,
        'status': 'posted', 'is_system_generated': true, 'created_by': userId,
      },
      'p_lines': [
        {'account_id': debitAccount, 'account_type': 'coa', 'account_name': debitName, 'party_id': null,
         'debit': amount, 'credit': 0, 'description': narration, 'line_order': 1},
        {'account_id': creditAccount, 'account_type': 'coa', 'account_name': creditName, 'party_id': null,
         'debit': 0, 'credit': amount, 'description': narration, 'line_order': 2},
      ],
    });
    return (id, no);
  }

  /// Balance of an account (credit − debit) from posted journal lines.
  static Future<double> creditBalance(String accountId) async {
    double b = 0;
    for (var from = 0; ; from += 1000) {
      final r = await _db.from('journal_lines').select('debit, credit').eq('account_id', accountId).range(from, from + 999);
      final list = r as List;
      for (final x in list) { b += n(x['credit']) - n(x['debit']); }
      if (list.length < 1000) break;
    }
    return b;
  }
}
