import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'erp_pos_held_bills_screen.dart';
import 'dart:js_util' as js_util;
import 'dart:js_util' as js_util;

// Cash actually collected for a transaction: the Cash tender from
// payment_details, or a legacy fallback for old rows without tenders.
double _posCashCollected(Map<String, dynamic> t) {
  final pd = t['payment_details'];
  if (pd is List && pd.isNotEmpty) {
    double c = 0;
    for (final tn in pd) {
      if (tn is! Map) continue;
      final code = (tn['code'] as String?)?.toLowerCase();
      final label = (tn['label'] as String?)?.toLowerCase();
      if (code == 'cash' || label == 'cash') c += (tn['amount'] as num?)?.toDouble() ?? 0;
    }
    return c;
  }
  final pm = ((t['payment_method'] as String?) ?? 'cash').toLowerCase();
  if (pm != 'cash') return 0;
  final tot = ((t['total'] as num?)?.toDouble() ?? 0).abs();
  final paid = (t['amount_paid'] as num?)?.toDouble();
  return (paid != null && paid < tot) ? paid : tot;
}

// Cash portion of POS refunds, mirroring post_pos_money's return-branch split.
// A return only removes cash from the drawer for the part of the ORIGINAL sale
// that was actually paid in cash; the credit part of the original reduces the
// customer's receivable (Cr AR) and no cash moves. Counting the FULL return
// total as cash out — the old behaviour — is what made expected closing cash
// drift below GL Cash-in-Hand whenever a credit-sale return was involved
// (e.g. a fully-on-credit return showed a phantom cash shortfall equal to the
// return value). This keeps the POS cash chain in lock-step with GL by using
// the identical split:
//   arPortion   = (original.total − original.amount_paid) clamped to the refund
//   cashPortion = refund − arPortion
// Originals are resolved by reference_transaction_id (they may live in an
// earlier session), so this is a batched DB lookup. Returns whose original is
// missing fall back to full-cash — the safe legacy default.
Future<double> _posCashRefundTotal(
    SupabaseClient client, List<Map<String, dynamic>> returns) async {
  if (returns.isEmpty) return 0;
  final refIds = returns
      .map((t) => t['reference_transaction_id'] as String?)
      .whereType<String>()
      .toSet()
      .toList();
  final Map<String, Map<String, dynamic>> origs = {};
  if (refIds.isNotEmpty) {
    try {
      final rows = await client
          .from('pos_transactions')
          .select('id, total, amount_paid')
          .inFilter('id', refIds);
      for (final o in rows as List) {
        origs[o['id'] as String] = Map<String, dynamic>.from(o as Map);
      }
    } catch (_) {}
  }
  double total = 0;
  for (final t in returns) {
    final refund = ((t['total'] as num?)?.toDouble() ?? 0).abs();
    final refId = t['reference_transaction_id'] as String?;
    final orig = refId == null ? null : origs[refId];
    if (orig == null) {
      total += refund; // legacy fallback: treat as full cash
      continue;
    }
    final origTotal = (orig['total'] as num?)?.toDouble() ?? 0;
    final origPaid = (orig['amount_paid'] as num?)?.toDouble() ?? origTotal;
    final arPortion = (origTotal - origPaid).clamp(0.0, refund).toDouble();
    total += refund - arPortion; // cash portion only
  }
  return total;
}

class ErpPosScreen extends ConsumerStatefulWidget {
  const ErpPosScreen({super.key});
  @override
  ConsumerState<ErpPosScreen> createState() => _ErpPosScreenState();
}

class _ErpPosScreenState extends ConsumerState<ErpPosScreen> {
  Map<String, dynamic>? _activeSession;
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;
  DateTime? _filterFrom;
  DateTime? _filterTo;
  String _sessionSearch = '';
  final Map<String, List<Map<String, dynamic>>> _sessionTxns = {};
  final Map<String, bool> _sessionExpanded = {};
  final Map<String, double> _sessionTotals = {};
  String _globalTxnSearch = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      final sessions = await client
          .from('pos_sessions')
          .select('*, branches(name)')
          .eq('org_id', orgId)
          .order('opened_at', ascending: false)
          .limit(200);
      final branches = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      // Per-session sales totals for the Recent Sessions list (show total sale per session).
      final Map<String, double> sessionTotals = {};
      final sessIds = (sessions as List).map((s) => s['id'] as String).toList();
      if (sessIds.isNotEmpty) {
        try {
          final tRows = await client
              .from('pos_transactions')
              .select('session_id, total, transaction_type')
              .inFilter('session_id', sessIds);
          for (final t in tRows as List) {
            final sid = t['session_id'] as String?;
            if (sid == null) continue;
            if (((t['transaction_type'] as String?) ?? 'sale') != 'sale') continue;
            sessionTotals[sid] = (sessionTotals[sid] ?? 0) + ((t['total'] as num?)?.toDouble() ?? 0);
          }
        } catch (_) {}
      }
      final activeList = (sessions as List).where((s) =>
          s['status'] == 'open' && s['opened_by'] == userId).toList();
      Map<String, dynamic>? active =
          activeList.isNotEmpty ? Map<String, dynamic>.from(activeList.first) : null;
      // Auto-close a session left open from a previous day (date rollover).
      bool autoClosed = false;
      if (active != null && active['opened_at'] != null) {
        final openedLocal = DateTime.parse(active['opened_at'] as String).toLocal();
        final now = DateTime.now();
        final openedDay = DateTime(openedLocal.year, openedLocal.month, openedLocal.day);
        final today = DateTime(now.year, now.month, now.day);
        if (openedDay.isBefore(today)) {
          await _autoCloseSession(active!);
          autoClosed = true;
          for (final s in sessions) {
            if (s['id'] == active!['id']) {
              s['status'] = 'closed';
              s['closed_at'] = DateTime.now().toUtc().toIso8601String();
            }
          }
          active = null;
        }
      }
      setState(() {
        _sessions = List<Map<String, dynamic>>.from(sessions);
        _branches = List<Map<String, dynamic>>.from(branches);
        _activeSession = active;
        _sessionTotals
          ..clear()
          ..addAll(sessionTotals);
        _loading = false;
      });
      if (autoClosed) _showSnack("Previous day's session was auto-closed.");
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  // Closes a stale (previous-day) session with an auto-computed expected cash.
  Future<void> _autoCloseSession(Map<String, dynamic> session) async {
    try {
      final client = Supabase.instance.client;
      final sid = session['id'];
      double cashSales = 0, cashExpenses = 0;
      final txns = await client
          .from('pos_transactions')
          .select('total, amount_paid, payment_method, transaction_type, payment_details, reference_transaction_id')
          .eq('session_id', sid);
      final returnTxns = <Map<String, dynamic>>[];
      for (final t in txns as List) {
        final type = (t['transaction_type'] as String?) ?? 'sale';
        if (type == 'return') {
          returnTxns.add(Map<String, dynamic>.from(t as Map));
        } else {
          cashSales += _posCashCollected(Map<String, dynamic>.from(t as Map));
        }
      }
      // Only the cash portion of a refund leaves the drawer (credit returns hit AR).
      final cashRefunds = await _posCashRefundTotal(client, returnTxns);
      try {
        final exps = await client
            .from('pos_expenses')
            .select('amount')
            .eq('session_id', sid);
        for (final e in exps as List) {
          cashExpenses += (e['amount'] as num?)?.toDouble() ?? 0;
        }
      } catch (_) {}
      final opening = (session['opening_cash'] as num?)?.toDouble() ?? 0;
      final expected = opening + cashSales - cashRefunds - cashExpenses;
      final existingNotes = (session['notes'] as String?) ?? '';
      await client.from('pos_sessions').update({
        'status': 'closed',
        'closed_at': DateTime.now().toUtc().toIso8601String(),
        'closing_cash': expected,
        'closed_by': ref.read(currentUserProvider)?.id,
        'notes': (existingNotes.isEmpty ? '' : '$existingNotes\n') +
            'Auto-closed on date change (expected cash auto-computed).',
      }).eq('id', sid);
    } catch (_) {}
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  void _showOpenSessionDialog() async {
    String? branchId;
    String lastClosing = '0';
    try {
      final orgId = ref.read(currentUserProvider)?.orgId;
      final last = await Supabase.instance.client.from('pos_sessions')
          .select('closing_cash').eq('org_id', orgId ?? '').eq('status', 'closed')
          .order('closed_at', ascending: false).limit(1);
      if ((last as List).isNotEmpty && last[0]['closing_cash'] != null)
        lastClosing = (last[0]['closing_cash'] as num).toStringAsFixed(2);
    } catch (_) {}
    final cashCtrl = TextEditingController(text: lastClosing);
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Open POS Session'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: branchId,
                decoration: const InputDecoration(labelText: 'Branch *'),
                hint: const Text('Select branch'),
                items: _branches.map((w) => DropdownMenuItem(
                    value: w['id'] as String,
                    child: Text(w['name'] as String))).toList(),
                onChanged: (v) => setS(() => branchId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: cashCtrl,
                decoration: const InputDecoration(
                    labelText: 'Opening Cash',
                    hintText: '0.00'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (branchId == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Select a branch')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final userId = ref.read(currentUserProvider)?.id;
                try {
                  await Supabase.instance.client.from('pos_sessions').insert({
                    'id': 'poss_${DateTime.now().millisecondsSinceEpoch}',
                    'org_id': orgId,
                    'branch_id': branchId,
                    'opened_by': userId,
                    'opening_cash': double.tryParse(cashCtrl.text.trim()) ?? 0,
                    'status': 'open',
                  });
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack('Session opened');
                  await _load();
                  if (_activeSession != null && mounted) {
                    _openSession(_activeSession!);
                  }
                } catch (e) {
                  if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: $e')));
                }
              },
              child: const Text('Open Session'),
            ),
          ],
        ),
      ),
    );
  }

  void _openSession(Map<String, dynamic> session) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PosSessionScreen(session: session, onUpdated: _load),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Point of Sale',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (_activeSession != null)
              ElevatedButton.icon(
                onPressed: () => _openSession(_activeSession!),
                icon: const Icon(Icons.point_of_sale, size: 18),
                label: const Text('Resume Session'),
              )
            else
              ElevatedButton.icon(
                onPressed: _showOpenSessionDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Open Session'),
              ),
          ]),
          const SizedBox(height: 8),
          if (_activeSession != null)
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppTheme.success.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.success.withOpacity(0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.circle, color: AppTheme.success, size: 10),
                const SizedBox(width: 8),
                Text(
                  'Active session open — ${_activeSession!['branches']?['name'] ?? ''}',
                  style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _openSession(_activeSession!),
                  child: const Text('Go to session →'),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('Recent Sessions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 15), label: Text(_filterFrom != null ? DateFormat('d MMM').format(_filterFrom!) : 'From', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _filterFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _filterFrom = d); }),
            const SizedBox(width: 6),
            OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 15), label: Text(_filterTo != null ? DateFormat('d MMM').format(_filterTo!) : 'To', style: const TextStyle(fontSize: 12)), onPressed: () async { final d = await showDatePicker(context: context, initialDate: _filterTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _filterTo = d); }),
            if (_filterFrom != null || _filterTo != null) ...[const SizedBox(width: 4), IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _filterFrom = null; _filterTo = null; }), tooltip: 'Clear dates')],
          ]),
          const SizedBox(height: 8),
          TextField(decoration: const InputDecoration(hintText: 'Search by branch, customer, phone or TRX ID…', prefixIcon: Icon(Icons.manage_search, size: 18), isDense: true), onChanged: (v) async {
            setState(() => _sessionSearch = v);
            if (v.trim().length >= 2) {
              final q2 = v.toLowerCase();
              for (final s in _sessions) {
                final sid = s['id'] as String;
                if (!_sessionTxns.containsKey(sid)) {
                  try { final rows = await Supabase.instance.client.from('pos_transactions').select('id, transaction_number, total, transacted_at, transaction_type, customers(shop_name), pos_customers(name, phone)').eq('session_id', sid).order('transacted_at', ascending: false); if (mounted) setState(() => _sessionTxns[sid] = List<Map<String, dynamic>>.from(rows)); } catch (_) {}
                }
                final txns = _sessionTxns[sid] ?? [];
                final hasMatch = txns.any((t) { final cu = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? '') as String).toLowerCase(); final ph = (t['pos_customers']?['phone'] as String? ?? '').toLowerCase(); final tr = (t['transaction_number'] as String? ?? '').toLowerCase(); return cu.contains(q2) || ph.contains(q2) || tr.contains(q2); });
                if (hasMatch && mounted) setState(() => _sessionExpanded[sid] = true);
              }
            }
          }),
          const SizedBox(height: 12),
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
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                    ),
                    child: const Row(children: [
                      Expanded(flex: 2, child: Text('Branch', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Opened', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Closed', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 2, child: Text('Total Sale', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                      SizedBox(width: 48),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Builder(builder: (ctx) {
                      final q = _sessionSearch.toLowerCase();
                      final filtered = _sessions.where((s) {
                        final branch = (s['branches']?['name'] as String? ?? '').toLowerCase();
                        final sid2 = s['id'] as String;
                        final txnsForSearch = _sessionTxns[sid2] ?? [];
                        final txnMatch = txnsForSearch.any((t) { final cu = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? '') as String).toLowerCase(); final ph = (t['pos_customers']?['phone'] as String? ?? '').toLowerCase(); final tr = (t['transaction_number'] as String? ?? '').toLowerCase(); return cu.contains(q) || ph.contains(q) || tr.contains(q); });
                        final matchSearch = q.isEmpty || branch.contains(q) || txnMatch;
                        final opened = s['opened_at'] != null ? DateTime.parse(s['opened_at'] as String).toLocal() : null;
                        final matchFrom = _filterFrom == null || (opened != null && !opened.isBefore(_filterFrom!));
                        final matchTo = _filterTo == null || (opened != null && !opened.isAfter(_filterTo!.add(const Duration(days: 1))));
                        return matchSearch && matchFrom && matchTo;
                      }).toList();
                      return filtered.isEmpty
                        ? const Center(child: Text('No sessions match.', style: TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final s = filtered[i];
                              final sid = s['id'] as String;
                              final isOpen = s['status'] == 'open';
                              final expanded = _sessionExpanded[sid] ?? false;
                              final txns = _sessionTxns[sid] ?? [];
                              final q = _sessionSearch.toLowerCase();
                              final filteredTxns = q.isEmpty ? txns : txns.where((t) { return matchesQuery('${t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? ''} ${t['pos_customers']?['phone'] ?? ''} ${t['transaction_number'] ?? ''}', q); }).toList();
                              final openedAt = s['opened_at'] != null
                                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(s['opened_at'] as String).toLocal())
                                  : '-';
                              final closedAt = s['closed_at'] != null
                                  ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(s['closed_at'] as String).toLocal())
                                  : '-';
                              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              InkWell(
                                onTap: () async {
                                  if (!_sessionTxns.containsKey(sid)) {
                                    try { final rows = await Supabase.instance.client.from('pos_transactions').select('id, transaction_number, total, transacted_at, transaction_type, customers(shop_name), pos_customers(name, phone)').eq('session_id', sid).order('transacted_at', ascending: false); setState(() => _sessionTxns[sid] = List<Map<String, dynamic>>.from(rows)); } catch (_) {}
                                  }
                                  setState(() => _sessionExpanded[sid] = !expanded);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                  child: Row(children: [
                                    Expanded(flex: 2, child: Text(s['branches']?['name'] as String? ?? '-',
                                        style: const TextStyle(fontWeight: FontWeight.w600))),
                                    Expanded(flex: 2, child: Text(openedAt,
                                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: Text(closedAt,
                                        style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                                    Expanded(flex: 2, child: Text('Rs. ${money(_sessionTotals[sid] ?? 0)}',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textPrimary))),
                                    Expanded(flex: 1, child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: isOpen ? AppTheme.success.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(isOpen ? 'Open' : 'Closed',
                                          style: TextStyle(
                                              color: isOpen ? AppTheme.success : AppTheme.textSecondary,
                                              fontSize: 12, fontWeight: FontWeight.w600)),
                                    )),
                                    SizedBox(width: isOpen ? 56 : 100, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                      TextButton(
                                        onPressed: () => _openSession(s),
                                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                        child: const Text('Enter', style: TextStyle(fontSize: 11))),
                                      if (!isOpen) Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.textSecondary),
                                    ])),
                                  ]),
                                ),
                              ),
                              if (expanded) Container(color: const Color(0xFFF9FAFB), padding: const EdgeInsets.only(bottom: 4), child: Column(children: [
                                if (!_sessionTxns.containsKey(sid)) const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                                else if (filteredTxns.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(52,8,20,8), child: Text('No invoices', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                                else ...filteredTxns.map((t) { final isRet = t['transaction_type'] == 'return'; final tot = (t['total'] as num?)?.toDouble() ?? 0; final cu = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String); final ph = t['pos_customers']?['phone'] as String? ?? ''; final tr = t['transaction_number'] as String? ?? ''; final ti = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : ''; return InkWell(onTap: () async { try { final ti2 = await Supabase.instance.client.from('pos_transaction_items').select('*, products(name)').eq('transaction_id', t['id'] as String); final ci2 = (ti2 as List).map((i) => {'name': i['products']?['name'] ?? '-', 'quantity': (i['quantity'] as num?)?.toDouble() ?? 0.0, 'unit_price': (i['unit_price'] as num?)?.toDouble() ?? 0.0, 'discount': (i['discount'] as num?)?.toDouble() ?? 0.0, 'discount_type': i['discount_type'] as String? ?? 'fixed'}).toList(); if (mounted) await showDialog(context: context, builder: (_) => _ReceiptDialog(transaction: Map<String, dynamic>.from(t), items: ci2, orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation', branchName: s['branches']?['name'] as String? ?? '', cashierName: '', footerNote: null)); } catch (_) {} }, child: Padding(padding: const EdgeInsets.fromLTRB(48,7,20,7), child: Row(children: [Icon(isRet ? Icons.reply : Icons.receipt_outlined, size: 13, color: isRet ? Colors.orange : AppTheme.primary), const SizedBox(width: 8), Expanded(child: Wrap(spacing: 8, children: [Text(cu, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)), if (ph.isNotEmpty) Text(ph, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)), if (tr.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal:5,vertical:1), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(3)), child: Text(tr, style: TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w600))), Text(ti, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))])), Text('${isRet ? '-' : ''}Rs. ${money(tot.abs())}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isRet ? Colors.orange : AppTheme.primary))])));  }),
                              ])),
                              ]);
                            });
                    }),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _PosSessionScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> session;
  final VoidCallback onUpdated;
  const _PosSessionScreen({required this.session, required this.onUpdated});
  @override ConsumerState<_PosSessionScreen> createState() => _PosSessionScreenState();
}

class _PosSessionScreenState extends ConsumerState<_PosSessionScreen> {
  late Map<String, dynamic> _session;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _allProducts = [];
  List<Map<String, dynamic>> _displayProducts = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _cart = [];
  // ── Staging ──────────────────────────────────────────────
  Map<String, dynamic>? _stagedProduct;
  int? _stagedCartIndex;  // null=new, int=editing existing
  String _stagedDiscType = 'percent';
  int _dropdownHighlight = -1;
  bool _showDropdown = false;
  final _stagedQtyCtrl = TextEditingController();
  final _stagedDiscCtrl = TextEditingController();
  final _stagedPriceCtrl = TextEditingController();
  final _stagedQtyFocus = FocusNode();
  final _stagedDiscFocus = FocusNode();
  final _stagedPriceFocus = FocusNode();
  final _searchFocus = FocusNode();
  String _cartSearch = '';
  Map<String, dynamic>? _selectedCustomer;
  String _paymentMethod = 'cash';
  final _customPaymentCtrl = TextEditingController();
  // Focus nodes for keyboard navigation
  final List<FocusNode> _qtyFocusNodes = [];
  final List<FocusNode> _discFocusNodes = [];
  final FocusNode _checkoutFocusNode = FocusNode();
  // Split payment
  bool _splitPayment = false;
  final _amountPaidCtrl = TextEditingController();
  // Phase 1: configurable payment methods (from pos_payment_methods) + per-method
  // tender amounts when splitting across modes.
  List<Map<String, dynamic>> _payMethods = [];
  final Map<String, TextEditingController> _tenderCtrls = {};
  // Bank accounts (children of the Bank Accounts COA node) for the Bank tender
  List<Map<String, dynamic>> _bankAccounts = [];
  String? _selectedBankId;
  double _orderDiscount = 0;
  String _orderDiscountType = 'fixed'; // 'fixed' | 'percent'
  bool _loading = true;
  bool _sessionPanelOpen = false;
  bool _customerExpanded = false; // bill-column customer picker starts collapsed (walk-ins are the norm)
  List<Map<String, dynamic>> _heldBills = [];
  bool _holdsPanelExpanded = false;
  List<Map<String, dynamic>> _expenses = [];
  bool _showExpenses = false;  // toggle between txns and expenses in panel
  String _search = '';
  final _searchCtrl = TextEditingController();
  final _customerSearchCtrl = TextEditingController();
  bool _showCustomerDropdown = false;
  List<Map<String, dynamic>> _filteredCustomers = [];
  List<Map<String, dynamic>> _posCustomers = [];
  Map<String, dynamic>? _selectedPosCustomer;  // quick POS customer
  List<Map<String, dynamic>> _promoters = [];        // active sales promoters
  List<Map<String, dynamic>> _suppliers = [];        // for POS payments (CPV)
  List<Map<String, dynamic>> _expenseAccounts = [];  // expense COA accounts for CPV
  List<Map<String, dynamic>> _sessionPayments = [];  // CPVs made from this session
  List<Map<String, dynamic>> _sessionReceipts = [];  // CRVs made from this session
  Map<String, dynamic>? _selectedPromoter;           // one promoter per bill (optional)
  Map<String, double> _stockMap = {};  // product_id → qty in stock
  bool _allowNoStock = false;           // org setting: allow selling without stock
  bool _allowPriceEdit = false;         // org setting: allow editing price at POS
  Map<String, String> _posConfig = {};

  @override void initState() { super.initState(); _session = Map.from(widget.session); WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelectorToSession()); _loadData(); }
  @override void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); _customerSearchCtrl.dispose(); _customPaymentCtrl.dispose(); _checkoutFocusNode.dispose(); for (final f in _qtyFocusNodes) f.dispose(); _stagedQtyCtrl.dispose(); _stagedDiscCtrl.dispose(); _stagedPriceCtrl.dispose(); _stagedQtyFocus.dispose(); _stagedDiscFocus.dispose(); _stagedPriceFocus.dispose(); for (final f in _discFocusNodes) f.dispose(); _amountPaidCtrl.dispose(); super.dispose(); }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isOpen => _session['status'] == 'open';

  // A POS session belongs to one branch. Keep the global branch selector pointed
  // at this session's branch while the till is open, so the indicator never lies.
  void _syncSelectorToSession() {
    if (!mounted) return;
    final sessId = _session['branch_id'] as String?;
    if (sessId == null) return;
    if ((ref.read(selectedBranchProvider)?['id'] as String?) == sessId) return;
    final ub = ref.read(userBranchesProvider).valueOrNull;
    if (ub == null) return;
    for (final b in ub) {
      if (b['id'] == sessId) {
        ref.read(selectedBranchProvider.notifier).state = Map<String, dynamic>.from(b);
        return;
      }
    }
  }

  // Selected branch diverged from this session's branch → leave the till.
  // The session stays OPEN (cash reconciliation belongs to its own branch);
  // guard against losing an in-progress cart first.
  Future<void> _handleBranchSwitch(Map<String, dynamic> newBranch) async {
    if (!mounted) return;
    final newName = newBranch['name'] as String? ?? 'the other branch';
    final thisName = _session['branches']?['name'] as String? ?? 'this branch';
    if (_cart.isNotEmpty) {
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Leave this POS session?'),
          content: Text('You have items in the cart for the "$thisName" till. Switching to "$newName" '
              'will leave this session — it stays open and you can resume it from the POS list.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Stay here')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Discard & leave')),
            ElevatedButton(onPressed: () => Navigator.pop(context, 'hold'), child: const Text('Hold bill & leave')),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == null || choice == 'cancel') { _syncSelectorToSession(); return; } // revert selector, stay
      if (choice == 'hold') { await _holdBill(); if (!mounted) return; }
      // 'discard' → leave the cart behind
    }
    widget.onUpdated();
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _showSnack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  // Pages past PostgREST's server-side max-rows cap (this project = 5000).
  // A bare .select() silently truncates at that cap with NO error, so the POS
  // terminal was loading at most 5000 products / stock rows. Page in 1000-row
  // batches (1000 is <= any max-rows value, so a short page reliably means
  // "end reached"). Returns a Future<List> so it drops into Future.wait.
  Future<List<Map<String, dynamic>>> _fetchAllPaged(
      dynamic Function(int from, int to) buildPage) async {
    const pageSz = 1000;
    final out = <Map<String, dynamic>>[];
    for (var from = 0; ; from += pageSz) {
      final rows = List<Map<String, dynamic>>.from(
          await buildPage(from, from + pageSz - 1) as List);
      out.addAll(rows);
      if (rows.length < pageSz) break;
    }
    return out;
  }

  // Lightweight post-sale refresh: only this session's transactions change on a
  // sale/return (stock is decremented locally), so re-fetch just those instead
  // of the full catalog/customer/price reload that made checkout feel slow.
  Future<void> _refreshSessionTxns() async {
    try {
      final rows = await Supabase.instance.client
          .from('pos_transactions')
          .select('*, customers(shop_name), pos_customers(name, phone), transaction_number, amount_paid, balance_change')
          .eq('session_id', _session['id']).order('transacted_at', ascending: false);
      if (mounted) setState(() => _transactions = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _loadData() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() { _loading = true; _stagedProduct = null; _stagedCartIndex = null; _stagedQtyCtrl.clear(); _stagedDiscCtrl.clear(); _showDropdown = false; });
    try {
      final client = Supabase.instance.client;
      final branchId = _session['branch_id'] as String? ?? '';
      final results = await Future.wait<dynamic>([
        client.from('pos_transactions').select('*, customers(shop_name), pos_customers(name, phone), transaction_number, amount_paid, balance_change').eq('session_id', _session['id']).order('transacted_at', ascending: false),
        _fetchAllPaged((from, to) => client.from('pos_catalog').select('id, name, sku, price, is_active, product_id, uom_id').eq('org_id', orgId).eq('branch_id', branchId).eq('is_active', true).order('name').order('id').range(from, to)),
        client.from('customers').select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true).order('shop_name'),
        client.from('pos_sessions').select('*, branches(name)').eq('id', _session['id']).single(),
        _fetchAllPaged((from, to) => client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId).order('product_id').range(from, to)),
        client.from('pos_customers').select('id, name, phone, cnic').eq('org_id', orgId).eq('branch_id', branchId).order('name'),
        client.from('pos_held_bills').select('*').eq('session_id', _session['id']).eq('status', 'held').order('held_at', ascending: false),
        client.from('sales_promoters').select('id, name, phone').eq('org_id', orgId).eq('is_active', true).order('name'),
        client.from('suppliers').select('id, name').eq('org_id', orgId).order('name'),
        client.from('chart_of_accounts').select('id, code, name').eq('org_id', orgId).eq('account_type', 'expense').order('code'),
      ]);
      final prods = List<Map<String, dynamic>>.from(results[1] as List);
      final stockRows = List<Map<String, dynamic>>.from(results[4] as List);
      final stockMap = <String, double>{for (final s in stockRows) s['product_id'] as String: (s['quantity'] as num?)?.toDouble() ?? 0.0};
      // Embed stock qty into each catalog product
      for (final p in prods) { final pid = p['product_id'] as String?; p['stock_qty'] = pid != null && pid.isNotEmpty ? (stockMap[pid] ?? -1.0) : -1.0; }
      // Live pricing: the sell price always comes from products.selling_price,
      // not the frozen pos_catalog.price snapshot — so a CSV/manual price update
      // reflects at the till immediately. There is no FK from pos_catalog to
      // products, so we fetch prices separately and merge by product_id rather
      // than relying on a PostgREST embedded join.
      // ── Second concurrent wave ────────────────────────────────────────────
      // These lookups are all independent of one another. Previously they ran
      // as ~9 SERIAL round-trips after the first batch — the bulk of the
      // session-open delay. Fire them together instead; each closure keeps its
      // own error handling (falling back to a safe default) so one failure
      // can't sink the batch. Pure post-processing (merges, defaults, config
      // parsing) happens after, once the rows are in hand.
      final sid = _session['id'];
      final priceFuture = (() async {
        try {
          return await _fetchAllPaged((from, to) => client
              .from('products')
              .select('id, selling_price, cost_price, is_consignment')
              .eq('org_id', orgId)
              .order('id')
              .range(from, to));
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      final expFuture = (() async {
        try {
          final r = await client.from('pos_expenses').select('*').eq('session_id', sid).order('created_at', ascending: false);
          return List<Map<String, dynamic>>.from(r as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      final payFuture = (() async {
        try {
          final r = await client.from('cpv_vouchers').select('id, voucher_number, total_amount, notes, created_at, cash_account_name, cpv_voucher_lines(account_name, account_type, description, amount)').eq('session_id', sid).eq('status', 'posted').order('created_at', ascending: false);
          return List<Map<String, dynamic>>.from(r as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      final rcvFuture = (() async {
        try {
          final r = await client.from('crv_vouchers').select('id, voucher_number, total_amount, notes, created_at, crv_voucher_lines(account_name, account_type, description, amount)').eq('session_id', sid).eq('status', 'posted').order('created_at', ascending: false);
          return List<Map<String, dynamic>>.from(r as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      final settingsFuture = (() async {
        try {
          return await client.from('pos_settings').select('allow_sell_without_stock, allow_price_edit').eq('org_id', orgId).maybeSingle();
        } catch (_) { return null; }
      })();
      final payMethodsFuture = (() async {
        try {
          final r = await client.from('pos_payment_methods').select('code, label, gl_account_id, is_credit, sort_order').eq('org_id', orgId).eq('is_active', true).order('sort_order');
          return List<Map<String, dynamic>>.from(r as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      // Bank accounts = active COA accounts under the "Bank Accounts" (1120)
      // node. Two dependent hops, but they overlap the rest of the wave.
      final bankFuture = (() async {
        try {
          final bankParent = await client.from('chart_of_accounts').select('id').eq('org_id', orgId).eq('code', '1120').maybeSingle();
          if (bankParent == null) return <Map<String, dynamic>>[];
          final banks = await client.from('chart_of_accounts').select('id, code, name').eq('org_id', orgId).eq('parent_id', bankParent['id']).eq('is_active', true).order('code');
          return List<Map<String, dynamic>>.from(banks as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();
      final cfgFuture = (() async {
        try {
          final r = await client.from('app_config').select('key, value, branch_id').eq('org_id', orgId).like('key', 'pos.%');
          return List<Map<String, dynamic>>.from(r as List);
        } catch (_) { return <Map<String, dynamic>>[]; }
      })();

      final priceRows = await priceFuture;
      final expenseList = await expFuture;
      _sessionPayments = await payFuture;
      _sessionReceipts = await rcvFuture;
      final s = await settingsFuture;
      _payMethods = await payMethodsFuture;
      _bankAccounts = await bankFuture;
      final cfgRows = await cfgFuture;

      // Live pricing: the sell price always comes from products.selling_price,
      // not the frozen pos_catalog.price snapshot, so a price update reflects at
      // the till immediately. No FK from pos_catalog to products, so merge by
      // product_id. If the price fetch failed the list is empty and each row
      // keeps its stored pos_catalog.price (no crash).
      final priceMap = <String, double>{};
      final costOk = <String, bool>{};   // has a valid cost basis (or is consignment)
      for (final r in priceRows) {
        final id = r['id'] as String?;
        if (id == null) continue;
        if (r['selling_price'] != null) priceMap[id] = (r['selling_price'] as num).toDouble();
        final isConsign = r['is_consignment'] == true;
        costOk[id] = isConsign || ((r['cost_price'] as num?)?.toDouble() ?? 0) > 0;
      }
      for (final p in prods) {
        final pid = p['product_id'] as String?;
        if (pid != null && priceMap.containsKey(pid)) p['price'] = priceMap[pid];
        p['cost_ok'] = pid != null ? (costOk[pid] ?? false) : false;
      }

      final allowNoStock = s != null && s['allow_sell_without_stock'] == true;
      final allowPriceEdit = s != null && s['allow_price_edit'] == true;

      // Payment methods: tender controllers + default selection.
      for (final m in _payMethods) {
        _tenderCtrls.putIfAbsent(m['code'] as String, () => TextEditingController());
      }
      if (_payMethods.isNotEmpty && !_payMethods.any((m) => m['code'] == _paymentMethod)) {
        _paymentMethod = _payMethods.first['code'] as String;
      }
      // Default bank selection needs both payMethods and bankAccounts.
      final bankMethod = _payMethods.firstWhere((m) => m['code'] == 'bank', orElse: () => <String, dynamic>{});
      if (_selectedBankId == null || !_bankAccounts.any((b) => b['id'] == _selectedBankId)) {
        final def = bankMethod.isEmpty ? null : bankMethod['gl_account_id'];
        _selectedBankId = (def != null && _bankAccounts.any((b) => b['id'] == def))
            ? def as String
            : (_bankAccounts.isNotEmpty ? _bankAccounts.first['id'] as String : null);
      }

      // Receipt config from app_config (pos.*). A branch's own config takes
      // precedence over the org-level default.
      final orgCfg = <String, String>{};
      final brCfg = <String, String>{};
      for (final row in cfgRows) {
        final k = row['key'] as String?;
        if (k == null) continue;
        final v = row['value']?.toString() ?? '';
        final b = row['branch_id'] as String?;
        if (b == null || b.isEmpty) {
          orgCfg[k] = v;
        } else if (b == branchId) {
          brCfg[k] = v;
        }
      }
      final posCfg = brCfg.isNotEmpty ? brCfg : orgCfg;

      setState(() {
        _expenses = expenseList;
        _expenses = expenseList;
        _transactions = List<Map<String, dynamic>>.from(results[0] as List);
        _allProducts = prods; _displayProducts = prods;
        _customers = List<Map<String, dynamic>>.from(results[2] as List);
        _session = Map<String, dynamic>.from(results[3] as Map);
        _stockMap = stockMap;
        _allowNoStock = allowNoStock;
        _allowPriceEdit = allowPriceEdit;
        _posCustomers = List<Map<String, dynamic>>.from(results[5] as List);
        _heldBills = List<Map<String, dynamic>>.from(results[6] as List);
        _promoters = List<Map<String, dynamic>>.from(results[7] as List);
        _suppliers = List<Map<String, dynamic>>.from(results[8] as List);
        _expenseAccounts = List<Map<String, dynamic>>.from(results[9] as List);
        _posConfig = posCfg;
        _loading = false;
      });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _loading = false); }
  }

  // ── Stage a product for editing before adding to bill ─────
  void _stageProduct(Map<String, dynamic> product, {int? cartIndex}) {
    // Cost-price hard block: a product with no cost basis can't be sold (would
    // book zero/estimated COGS). Applies even when overselling is allowed.
    // cost_ok is false only when we positively know the product lacks cost; if
    // the cost lookup was unavailable it defaults true (fail-open, won't block
    // the till on a network hiccup — costless products are already barred from POS).
    if (cartIndex == null && product['cost_ok'] == false) {
      _playBadgeSound();
      _showSnack('"${product['name']}" has no cost price set — cannot sell until cost is set');
      return;
    }
    // Block unless org allows no-stock selling, or the item has tracked stock > 0
    final pStock = (product['stock_qty'] as num?)?.toDouble() ?? 0;
    if (cartIndex == null && !_allowNoStock && pStock <= 0) { _playBadgeSound(); return; }
    // If already in cart and not explicitly editing, load that cart entry
    if (cartIndex == null) {
      final existIdx = _cart.indexWhere((ci) => ci['pos_catalog_id'] == (product['id'] ?? product['pos_catalog_id']));
      if (existIdx >= 0) { _stageProduct(product, cartIndex: existIdx); return; }
    }
    setState(() {
      _stagedProduct = product;
      _dropdownHighlight = -1;
      final basePrice = (product['price'] as num?)?.toDouble() ?? (product['unit_price'] as num?)?.toDouble() ?? 0;
      if (cartIndex != null) {
        _stagedCartIndex = cartIndex;
        final it = _cart[cartIndex];
        _stagedQtyCtrl.text = (it['quantity'] as double).toStringAsFixed(0);
        final d = (it['discount'] as double);
        _stagedDiscCtrl.text = d > 0 ? d.toStringAsFixed(0) : '';
        _stagedDiscType = it['discount_type'] as String? ?? 'fixed';
        _stagedPriceCtrl.text = ((it['unit_price'] as num?)?.toDouble() ?? basePrice).toStringAsFixed(2);
      } else {
        _stagedCartIndex = null;
        _stagedQtyCtrl.text = '1';
        _stagedDiscCtrl.clear();
        _stagedDiscType = 'percent';
        _stagedPriceCtrl.text = basePrice.toStringAsFixed(2);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_allowPriceEdit) {
        _stagedPriceCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _stagedPriceCtrl.text.length);
        _stagedPriceFocus.requestFocus();
      } else {
        _stagedQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _stagedQtyCtrl.text.length);
        _stagedQtyFocus.requestFocus();
      }
    });
  }

  void _confirmStaged() {
    if (_stagedProduct == null || !_isOpen) return;
    final qty = double.tryParse(_stagedQtyCtrl.text.trim()) ?? 1;
    if (qty <= 0) return;
    final basePrice = (_stagedProduct!['price'] as num?)?.toDouble() ?? (_stagedProduct!['unit_price'] as num?)?.toDouble() ?? 0;
    final price = _allowPriceEdit ? (double.tryParse(_stagedPriceCtrl.text.trim()) ?? basePrice) : basePrice;
    // Clamp discount so a line can never go negative or free: percent to 0-100,
    // fixed to 0-(line gross). Prevents corrupt sales from a mistyped discount
    // (e.g. -1000% or 99% that zeroed the total).
    final rawDisc = double.tryParse(_stagedDiscCtrl.text.trim()) ?? 0;
    final disc = _stagedDiscType == 'percent'
        ? rawDisc.clamp(0, 100).toDouble()
        : rawDisc.clamp(0, price * qty).toDouble();
    setState(() {
      if (_stagedCartIndex != null && _stagedCartIndex! < _cart.length) {
        _cart[_stagedCartIndex!]['quantity'] = qty;
        _cart[_stagedCartIndex!]['discount'] = disc;
        _cart[_stagedCartIndex!]['discount_type'] = _stagedDiscType;
        if (_allowPriceEdit) _cart[_stagedCartIndex!]['unit_price'] = price;
      } else {
        _cart.add({
          'pos_catalog_id': _stagedProduct!['id'] ?? _stagedProduct!['pos_catalog_id'],
          'product_id': _stagedProduct!['product_id'],
          'name': _stagedProduct!['name'],
          'sku': _stagedProduct!['sku'] ?? '',
          'uom_id': _stagedProduct!['uom_id'],
          'unit_price': price,
          'quantity': qty,
          'discount': disc,
          'discount_type': _stagedDiscType,
          'stock_qty': (_stagedProduct!['stock_qty'] as num?)?.toDouble() ?? 0.0,
        });
      }
      _stagedProduct = null; _stagedCartIndex = null;
      _stagedQtyCtrl.clear(); _stagedDiscCtrl.clear(); _stagedPriceCtrl.clear();
      _searchCtrl.clear(); _filterProducts('');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  void _clearStaged() {
    setState(() { _stagedProduct = null; _stagedCartIndex = null; _stagedQtyCtrl.clear(); _stagedDiscCtrl.clear(); });
    _searchFocus.requestFocus();
  }

  // Full-screen review of the current bill for long carts: search + scroll,
  // tap an item to edit it (routes through the existing staging editor),
  // or remove it inline. Read-only mirror of _cart; edits reuse _stageProduct.
  void _openBillReview() {
    String q = '';
    showDialog(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setModal) {
        // Preserve real cart indices while filtering.
        final rows = <MapEntry<int, Map<String, dynamic>>>[];
        for (var i = 0; i < _cart.length; i++) {
          final it = _cart[i];
          if (matchesQuery('${it['name'] ?? ''} ${it['sku'] ?? ''}', q)) rows.add(MapEntry(i, it));
        }
        double billTotal = 0;
        for (final it in _cart) {
          final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final d = (it['discount'] as num?)?.toDouble() ?? 0;
          final dt = it['discount_type'] as String? ?? 'fixed';
          final da = dt == 'percent' ? price * qty * d / 100 : d;
          billTotal += price * qty - da;
        }
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 660),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Header
              Padding(padding: const EdgeInsets.fromLTRB(18, 16, 12, 8), child: Row(children: [
                const Icon(Icons.receipt_long, size: 20, color: AppTheme.primary),
                const SizedBox(width: 8),
                Text('Review Bill  (${_cart.length} item${_cart.length == 1 ? '' : 's'})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(dctx).pop()),
              ])),
              // Search
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search this bill by name or SKU...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true, filled: true, fillColor: const Color(0xFFF8F9FA),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                onChanged: (v) => setModal(() => q = v),
              )),
              const Divider(height: 1),
              // Items
              Flexible(child: rows.isEmpty
                ? const Padding(padding: EdgeInsets.all(28), child: Text('No matching items', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, r) {
                      final idx = rows[r].key;
                      final it = rows[r].value;
                      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                      final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
                      final d = (it['discount'] as num?)?.toDouble() ?? 0;
                      final dt = it['discount_type'] as String? ?? 'fixed';
                      final da = dt == 'percent' ? price * qty * d / 100 : d;
                      final lineTotal = price * qty - da;
                      final discLabel = d > 0 ? (dt == 'percent' ? '  (-${d.toStringAsFixed(0)}%)' : '  (-${money(d)})') : '';
                      return InkWell(
                        onTap: _isOpen ? () { Navigator.of(dctx).pop(); _stageProduct(it, cartIndex: idx); } : null,
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(it['name'] as String? ?? '-', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('${qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 2)} x Rs. ${money(price)}$discLabel',
                                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                          ])),
                          const SizedBox(width: 10),
                          Text('Rs. ${money(lineTotal)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Remove',
                            onPressed: _isOpen ? () {
                              setState(() {
                                if (_stagedCartIndex == idx) { _stagedProduct = null; _stagedCartIndex = null; }
                                else if (_stagedCartIndex != null && _stagedCartIndex! > idx) _stagedCartIndex = _stagedCartIndex! - 1;
                                _cart.removeAt(idx);
                              });
                              setModal(() {});
                            } : null,
                          ),
                        ])),
                      );
                    })),
              const Divider(height: 1),
              // Footer total
              Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 16), child: Row(children: [
                const Text('Total', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const Spacer(),
                Text('Rs. ${money(billTotal)}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              ])),
            ]),
          ),
        );
      }),
    );
  }

  Widget _buildStagingCard() {
    final p = _stagedProduct!;
    final basePrice = (p['price'] as num?)?.toDouble() ?? (p['unit_price'] as num?)?.toDouble() ?? 0;
    final price = _allowPriceEdit ? (double.tryParse(_stagedPriceCtrl.text.trim()) ?? basePrice) : basePrice;
    final stock = (p['stock_qty'] as num?)?.toDouble() ?? 0;
    final qty = double.tryParse(_stagedQtyCtrl.text.trim()) ?? 1;
    final rawDisc = double.tryParse(_stagedDiscCtrl.text.trim()) ?? 0;
    final disc = _stagedDiscType == 'percent' ? rawDisc.clamp(0, 100).toDouble() : rawDisc.clamp(0, price * qty).toDouble();
    final da = _stagedDiscType == 'percent' ? price * qty * disc / 100 : disc;
    final total = price * qty - da;
    final isEdit = _stagedCartIndex != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isEdit ? AppTheme.primary : Colors.green.shade300, width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(p['name'] as String? ?? '-', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
          if (isEdit) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: const Text('Editing', style: TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 3),
        if (_allowPriceEdit)
          Row(children: [
            SizedBox(width: 160, child: TextField(controller: _stagedPriceCtrl, focusNode: _stagedPriceFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              decoration: InputDecoration(prefixText: 'Rs. ', labelText: 'Unit price', isDense: true,
                filled: true, fillColor: const Color(0xFFF8F9FA),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) { _stagedQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _stagedQtyCtrl.text.length); _stagedQtyFocus.requestFocus(); })),
            const SizedBox(width: 12),
            Expanded(child: Text(stock >= 0 ? 'Stock: ' + stock.toStringAsFixed(0) : (_allowNoStock ? 'Stock not tracked' : 'No stock'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          ])
        else
          Text('Rs. ' + money(price) + '   ' + (stock >= 0 ? 'Stock: ' + stock.toStringAsFixed(0) : (_allowNoStock ? 'Stock not tracked' : 'No stock')), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Qty', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            TextField(controller: _stagedQtyCtrl, focusNode: _stagedQtyFocus,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              decoration: InputDecoration(filled: true, fillColor: const Color(0xFFF8F9FA), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(vertical: 12)),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _stagedDiscFocus.requestFocus()),
          ])),
          const SizedBox(width: 14),
          Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Discount', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(child: TextField(controller: _stagedDiscCtrl, focusNode: _stagedDiscFocus,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(filled: true, fillColor: const Color(0xFFF8F9FA), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                onChanged: (v) => setState(() {
                  if (_stagedDiscType == 'percent') {
                    final n = double.tryParse(v);
                    if (n != null && n > 100) {
                      _stagedDiscCtrl.text = '100';
                      _stagedDiscCtrl.selection = TextSelection.collapsed(offset: _stagedDiscCtrl.text.length);
                    }
                  }
                }),
                onSubmitted: (_) => _confirmStaged())),
              const SizedBox(width: 8),
              DropdownButton<String>(value: _stagedDiscType, isDense: true, underline: const SizedBox(),
                items: const [DropdownMenuItem(value: 'fixed', child: Text('Rs')), DropdownMenuItem(value: 'percent', child: Text('%'))],
                onChanged: (v) => setState(() => _stagedDiscType = v!)),
            ]),
          ])),
        ]),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Rs. ' + money(total), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          Row(children: [
            TextButton(onPressed: _clearStaged, child: const Text('Cancel')),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: Icon(isEdit ? Icons.check : Icons.add_shopping_cart, size: 16),
              label: Text(isEdit ? 'Update Bill' : 'Add to Bill'),
              onPressed: _confirmStaged,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
          ]),
        ]),
      ]),
    );
  }

  void _playBadgeSound() {
    try { _playTone(880, 0.3, 'sawtooth'); } catch (_) {}
  }

  void _playSuccessSound() {
    try { _playTone(523, 0.15, 'sine'); Future.delayed(const Duration(milliseconds: 150), () { try { _playTone(659, 0.15, 'sine'); } catch (_) {} }); Future.delayed(const Duration(milliseconds: 300), () { try { _playTone(784, 0.2, 'sine'); } catch (_) {} }); } catch (_) {}
  }

  void _playTone(double freq, double duration, String type) {
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [
        'try{var a=new(window.AudioContext||window.webkitAudioContext)();'
        'var o=a.createOscillator();var g=a.createGain();'
        'o.connect(g);g.connect(a.destination);'
        'o.type="$type";o.frequency.value=$freq;'
        'g.gain.setValueAtTime(0.3,a.currentTime);'
        'g.gain.exponentialRampToValueAtTime(0.001,a.currentTime+$duration);'
        'o.start();o.stop(a.currentTime+$duration);}catch(e){}'
      ]);
    } catch (_) {}
  }

  void _filterProducts(String q) {
    setState(() {
      _search = q;
      _displayProducts = q.isEmpty ? _allProducts : _allProducts.where((p) =>
          matchesQuery('${p['name'] ?? ''} ${p['sku'] ?? ''}', q)).toList();
    });
  }

  void _syncFocusNodes() {
    while (_qtyFocusNodes.length < _cart.length) { _qtyFocusNodes.add(FocusNode()); _discFocusNodes.add(FocusNode()); }
    while (_qtyFocusNodes.length > _cart.length) { _qtyFocusNodes.removeLast().dispose(); _discFocusNodes.removeLast().dispose(); }
  }

  void _addToCart(Map<String, dynamic> product) {
    final existing = _cart.indexWhere((c) => c['pos_catalog_id'] == product['id']);
    setState(() {
      if (existing >= 0) {
        _cart[existing]['quantity'] = (_cart[existing]['quantity'] as double) + 1;
      } else {
        _cart.add({
          'pos_catalog_id': product['id'],
          'product_id': product['product_id'],
          'name': product['name'],
          'sku': product['sku'],
          'unit_price': (product['price'] as num?)?.toDouble() ?? 0,
          'uom_id': product['uom_id'],
          'quantity': 1.0,
          'discount': 0.0,
          'discount_type': 'fixed',
          'stock_qty': (product['stock_qty'] as num?)?.toDouble() ?? 0.0,
        });
      }
    });
  }

  double _lineSubtotal(Map<String, dynamic> item) {
    final qty = item['quantity'] as double;
    final price = item['unit_price'] as double;
    final disc = item['discount'] as double;
    final discType = item['discount_type'] as String;
    final discAmt = discType == 'percent' ? price * qty * (disc / 100) : disc;
    return (price * qty) - discAmt;
  }

  double get _cartSubtotal => _cart.fold(0, (s, i) => s + (i['unit_price'] as double) * (i['quantity'] as double));
  double get _cartItemDiscounts => _cart.fold(0, (s, i) {
    final d = (i['discount'] as num?)?.toDouble() ?? 0; final qty = (i['quantity'] as num?)?.toDouble() ?? 0; final price = (i['unit_price'] as num?)?.toDouble() ?? 0;
    final gross = price * qty;
    // Safety net: clamp even if a bad discount was somehow stored, so a total
    // can never be driven negative. % -> 0-100, fixed -> 0-(line gross).
    final da = i['discount_type'] == 'percent' ? gross * (d.clamp(0, 100) / 100) : d.clamp(0, gross).toDouble();
    return s + da;
  });
  double get _orderDiscountAmt {
    // Apply the order-level discount to the subtotal AFTER line-item discounts,
    // so a percent discount isn't inflated by the gross and the combined
    // discount (line + order) can never exceed the sale.
    final base = (_cartSubtotal - _cartItemDiscounts).clamp(0, double.infinity).toDouble();
    return _orderDiscountType == 'percent'
        ? base * (_orderDiscount.clamp(0, 100) / 100)
        : _orderDiscount.clamp(0, base).toDouble();
  }
  double get _cartTotal => (_cartSubtotal - _cartItemDiscounts - _orderDiscountAmt).clamp(0, double.infinity);
  double get _totalDiscount => _cartItemDiscounts + _orderDiscountAmt;

  bool _checkingOut = false;
  // ── Phase 1: tender helpers ─────────────────────────────────────────────
  Map<String, dynamic>? _methodByCode(String code) {
    for (final m in _payMethods) { if (m['code'] == code) return m; }
    return null;
  }

  Widget _bankDropdown() => DropdownButtonFormField<String>(
    value: _selectedBankId,
    isExpanded: true,
    decoration: const InputDecoration(isDense: true, labelText: 'Bank account', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
    items: _bankAccounts.map((b) => DropdownMenuItem(value: b['id'] as String, child: Text(b['name'] as String, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))).toList(),
    onChanged: _isOpen ? (v) => setState(() => _selectedBankId = v) : null,
  );

  // Tenders for the current sale. Single mode: full total on selected method.
  // Split mode: each method's entered amount (non-zero only).
  List<Map<String, dynamic>> _buildTenders(double total) {
    final out = <Map<String, dynamic>>[];
    void addTender(Map<String, dynamic> m, double amt) {
      var acct = m['gl_account_id'];
      var label = m['label'] as String;
      if (m['code'] == 'bank' && _selectedBankId != null) {
        acct = _selectedBankId;
        final b = _bankAccounts.firstWhere((x) => x['id'] == _selectedBankId, orElse: () => const {});
        if (b.isNotEmpty) label = '${m['label']} — ${b['name']}';
      }
      out.add({'code': m['code'], 'label': label, 'account_id': acct, 'is_credit': m['is_credit'] == true, 'amount': amt});
    }
    if (_splitPayment) {
      for (final m in _payMethods) {
        final amt = double.tryParse(_tenderCtrls[m['code'] as String]?.text.trim() ?? '') ?? 0;
        if (amt != 0) addTender(m, amt);
      }
    } else {
      final m = _methodByCode(_paymentMethod);
      if (m != null) addTender(m, total);
    }
    return out;
  }

  double _tendersEntered() {
    double s = 0;
    for (final m in _payMethods) { s += double.tryParse(_tenderCtrls[m['code']]?.text.trim() ?? '') ?? 0; }
    return s;
  }

  double _collectedNonCredit(List<Map<String, dynamic>> tenders) =>
      tenders.where((t) => t['is_credit'] != true).fold(0.0, (s, t) => s + (t['amount'] as num).toDouble());
  double _creditPortion(List<Map<String, dynamic>> tenders) =>
      tenders.where((t) => t['is_credit'] == true).fold(0.0, (s, t) => s + (t['amount'] as num).toDouble());

  // Whether the current payment entry is valid to complete the sale.
  bool _paymentValid() {
    final tenders = _buildTenders(_cartTotal);
    if (tenders.isEmpty) return false;
    final collected = _collectedNonCredit(tenders);
    final owed = _creditPortion(tenders);
    final hasCust = _selectedCustomer != null || _selectedPosCustomer != null;
    if (_splitPayment) {
      final diff = collected - (_cartTotal - owed); // <0 short, >0 overpaid (advance)
      if (diff < -0.01) return false;               // short — not allowed
      if (diff > 0.01 && !hasCust) return false;    // surplus needs a customer
    }
    // any on-credit (owed) portion requires a customer too
    if (owed > 0 && !hasCust) return false;
    return true;
  }

  // Session payment breakdown: amount collected per method/account label,
  // from captured tenders (payment_details) with a legacy fallback for old rows.
  Map<String, double> _sessionBreakdown() {
    final out = <String, double>{};
    for (final t in _transactions) {
      if (((t['transaction_type'] as String?) ?? 'sale') == 'return') continue;
      final pd = t['payment_details'];
      if (pd is List && pd.isNotEmpty) {
        for (final tn in pd) {
          if (tn is! Map) continue;
          final amt = (tn['amount'] as num?)?.toDouble() ?? 0;
          if (amt == 0) continue;
          if (tn['is_credit'] == true) {
            // positive = owed on account; negative = advance/credit to customer
            if (amt > 0) {
              out['Customer Account (owed)'] = (out['Customer Account (owed)'] ?? 0) + amt;
            } else {
              out['Customer Account (advance)'] = (out['Customer Account (advance)'] ?? 0) + (-amt);
            }
          } else {
            final label = (tn['label'] as String?) ?? 'Other';
            out[label] = (out[label] ?? 0) + amt;
          }
        }
      } else {
        final tot = ((t['total'] as num?)?.toDouble() ?? 0).abs();
        final paid = (t['amount_paid'] as num?)?.toDouble();
        final cashPortion = (paid != null && paid < tot) ? paid : tot;
        final credit = tot - cashPortion;
        final pm = (t['payment_method'] as String?) ?? 'Cash';
        final label = pm.isEmpty ? 'Cash' : '${pm[0].toUpperCase()}${pm.substring(1)}';
        if (cashPortion != 0) out[label] = (out[label] ?? 0) + cashPortion;
        if (credit > 0) out['Customer Account (owed)'] = (out['Customer Account (owed)'] ?? 0) + credit;
      }
    }
    return out;
  }

  // Per-customer customer-account detail for this session: name -> {owed, advance}.
  Map<String, Map<String, double>> _customerAccountDetail() {
    final out = <String, Map<String, double>>{};
    for (final t in _transactions) {
      if (((t['transaction_type'] as String?) ?? 'sale') == 'return') continue;
      final name = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      void add(double owed, double adv) {
        final m = out.putIfAbsent(name, () => {'owed': 0, 'advance': 0});
        m['owed'] = m['owed']! + owed;
        m['advance'] = m['advance']! + adv;
      }
      final pd = t['payment_details'];
      if (pd is List && pd.isNotEmpty) {
        for (final tn in pd) {
          if (tn is! Map || tn['is_credit'] != true) continue;
          final amt = (tn['amount'] as num?)?.toDouble() ?? 0;
          if (amt > 0) { add(amt, 0); } else if (amt < 0) { add(0, -amt); }
        }
      } else {
        final tot = ((t['total'] as num?)?.toDouble() ?? 0).abs();
        final paid = (t['amount_paid'] as num?)?.toDouble();
        final onAcct = (paid != null && paid < tot) ? (tot - paid) : 0.0;
        if (onAcct > 0) add(onAcct, 0);
      }
    }
    out.removeWhere((k, m) => (m['owed'] ?? 0) == 0 && (m['advance'] ?? 0) == 0);
    return out;
  }

  // Human-readable split for a transaction's tenders, or '' if single/none.
  String _tenderSummary(Map<String, dynamic> txn) {
    final pd = txn['payment_details'];
    if (pd is List && pd.length > 1) {
      return pd.map((t) {
        final m = t as Map;
        final amt = (m['amount'] as num?)?.toDouble() ?? 0;
        return amt < 0
            ? '${m['label']} (credit): ${(-amt).toStringAsFixed(0)}'
            : '${m['label']}: ${amt.toStringAsFixed(0)}';
      }).join('  ·  ');
    }
    return '';
  }

  // Searchable promoter picker (optional, one per bill).
  Future<void> _pickPromoter() async {
    final searchCtrl = TextEditingController();
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        String q = '';
        return StatefulBuilder(builder: (ctx, setD) {
          final ql = q.trim().toLowerCase();
          final list = ql.isEmpty
              ? _promoters
              : _promoters.where((p) =>
                  matchesQuery('${p['name'] ?? ''} ${p['phone'] ?? ''}', ql)).toList();
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 6), child: Row(children: [
                  const Expanded(child: Text('Select promoter', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                  IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
                ])),
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
                  controller: searchCtrl, autofocus: true,
                  decoration: InputDecoration(hintText: 'Search name or phone…', prefixIcon: const Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
                  onChanged: (v) => setD(() => q = v),
                )),
                const Divider(height: 1),
                Expanded(child: list.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No promoters found', style: TextStyle(color: AppTheme.textSecondary))))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final phone = p['phone'] as String?;
                        return ListTile(dense: true,
                          title: Text(p['name'] as String? ?? '-', style: const TextStyle(fontSize: 13.5)),
                          subtitle: (phone != null && phone.isNotEmpty) ? Text(phone, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)) : null,
                          onTap: () => Navigator.pop(ctx, p));
                      },
                    )),
              ]),
            ),
          );
        });
      },
    );
    if (picked != null) setState(() => _selectedPromoter = picked);
  }

  // Complete the sale if the same guards as the button pass. Used by the
  // Cmd/Ctrl+Enter global hotkey so a sale can be finished without the mouse.
  void _tryCheckout() {
    if (_cart.isNotEmpty && _isOpen && _paymentValid()) _checkout();
  }

  Future<void> _checkout() async {
    if (_checkingOut) return;
    // Guards run BEFORE claiming the flag — the old order set _checkingOut=true
    // then could early-return (empty cart / stock short), leaving it stuck true
    // and bricking the checkout button until the screen reloaded.
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    if (_cart.any((i) => i['product_id'] == null)) { _showSnack('Some items have no product link — remove and re-add'); return; }
    // Stock check
    for (final item in _cart) {
      final qty = item['quantity'] as double;
      final stock = (item['stock_qty'] as num?)?.toDouble() ?? 0;
      if (!_allowNoStock && (stock <= 0 || qty > stock)) { _showSnack('Insufficient stock for "${item['name']}": ${(stock < 0 ? 0 : stock).toStringAsFixed(0)} available'); return; }
    }
    _checkingOut = true;
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final txnId = 'post_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(9999999)}';
      String txnNumber = 'TRX-${DateTime.now().year}-00001';
      bool numbered = false;
      try {
        // Atomic per-org sequence — two concurrent checkouts can't mint the same
        // number. Falls back to the old client scan if the RPC isn't deployed yet.
        final n = await client.rpc('next_pos_transaction_number', params: {'p_org': orgId ?? ''});
        if (n is String && n.isNotEmpty) { txnNumber = n; numbered = true; }
      } catch (_) {}
      if (!numbered) {
        try {
          final lastTxn = await client.from('pos_transactions').select('transaction_number')
              .eq('org_id', orgId ?? '').not('transaction_number', 'is', null)
              .order('transacted_at', ascending: false).limit(1);
          if ((lastTxn as List).isNotEmpty && lastTxn[0]['transaction_number'] != null) {
            final last = lastTxn[0]['transaction_number'] as String;
            final lastNum = int.tryParse(last.split('-').last) ?? 0;
            txnNumber = 'TRX-${DateTime.now().year}-${(lastNum + 1).toString().padLeft(5, "0")}';
          }
        } catch (_) {}
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final cartSnapshot = List<Map<String, dynamic>>.from(_cart);
      final totalAmt = _cartTotal;
      final discountAmt = _totalDiscount;
      final entered = _buildTenders(totalAmt);
      final money = entered.where((t) => t['is_credit'] != true).toList();
      final collected = money.fold<double>(0, (s, t) => s + (t['amount'] as num).toDouble());
      final owed = _creditPortion(entered);
      final advance = collected - (totalAmt - owed);        // >0 = overpaid (advance)
      final netAr = owed - (advance > 0 ? advance : 0);      // +ve Dr AR (owed), -ve Cr AR (advance)
      final creditMethod = _payMethods.firstWhere((m) => m['is_credit'] == true, orElse: () => <String, dynamic>{});
      final tenders = <Map<String, dynamic>>[...money];
      if (netAr.abs() > 0.01) {
        tenders.add({
          'code': 'customer',
          'label': creditMethod.isEmpty ? 'Customer Account' : (creditMethod['label'] as String? ?? 'Customer Account'),
          'account_id': creditMethod.isEmpty ? null : creditMethod['gl_account_id'],
          'is_credit': true,
          'amount': netAr,
        });
      }
      final balanceChange = -netAr;                          // +ve credit added, -ve balance due
      final primaryMethod = tenders.length == 1 ? (tenders.first['label'] as String) : (tenders.isEmpty ? 'Cash' : 'Split');
      // Atomic + idempotent: ONE DB transaction inserts the transaction, its
      // items, the stock movements and the stock updates. A retry with the same
      // txnId hits the primary key and errors instead of double-posting.
      await client.rpc('post_pos_transaction', params: {
        'p_txn': {
          'id': txnId, 'transaction_number': txnNumber, 'org_id': orgId, 'session_id': _session['id'],
          'customer_id': _selectedCustomer?['id'],
          'pos_customer_id': _selectedPosCustomer?['id'],
          'promoter_id': _selectedPromoter?['id'],
          'total': totalAmt, 'discount': discountAmt,
          'payment_method': primaryMethod,
          'payment_details': tenders,
          'amount_paid': collected,
          'balance_change': balanceChange,
          'transaction_type': 'sale',
          'created_by': userId, 'transacted_at': now,
        },
        'p_lines': [
          for (final item in cartSnapshot)
            {
              'product_id': item['product_id'],
              'uom_id': item['uom_id'],
              'quantity': item['quantity'],
              'unit_price': item['unit_price'],
              'discount': item['discount'],
              'discount_type': item['discount_type'] as String? ?? 'fixed',
            },
        ],
        'p_branch_id': branchId,
      });
      // Customer balances are GL-computed (via the sale's AR posting under
      // customer_id) — no separate balance column to maintain.
      final custShop = _selectedCustomer?['shop_name'] as String?;
      setState(() {
        // Decrement local stock for the sold items so the till reflects it
        // instantly — this removes the need for the slow full reload post-sale.
        for (final ci in cartSnapshot) {
          final pid = ci['product_id'];
          final q = (ci['quantity'] as num?)?.toDouble() ?? 0;
          for (final pr in _allProducts) {
            if (pr['product_id'] == pid) { pr['stock_qty'] = ((pr['stock_qty'] as num?)?.toDouble() ?? 0) - q; break; }
          }
        }
        _cart.clear(); _orderDiscount = 0; _selectedCustomer = null; _selectedPosCustomer = null; _selectedPromoter = null; _customerSearchCtrl.clear(); _paymentMethod = _payMethods.isNotEmpty ? _payMethods.first['code'] as String : 'cash'; _customPaymentCtrl.clear(); _splitPayment = false; _amountPaidCtrl.clear(); for (final c in _tenderCtrls.values) { c.clear(); } _syncFocusNodes();
      }); _playSuccessSound();
      // Show the receipt immediately from the just-posted data — don't block the
      // cashier on a full catalog/stock reload (that was the post-sale lag).
      if (mounted) {
        final Map<String, dynamic> txn = {'id': txnId, 'transaction_number': txnNumber, 'total': totalAmt, 'discount': discountAmt, 'payment_method': primaryMethod, 'transacted_at': now, 'customers': custShop != null ? {'shop_name': custShop} : null};
        await showDialog(context: context, barrierDismissible: false, builder: (_) => _ReceiptDialog(
          transaction: txn, items: cartSnapshot,
          orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
          branchName: _session['branches']?['name'] as String? ?? '',
          cashierName: ref.read(currentUserProvider)?.name ?? '', posConfig: _posConfig,
        ));
      }
      // Refresh only this session's transactions (one fast query) so the
      // receipts panel updates. Catalog / customers / prices are unchanged.
      await _refreshSessionTxns();
    } catch (e) { _showSnack('Failed: $e'); } finally { setState(() => _checkingOut = false); }
  }

  Future<void> _processReturn(Map<String, dynamic> originalTxn, List<Map<String, dynamic>> returnItems) async {
    if (returnItems.isEmpty) { _showSnack('Select at least one item'); return; }
    // Ask where the refund goes — always offer both. Customer Account needs a
    // customer on the sale (post_pos_money credits their receivable).
    final hasCustomer = (originalTxn['customer_id'] as String?)?.isNotEmpty == true;
    final refundDest = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Refund to'),
      content: const Text('Where should this refund go?'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        OutlinedButton(onPressed: () => Navigator.pop(ctx, 'Customer Account'), child: const Text('Customer Account')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, 'Cash'), child: const Text('Cash')),
      ],
    ));
    if (refundDest == null) return; // cancelled
    if (refundDest == 'Customer Account' && !hasCustomer) {
      _showSnack('This sale has no customer — attach a customer to refund to their account, or choose Cash.');
      return;
    }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final retId = 'posr_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().toUtc().toIso8601String();
      double returnTotal = returnItems.fold(0, (s, i) { final qty = i['return_qty'] as double; final price = (i['unit_price'] as num?)?.toDouble() ?? 0; final disc = (i['discount'] as num?)?.toDouble() ?? 0; final discType = i['discount_type'] as String? ?? 'fixed'; final origQty = (i['quantity'] as num?)?.toDouble() ?? 1; final da = discType == 'percent' ? price * origQty * (disc/100) : disc; return s + qty * (price - (origQty > 0 ? da/origQty : 0)); });
      // Atomic + idempotent — same RPC as checkout; a 'return' transaction
      // stores negative item qtys and adds the stock back, all in one txn.
      await client.rpc('post_pos_transaction', params: {
        'p_txn': {
          'id': retId, 'org_id': orgId, 'session_id': _session['id'],
          'customer_id': originalTxn['customer_id'],
          'total': -returnTotal, 'discount': 0,
          'payment_method': refundDest,
          'transaction_type': 'return',
          'reference_transaction_id': originalTxn['id'],
          'created_by': userId, 'transacted_at': now,
        },
        // Store the NET unit price (original price minus the line discount,
        // pro-rated per unit) with discount 0, so the return line's value equals
        // its share of the refund total. Previously it recorded the GROSS price
        // with discount 0, so line-derived reports overstated returns.
        'p_lines': returnItems.map((item) {
          final price = (item['unit_price'] as num?)?.toDouble() ?? 0;
          final disc = (item['discount'] as num?)?.toDouble() ?? 0;
          final discType = item['discount_type'] as String? ?? 'fixed';
          final origQty = (item['quantity'] as num?)?.toDouble() ?? 1;
          final daPerUnit = discType == 'percent' ? price * (disc / 100) : (origQty > 0 ? disc / origQty : 0);
          final netUnit = (price - daPerUnit).clamp(0, double.infinity).toDouble();
          return {
            'product_id': item['product_id'],
            'uom_id': item['uom_id'],
            'quantity': item['return_qty'],
            'unit_price': netUnit,
            'discount': 0,
          };
        }).toList(),
        'p_branch_id': branchId,
      });
      _showSnack('Return processed — Rs. ${money(returnTotal)} refunded');
      await _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _showQuickAddCustomer() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final cnicCtrl = TextEditingController();
    final orgId = _orgId; final branchId = _session['branch_id'] as String?;
    if (orgId == null || branchId == null) return;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Quick Add Customer'),
      content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name *', hintText: 'Customer name'), autofocus: true, textCapitalization: TextCapitalization.words),
        const SizedBox(height: 10),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone', hintText: '03XX-XXXXXXX'), keyboardType: TextInputType.phone),
        const SizedBox(height: 10),
        TextField(controller: cnicCtrl, decoration: const InputDecoration(labelText: 'CNIC (optional)', hintText: 'XXXXX-XXXXXXX-X'), keyboardType: TextInputType.number),
      ])),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Add Customer'))],
    ));
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      final client = Supabase.instance.client;
      final name = nameCtrl.text.trim();
      // Generate a POS-000N code (POS-origin customers).
      final existing = await client.from('customers').select('code').eq('org_id', orgId).like('code', 'POS-%');
      int maxN = 0;
      for (final r in (existing as List)) {
        final c = (r['code'] as String? ?? '');
        final n = int.tryParse(c.replaceFirst('POS-', '')) ?? 0;
        if (n > maxN) maxN = n;
      }
      final code = 'POS-${(maxN + 1).toString().padLeft(4, '0')}';
      final id = 'cust_pos_${DateTime.now().millisecondsSinceEpoch}';
      // A customer is a customer — created via POS is just a different route.
      // Required ERP fields are defaulted; complete them later in ERP.
      await client.from('customers').insert({
        'id': id, 'org_id': orgId, 'code': code,
        'shop_name': name, 'contact_person': name,
        'phone': phoneCtrl.text.trim(), 'address': '',
        'cnic': cnicCtrl.text.trim().isEmpty ? null : cnicCtrl.text.trim(),
        'is_active': true, 'location_capture_allowed': false,
        'monthly_sale_target': 0, 'source': 'pos',
        'updated_at': DateTime.now().toIso8601String(),
      });
      final newCust = {'id': id, 'shop_name': name, 'code': code, 'phone': phoneCtrl.text.trim(), 'cnic': cnicCtrl.text.trim(), 'source': 'pos'};
      setState(() { _customers.add(newCust); _selectedCustomer = newCust; _selectedPosCustomer = null; _customerSearchCtrl.clear(); });
      _showSnack('Customer "$name" added');
    } catch (e) { _showSnack('Failed: $e'); } finally { _checkingOut = false; }
  }

  Future<void> _closeSession() async {
    final opening = (_session['opening_cash'] as num?)?.toDouble() ?? 0;
    double cashSales = 0, cashExpenses = 0;
    final returnTxns = _transactions
        .where((t) => (t['transaction_type'] as String?) == 'return')
        .toList();
    for (final t in _transactions) {
      final type = (t['transaction_type'] as String?) ?? 'sale';
      if (type != 'return') cashSales += _posCashCollected(t);
    }
    // Only the cash portion of a refund leaves the drawer (credit returns hit AR).
    final cashRefunds = await _posCashRefundTotal(Supabase.instance.client, returnTxns);
    for (final e in _expenses) {
      cashExpenses += (e['amount'] as num?)?.toDouble() ?? 0;
    }
    double cashPayments = 0;
    for (final p in _sessionPayments) {
      cashPayments += (p['total_amount'] as num?)?.toDouble() ?? 0;
    }
    double cashReceipts = 0;
    for (final p in _sessionReceipts) {
      cashReceipts += (p['total_amount'] as num?)?.toDouble() ?? 0;
    }
    final breakdown = _sessionBreakdown();
    final expectedClose = opening + cashSales - cashRefunds - cashExpenses - cashPayments + cashReceipts;
    final cashCtrl = TextEditingController(text: expectedClose.toStringAsFixed(2));
    final notesCtrl = TextEditingController();
    Widget ccRow(String label, double val, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: bold ? AppTheme.textPrimary : AppTheme.textSecondary)),
        Text('Rs. ${money(val == 0 ? 0.0 : val)}', style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: bold ? AppTheme.primary : AppTheme.textPrimary)),
      ]),
    );
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Close Session'),
      content: SizedBox(width: 320, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ccRow('Opening cash', opening),
            ccRow('+ Cash sales', cashSales),
            ccRow('- Cash refunds', -cashRefunds),
            ccRow('- Cash expenses', -cashExpenses),
            if (cashPayments > 0) ccRow('- Supplier/expense payments', -cashPayments),
            if (cashReceipts > 0) ccRow('+ Customer receipts', cashReceipts),
            const Divider(height: 14),
            ccRow('Expected closing cash', expectedClose, bold: true),
          ]),
        ),
        if (breakdown.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Collected by account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 4),
              ...breakdown.entries.map((e) => ccRow(e.key, e.value)),
            ]),
          ),
        ],
        const SizedBox(height: 4),
        const Align(alignment: Alignment.centerLeft, child: Text('Auto-filled - edit to the actual counted cash if it differs.', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary, fontStyle: FontStyle.italic))),
        const SizedBox(height: 8),
        TextField(controller: cashCtrl, decoration: const InputDecoration(labelText: 'Closing Cash', prefixText: 'Rs. '), keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true),
        const SizedBox(height: 12),
        TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes (optional)'), maxLines: 2),
      ])),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () {
          if (double.tryParse(cashCtrl.text.trim()) == null) { _showSnack('Enter the closing cash to close the session'); return; }
          Navigator.of(context, rootNavigator: true).pop(true);
        }, child: const Text('Close Session'))],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('pos_sessions').update({
        'status': 'closed', 'closed_at': DateTime.now().toUtc().toIso8601String(),
        'closing_cash': double.tryParse(cashCtrl.text.trim()) ?? 0,
        'closed_by': ref.read(currentUserProvider)?.id,
        'notes': notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
      }).eq('id', _session['id']);
      await _loadData();
      await _exportSummary(); // ask bill-wise vs combined on close (restored)
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  /// Asks whether the product breakdown should be per-transaction (bill-wise,
  /// the current format) or merged into one row per product (combined).
  /// Returns true=combined, false=bill-wise, null=cancelled.
  Future<bool?> _askSummaryMode() async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export summary'),
        content: const Text(
          'How should the product breakdown appear?\n\n'
          '• Bill-wise — one row per transaction (current format).\n'
          '• Combined — all bills merged, one row per product with total quantity.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Bill-wise')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Combined')),
        ],
      ),
    );
  }

  Future<void> _exportSummary({bool? combined}) async {
    // When not told explicitly (e.g. the manual Summary buttons), ask the user.
    if (combined == null) {
      combined = await _askSummaryMode();
      if (combined == null) return; // cancelled
    }
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
    // The printed summary reads closing_cash / closed_at from _session. If the
    // session was closed just now or in another tab, the in-memory copy can be
    // stale (closing cash shows 0). Re-fetch the authoritative values from the
    // DB so the printout always reflects the saved close.
    try {
      final fresh = await client
          .from('pos_sessions')
          .select('opening_cash, closing_cash, closed_at, status')
          .eq('id', _session['id'])
          .single();
      _session['opening_cash'] = fresh['opening_cash'];
      _session['closing_cash'] = fresh['closing_cash'];
      _session['closed_at'] = fresh['closed_at'];
      _session['status'] = fresh['status'];
    } catch (_) {}
    final txnIds = _transactions.map((t) => t['id'] as String).toList();
    Map<String, List<Map<String, dynamic>>> itemsByTxn = {};
    if (txnIds.isNotEmpty) {
      try {
        final allItems = await client.from('pos_transaction_items').select('*, products(name, sku)').inFilter('transaction_id', txnIds);
        for (final item in allItems as List) {
          final tid = item['transaction_id'] as String;
          itemsByTxn.putIfAbsent(tid, () => []).add(Map<String, dynamic>.from(item));
        }
      } catch (_) {}
    }
    final sales = _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').toList();
    final returns = _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'return').toList();
    double totalSales = 0, totalReturns = 0;
    for (final t in sales) totalSales += (t['total'] as num?)?.toDouble() ?? 0;
    for (final t in returns) totalReturns += ((t['total'] as num?)?.toDouble() ?? 0).abs();
    double customerAccountSale = 0;  // amount put on customer accounts (unpaid/credit portion) this session
    for (final t in sales) {
      final tot = (t['total'] as num?)?.toDouble() ?? 0;
      final paid = (t['amount_paid'] as num?)?.toDouble() ?? tot;
      final onAcct = tot - paid;
      if (onAcct > 0) customerAccountSale += onAcct;
    }
    final breakdown = _sessionBreakdown();
    String breakdownRows = '';
    breakdown.forEach((k, v) {
      breakdownRows += '<tr><td>$k</td><td style="text-align:right;font-weight:600">${money(v)}</td></tr>';
    });
    final custDetail = _customerAccountDetail();
    String custRows = '';
    custDetail.forEach((name, m) {
      final owed = m['owed'] ?? 0; final adv = m['advance'] ?? 0;
      if (owed != 0) custRows += '<tr><td>$name</td><td style="text-align:right;font-weight:600">${money(owed)}</td></tr>';
      if (adv != 0) custRows += '<tr><td>$name <span style="color:#27ae60">(advance / credit)</span></td><td style="text-align:right;font-weight:600;color:#27ae60">${money(adv)}</td></tr>';
    });
    final openingCash = (_session['opening_cash'] as num?)?.toDouble() ?? 0;
    final closingCash = (_session['closing_cash'] as num?)?.toDouble() ?? 0;
    double totalExpenses = 0; String expRows = '';
    for (final e in _expenses) {
      final ea = (e['amount'] as num?)?.toDouble() ?? 0; totalExpenses += ea;
      final ec = e['category'] as String? ?? '-'; final en = e['note'] as String? ?? '';
      final et = e['created_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '';
      expRows += '<tr style="background:#fff5f5"><td>$et</td><td>$ec</td><td>${en}</td><td style="text-align:right;color:#c0392b;font-weight:bold">-${money(ea)}</td></tr>';
    }
    double cashSales = 0;
    for (final t in sales) { cashSales += _posCashCollected(t); }
    // Supplier/expense payments (CPVs) made from the till this session.
    // One row per line so each supplier/account name shows; CPV# is reference.
    double totalPayments = 0; String payRows = '';
    for (final p in _sessionPayments) {
      final pa = (p['total_amount'] as num?)?.toDouble() ?? 0; totalPayments += pa;
      final pv = p['voucher_number'] as String? ?? '-';
      final pt = p['created_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(p['created_at'] as String).toLocal()) : '';
      final plines = (p['cpv_voucher_lines'] as List?) ?? const [];
      if (plines.isEmpty) {
        final pn = p['notes'] as String? ?? '';
        payRows += '<tr style="background:#fff5f5"><td>$pt</td><td>$pv</td><td>${pn}</td><td style="text-align:right;color:#c0392b;font-weight:bold">-${money(pa)}</td></tr>';
      } else {
        for (final l in plines) {
          final la = (l['amount'] as num?)?.toDouble() ?? 0;
          final name = (l['account_name'] as String?) ?? '-';
          final ldesc = (l['description'] as String?) ?? '';
          final label = ldesc.isNotEmpty ? '$name — $ldesc' : name;
          payRows += '<tr style="background:#fff5f5"><td>$pt</td><td>$pv</td><td>$label</td><td style="text-align:right;color:#c0392b;font-weight:bold">-${money(la)}</td></tr>';
        }
      }
    }
    // For the drawer reconciliation use only the CASH portion of refunds — a
    // credit-sale return reduces AR, not cash. (totalReturns above stays the
    // full customer-facing refund value shown in the Total Refunds stat.)
    final cashRefunds = await _posCashRefundTotal(client, returns);
    final expectedDrawer = openingCash + cashSales - cashRefunds - totalExpenses - totalPayments; // cash refunds, expenses & payments are cash out of drawer
    // Customer receipts (CRVs) into the till this session — cash IN.
    double totalReceipts = 0; String rcvRows = '';
    for (final p in _sessionReceipts) {
      final pa = (p['total_amount'] as num?)?.toDouble() ?? 0; totalReceipts += pa;
      final pv = p['voucher_number'] as String? ?? '-';
      final pt = p['created_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(p['created_at'] as String).toLocal()) : '';
      final plines = (p['crv_voucher_lines'] as List?) ?? const [];
      if (plines.isEmpty) {
        final pn = p['notes'] as String? ?? '';
        rcvRows += '<tr style="background:#f0fff4"><td>$pt</td><td>$pv</td><td>${pn}</td><td style="text-align:right;color:#1e7e34;font-weight:bold">+${money(pa)}</td></tr>';
      } else {
        for (final l in plines) {
          final la = (l['amount'] as num?)?.toDouble() ?? 0;
          final name = (l['account_name'] as String?) ?? '-';
          final ldesc = (l['description'] as String?) ?? '';
          final label = ldesc.isNotEmpty ? '$name — $ldesc' : name;
          rcvRows += '<tr style="background:#f0fff4"><td>$pt</td><td>$pv</td><td>$label</td><td style="text-align:right;color:#1e7e34;font-weight:bold">+${money(la)}</td></tr>';
        }
      }
    }
    final expectedDrawerFinal = expectedDrawer + totalReceipts; // receipts are cash INTO the drawer
    final cashDiff = expectedDrawerFinal - closingCash;  // +ve = cash short, -ve = cash over
    final branch = _session['branches']?['name'] as String? ?? '-';
    final user = ref.read(currentUserProvider);
    final cashier = user?.name ?? user?.id ?? '-';
    final openedAt = _session['opened_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['opened_at'] as String).toLocal()) : '-';
    final closedAt = _session['closed_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['closed_at'] as String).toLocal()) : 'Open';

    // Renders a discount table cell: the amount with its % (of gross) beneath.
    String discCell(double amount, double gross) {
      if (amount <= 0) return '<td>-</td>';
      final pct = gross > 0 ? (amount / gross * 100) : 0;
      return '<td style="color:#e67e22">-${money(amount)}'
          '<div style="font-size:10px;color:#c98b57">(${pct.toStringAsFixed(1)}%)</div></td>';
    }

    // ── Bill-wise rows (one per transaction) ──────────────────────────────
    String txnRows = '';
    for (final t in sales) {
      final tid = t['id'] as String;
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      final method = t['payment_method'] as String? ?? '';
      final totalNum = (t['total'] as num?)?.toDouble() ?? 0;
      final total = money(totalNum);
      final disc = (t['discount'] as num?)?.toDouble() ?? 0;
      final items = itemsByTxn[tid] ?? [];
      final itemStr = items.map((i) { final q = (i['quantity'] as num?)?.toDouble() ?? 0; final p = (i['unit_price'] as num?)?.toDouble() ?? 0; final d = (i['discount'] as num?)?.toDouble() ?? 0; final n = i['products']?['name'] as String? ?? '-'; return '$n × ${q.toStringAsFixed(0)} @ ${money(p)}${d > 0 ? ' (-${money(d)})' : ''}'; }).join('<br>');
      txnRows += '<tr><td>$time</td><td style="font-size:11px;color:#666">${tid.substring(0, 10)}…</td><td>$customer</td><td style="font-size:11px">$itemStr</td><td>$method</td>${discCell(disc, totalNum + disc)}<td style="text-align:right;font-weight:bold">$total</td></tr>';
    }

    // ── Combined rows (one per product, merged across every bill) ──────────
    final Map<String, Map<String, dynamic>> combinedMap = {};
    for (final t in sales) {
      final tid = t['id'] as String;
      for (final i in (itemsByTxn[tid] ?? const [])) {
        final n = i['products']?['name'] as String? ?? '-';
        final sku = i['products']?['sku'] as String? ?? '';
        final key = '$n|$sku';
        final q = (i['quantity'] as num?)?.toDouble() ?? 0;
        final p = (i['unit_price'] as num?)?.toDouble() ?? 0;
        final d = (i['discount'] as num?)?.toDouble() ?? 0;
        final e = combinedMap.putIfAbsent(key, () => {'name': n, 'sku': sku, 'qty': 0.0, 'gross': 0.0, 'disc': 0.0});
        e['qty'] = (e['qty'] as double) + q;
        e['gross'] = (e['gross'] as double) + q * p;
        e['disc'] = (e['disc'] as double) + d;
      }
    }
    final combinedEntries = combinedMap.values.toList()
      ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    String combinedRows = '';
    double combQty = 0, combDisc = 0, combNet = 0;
    for (final e in combinedEntries) {
      final q = e['qty'] as double; final g = e['gross'] as double; final d = e['disc'] as double;
      final net = g - d;
      combQty += q; combDisc += d; combNet += net;
      final sku = e['sku'] as String;
      combinedRows += '<tr><td>${e['name']}'
          '${sku.isNotEmpty ? ' <span style="color:#999;font-size:11px">$sku</span>' : ''}</td>'
          '<td style="text-align:right">${q.toStringAsFixed(q == q.roundToDouble() ? 0 : 2)}</td>'
          '${discCell(d, g)}'
          '<td style="text-align:right;font-weight:bold">${money(net)}</td></tr>';
    }
    final String productSection = combined
        ? (combinedRows.isNotEmpty ? '''<h2>Products Sold (Combined)</h2>
<table><thead><tr><th>Product</th><th style="text-align:right">Qty</th><th>Discount</th><th style="text-align:right">Total</th></tr></thead>
<tbody>$combinedRows
<tr class="total-row"><td>TOTAL</td><td style="text-align:right">${combQty.toStringAsFixed(combQty == combQty.roundToDouble() ? 0 : 2)}</td>${discCell(combDisc, combNet + combDisc)}<td style="text-align:right">${money(combNet)}</td></tr>
</tbody></table>''' : '')
        : (txnRows.isNotEmpty ? '''<h2>Sales Transactions</h2>
<table><thead><tr><th>Time</th><th>Txn #</th><th>Customer</th><th>Items</th><th>Payment</th><th>Discount</th><th>Total</th></tr></thead>
<tbody>$txnRows
<tr class="total-row"><td colspan="6">TOTAL SALES</td><td style="text-align:right">${money(totalSales)}</td></tr>
</tbody></table>''' : '');
    final sessDateStr = _session['opened_at'] != null
        ? DateFormat('yyyy-MM-dd').format(DateTime.parse(_session['opened_at'] as String).toLocal())
        : DateFormat('yyyy-MM-dd').format(DateTime.now());
    final fileTitle = 'POS_Summary_$sessDateStr';
    final Map<String, String> origNumbers = {};
    final refIds = returns.map((t) => t['reference_transaction_id'] as String?).whereType<String>().toSet().toList();
    if (refIds.isNotEmpty) {
      try {
        final origs = await Supabase.instance.client.from('pos_transactions').select('id, transaction_number').inFilter('id', refIds);
        for (final o in origs as List) { origNumbers[o['id'] as String] = (o['transaction_number'] as String?) ?? ''; }
      } catch (_) {}
    }
    String retRows = '';
    for (final t in returns) {
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final refId = t['reference_transaction_id'] as String? ?? '';
      final refNum = (origNumbers[refId]?.isNotEmpty == true) ? origNumbers[refId]! : (refId.isEmpty ? '-' : refId);
      final total = money(((t['total'] as num?)?.toDouble() ?? 0).abs());
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      retRows += '<tr style="background:#fff5f5"><td>$time</td><td>$customer</td><td style="font-size:12px;color:#666">← $refNum</td><td style="text-align:right;color:#e74c3c;font-weight:bold">-$total</td></tr>';
    }

    final htmlContent = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>$fileTitle</title>
<style>@page{margin:0}
*{box-sizing:border-box}body{font-family:Arial,sans-serif;padding:32px;color:#333;max-width:900px;margin:0 auto}
h1{font-size:24px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 10px;color:#555;border-bottom:2px solid #eee;padding-bottom:6px}
.meta{color:#888;font-size:13px;margin-bottom:20px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:24px}
.stat{background:#f8f9fa;padding:14px 16px;border-radius:10px;border:1px solid #e9ecef}
.sl{font-size:11px;color:#888;text-transform:uppercase;letter-spacing:.5px;margin-bottom:4px}
.sv{font-size:20px;font-weight:700;color:#2c3e50}
.sv.green{color:#27ae60}.sv.red{color:#e74c3c}.sv.blue{color:#2980b9}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#f1f3f5;padding:9px 12px;text-align:left;font-size:12px;font-weight:600;color:#555}
td{padding:8px 12px;border-bottom:1px solid #f0f0f0;vertical-align:top}
tr:hover td{background:#fafafa}.total-row td{font-weight:700;background:#f8f9fa;font-size:14px}
.badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.badge-sale{background:#d4edda;color:#155724}.badge-ret{background:#f8d7da;color:#721c24}
@media print{body{padding:16px}h1{font-size:20px}}
</style></head><body>
<h1>POS Session Summary</h1>
<div class="meta">Branch: <b>$branch</b> &nbsp;|&nbsp; Cashier: <b>$cashier</b> &nbsp;|&nbsp; Opened: <b>$openedAt</b> &nbsp;|&nbsp; Closed: <b>$closedAt</b></div>
<div class="stats">
  <div class="stat"><div class="sl">Transactions</div><div class="sv blue">${sales.length}</div></div>
  <div class="stat"><div class="sl">Returns</div><div class="sv red">${returns.length}</div></div>
  <div class="stat"><div class="sl">Total Sales</div><div class="sv green">${money(totalSales)}</div></div>
  <div class="stat"><div class="sl">Total Refunds</div><div class="sv red">${money(totalReturns)}</div></div>
  <div class="stat"><div class="sl">Net Sales</div><div class="sv">${money(totalSales - totalReturns)}</div></div>
  <div class="stat"><div class="sl">Customer Account Sale</div><div class="sv blue">${money(customerAccountSale)}</div></div>
  <div class="stat"><div class="sl">Opening Cash</div><div class="sv">${money(openingCash)}</div></div>
  <div class="stat"><div class="sl">Closing Cash</div><div class="sv">${money(closingCash)}</div></div>
  <div class="stat"><div class="sl">Cash Difference</div><div class="sv ${cashDiff <= 0 ? 'green' : 'red'}">${cashDiff > 0 ? '-' : '+'}${money(cashDiff.abs())}</div></div>
</div>
${breakdownRows.isNotEmpty ? '''<h2>Payment Breakdown</h2>
<table><thead><tr><th>Account / Mode</th><th style="text-align:right">Collected</th></tr></thead>
<tbody>$breakdownRows</tbody></table>''' : ''}
${custRows.isNotEmpty ? '''<h2>Customer Account Detail</h2>
<table><thead><tr><th>Customer</th><th style="text-align:right">Amount</th></tr></thead>
<tbody>$custRows</tbody></table>''' : ''}
$productSection
${expRows.isNotEmpty ? '''<h2>Expenses</h2>
<table><thead><tr><th>Time</th><th>Category</th><th>Note</th><th>Amount</th></tr></thead>
<tbody>$expRows
<tr class="total-row"><td colspan="3">TOTAL EXPENSES</td><td style="text-align:right;color:#c0392b">-${money(totalExpenses)}</td></tr>
</tbody></table>''' : ''}
${payRows.isNotEmpty ? '''<h2>Supplier / Expense Payments (from till)</h2>
<table><thead><tr><th>Time</th><th>CPV Ref.</th><th>Paid To / Description</th><th>Amount</th></tr></thead>
<tbody>$payRows
<tr class="total-row"><td colspan="3">TOTAL PAYMENTS</td><td style="text-align:right;color:#c0392b">-${money(totalPayments)}</td></tr>
</tbody></table>''' : ''}
${rcvRows.isNotEmpty ? '''<h2>Customer Receipts (into till)</h2>
<table><thead><tr><th>Time</th><th>CRV Ref.</th><th>Received From / Description</th><th>Amount</th></tr></thead>
<tbody>$rcvRows
<tr class="total-row"><td colspan="3">TOTAL RECEIPTS</td><td style="text-align:right;color:#1e7e34">+${money(totalReceipts)}</td></tr>
</tbody></table>''' : ''}
${retRows.isNotEmpty ? '''<h2>Returns &amp; Refunds</h2>
<table><thead><tr><th>Time</th><th>Customer</th><th>Original Txn</th><th>Refund</th></tr></thead>
<tbody>$retRows
<tr class="total-row"><td colspan="3">TOTAL REFUNDS</td><td style="text-align:right;color:#e74c3c">-${money(totalReturns)}</td></tr>
</tbody></table>''' : ''}
<script>window.onload=function(){window.print();}</script>
</body></html>''';

    final blob = html.Blob([htmlContent], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');  // opens in new tab, auto-prints via window.onload
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, dynamic>?>(selectedBranchProvider, (prev, next) {
      final nextId = next?['id'] as String?;
      final sessId = _session['branch_id'] as String?;
      if (nextId == null || nextId == sessId || prev?['id'] == nextId) return;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _handleBranchSwitch(next!); });
    });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _tryCheckout,   // Cmd+Enter (Mac)
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _tryCheckout, // Ctrl+Enter (Win/Linux)
        const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true): _tryCheckout,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true): _tryCheckout,
      },
      child: Focus(
        autofocus: false,
        child: Scaffold(
      backgroundColor: const Color(0xFFF0F2F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary), onPressed: () { widget.onUpdated(); Navigator.of(context).pop(); }),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_session['session_number'] as String? ?? 'POS Session', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          Text(_session['branches']?['name'] as String? ?? '', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
        actions: [
          if (_isOpen) ...[
            TextButton.icon(icon: const Icon(Icons.reply, size: 18), label: const Text('Return'), onPressed: () => _showReturnDialog(), style: TextButton.styleFrom(foregroundColor: Colors.orange)),
            const SizedBox(width: 4),
            TextButton.icon(icon: const Icon(Icons.pause_circle_outline, size: 18), label: const Text('Holds'), onPressed: () async { final bill = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const ErpPosHeldBillsScreen())); if (bill != null && mounted) _restoreBill(bill); }, style: TextButton.styleFrom(foregroundColor: Colors.orange)),
            const SizedBox(width: 4),
            TextButton.icon(icon: const Icon(Icons.payments_outlined, size: 18), label: const Text('Payment'), onPressed: _addPayment, style: TextButton.styleFrom(foregroundColor: Colors.red.shade700)),
            TextButton.icon(icon: const Icon(Icons.savings_outlined, size: 18), label: const Text('Receipt'), onPressed: _addReceipt, style: TextButton.styleFrom(foregroundColor: Colors.green.shade700)),
            const SizedBox(width: 4),
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Summary'), onPressed: () => _exportSummary()),
            const SizedBox(width: 4),
            ElevatedButton.icon(icon: const Icon(Icons.power_settings_new, size: 16), label: const Text('Close Session'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: _closeSession),
          ] else ...[
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Export Summary'), onPressed: () => _exportSummary()),
          ],
          const SizedBox(width: 12),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : Row(children: [
        // ── Staging Panel ──────────────────────────────────────
        Expanded(child: Column(children: [
          // Search bar
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 8), child: KeyboardListener(
            focusNode: FocusNode(),
            onKeyEvent: (e) {
              if (e is! KeyDownEvent) return;
              final opts = _displayProducts.take(8).toList();
              if (e.logicalKey == LogicalKeyboardKey.arrowDown) { setState(() => _dropdownHighlight = (_dropdownHighlight + 1).clamp(0, opts.length - 1)); }
              else if (e.logicalKey == LogicalKeyboardKey.arrowUp) { setState(() => _dropdownHighlight = (_dropdownHighlight - 1).clamp(0, opts.length - 1)); }
              else if (e.logicalKey == LogicalKeyboardKey.escape) { setState(() { _showDropdown = false; _searchCtrl.clear(); _filterProducts(''); }); }
            },
            child: TextField(
            controller: _searchCtrl, focusNode: _searchFocus,
            decoration: InputDecoration(
              hintText: _stagedProduct != null
                  ? 'Editing: ' + (_stagedProduct!['name'] as String? ?? '')
                  : 'Search product by name or SKU...',
              prefixIcon: Icon(_stagedProduct != null ? Icons.edit_outlined : Icons.search, size: 20,
                  color: _stagedProduct != null ? AppTheme.primary : null),
              suffixIcon: (_search.isNotEmpty || _stagedProduct != null)
                  ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () {
                      _searchCtrl.clear(); _filterProducts('');
                      setState(() { _stagedProduct = null; _stagedCartIndex = null; });
                    }) : null,
              filled: true, fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
            onTap: () => setState(() => _showDropdown = true),
            onTapOutside: (_) => Future.delayed(const Duration(milliseconds: 150), () { if (mounted) setState(() => _showDropdown = false); }),
            onChanged: (v) { _filterProducts(v); setState(() { _dropdownHighlight = -1; _showDropdown = true; }); },
            onSubmitted: (_) {
              final opts = _displayProducts.take(8).toList();
              if (opts.isNotEmpty) {
                final idx = _dropdownHighlight.clamp(0, opts.length - 1);
                final sel = opts[idx];
                final selStock = (sel['stock_qty'] as num?)?.toDouble() ?? 0;
                if (!_allowNoStock && selStock <= 0) { _playBadgeSound(); } else { _stageProduct(sel); _searchCtrl.clear(); _filterProducts(''); }
              }
            },
          ))),
          // Dropdown results (only when searching and nothing staged)
          if ((_search.isNotEmpty || _showDropdown) && _stagedProduct == null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              constraints: const BoxConstraints(maxHeight: 380),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.07), blurRadius: 10)]),
              child: _displayProducts.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('No products found', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                : Scrollbar(child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _displayProducts.length,
                    itemBuilder: (ctx, i) {
                      final p = _displayProducts[i];
                      final price = (p['price'] as num?)?.toDouble() ?? 0;
                      final stock = (p['stock_qty'] as num?)?.toDouble() ?? 0;
                      final tracked = stock >= 0;            // < 0 is the "no inventory record" sentinel
                      final blocked = !_allowNoStock && !(tracked && stock > 0);
                      final stockLabel = tracked ? 'Stock: ' + stock.toStringAsFixed(0) : (_allowNoStock ? 'Stock not tracked' : 'No stock');
                      final highlighted = i == _dropdownHighlight;
                      return InkWell(
                        onTap: blocked ? () { _playBadgeSound(); } : () { _stageProduct(p); _searchCtrl.clear(); _filterProducts(''); },
                        child: Container(
                          color: highlighted ? AppTheme.primary.withOpacity(0.08) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Row(children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p['name'] as String? ?? '-',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                      color: blocked ? Colors.grey : AppTheme.textPrimary)),
                              Text('Rs. ' + money(price) + '  |  ' + stockLabel,
                                  style: TextStyle(fontSize: 11,
                                      color: blocked ? Colors.red.shade300 : AppTheme.textSecondary)),
                            ])),
                            if (blocked)
                              Text(tracked ? 'OUT' : 'NO STOCK', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.red))
                            else if (highlighted)
                              const Icon(Icons.keyboard_return, size: 14, color: AppTheme.primary),
                          ]),
                        ),
                      );
                    })),
            ),
          // Staging card
          if (_stagedProduct != null) _buildStagingCard(),
          // Empty state
          if (_stagedProduct == null && _search.isEmpty && !_showDropdown)
            Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.point_of_sale_outlined, size: 64, color: Colors.grey.shade200),
              const SizedBox(height: 12),
              Text(_allProducts.isEmpty
                  ? 'No products in catalog\nAdd products via POS Catalog'
                  : 'Search to add products to the bill',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
            ]))),
        ])),
                // ── Cart Panel ─────────────────────────────────────────────────
        Container(
          width: 480,
          decoration: const BoxDecoration(color: Colors.white, border: Border(left: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            // Customer search filter
          if (_cart.length > 4) Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: TextField(decoration: const InputDecoration(hintText: "Filter cart items...", prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8)), onChanged: (v) => setState(() => _cartSearch = v))),
          // Customer — collapsed to a compact chip by default (walk-ins are
          // the norm); tap to expand the search. Frees vertical space above
          // the bill list.
            Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: Builder(builder: (_) {
              final selected = _selectedCustomer;
              final selName = _selectedCustomer != null ? _selectedCustomer!['shop_name'] as String? : null;
              if (!_customerExpanded) {
                return InkWell(
                  onTap: _isOpen ? () => setState(() => _customerExpanded = true) : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(children: [
                      Icon(selected != null ? Icons.person_pin : Icons.person_outline,
                          size: 18,
                          color: selected != null ? AppTheme.primary : AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      Expanded(child: Text(selName ?? 'Walk-in',
                          style: TextStyle(fontSize: 13,
                              color: selected != null ? AppTheme.primary : AppTheme.textSecondary,
                              fontWeight: selected != null ? FontWeight.w600 : FontWeight.normal),
                          overflow: TextOverflow.ellipsis)),
                      if (selected != null)
                        InkWell(
                          onTap: () => setState(() { _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); }),
                          child: const Icon(Icons.clear, size: 16, color: AppTheme.textSecondary))
                      else
                        const Icon(Icons.add, size: 16, color: AppTheme.textSecondary),
                    ]),
                  ),
                );
              }
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Customer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary, letterSpacing: 0.5)),
                const Spacer(),
                InkWell(
                    onTap: () => setState(() { _customerExpanded = false; _showCustomerDropdown = false; }),
                    child: const Icon(Icons.expand_less, size: 18, color: AppTheme.textSecondary)),
              ]),
              const SizedBox(height: 4),
              TextField(
                controller: _customerSearchCtrl,
                enabled: _isOpen,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: selName ?? 'Walk-in (optional)',
                  hintStyle: TextStyle(color: selected != null ? AppTheme.primary : AppTheme.textSecondary, fontWeight: selected != null ? FontWeight.w600 : FontWeight.normal),
                  prefixIcon: Icon(Icons.person_outline, size: 18, color: selected != null ? AppTheme.primary : AppTheme.textSecondary),
                  suffixIcon: selected != null ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); })) : null,
                  isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)),
                ),
                onChanged: (q) {
                  final ql = q.toLowerCase();
                  final matches = q.isEmpty ? <Map<String, dynamic>>[] : _customers.where((c) =>
                      matchesQuery('${c['shop_name'] ?? ''} ${c['phone'] ?? ''} ${c['code'] ?? ''}', ql)
                    ).take(8).toList();
                  setState(() { _showCustomerDropdown = q.isNotEmpty; _filteredCustomers = matches; });
                },
              ),
              if (_showCustomerDropdown)
                Container(margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
                  child: Column(children: [
                    ListTile(dense: true, leading: const Icon(Icons.add_circle, color: AppTheme.primary, size: 20), title: const Text('Quick-add new customer', style: TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w600)), onTap: () { setState(() => _showCustomerDropdown = false); _showQuickAddCustomer(); }),
                    if (_filteredCustomers.isNotEmpty) const Divider(height: 1),
                    ..._filteredCustomers.map((cx) {
                      final isPos = cx['source'] == 'pos';
                      final name = cx['shop_name'] as String? ?? '-';
                      final sub = (cx['phone'] as String?)?.isNotEmpty == true ? cx['phone'] as String? : cx['code'] as String?;
                      return ListTile(dense: true,
                        leading: Icon(isPos ? Icons.person_pin : Icons.business, size: 18, color: isPos ? Colors.purple : AppTheme.textSecondary),
                        title: Text(name, style: const TextStyle(fontSize: 13)),
                        subtitle: sub != null && sub.isNotEmpty ? Text(sub, style: const TextStyle(fontSize: 11)) : null,
                        trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isPos ? Colors.purple.withOpacity(0.1) : AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(isPos ? 'POS' : 'ERP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: isPos ? Colors.purple : AppTheme.primary))),
                        onTap: () => setState(() {
                          _selectedCustomer = cx; _selectedPosCustomer = null;
                          _customerSearchCtrl.clear(); _showCustomerDropdown = false; _customerExpanded = false;
                        }));
                    }),
                  ])),
              ]);
            })),
            // Bill header + review-in-modal action (for long bills)
            if (_cart.isNotEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(14, 6, 4, 0), child: Row(children: [
                const Text('Bill', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(width: 6),
                Text('${_cart.length} item${_cart.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.zoom_out_map, size: 18, color: AppTheme.primary),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Review bill',
                  onPressed: _openBillReview,
                ),
              ])),
            // Bill — read-only, tap to edit
            Expanded(child: _cart.isEmpty
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey.shade200),
                    const SizedBox(height: 8),
                    Text(_isOpen ? 'Use search to add products' : 'Session closed',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  ]))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    itemCount: (_cartSearch.isEmpty ? _cart : _cart.where((it) => matchesQuery('${it['name'] ?? ''}', _cartSearch)).toList()).length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final billView = _cartSearch.isEmpty ? _cart : _cart.where((it) => matchesQuery('${it['name'] ?? ''}', _cartSearch)).toList();
                      final item = billView[i];
                      final cartIdx = _cart.indexOf(item);
                      final qty = item['quantity'] as double;
                      final price = item['unit_price'] as double;
                      final disc = item['discount'] as double;
                      final discType = item['discount_type'] as String? ?? 'fixed';
                      final da = discType == 'percent' ? price * qty * disc / 100 : disc;
                      final lineTotal = qty * price - da;
                      final editing = _stagedCartIndex == i;
                      return InkWell(
                        onTap: _isOpen ? () => _stageProduct(item, cartIndex: cartIdx) : null,
                        child: Container(
                          color: editing ? AppTheme.primary.withOpacity(0.05) : Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                          child: Row(children: [
                            SizedBox(width: 18, child: editing
                                ? const Icon(Icons.edit, size: 13, color: AppTheme.primary)
                                : const SizedBox()),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(item['name'] as String? ?? '-',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                      color: editing ? AppTheme.primary : AppTheme.textPrimary)),
                              Builder(builder: (_) {
                                final discStr = da > 0
                                    ? (discType == 'percent' ? '  (-${disc.toStringAsFixed(0)}%)' : '  (-${money(da)})')
                                    : '';
                                return Text(qty.toStringAsFixed(0) + ' x Rs. ' + money(price) + discStr,
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary));
                              }),
                            ])),
                            Text('Rs. ' + money(lineTotal),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                            if (_isOpen)
                              IconButton(
                                icon: const Icon(Icons.close, size: 15),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                                color: AppTheme.textSecondary,
                                onPressed: () => setState(() {
                                  if (_stagedCartIndex == cartIdx) { _stagedProduct = null; _stagedCartIndex = null; }
                                  else if (_stagedCartIndex != null && _stagedCartIndex! > cartIdx) _stagedCartIndex = _stagedCartIndex! - 1;
                                  _cart.removeAt(cartIdx);
                                }),
                              ),
                          ]),
                        ),
                      );
                    })),
                        // Order discount + payment + total
            Container(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
              child: Column(children: [
                // Order-level discount
                Row(children: [
                  const Text('Order Discount', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  SizedBox(width: 80, child: TextField(
                    enabled: _isOpen,
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true), textAlign: TextAlign.right,
                    onChanged: (v) => setState(() {
                      final raw = double.tryParse(v) ?? 0;
                      _orderDiscount = _orderDiscountType == 'percent'
                          ? raw.clamp(0, 100).toDouble()
                          : (raw < 0 ? 0 : raw);
                    }),
                  )),
                  const SizedBox(width: 6),
                  DropdownButton<String>(value: _orderDiscountType, isDense: true, underline: const SizedBox(),
                    items: const [DropdownMenuItem(value: 'fixed', child: Text('Fixed', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
                    onChanged: _isOpen ? (v) => setState(() => _orderDiscountType = v!) : null),
                ]),
                const SizedBox(height: 6),
                // Promoter (optional, one per bill) — compact selector
                Row(children: [
                  const Icon(Icons.badge_outlined, size: 15, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  const Text('Promoter', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  if (_selectedPromoter != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(8, 3, 4, 3),
                      decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(6)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(_selectedPromoter!['name'] as String? ?? '-', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                        const SizedBox(width: 2),
                        InkWell(onTap: () => setState(() => _selectedPromoter = null),
                          child: const Icon(Icons.close, size: 14, color: AppTheme.primary)),
                      ]),
                    )
                  else
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0), minimumSize: const Size(0, 28)),
                      onPressed: _isOpen ? _pickPromoter : null,
                    ),
                ]),
                const SizedBox(height: 6),
                // Payment
                Row(children: [
                  const Text('Payment', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  if (_isOpen) TextButton.icon(icon: Icon(_splitPayment ? Icons.call_merge : Icons.call_split, size: 15), label: Text(_splitPayment ? 'Single' : 'Split', style: const TextStyle(fontSize: 11)), onPressed: () => setState(() { _splitPayment = !_splitPayment; _amountPaidCtrl.clear(); for (final c in _tenderCtrls.values) { c.clear(); } })),
                ]),
                if (!_splitPayment) ...[
                  Wrap(spacing: 6, runSpacing: 6, children: _payMethods.map((m) {
                    final code = m['code'] as String;
                    return ChoiceChip(
                      label: Text(m['label'] as String, style: const TextStyle(fontSize: 11)),
                      selected: _paymentMethod == code,
                      visualDensity: VisualDensity.compact,
                      onSelected: _isOpen ? (_) => setState(() => _paymentMethod = code) : null,
                    );
                  }).toList()),
                  if (_paymentMethod == 'bank' && _bankAccounts.length > 1) ...[
                    const SizedBox(height: 8),
                    _bankDropdown(),
                  ],
                  if (_methodByCode(_paymentMethod)?['is_credit'] == true) ...[
                    const SizedBox(height: 6),
                    Builder(builder: (_) {
                      final hasCust = _selectedCustomer != null || _selectedPosCustomer != null;
                      return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.orange.shade200)),
                        child: Row(children: [
                          Icon(Icons.account_balance_wallet_outlined, size: 16, color: Colors.orange.shade700),
                          const SizedBox(width: 6),
                          Expanded(child: Text('Full amount on customer account', style: TextStyle(fontSize: 11, color: Colors.orange.shade800, fontWeight: FontWeight.w600))),
                          if (!hasCust) const Text('Select customer', style: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.w700)),
                        ]));
                    }),
                  ],
                ] else ...[
                  const SizedBox(height: 6),
                  for (final m in _payMethods)
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
                      SizedBox(width: 120, child: Text(m['label'] as String, style: const TextStyle(fontSize: 12))),
                      Expanded(child: TextField(
                        controller: _tenderCtrls[m['code']],
                        decoration: const InputDecoration(hintText: '0.00', isDense: true, prefixText: 'Rs. ', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        enabled: _isOpen,
                        onChanged: (_) => setState(() {}),
                      )),
                    ])),
                  if (_bankAccounts.length > 1 && (double.tryParse(_tenderCtrls['bank']?.text.trim() ?? '') ?? 0) > 0) ...[
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
                      const SizedBox(width: 120, child: Text('Bank account', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                      Expanded(child: _bankDropdown()),
                    ])),
                  ],
                  const SizedBox(height: 4),
                  Builder(builder: (_) {
                    final tenders = _buildTenders(_cartTotal);
                    final collected = _collectedNonCredit(tenders);
                    final owed = _creditPortion(tenders);
                    final diff = collected - (_cartTotal - owed); // <0 short, >0 surplus(advance)
                    final hasCust = _selectedCustomer != null || _selectedPosCustomer != null;
                    if (collected == 0 && owed == 0) return const SizedBox.shrink();
                    if (diff.abs() <= 0.01) {
                      return Row(children: [
                        const Icon(Icons.check_circle, size: 14, color: AppTheme.success),
                        const SizedBox(width: 4),
                        Expanded(child: Text(owed > 0 ? 'Balanced — Rs. ${money(owed)} on customer account' : 'Balanced', style: const TextStyle(fontSize: 12, color: AppTheme.success))),
                        if (owed > 0 && !hasCust) const Text('Select customer', style: TextStyle(fontSize: 10, color: Colors.red, fontWeight: FontWeight.w700)),
                      ]);
                    }
                    if (diff > 0) {
                      // overpayment -> surplus becomes a credit/advance on the customer account
                      return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.green.shade200)),
                        child: Row(children: [
                          Icon(Icons.savings_outlined, size: 16, color: Colors.green.shade700),
                          const SizedBox(width: 6),
                          Expanded(child: Text('Credit Rs. ${money(diff)} added to customer account', style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w600))),
                          if (!hasCust) const Text('Select customer', style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w700)),
                        ]));
                    }
                    return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.red.shade200)),
                      child: Row(children: [
                        Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Short by Rs. ${money(-diff)} — collect more or put the rest on Customer Account', style: TextStyle(fontSize: 11, color: Colors.red.shade700, fontWeight: FontWeight.w600))),
                      ]));
                  }),
                ],
                const SizedBox(height: 6),
                // Totals
                if (_totalDiscount > 0) Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Discount', style: TextStyle(fontSize: 12, color: Colors.orange)),
                  Text('- ${money(_totalDiscount)}', style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text('Rs. ${money(_cartTotal)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                ]),
                const SizedBox(height: 6),
                if (_isOpen && _cart.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: SizedBox(width: double.infinity, height: 36, child: OutlinedButton.icon(
                  icon: const Icon(Icons.pause_circle_outline, size: 16),
                  label: const Text('Hold Bill', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.orange.shade700, side: BorderSide(color: Colors.orange.shade300)),
                  onPressed: _holdBill,
                ))),
                KeyboardListener(focusNode: _checkoutFocusNode, onKeyEvent: (e) { if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter && _cart.isNotEmpty && _isOpen) _checkout(); },
                  child: SizedBox(width: double.infinity, height: 48, child: ElevatedButton.icon(
                    focusNode: FocusNode(),
                    icon: const Icon(Icons.check_circle_outline, size: 20),
                    label: Builder(builder: (_) { final entered = _buildTenders(_cartTotal); final collected = _collectedNonCredit(entered); final owed = _creditPortion(entered); final advance = collected - (_cartTotal - owed); if (advance > 0.01) return Text('Complete Sale (Credit: Rs. ${money(advance)})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)); if (owed > 0.01) return Text('Complete Sale (On a/c: Rs. ${money(owed)})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)); return Text(_cart.isEmpty ? 'Add items to checkout' : 'Complete Sale — Rs. ${money(_cartTotal)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)); }),
                    style: ElevatedButton.styleFrom(backgroundColor: _cart.isNotEmpty && _isOpen ? AppTheme.primary : Colors.grey, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: _cart.isNotEmpty && _isOpen && _paymentValid() ? _checkout : null,
                  ))),
              ])),
          ]),
        ),
        // ── Session Drawer (collapsible) ───────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: _sessionPanelOpen ? 320 : 40,
          decoration: const BoxDecoration(color: Color(0xFFF8F9FA), border: Border(left: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            // Toggle
            InkWell(
              onTap: () => setState(() => _sessionPanelOpen = !_sessionPanelOpen),
              child: Container(height: 48, padding: const EdgeInsets.symmetric(horizontal: 10), color: Colors.white,
                child: Row(children: [
                  Icon(_sessionPanelOpen ? Icons.chevron_right : Icons.chevron_left, color: AppTheme.textSecondary),
                  if (_sessionPanelOpen) ...[const SizedBox(width: 6), const Text('Session', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))],
                ])),
            ),
            if (_sessionPanelOpen) ...[
              // Stats
              Padding(padding: const EdgeInsets.all(12), child: Column(children: [
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Transactions', value: '${_transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').length}', color: AppTheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Returns', value: '${_transactions.where((t) => t['transaction_type'] == 'return').length}', color: Colors.orange)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Sales Total', value: money(_transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').fold<double>(0.0, (s, t) => s + ((t['total'] as num?)?.toDouble() ?? 0))), color: AppTheme.success)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Opening Cash', value: money(_session['opening_cash'] as num?), color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Expenses', value: '${_expenses.length}', color: Colors.red.shade700)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Exp. Total', value: money(_expenses.fold<double>(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0))), color: Colors.red.shade700)),
                ]),
                const SizedBox(height: 8),
                Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Icon(_isOpen ? Icons.circle : Icons.circle_outlined, size: 10, color: _isOpen ? Colors.green : Colors.grey),
                    const SizedBox(width: 8),
                    Text(_isOpen ? 'Session Open' : 'Session Closed', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _isOpen ? Colors.green : Colors.grey)),
                    const Spacer(),
                    if (!_isOpen) TextButton(onPressed: _exportSummary, child: const Text('Export', style: TextStyle(fontSize: 11))),
                  ])),
                // Tab toggle
                if (_isOpen) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: GestureDetector(onTap: () => setState(() => _showExpenses = false), child: Container(padding: const EdgeInsets.symmetric(vertical: 6), decoration: BoxDecoration(color: !_showExpenses ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.primary.withOpacity(0.3))), child: Text('Sales (${_transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').length})', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: !_showExpenses ? Colors.white : AppTheme.textSecondary))))),
                    const SizedBox(width: 6),
                    Expanded(child: GestureDetector(onTap: () => setState(() => _showExpenses = true), child: Container(padding: const EdgeInsets.symmetric(vertical: 6), decoration: BoxDecoration(color: _showExpenses ? Colors.red.shade700 : AppTheme.background, borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.red.shade200)), child: Text('Expenses (${_expenses.length})', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _showExpenses ? Colors.white : AppTheme.textSecondary))))),
                  ]),
                ],
              ])),
              const Divider(height: 1),
              // Transactions / Expenses list
              Expanded(child: _showExpenses
                  ? (_expenses.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.receipt_long_outlined, size: 32, color: AppTheme.border), const SizedBox(height: 8), const Text('No expenses yet', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12))]))
                    : ListView.separated(
                        padding: const EdgeInsets.all(8),
                        itemCount: _expenses.length, separatorBuilder: (_, __) => const SizedBox(height: 4),
                        itemBuilder: (_, i) {
                          final e = _expenses[i];
                          final amt = (e['amount'] as num?)?.toDouble() ?? 0;
                          final cat = e['category'] as String? ?? '-';
                          final note = e['note'] as String? ?? '';
                          final time = e['created_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '';
                          return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade100)),
                            child: Row(children: [
                              Icon(Icons.receipt_long_outlined, size: 16, color: Colors.red.shade700),
                              const SizedBox(width: 8),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(cat, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.red.shade800)),
                                if (note.isNotEmpty) Text(note, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                                Text(time, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                              ])),
                              Text('-${money(amt)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
                            ]));
                        }))
                  : (_transactions.isEmpty
                  ? const Center(child: Text('No transactions yet', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)))
                  : ListView.separated(
                      padding: const EdgeInsets.all(8),
                      itemCount: _transactions.length, separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (_, i) {
                        final t = _transactions[i];
                        final isReturn = t['transaction_type'] == 'return';
                        final total = (t['total'] as num?)?.toDouble() ?? 0;
                        final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
                        final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
                        return GestureDetector(
                          // Returns are openable too — their receipt loads the
                          // same way as a sale's; leaving onTap null made a return
                          // in the drawer un-clickable (only bills opened).
                          onTap: () async {
                            try {
                              final ti = await Supabase.instance.client.from('pos_transaction_items').select('*, products(name)').eq('transaction_id', t['id'] as String);
                              String? fn; try { final fr = await Supabase.instance.client.from('app_config').select('value').eq('org_id', _orgId!).eq('key', 'org.voucher_footer_note').maybeSingle(); fn = fr?['value'] as String?; } catch (_) {}
                              final ci = (ti as List).map((i) => {'name': i['products']?['name'] ?? '-', 'quantity': (i['quantity'] as num?)?.toDouble() ?? 0.0, 'unit_price': (i['unit_price'] as num?)?.toDouble() ?? 0.0, 'discount': (i['discount'] as num?)?.toDouble() ?? 0.0, 'discount_type': i['discount_type'] as String? ?? 'fixed'}).toList();
                              if (mounted) await showDialog(context: context, builder: (_) => _ReceiptDialog(transaction: Map<String, dynamic>.from(t), items: List<Map<String, dynamic>>.from(ci), orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation', branchName: _session['branches']?['name'] as String? ?? '', cashierName: ref.read(currentUserProvider)?.name ?? '', posConfig: _posConfig, footerNote: fn));
                            } catch (_) {}
                          },
                          child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(
                            color: isReturn ? Colors.red.shade50 : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isReturn ? Colors.red.shade100 : AppTheme.border),
                          ), child: Row(children: [
                            Icon(isReturn ? Icons.reply : Icons.receipt_outlined, size: 16, color: isReturn ? Colors.red : AppTheme.primary),
                            const SizedBox(width: 8),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(customer, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                              Text(time, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                            ])),
                            Text('${isReturn ? '-' : ''}${money(total.abs())}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isReturn ? Colors.red : AppTheme.primary)),
                            const Icon(Icons.chevron_right, size: 14, color: AppTheme.textSecondary),
                          ])));
                      }))),
            ],
          ]),
        ),
      ]),
        ),
      ),
    );
  }

  // Record a payment from the till as a proper CPV (Cash Payment Voucher).
  // Pays either a supplier (Dr Accounts Payable) or an expense account
  // (Dr Expense) — Cr Cash in Hand. Session-linked so it reduces closing cash,
  // and posted to the GL via the shared post_cpv function (one posting path).
  // Record a payment from the till as a proper CPV with one or MORE lines.
  // Each line pays a supplier (Dr Accounts Payable) or an expense account
  // (Dr Expense). One CPV, multiple lines. Cr Cash in Hand for the total.
  // Session-linked (reduces closing cash), posted via shared post_cpv.
  Future<void> _addPayment() async {
    // Each line: {type: 'supplier'|'expense', id, name, amtCtrl, descCtrl}
    final payLines = <Map<String, dynamic>>[
      {'type': 'supplier', 'id': null, 'name': null, 'amtCtrl': TextEditingController(), 'descCtrl': TextEditingController()},
    ];

    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) {
      double total = 0;
      for (final l in payLines) { total += double.tryParse((l['amtCtrl'] as TextEditingController).text.trim()) ?? 0; }

      Widget lineCard(int idx) {
        final l = payLines[idx];
        final type = l['type'] as String;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              // type toggle
              Expanded(child: Row(children: [
                Expanded(child: GestureDetector(onTap: () => setS(() { l['type'] = 'supplier'; l['id'] = null; l['name'] = null; }),
                  child: Container(padding: const EdgeInsets.symmetric(vertical: 5), decoration: BoxDecoration(color: type=='supplier' ? AppTheme.primary : Colors.white, borderRadius: const BorderRadius.horizontal(left: Radius.circular(5)), border: Border.all(color: AppTheme.border)),
                    child: Text('Supplier', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: type=='supplier' ? Colors.white : AppTheme.textSecondary))))),
                Expanded(child: GestureDetector(onTap: () => setS(() { l['type'] = 'expense'; l['id'] = null; l['name'] = null; }),
                  child: Container(padding: const EdgeInsets.symmetric(vertical: 5), decoration: BoxDecoration(color: type=='expense' ? AppTheme.primary : Colors.white, borderRadius: const BorderRadius.horizontal(right: Radius.circular(5)), border: Border.all(color: AppTheme.border)),
                    child: Text('Expense', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: type=='expense' ? Colors.white : AppTheme.textSecondary))))),
              ])),
              if (payLines.length > 1)
                IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.red), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => setS(() => payLines.removeAt(idx))),
            ]),
            const SizedBox(height: 6),
            // account picker
            if (type == 'supplier')
              GestureDetector(onTap: () async {
                final picked = await _pickSupplierDialog();
                if (picked != null) setS(() { l['id'] = picked['id']; l['name'] = picked['name']; });
              }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                child: Row(children: [Expanded(child: Text(l['name'] as String? ?? 'Tap to pick supplier', style: TextStyle(fontSize: 12, color: l['name']==null ? AppTheme.textSecondary : null), overflow: TextOverflow.ellipsis)), const Icon(Icons.arrow_drop_down, size: 18)])))
            else
              DropdownButtonFormField<String>(value: l['id'] as String?, isExpanded: true, isDense: true,
                decoration: const InputDecoration(hintText: 'Expense account', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), border: OutlineInputBorder()),
                items: _expenseAccounts.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('${a['code']} — ${a['name']}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))).toList(),
                onChanged: (v) => setS(() { l['id'] = v; l['name'] = _expenseAccounts.firstWhere((a) => a['id']==v, orElse: () => {})['name']; })),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(flex: 2, child: TextField(controller: l['amtCtrl'] as TextEditingController, decoration: const InputDecoration(labelText: 'Amount', prefixText: 'Rs. ', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], onChanged: (_) => setS(() {}))),
              const SizedBox(width: 6),
              Expanded(flex: 3, child: TextField(controller: l['descCtrl'] as TextEditingController, decoration: const InputDecoration(labelText: 'Description', isDense: true, border: OutlineInputBorder()))),
            ]),
          ]),
        );
      }

      return AlertDialog(
        title: const Text('Record Payment (CPV)'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < payLines.length; i++) lineCard(i),
          ]))),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add line'),
            onPressed: () => setS(() => payLines.add({'type': 'supplier', 'id': null, 'name': null, 'amtCtrl': TextEditingController(), 'descCtrl': TextEditingController()})))),
          const Divider(),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Total', style: TextStyle(fontWeight: FontWeight.w700)),
            Text('Rs. ${money(total)}', style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.primary)),
          ]),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Save & Post')),
        ],
      );
    }));
    if (ok != true) return;

    // Validate
    final validLines = <Map<String, dynamic>>[];
    for (final l in payLines) {
      final amt = double.tryParse((l['amtCtrl'] as TextEditingController).text.trim()) ?? 0;
      if (amt <= 0) continue;
      if (l['id'] == null) { _showSnack('Each line needs a supplier/account'); return; }
      validLines.add({'type': l['type'], 'id': l['id'], 'name': l['name'], 'amount': amt, 'desc': (l['descCtrl'] as TextEditingController).text.trim()});
    }
    if (validLines.isEmpty) { _showSnack('Add at least one payment line with an amount'); return; }
    final total = validLines.fold<double>(0, (s, l) => s + (l['amount'] as double));

    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    final bid = _session['branch_id'] as String? ?? '';
    final cashAccId = 'coa_${orgId}_1110'; // POS reconciles against Cash in Hand
    final client = Supabase.instance.client;
    try {
      final cnt = await client.from('cpv_vouchers').select('id').eq('org_id', orgId!);
      final vNum = 'CPV-${DateTime.now().year}-${((cnt as List).length + 1).toString().padLeft(4, '0')}';
      final vid = 'cpv_${DateTime.now().millisecondsSinceEpoch}';
      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      await client.from('cpv_vouchers').insert({
        'id': vid, 'org_id': orgId, 'branch_id': bid, 'voucher_number': vNum, 'voucher_date': dateStr,
        'cash_account_id': cashAccId, 'cash_account_name': 'Cash in Hand',
        'status': 'posted', 'total_amount': total,
        'created_by': userId, 'posted_by': userId, 'posted_by_name': userName,
        'posted_at': DateTime.now().toIso8601String(), 'session_id': _session['id'],
      });
      for (var i = 0; i < validLines.length; i++) {
        final l = validLines[i];
        await client.from('cpv_voucher_lines').insert({
          'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_$i', 'voucher_id': vid,
          'account_type': l['type'] == 'supplier' ? 'supplier' : 'expense',
          'account_id': l['id'], 'account_name': l['name'],
          'description': l['desc'], 'amount': l['amount'], 'line_order': i,
        });
      }
      await client.rpc('post_cpv', params: {'p_voucher_id': vid});
      _showSnack('Payment posted: $vNum • Rs. ${money(total)}');
      _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // Searchable supplier picker for a payment line.
  Future<Map<String, dynamic>?> _pickSupplierDialog() async {
    final searchCtrl = TextEditingController();
    return showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) {
      final q = searchCtrl.text.trim().toLowerCase();
      final list = q.isEmpty ? _suppliers : _suppliers.where((s) => matchesQuery('${s['name'] ?? ''}', q)).toList();
      return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 500), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 6), child: Row(children: [
          const Expanded(child: Text('Select supplier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(controller: searchCtrl, autofocus: true,
          decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder()), onChanged: (_) => setS(() {}))),
        const Divider(height: 1),
        Expanded(child: list.isEmpty ? const Center(child: Text('No suppliers', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: list.length, separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) { final s = list[i]; return ListTile(dense: true, title: Text(s['name'] as String? ?? '-', style: const TextStyle(fontSize: 13)), onTap: () => Navigator.pop(ctx, s)); })),
      ])));
    }));
  }

  // Record a customer receipt into the till as a CRV (cash IN). Mirror of
  // _addPayment: multi-line, each line credits a customer's receivable (or an
  // account). Dr Cash / Cr AR. Session-linked (increases closing cash), posted
  // via shared post_crv.
  Future<void> _addReceipt() async {
    final rcvLines = <Map<String, dynamic>>[
      {'id': null, 'name': null, 'amtCtrl': TextEditingController(), 'descCtrl': TextEditingController()},
    ];

    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) {
      double total = 0;
      for (final l in rcvLines) { total += double.tryParse((l['amtCtrl'] as TextEditingController).text.trim()) ?? 0; }

      Widget lineCard(int idx) {
        final l = rcvLines[idx];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Customer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary))),
              if (rcvLines.length > 1)
                IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.red), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => setS(() => rcvLines.removeAt(idx))),
            ]),
            const SizedBox(height: 6),
            GestureDetector(onTap: () async {
              final picked = await _pickCustomerDialog();
              if (picked != null) setS(() { l['id'] = picked['id']; l['name'] = picked['shop_name'] ?? picked['code']; });
            }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
              child: Row(children: [Expanded(child: Text(l['name'] as String? ?? 'Tap to pick customer', style: TextStyle(fontSize: 12, color: l['name']==null ? AppTheme.textSecondary : null), overflow: TextOverflow.ellipsis)), const Icon(Icons.arrow_drop_down, size: 18)]))),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(flex: 2, child: TextField(controller: l['amtCtrl'] as TextEditingController, decoration: const InputDecoration(labelText: 'Amount', prefixText: 'Rs. ', isDense: true, border: OutlineInputBorder()),
                keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))], onChanged: (_) => setS(() {}))),
              const SizedBox(width: 6),
              Expanded(flex: 3, child: TextField(controller: l['descCtrl'] as TextEditingController, decoration: const InputDecoration(labelText: 'Description', isDense: true, border: OutlineInputBorder()))),
            ]),
          ]),
        );
      }

      return AlertDialog(
        title: const Text('Record Receipt (CRV)'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < rcvLines.length; i++) lineCard(i),
          ]))),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add line'),
            onPressed: () => setS(() => rcvLines.add({'id': null, 'name': null, 'amtCtrl': TextEditingController(), 'descCtrl': TextEditingController()})))),
          const Divider(),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Total', style: TextStyle(fontWeight: FontWeight.w700)),
            Text('Rs. ${money(total)}', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.green.shade700)),
          ]),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Save & Post')),
        ],
      );
    }));
    if (ok != true) return;

    final validLines = <Map<String, dynamic>>[];
    for (final l in rcvLines) {
      final amt = double.tryParse((l['amtCtrl'] as TextEditingController).text.trim()) ?? 0;
      if (amt <= 0) continue;
      if (l['id'] == null) { _showSnack('Each line needs a customer'); return; }
      validLines.add({'id': l['id'], 'name': l['name'], 'amount': amt, 'desc': (l['descCtrl'] as TextEditingController).text.trim()});
    }
    if (validLines.isEmpty) { _showSnack('Add at least one receipt line with an amount'); return; }
    final total = validLines.fold<double>(0, (s, l) => s + (l['amount'] as double));

    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    final bid = _session['branch_id'] as String? ?? '';
    final cashAccId = 'coa_${orgId}_1110';
    final client = Supabase.instance.client;
    try {
      final cnt = await client.from('crv_vouchers').select('id').eq('org_id', orgId!);
      final vNum = 'CRV-${DateTime.now().year}-${((cnt as List).length + 1).toString().padLeft(4, '0')}';
      final vid = 'crv_${DateTime.now().millisecondsSinceEpoch}';
      final dateStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      await client.from('crv_vouchers').insert({
        'id': vid, 'org_id': orgId, 'branch_id': bid, 'voucher_number': vNum, 'voucher_date': dateStr,
        'cash_account_id': cashAccId, 'cash_account_name': 'Cash in Hand',
        'status': 'posted', 'total_amount': total,
        'created_by': userId, 'posted_by': userId, 'posted_by_name': userName,
        'posted_at': DateTime.now().toIso8601String(), 'session_id': _session['id'],
      });
      for (var i = 0; i < validLines.length; i++) {
        final l = validLines[i];
        await client.from('crv_voucher_lines').insert({
          'id': 'crvl_${DateTime.now().microsecondsSinceEpoch}_$i', 'voucher_id': vid,
          'account_type': 'customer', 'account_id': l['id'], 'account_name': l['name'],
          'description': l['desc'], 'amount': l['amount'], 'line_order': i,
        });
      }
      await client.rpc('post_crv', params: {'p_voucher_id': vid});
      _showSnack('Receipt posted: $vNum • Rs. ${money(total)}');
      _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<Map<String, dynamic>?> _pickCustomerDialog() async {
    final searchCtrl = TextEditingController();
    return showDialog<Map<String, dynamic>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) {
      final q = searchCtrl.text.trim().toLowerCase();
      final list = q.isEmpty ? _customers : _customers.where((c) => matchesQuery('${c['shop_name'] ?? ''} ${c['code'] ?? ''}', q)).toList();
      return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 500), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 6), child: Row(children: [
          const Expanded(child: Text('Select customer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.pop(ctx)),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(controller: searchCtrl, autofocus: true,
          decoration: const InputDecoration(hintText: 'Search…', prefixIcon: Icon(Icons.search, size: 20), isDense: true, border: OutlineInputBorder()), onChanged: (_) => setS(() {}))),
        const Divider(height: 1),
        Expanded(child: list.isEmpty ? const Center(child: Text('No customers', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(itemCount: list.length, separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) { final c = list[i]; return ListTile(dense: true, title: Text(c['shop_name'] as String? ?? c['code'] as String? ?? '-', style: const TextStyle(fontSize: 13)),
              subtitle: c['code'] != null ? Text(c['code'] as String, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)) : null,
              onTap: () => Navigator.pop(ctx, c)); })),
      ])));
    }));
  }

  // ── Hold Bill ─────────────────────────────────────────────────
  Future<void> _holdBill() async {
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    final orgId = _orgId;
    final branchId = _session['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final customerName = _selectedCustomer?['shop_name'] as String? ?? 'Walk-in';
    try {
      await Supabase.instance.client.from('pos_held_bills').insert({
        'id': 'held_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId, 'branch_id': branchId, 'session_id': _session['id'],
        'customer_id': _selectedCustomer?['id'],
        'pos_customer_id': _selectedPosCustomer?['id'],
        'customer_name': customerName,
        'items': _cart,
        'order_discount': _orderDiscount,
        'order_discount_type': _orderDiscountType,
        'payment_method': _paymentMethod,
        'total': _cartTotal,
        'held_by': userId,
        'status': 'held',
      });
      setState(() {
        _cart.clear(); _orderDiscount = 0; _selectedCustomer = null; _selectedPosCustomer = null; _selectedPromoter = null;
        _customerSearchCtrl.clear(); _paymentMethod = 'cash';
        _stagedProduct = null; _stagedCartIndex = null;
        _holdsPanelExpanded = true;
      });
      await _loadData();
      _showSnack('Bill held — tap to restore');
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _restoreBill(Map<String, dynamic> bill) async {
    if (_cart.isNotEmpty) {
      final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
        title: const Text('Replace current cart?'),
        content: const Text('Current cart items will be cleared and replaced with this held bill.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
        ],
      ));
      if (ok != true) return;
    }
    // Held cart is stored as JSONB. Two things can crash the rebuild:
    //  1) numbers come back as int (1 not 1.0) → 'as double' throws,
    //  2) items may come back as a JSON string instead of a List.
    final rawItems = bill['items'];
    final List itemsList = rawItems is String
        ? (jsonDecode(rawItems) as List? ?? const [])
        : (rawItems as List? ?? const []);
    final items = itemsList.map((i) {
      final m = Map<String, dynamic>.from(i as Map);
      m['quantity'] = (m['quantity'] as num?)?.toDouble() ?? 1.0;
      m['unit_price'] = (m['unit_price'] as num?)?.toDouble() ?? 0.0;
      m['discount'] = (m['discount'] as num?)?.toDouble() ?? 0.0;
      m['stock_qty'] = (m['stock_qty'] as num?)?.toDouble() ?? 0.0;
      m['discount_type'] = (m['discount_type'] == 'percent') ? 'percent' : 'fixed';
      m['name'] = m['name'] as String? ?? '-';
      return m;
    }).toList();
    // Clamp restored values to what their widgets accept, or the DropdownButton
    // (order discount type) and SegmentedButton (payment) will assert → white screen.
    final odt = bill['order_discount_type'] as String?;
    final pm = bill['payment_method'] as String?;
    // Carry the customer forward from the held bill (quotation export sets these).
    final billCustId = bill['customer_id'] as String?;
    final billCustName = bill['customer_name'] as String?;
    Map<String, dynamic>? restoredCustomer;
    if (billCustId != null) {
      // Regular customer: match the loaded list, else synthesize from stored name.
      restoredCustomer = _customers.firstWhere(
        (c) => c['id'] == billCustId,
        orElse: () => {'id': billCustId, 'shop_name': billCustName ?? 'Customer'},
      );
    } else if (billCustName != null && billCustName.isNotEmpty && billCustName != 'Walk-in') {
      // Customer stored by name (older held bills) — match in unified customers.
      restoredCustomer = _customers.firstWhere(
        (c) => (c['shop_name'] as String?) == billCustName,
        orElse: () => {'id': billCustId, 'shop_name': billCustName},
      );
    }
    setState(() {
      _cart = items;
      _orderDiscount = (bill['order_discount'] as num?)?.toDouble() ?? 0;
      _orderDiscountType = (odt == 'percent') ? 'percent' : 'fixed';
      _paymentMethod = const {'cash', 'card', 'other'}.contains(pm) ? pm! : 'cash';
      _stagedProduct = null; _stagedCartIndex = null;
      _selectedCustomer = restoredCustomer;
      _selectedPosCustomer = null;
    });
    try {
      await Supabase.instance.client.from('pos_held_bills')
          .update({'status': 'restored'}).eq('id', bill['id'] as String);
      await _loadData();
    } catch (_) {}
    _showSnack('Bill restored');
  }

  void _showReturnDialog() {
    showDialog(context: context, builder: (_) => _ReturnDialog(
      orgId: _orgId ?? '',
      onProcess: _processReturn,
    ));
  }
}

// ── Receipt Dialog ─────────────────────────────────────────────────────────
class _ReceiptDialog extends StatelessWidget {
  final Map<String, dynamic> transaction;
  final List<Map<String, dynamic>> items;
  final String orgName, branchName, cashierName;
  final String? footerNote;
  final Map<String, String> posConfig;
  const _ReceiptDialog({required this.transaction, required this.items, required this.orgName, required this.branchName, required this.cashierName, this.footerNote, this.posConfig = const {}});

  // Human-readable split for a transaction's tenders, or '' if single/none.
  static String _tenderSummary(Map<String, dynamic> txn) {
    final pd = txn['payment_details'];
    if (pd is List && pd.length > 1) {
      return pd.map((t) {
        final m = t as Map;
        final amt = (m['amount'] as num?)?.toDouble() ?? 0;
        return amt < 0
            ? '${m['label']} (credit): ${(-amt).toStringAsFixed(0)}'
            : '${m['label']}: ${amt.toStringAsFixed(0)}';
      }).join('  ·  ');
    }
    return '';
  }

  @override Widget build(BuildContext context) {
    final total = (transaction['total'] as num?)?.toDouble() ?? 0;
    final discount = (transaction['discount'] as num?)?.toDouble() ?? 0;
    final subtotal = items.fold(0.0, (s, i) => s + ((i['unit_price'] as double) * (i['quantity'] as double)));
    final customer = (transaction['pos_customers']?['name'] ?? transaction['customers']?['shop_name'] ?? 'Walk-in') as String;
    final method = (transaction['payment_method'] as String? ?? 'cash').toUpperCase();
    final tenderSplit = _tenderSummary(transaction);
    final splitHtml = tenderSplit.isNotEmpty ? '<p style="text-align:center;font-size:11px;color:#444;margin:2px 0">$tenderSplit</p>' : '';
    final ts = transaction['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(transaction['transacted_at'] as String).toLocal()) : DateFormat('d MMM yyyy  HH:mm').format(DateTime.now());
    final hasCustomCompany = posConfig['pos.company_name']?.isNotEmpty == true;
    final company = hasCustomCompany ? posConfig['pos.company_name']! : orgName;
    final ntn = posConfig['pos.ntn'] ?? '';
    final contact = posConfig['pos.contact'] ?? '';
    final terms = posConfig['pos.terms'] ?? '';
    final effFooter = (footerNote != null && footerNote!.isNotEmpty) ? footerNote! : (posConfig['pos.footer_note'] ?? '');
    final logo = posConfig['pos.logo'] ?? '';
    Widget? logoWidget;
    if (logo.isNotEmpty) {
      try {
        if (logo.startsWith('data:')) {
          final b64 = logo.contains(',') ? logo.split(',').last : logo;
          logoWidget = Image.memory(base64Decode(b64), height: 56, errorBuilder: (_, __, ___) => const SizedBox.shrink());
        } else {
          logoWidget = Image.network(logo, height: 56, errorBuilder: (_, __, ___) => const SizedBox.shrink());
        }
      } catch (_) { logoWidget = null; }
    }
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      if (logoWidget != null) ...[Padding(padding: const EdgeInsets.only(bottom: 8), child: logoWidget)],
      Text(company, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      if (!hasCustomCompany && branchName.isNotEmpty) Text(branchName, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      if (ntn.isNotEmpty) Text(ntn, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      if (contact.isNotEmpty) Text(contact, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 4),
      const Text('SALES RECEIPT', style: TextStyle(fontSize: 11, letterSpacing: 2, color: AppTheme.textSecondary)),
      if ((transaction['transaction_number'] as String?)?.isNotEmpty == true) Text('Ref: ' + (transaction['transaction_number'] as String? ?? ''), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      const Divider(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Customer: $customer', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
      const SizedBox(height: 12),
      Container(decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(8)), child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: const [
          Expanded(flex: 4, child: Text('Item', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 1, child: Text('Qty', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Price', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Disc', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('Total', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
        ])),
        const Divider(height: 1),
        ...items.map((it) {
          final qty = it['quantity'] as double; final price = it['unit_price'] as double;
          final disc = it['discount'] as double; final discType = it['discount_type'] as String? ?? 'fixed';
          final discAmt = discType == 'percent' ? price * qty * (disc / 100) : disc;
          final lt = qty * price - discAmt;
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Row(children: [
            Expanded(flex: 4, child: Text(it['name'] as String? ?? '-', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            Expanded(flex: 1, child: Text('x${qty.toStringAsFixed(0)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(money(price), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: discAmt > 0 ? Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [Text('-Rs.${money(discAmt)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Colors.orange)), if (discType == 'percent') Text('(${disc.toStringAsFixed(0)}%)', textAlign: TextAlign.right, style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary))]) : const Text('-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text(money(lt), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]));
        }),
      ])),
      const Divider(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Subtotal', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        Text(money(subtotal), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ]),
      if (discount > 0) ...[
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total Discount', style: TextStyle(fontSize: 13, color: Colors.orange)),
          Text('- ${money(discount)}', style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w600)),
        ]),
      ],
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('TOTAL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('Rs. ${money(total)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.primary)),
      ]),
      const SizedBox(height: 4),
      Text('Payment: $method', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      if (_tenderSummary(transaction).isNotEmpty) Text(_tenderSummary(transaction), style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      Text('Cashier: $cashierName', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
      if (effFooter.isNotEmpty) ...[
        const Divider(),
        Text(effFooter, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ],
      if (terms.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(terms, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary)),
      ],
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print'), onPressed: () {
          final posHasCustomCompany = posConfig['pos.company_name']?.isNotEmpty == true;
          final posCompany = posHasCustomCompany ? posConfig['pos.company_name']! : orgName;
          final posBranchLine = posHasCustomCompany ? '' : '<h3 style="font-weight:normal;color:#666">$branchName</h3>';
          final posNtn = posConfig['pos.ntn'] ?? '';
          final posContact = posConfig['pos.contact'] ?? '';
          final posFooter = posConfig['pos.footer_note']?.isNotEmpty == true ? posConfig['pos.footer_note']! : (footerNote ?? '');
          final posTerms = posConfig['pos.terms'] ?? '';
          final posLogo = posConfig['pos.logo'] ?? '';
          final amountPaid = money(transaction['amount_paid'] as num?);
          final balanceChange = money(transaction['balance_change'] as num?);
          final rows = items.map((i) { final q = i['quantity'] as double; final p = i['unit_price'] as double; final d = i['discount'] as double; final dt = i['discount_type'] as String? ?? 'fixed'; final da = dt == 'percent' ? p * q * (d / 100) : d; final lt = q * p - da; final n = i['name'] as String? ?? '-'; return '<tr><td>$n</td><td style="text-align:center">${q.toStringAsFixed(0)}</td><td style="text-align:right">${money(p)}</td><td style="text-align:right;color:${da > 0 ? "#e67e22" : "#999"}">${da > 0 ? (dt == 'percent' ? "-Rs.${money(da)} <small style='color:#aaa'>(${d.toStringAsFixed(0)}%)</small>" : "-Rs.${money(da)}") : "-"}</td><td style="text-align:right;font-weight:bold">${money(lt)}</td></tr>'; }).join();
          final discRow = discount > 0 ? '<tr><td colspan="4" style="color:#e67e22">Total Discount</td><td style="text-align:right;color:#e67e22">-${money(discount)}</td></tr>' : '';
          final footerHtml = (footerNote != null && footerNote!.isNotEmpty) ? '<p style="text-align:center;color:#888;font-size:11px;border-top:1px dashed #ccc;padding-top:8px;margin-top:8px">$footerNote</p>' : '';
          final content = '<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Receipt</title><style>@page{margin:0}body{font-family:Arial,sans-serif;padding:20px;max-width:320px;margin:0 auto;font-size:12px}h2,h3{text-align:center;margin:4px 0}table{width:100%;border-collapse:collapse;margin:8px 0}th{background:#f5f5f5;padding:5px 6px;font-size:11px;text-align:left}td{padding:5px 6px;border-bottom:1px solid #eee}.total-row td{font-weight:bold;font-size:13px;border-top:2px solid #333}hr{border:none;border-top:1px dashed #ccc;margin:8px 0}</style></head><body>${posLogo.isNotEmpty ? '<div style=\"text-align:center;margin-bottom:8px\"><img src=\"$posLogo\" style=\"max-height:60px;max-width:200px\"></div>' : ''}<h2>$posCompany</h2>$posBranchLine${posNtn.isNotEmpty ? '<p style="text-align:center;font-size:11px;color:#666;margin:2px 0">$posNtn</p>' : ''}${posContact.isNotEmpty ? '<p style="text-align:center;font-size:11px;color:#666;margin:2px 0">$posContact</p>' : ''}<p style="text-align:center;margin:4px 0">$ts</p><p style="text-align:center;margin:4px 0">Customer: $customer</p>${(transaction['transaction_number'] as String?)?.isNotEmpty == true ? '<p style="text-align:center;font-size:10px;color:#888;margin:2px 0">Ref: ' + (transaction['transaction_number'] as String) + '</p>' : ''}<hr><table><thead><tr><th>Item</th><th style="text-align:center">Qty</th><th style="text-align:right">Price</th><th style="text-align:right">Disc</th><th style="text-align:right">Total</th></tr></thead><tbody>$rows<tr><td colspan="4" style="color:#666">Subtotal</td><td style="text-align:right">${money(subtotal)}</td></tr>$discRow<tr class="total-row"><td colspan="4">TOTAL</td><td style="text-align:right">Rs. ${money(total)}</td></tr></tbody></table><p style="text-align:center">Payment: $method | Cashier: $cashierName</p>$splitHtml${(() { final ap = (transaction['amount_paid'] as num?)?.toDouble(); final bc = (transaction['balance_change'] as num?)?.toDouble() ?? 0; if (ap == null) return ''; if (bc == 0) return ''; return '<p style="text-align:center;font-size:11px;font-weight:bold">' + (bc < 0 ? 'Balance Due: Rs. ' + money(-bc) : 'Credit Added: Rs. ' + money(bc)) + '</p>'; })()}${posFooter.isNotEmpty ? '<p style=\"text-align:center;color:#888;font-size:11px;border-top:1px dashed #ccc;padding-top:8px;margin-top:8px\">$posFooter</p>' : ''}${posTerms.isNotEmpty ? '<p style=\"text-align:center;font-size:9px;color:#aaa;margin-top:6px\">$posTerms</p>' : ''}<script>window.print()</script></body></html>';
          final blob = html.Blob([content], 'text/html;charset=utf-8'); final url = html.Url.createObjectUrlFromBlob(blob); html.window.open(url, '_blank');
        })),
        const SizedBox(width: 12),
        Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.add_shopping_cart, size: 16), label: const Text('New Sale'), onPressed: () => Navigator.pop(context))),
      ]),
    ]))));
  }
}


class _ReturnDialog extends StatefulWidget {
  final String orgId;
  final Future<void> Function(Map<String, dynamic>, List<Map<String, dynamic>>) onProcess;
  const _ReturnDialog({required this.orgId, required this.onProcess});
  @override State<_ReturnDialog> createState() => _ReturnDialogState();
}
class _ReturnDialogState extends State<_ReturnDialog> {
  List<Map<String, dynamic>> _transactions = [];
  Map<String, dynamic>? _selectedTxn;
  List<Map<String, dynamic>> _txnItems = [];
  bool _loadingTxns = true;
  bool _loadingItems = false;
  bool _allReturned = false; // opened bill had items, but all already returned
  String _q = '';
  DateTime? _dateFrom;
  DateTime? _dateTo;
  final Map<String, bool> _selected = {};
  final Map<String, TextEditingController> _qtyCtrls = {};

  @override void initState() { super.initState(); _loadTransactions(); }
  @override void dispose() { for (final c in _qtyCtrls.values) c.dispose(); super.dispose(); }

  Future<void> _loadTransactions() async {
    setState(() => _loadingTxns = true);
    try {
      // Load ALL sale transactions for this org that haven't been returned
      final txns = await Supabase.instance.client
          .from('pos_transactions')
          .select('*, customers(shop_name), pos_customers(name, phone)')
          .eq('org_id', widget.orgId)
          .or('transaction_type.eq.sale,transaction_type.is.null')
          .order('transacted_at', ascending: false)
          .limit(500);
      // Show all sales. Per-line REMAINING quantity (sold minus already-returned)
      // is enforced when an invoice is opened (see _loadItems), so a partially
      // returned invoice stays returnable for its un-returned lines instead of
      // disappearing from the list after a single partial return.
      setState(() {
        _transactions = (txns as List).map((t) => Map<String, dynamic>.from(t)).toList();
        _loadingTxns = false;
      });
    } catch (e) { setState(() => _loadingTxns = false); }
  }

  Future<void> _loadItems(Map<String, dynamic> txn) async {
    setState(() { _selectedTxn = txn; _loadingItems = true; _txnItems = []; _allReturned = false; _selected.clear(); _qtyCtrls.forEach((_, c) => c.dispose()); _qtyCtrls.clear(); });
    try {
      final items = await Supabase.instance.client
          .from('pos_transaction_items')
          .select('*, products(name, sku)')
          .eq('transaction_id', txn['id'] as String)
          .gt('quantity', 0);
      // How much of this invoice was already returned, per product, so each line
      // only offers its REMAINING quantity (sold - already returned).
      final Map<String, double> returnedByProduct = {};
      try {
        final priorRet = await Supabase.instance.client
            .from('pos_transactions').select('id')
            .eq('org_id', widget.orgId).eq('transaction_type', 'return')
            .eq('reference_transaction_id', txn['id'] as String);
        final retIds = [for (final r in priorRet as List) r['id'] as String];
        if (retIds.isNotEmpty) {
          final retItems = await Supabase.instance.client
              .from('pos_transaction_items').select('product_id, quantity')
              .inFilter('transaction_id', retIds);
          for (final ri in retItems as List) {
            final pid = ri['product_id'] as String?;
            if (pid == null) continue;
            returnedByProduct[pid] = (returnedByProduct[pid] ?? 0) + ((ri['quantity'] as num?)?.toDouble() ?? 0).abs();
          }
        }
      } catch (_) {}
      final annotated = <Map<String, dynamic>>[];
      for (final raw in (items as List)) {
        final it = Map<String, dynamic>.from(raw as Map);
        final sold = (it['quantity'] as num?)?.toDouble() ?? 0;
        final alreadyRet = returnedByProduct[it['product_id']] ?? 0;
        final remaining = sold - alreadyRet;
        if (remaining <= 0) continue; // already fully returned — nothing left
        it['returnable'] = remaining;
        annotated.add(it);
      }
      setState(() {
        _txnItems = annotated;
        // Distinguish "no items at all" from "every line already fully returned"
        // so the empty state can say so instead of a bare "No items found".
        _allReturned = (items as List).isNotEmpty && annotated.isEmpty;
        for (final it in _txnItems) {
          final id = it['id'] as String;
          _selected[id] = false;
          final rem = (it['returnable'] as num?)?.toDouble() ?? 0;
          _qtyCtrls[id] = TextEditingController(text: rem.toStringAsFixed(0));
        }
        _loadingItems = false;
      });
    } catch (e) { setState(() => _loadingItems = false); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _q.toLowerCase();
    return _transactions.where((t) {
      final matchSearch = matchesQuery('${t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? ''} ${t['id'] ?? ''} ${t['transaction_number'] ?? ''} ${t['pos_customers']?['phone'] ?? ''}', q);
      final ts = t['transacted_at'] != null ? DateTime.parse(t['transacted_at'] as String).toLocal() : null;
      final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
      final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
      return matchSearch && matchFrom && matchTo;
    }).toList();
  }

  @override Widget build(BuildContext context) {
    final filtered = _filtered;
    final selectedItems = _txnItems.where((it) => _selected[it['id']] == true).toList();
    final returnTotal = selectedItems.fold(0.0, (s, it) { final qty = (double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0).clamp(0, (it['returnable'] as num?)?.toDouble() ?? 0).toDouble(); final price = (it['unit_price'] as num?)?.toDouble() ?? 0; final disc = (it['discount'] as num?)?.toDouble() ?? 0; final discType = it['discount_type'] as String? ?? 'fixed'; final origQty = (it['quantity'] as num?)?.toDouble() ?? 1; final discAmt = discType == 'percent' ? price * origQty * (disc/100) : disc; final netPrice = price - (origQty > 0 ? discAmt / origQty : 0); return s + qty * netPrice; });
    return Dialog(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800, maxHeight: 600), child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Process Return', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('${_transactions.length} returnable orders', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ]),
      const SizedBox(height: 12),
      // Search + date filter row
      Row(children: [
        Expanded(child: TextField(decoration: const InputDecoration(hintText: 'Search by customer name, phone, transaction ID…', prefixIcon: Icon(Icons.search, size: 18), isDense: true), onChanged: (v) => setState(() => _q = v))),
        const SizedBox(width: 8),
        OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 16), label: Text(_dateFrom != null ? DateFormat('d MMM').format(_dateFrom!) : 'From', style: const TextStyle(fontSize: 12)),
          onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateFrom ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateFrom = d); }),
        const SizedBox(width: 4),
        OutlinedButton.icon(icon: const Icon(Icons.date_range, size: 16), label: Text(_dateTo != null ? DateFormat('d MMM').format(_dateTo!) : 'To', style: const TextStyle(fontSize: 12)),
          onPressed: () async { final d = await showDatePicker(context: context, initialDate: _dateTo ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now()); if (d != null) setState(() => _dateTo = d); }),
        if (_dateFrom != null || _dateTo != null) ...[
          const SizedBox(width: 4),
          IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _dateFrom = null; _dateTo = null; })),
        ],
      ]),
      const SizedBox(height: 12),
      Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Left: transaction list
        Expanded(child: _loadingTxns ? const Center(child: CircularProgressIndicator())
          : filtered.isEmpty ? Center(child: Text(_transactions.isEmpty ? 'No returnable orders found.' : 'No orders match your search.', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
          : ListView.separated(itemCount: filtered.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = filtered[i]; final sel = _selectedTxn?['id'] == t['id'];
                final total = (t['total'] as num?)?.toDouble() ?? 0;
                final ts = t['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
                final custName = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
                return ListTile(dense: true, selected: sel, selectedTileColor: AppTheme.primary.withOpacity(0.08),
                  title: Row(children: [
                    Expanded(child: Text(custName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                    Text('Rs. ${money(total)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  ]),
                  subtitle: Row(children: [
                    Expanded(child: Text(ts, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                    if ((t['transaction_number'] as String?)?.isNotEmpty == true)
                      Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(3)), child: Text(t['transaction_number'] as String, style: TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w600))),
                  ]),
                  onTap: () => _loadItems(t));
              })),
        const SizedBox(width: 16),
        // Right: item selection
        Expanded(child: _selectedTxn == null
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.touch_app_outlined, size: 32, color: AppTheme.textSecondary), SizedBox(height: 8), Text('Select a transaction to view items', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))]))
            : _loadingItems ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Select items to return', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                Expanded(child: _txnItems.isEmpty ? Center(child: Text(_allReturned ? 'This bill has already been fully returned' : 'No items found', textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textSecondary)))
                  : ListView(children: _txnItems.map((it) {
                      final id = it['id'] as String;
                      final name = it['products']?['name'] as String? ?? it['name'] as String? ?? '-';
                      final origQty = (it['quantity'] as num?)?.toDouble() ?? 0;
                      final returnable = (it['returnable'] as num?)?.toDouble() ?? origQty;
                      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                      return CheckboxListTile(dense: true, value: _selected[id] ?? false, onChanged: (v) => setState(() => _selected[id] = v ?? false),
                        title: Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Builder(builder: (_) { final disc = (it['discount'] as num?)?.toDouble() ?? 0; final discType = it['discount_type'] as String? ?? 'fixed'; final discAmt = discType == 'percent' ? price * origQty * (disc/100) : disc; final discLabel = disc > 0 ? (discType == 'percent' ? ' -${disc.toStringAsFixed(0)}%' : ' -Rs.${money(discAmt)}') : ''; final net = origQty * price - discAmt; return Text('${origQty.toStringAsFixed(0)} × Rs. ${money(price)}$discLabel = Rs. ${money(net)}', style: const TextStyle(fontSize: 11)); }),
                        secondary: SizedBox(width: 72, child: TextField(
                          controller: _qtyCtrls[id],
                          decoration: InputDecoration(labelText: 'Return qty', isDense: true, filled: true, fillColor: _selected[id] == true ? Colors.orange.withOpacity(0.08) : Colors.grey.withOpacity(0.05)),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          enabled: _selected[id] == true,
                          onChanged: (v) {
                            // Cap the return qty at what's still returnable (sold
                            // minus already-returned) — prevents over-refund and
                            // inventory inflation, including across repeat returns.
                            final ent = double.tryParse(v) ?? 0;
                            if (ent > returnable) {
                              final c = _qtyCtrls[id]!;
                              c.text = returnable.toStringAsFixed(0);
                              c.selection = TextSelection.collapsed(offset: c.text.length);
                            }
                            setState(() {});
                          },
                        )));
                    }).toList())),
                if (selectedItems.isNotEmpty) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [const Text('Refund Total: ', style: TextStyle(fontWeight: FontWeight.w600)), const Spacer(), Text('Rs. ${money(returnTotal)}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.red, fontSize: 15))])),
              ])),
      ])),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.reply, size: 16),
          label: Text('Process Return${selectedItems.isNotEmpty ? ' — Rs. ${money(returnTotal)}' : ''}'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: selectedItems.isEmpty ? null : () async {
            final retItems = selectedItems.map((it) { final cap = (it['returnable'] as num?)?.toDouble() ?? (it['quantity'] as num?)?.toDouble() ?? 0; final qty = (double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0).clamp(0, cap).toDouble(); return {...it, 'return_qty': qty}; }).toList();
            Navigator.pop(context);
            await widget.onProcess(_selectedTxn!, retItems);
          }),
      ]),
    ]))));
  }
}


class _ProductCard extends StatelessWidget {
  final Map<String, dynamic> product;
  final bool inCart, isOpen;
  final VoidCallback? onTap;
  const _ProductCard({required this.product, required this.inCart, required this.isOpen, this.onTap});
  @override Widget build(BuildContext context) {
    final price = (product['price'] as num?)?.toDouble() ?? 0;
    final stockQty = (product['stock_qty'] as num?)?.toDouble() ?? 0;
    final blocked = isOpen && stockQty <= 0;
    return GestureDetector(onTap: blocked ? null : onTap, child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: blocked ? const Color(0xFFF5F5F5) : (inCart ? AppTheme.primary.withOpacity(0.06) : Colors.white),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: blocked ? Colors.grey.withOpacity(0.3) : (inCart ? AppTheme.primary.withOpacity(0.4) : AppTheme.border), width: inCart ? 1.5 : 1),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Row(children: [
          Expanded(child: Text(product['name'] as String? ?? '-', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: inCart ? AppTheme.primary : AppTheme.textPrimary), maxLines: 2, overflow: TextOverflow.ellipsis)),
          if (inCart) const Icon(Icons.check_circle, size: 14, color: AppTheme.primary),
        ]),
        if (product['sku'] != null) Text(product['sku'] as String, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        const Spacer(),
        Row(children: [
          Expanded(child: Text('Rs. ${money(price)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: inCart ? AppTheme.primary : AppTheme.textPrimary))),
          _StockBadge(stockQty: stockQty),
        ]),
        if (!isOpen) const Text('Session closed', style: TextStyle(fontSize: 9, color: AppTheme.textSecondary)),
      ]),
    ));
  }
}

class _CartItemTile extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool isOpen;
  final ValueChanged<double> onQtyChanged;
  final void Function(double, String) onDiscountChanged;
  final VoidCallback onRemove;
  final double lineTotal;
  final FocusNode? qtyFocusNode;
  final FocusNode? discFocusNode;
  final VoidCallback? onFieldDone;
  const _CartItemTile({required this.item, required this.isOpen, required this.onQtyChanged, required this.onDiscountChanged, required this.onRemove, required this.lineTotal, this.qtyFocusNode, this.discFocusNode, this.onFieldDone});
  @override State<_CartItemTile> createState() => _CartItemTileState();
}
class _CartItemTileState extends State<_CartItemTile> {
  late TextEditingController _qtyCtrl;
  @override void initState() { super.initState(); _qtyCtrl = TextEditingController(text: (widget.item['quantity'] as double).toStringAsFixed(0)); }
  @override void didUpdateWidget(_CartItemTile old) { super.didUpdateWidget(old); final q = (widget.item['quantity'] as double).toStringAsFixed(0); if (_qtyCtrl.text != q) _qtyCtrl.text = q; }
  @override void dispose() { _qtyCtrl.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final qty = widget.item['quantity'] as double;
    final disc = widget.item['discount'] as double;
    final discType = widget.item['discount_type'] as String;
    return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text(widget.item['name'] as String? ?? '-', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          Text('Rs. ${money(widget.lineTotal)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          const SizedBox(width: 4),
          if (widget.isOpen) GestureDetector(onTap: widget.onRemove, child: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          if (widget.isOpen) GestureDetector(onTap: () { if (qty > 1) widget.onQtyChanged(qty - 1); }, child: Container(width: 24, height: 24, decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(4)), child: const Icon(Icons.remove, size: 14))),
          const SizedBox(width: 6),
          SizedBox(width: 48, child: TextField(controller: _qtyCtrl, focusNode: widget.qtyFocusNode, textAlign: TextAlign.center, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4, horizontal: 4)), enabled: widget.isOpen, onSubmitted: (v) { final n = double.tryParse(v); if (n != null && n > 0) widget.onQtyChanged(n); else _qtyCtrl.text = qty.toStringAsFixed(0); widget.discFocusNode?.requestFocus(); })),
          const SizedBox(width: 6),
          if (widget.isOpen) GestureDetector(onTap: () => widget.onQtyChanged(qty + 1), child: Container(width: 24, height: 24, decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Icon(Icons.add, size: 14, color: AppTheme.primary))),
          const Spacer(),
          if (widget.isOpen) ...[
            SizedBox(width: 60, child: TextField(focusNode: widget.discFocusNode, decoration: const InputDecoration(hintText: 'Disc', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4)), keyboardType: const TextInputType.numberWithOptions(decimal: true), controller: TextEditingController(text: disc > 0 ? disc.toStringAsFixed(0) : ''), onChanged: (v) => widget.onDiscountChanged(double.tryParse(v) ?? 0, discType), textAlign: TextAlign.right, onSubmitted: (_) => widget.onFieldDone?.call())),
            const SizedBox(width: 4),
            GestureDetector(onTap: () => widget.onDiscountChanged(disc, discType == 'fixed' ? 'percent' : 'fixed'), child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), decoration: BoxDecoration(color: disc > 0 ? Colors.orange.withOpacity(0.1) : AppTheme.background, borderRadius: BorderRadius.circular(4), border: Border.all(color: AppTheme.border)), child: Text(discType == 'percent' ? '%' : 'Rs', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: disc > 0 ? Colors.orange : AppTheme.textSecondary)))),
          ],
        ]),
      ]));
  }
}

class _SessionStat extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _SessionStat({required this.label, required this.value, this.color});
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, letterSpacing: 0.5)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color ?? AppTheme.textPrimary)),
    ]));
}

class _StockBadge extends StatelessWidget {
  final double stockQty;
  const _StockBadge({required this.stockQty});
  @override Widget build(BuildContext context) {
    if (stockQty < 0) return const SizedBox.shrink(); // no product_id link
    if (stockQty > 10) return const SizedBox.shrink();
    if (stockQty <= 0) return Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: const Text('OUT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: AppTheme.danger)));
    return Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text('${stockQty.toStringAsFixed(0)} left', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.orange)));
  }
}
