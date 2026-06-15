import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'erp_pos_held_bills_screen.dart';
import 'dart:js_util' as js_util;
import 'dart:js_util' as js_util;

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
      double cashSales = 0, cashRefunds = 0, cashExpenses = 0;
      final txns = await client
          .from('pos_transactions')
          .select('total, amount_paid, payment_method, transaction_type')
          .eq('session_id', sid);
      for (final t in txns as List) {
        final pm = ((t['payment_method'] as String?) ?? 'cash').toLowerCase();
        if (pm != 'cash') continue;
        final tot = ((t['total'] as num?)?.toDouble() ?? 0).abs();
        final type = (t['transaction_type'] as String?) ?? 'sale';
        if (type == 'return') {
          cashRefunds += tot;
        } else {
          final paid = (t['amount_paid'] as num?)?.toDouble();
          cashSales += (paid != null && paid < tot) ? paid : tot;
        }
      }
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
                              final filteredTxns = q.isEmpty ? txns : txns.where((t) { final cu = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? '') as String).toLowerCase(); final ph = (t['pos_customers']?['phone'] as String? ?? '').toLowerCase(); final tr = (t['transaction_number'] as String? ?? '').toLowerCase(); return cu.contains(q) || ph.contains(q) || tr.contains(q); }).toList();
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
                                    Expanded(flex: 2, child: Text('Rs. ${(_sessionTotals[sid] ?? 0).toStringAsFixed(2)}',
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
                                else ...filteredTxns.map((t) { final isRet = t['transaction_type'] == 'return'; final tot = (t['total'] as num?)?.toDouble() ?? 0; final cu = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String); final ph = t['pos_customers']?['phone'] as String? ?? ''; final tr = t['transaction_number'] as String? ?? ''; final ti = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : ''; return InkWell(onTap: () async { try { final ti2 = await Supabase.instance.client.from('pos_transaction_items').select('*, products(name)').eq('transaction_id', t['id'] as String); final ci2 = (ti2 as List).map((i) => {'name': i['products']?['name'] ?? '-', 'quantity': (i['quantity'] as num?)?.toDouble() ?? 0.0, 'unit_price': (i['unit_price'] as num?)?.toDouble() ?? 0.0, 'discount': (i['discount'] as num?)?.toDouble() ?? 0.0, 'discount_type': i['discount_type'] as String? ?? 'fixed'}).toList(); if (mounted) await showDialog(context: context, builder: (_) => _ReceiptDialog(transaction: Map<String, dynamic>.from(t), items: ci2, orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation', branchName: s['branches']?['name'] as String? ?? '', cashierName: '', footerNote: null)); } catch (_) {} }, child: Padding(padding: const EdgeInsets.fromLTRB(48,7,20,7), child: Row(children: [Icon(isRet ? Icons.reply : Icons.receipt_outlined, size: 13, color: isRet ? Colors.orange : AppTheme.primary), const SizedBox(width: 8), Expanded(child: Wrap(spacing: 8, children: [Text(cu, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)), if (ph.isNotEmpty) Text(ph, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)), if (tr.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal:5,vertical:1), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(3)), child: Text(tr, style: TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w600))), Text(ti, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary))])), Text('${isRet ? '-' : ''}Rs. ${tot.abs().toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isRet ? Colors.orange : AppTheme.primary))])));  }),
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
  double _orderDiscount = 0;
  String _orderDiscountType = 'fixed'; // 'fixed' | 'percent'
  bool _loading = true;
  bool _sessionPanelOpen = true;
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
  Map<String, double> _stockMap = {};  // product_id → qty in stock
  bool _allowNoStock = false;           // org setting: allow selling without stock
  bool _allowPriceEdit = false;         // org setting: allow editing price at POS
  Map<String, String> _posConfig = {};

  @override void initState() { super.initState(); _session = Map.from(widget.session); WidgetsBinding.instance.addPostFrameCallback((_) => _syncSelectorToSession()); _loadData(); }
  @override void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); _customerSearchCtrl.dispose(); _customPaymentCtrl.dispose(); _checkoutFocusNode.dispose(); for (final f in _qtyFocusNodes) f.dispose(); _stagedQtyCtrl.dispose(); _stagedDiscCtrl.dispose(); _stagedPriceCtrl.dispose(); _stagedQtyFocus.dispose(); _stagedDiscFocus.dispose(); for (final f in _discFocusNodes) f.dispose(); _amountPaidCtrl.dispose(); super.dispose(); }

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

  Future<void> _loadData() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() { _loading = true; _stagedProduct = null; _stagedCartIndex = null; _stagedQtyCtrl.clear(); _stagedDiscCtrl.clear(); _showDropdown = false; });
    try {
      final client = Supabase.instance.client;
      final branchId = _session['branch_id'] as String? ?? '';
      final results = await Future.wait([
        client.from('pos_transactions').select('*, customers(shop_name), pos_customers(name, phone), transaction_number, amount_paid, balance_change').eq('session_id', _session['id']).order('transacted_at', ascending: false),
        client.from('pos_catalog').select('id, name, sku, price, is_active, product_id, uom_id').eq('org_id', orgId).eq('branch_id', branchId).eq('is_active', true).order('name'),
        client.from('customers').select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true).order('shop_name'),
        client.from('pos_sessions').select('*, branches(name)').eq('id', _session['id']).single(),
        client.from('inventory_stock').select('product_id, quantity').eq('org_id', orgId).eq('branch_id', branchId),
        client.from('pos_customers').select('id, name, phone, cnic').eq('org_id', orgId).eq('branch_id', branchId).order('name'),
        client.from('pos_held_bills').select('*').eq('session_id', _session['id']).eq('status', 'held').order('held_at', ascending: false),
      ]);
      final prods = List<Map<String, dynamic>>.from(results[1] as List);
      final stockRows = List<Map<String, dynamic>>.from(results[4] as List);
      final stockMap = <String, double>{for (final s in stockRows) s['product_id'] as String: (s['quantity'] as num?)?.toDouble() ?? 0.0};
      // Embed stock qty into each catalog product
      for (final p in prods) { final pid = p['product_id'] as String?; p['stock_qty'] = pid != null && pid.isNotEmpty ? (stockMap[pid] ?? -1.0) : -1.0; }
      List<Map<String, dynamic>> expenseList = [];
      try {
        final expRows = await Supabase.instance.client.from('pos_expenses').select('*').eq('session_id', _session['id']).order('created_at', ascending: false);
        expenseList = List<Map<String, dynamic>>.from(expRows);
      } catch (_) {}
      // Load expenses separately (avoids Future.wait index issues)
      bool allowNoStock = false;
      bool allowPriceEdit = false;
      try {
        final s = await Supabase.instance.client.from('pos_settings').select('allow_sell_without_stock, allow_price_edit').eq('org_id', orgId).maybeSingle();
        allowNoStock = s != null && s['allow_sell_without_stock'] == true;
        allowPriceEdit = s != null && s['allow_price_edit'] == true;
      } catch (_) {}

      // Receipt config from app_config (pos.*). Branch-scoped: a branch's own
      // config (branch_id == this branch) takes precedence as a complete set;
      // otherwise fall back to the org-level default (branch_id null/empty).
      Map<String, String> orgCfg = {};
      Map<String, String> brCfg = {};
      try {
        final cfgRows = await Supabase.instance.client
            .from('app_config').select('key, value, branch_id').eq('org_id', orgId).like('key', 'pos.%');
        for (final row in (cfgRows as List)) {
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
      } catch (_) {}
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
        _posConfig = posCfg;
        _loading = false;
      });
    } catch (e) { _showSnack('Load error: $e'); setState(() => _loading = false); }
  }

  // ── Stage a product for editing before adding to bill ─────
  void _stageProduct(Map<String, dynamic> product, {int? cartIndex}) {
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
      _stagedQtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _stagedQtyCtrl.text.length);
      _stagedQtyFocus.requestFocus();
    });
  }

  void _confirmStaged() {
    if (_stagedProduct == null || !_isOpen) return;
    final qty = double.tryParse(_stagedQtyCtrl.text.trim()) ?? 1;
    if (qty <= 0) return;
    final disc = double.tryParse(_stagedDiscCtrl.text.trim()) ?? 0;
    final basePrice = (_stagedProduct!['price'] as num?)?.toDouble() ?? (_stagedProduct!['unit_price'] as num?)?.toDouble() ?? 0;
    final price = _allowPriceEdit ? (double.tryParse(_stagedPriceCtrl.text.trim()) ?? basePrice) : basePrice;
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

  Widget _buildStagingCard() {
    final p = _stagedProduct!;
    final basePrice = (p['price'] as num?)?.toDouble() ?? (p['unit_price'] as num?)?.toDouble() ?? 0;
    final price = _allowPriceEdit ? (double.tryParse(_stagedPriceCtrl.text.trim()) ?? basePrice) : basePrice;
    final stock = (p['stock_qty'] as num?)?.toDouble() ?? 0;
    final qty = double.tryParse(_stagedQtyCtrl.text.trim()) ?? 1;
    final disc = double.tryParse(_stagedDiscCtrl.text.trim()) ?? 0;
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
            SizedBox(width: 160, child: TextField(controller: _stagedPriceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              decoration: InputDecoration(prefixText: 'Rs. ', labelText: 'Unit price', isDense: true,
                filled: true, fillColor: const Color(0xFFF8F9FA),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              onChanged: (_) => setState(() {}))),
            const SizedBox(width: 12),
            Expanded(child: Text(stock >= 0 ? 'Stock: ' + stock.toStringAsFixed(0) : (_allowNoStock ? 'Stock not tracked' : 'No stock'),
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          ])
        else
          Text('Rs. ' + price.toStringAsFixed(2) + '   ' + (stock >= 0 ? 'Stock: ' + stock.toStringAsFixed(0) : (_allowNoStock ? 'Stock not tracked' : 'No stock')), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
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
                onChanged: (_) => setState(() {}),
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
          Text('Rs. ' + total.toStringAsFixed(2), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.primary)),
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
          (p['name'] as String? ?? '').toLowerCase().contains(q.toLowerCase()) ||
          (p['sku'] as String? ?? '').toLowerCase().contains(q.toLowerCase())).toList();
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
    final d = i['discount'] as double; final qty = i['quantity'] as double; final price = i['unit_price'] as double;
    return s + (i['discount_type'] == 'percent' ? price * qty * (d / 100) : d);
  });
  double get _orderDiscountAmt => _orderDiscountType == 'percent' ? _cartSubtotal * (_orderDiscount / 100) : _orderDiscount;
  double get _cartTotal => (_cartSubtotal - _cartItemDiscounts - _orderDiscountAmt).clamp(0, double.infinity);
  double get _totalDiscount => _cartItemDiscounts + _orderDiscountAmt;

  bool _checkingOut = false;
  Future<void> _checkout() async {
    if (_checkingOut) return;
    _checkingOut = true;
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    if (_cart.any((i) => i['product_id'] == null)) { _showSnack('Some items have no product link — remove and re-add'); return; }
    // Stock check
    for (final item in _cart) {
      final qty = item['quantity'] as double;
      final stock = (item['stock_qty'] as num?)?.toDouble() ?? 0;
      if (!_allowNoStock && (stock <= 0 || qty > stock)) { _showSnack('Insufficient stock for "${item['name']}": ${(stock < 0 ? 0 : stock).toStringAsFixed(0)} available'); return; }
    }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final txnId = 'post_${DateTime.now().millisecondsSinceEpoch}_${math.Random().nextInt(9999999)}';
      String txnNumber = 'TRX-${DateTime.now().year}-00001';
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
      final now = DateTime.now().toUtc().toIso8601String();
      final cartSnapshot = List<Map<String, dynamic>>.from(_cart);
      final totalAmt = _cartTotal;
      final discountAmt = _totalDiscount;
      await client.from('pos_transactions').insert({
        'id': txnId, 'transaction_number': txnNumber, 'org_id': orgId, 'session_id': _session['id'],
        'customer_id': _selectedCustomer?['id'],
        'pos_customer_id': _selectedPosCustomer?['id'],
        'total': totalAmt, 'discount': discountAmt,
        'payment_method': _paymentMethod == 'other' ? (_customPaymentCtrl.text.trim().isEmpty ? 'other' : _customPaymentCtrl.text.trim()) : _paymentMethod,
        'amount_paid': _splitPayment ? (double.tryParse(_amountPaidCtrl.text.trim()) ?? totalAmt) : totalAmt,
        'balance_change': _splitPayment ? ((double.tryParse(_amountPaidCtrl.text.trim()) ?? totalAmt) - totalAmt) : 0,
        'transaction_type': 'sale',
        'created_by': userId, 'transacted_at': now,
      });
      for (final item in cartSnapshot) {
        final qty = item['quantity'] as double;
        final pid = item['product_id'] as String;
        await client.from('pos_transaction_items').insert({
          'id': 'posti_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'transaction_id': txnId, 'product_id': pid,
          'uom_id': item['uom_id'], 'quantity': qty,
          'unit_price': item['unit_price'], 'discount': item['discount'], 'discount_type': item['discount_type'] as String? ?? 'fixed',
        });
        final existing = await client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (existing != null) {
          await client.from('inventory_stock').update({
            'quantity': (existing['quantity'] as num).toDouble() - qty,
            'updated_at': now,
          }).eq('id', existing['id']);
        }
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': item['uom_id'], 'quantity': -qty, 'movement_type': 'pos',
          'reference_id': txnId, 'reference_type': 'pos_transaction',
          'moved_at': now, 'created_by': userId,
        });
      }
      // Update customer balance for split payment
      if (_splitPayment && (_selectedPosCustomer != null || _selectedCustomer != null)) {
        final paid = double.tryParse(_amountPaidCtrl.text.trim()) ?? totalAmt;
        final diff = paid - totalAmt; // positive = credit, negative = balance due
        if (diff != 0 && _selectedPosCustomer != null) {
          try {
            final custId = _selectedPosCustomer!['id'] as String;
            final existing = await client.from('pos_customers').select('balance').eq('id', custId).single();
            final curBal = (existing['balance'] as num?)?.toDouble() ?? 0;
            await client.from('pos_customers').update({'balance': curBal + diff}).eq('id', custId);
          } catch (_) {}
        }
      }
      setState(() { _cart.clear(); _orderDiscount = 0; _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); _paymentMethod = 'cash'; _customPaymentCtrl.clear(); _splitPayment = false; _amountPaidCtrl.clear(); _syncFocusNodes(); }); _playSuccessSound();
      await _loadData();
      // Show receipt
      if (mounted) {
        final txn = _transactions.firstWhere((t) => t['id'] == txnId, orElse: () => {'id': txnId, 'transaction_number': txnNumber, 'total': totalAmt, 'discount': discountAmt, 'payment_method': _paymentMethod, 'transacted_at': now, 'customers': _selectedCustomer != null ? {'shop_name': _selectedCustomer!['shop_name']} : (_selectedPosCustomer != null ? {'shop_name': _selectedPosCustomer!['name']} : null)});
        await showDialog(context: context, barrierDismissible: false, builder: (_) => _ReceiptDialog(
          transaction: txn, items: cartSnapshot,
          orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
          branchName: _session['branches']?['name'] as String? ?? '',
          cashierName: ref.read(currentUserProvider)?.name ?? '', posConfig: _posConfig,
        ));
      }
    } catch (e) { _showSnack('Failed: $e'); } finally { setState(() => _checkingOut = false); }
  }

  Future<void> _processReturn(Map<String, dynamic> originalTxn, List<Map<String, dynamic>> returnItems) async {
    if (returnItems.isEmpty) { _showSnack('Select at least one item'); return; }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    final branchId = _session['branch_id'] as String;
    try {
      final client = Supabase.instance.client;
      final retId = 'posr_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().toUtc().toIso8601String();
      double returnTotal = returnItems.fold(0, (s, i) { final qty = i['return_qty'] as double; final price = (i['unit_price'] as num?)?.toDouble() ?? 0; final disc = (i['discount'] as num?)?.toDouble() ?? 0; final discType = i['discount_type'] as String? ?? 'fixed'; final origQty = (i['quantity'] as num?)?.toDouble() ?? 1; final da = discType == 'percent' ? price * origQty * (disc/100) : disc; return s + qty * (price - (origQty > 0 ? da/origQty : 0)); });
      await client.from('pos_transactions').insert({
        'id': retId, 'org_id': orgId, 'session_id': _session['id'],
        'customer_id': originalTxn['customer_id'],
        'total': -returnTotal, 'discount': 0,
        'payment_method': originalTxn['payment_method'] ?? 'cash',
        'transaction_type': 'return',
        'reference_transaction_id': originalTxn['id'],
        'created_by': userId, 'transacted_at': now,
      });
      for (final item in returnItems) {
        final qty = item['return_qty'] as double;
        final pid = item['product_id'] as String;
        await client.from('pos_transaction_items').insert({
          'id': 'posti_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'transaction_id': retId, 'product_id': pid,
          'uom_id': item['uom_id'], 'quantity': -qty,
          'unit_price': item['unit_price'], 'discount': 0,
        });
        // Add stock back
        final stock = await client.from('inventory_stock').select()
            .eq('org_id', orgId!).eq('product_id', pid).eq('branch_id', branchId).maybeSingle();
        if (stock != null) {
          await client.from('inventory_stock').update({'quantity': (stock['quantity'] as num).toDouble() + qty, 'updated_at': now}).eq('id', stock['id']);
        } else {
          await client.from('inventory_stock').insert({'id': 'is_${DateTime.now().microsecondsSinceEpoch}', 'org_id': orgId, 'product_id': pid, 'branch_id': branchId, 'quantity': qty});
        }
        await client.from('inventory_movements').insert({
          'id': 'im_${DateTime.now().microsecondsSinceEpoch}_${pid.substring(0, 4)}',
          'org_id': orgId, 'product_id': pid, 'branch_id': branchId,
          'uom_id': item['uom_id'], 'quantity': qty, 'movement_type': 'adjustment',
          'reference_id': retId, 'reference_type': 'pos_return',
          'moved_at': now, 'created_by': userId,
        });
      }
      _showSnack('Return processed — Rs. ${returnTotal.toStringAsFixed(2)} refunded');
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
      final id = 'posc_${DateTime.now().millisecondsSinceEpoch}';
      await Supabase.instance.client.from('pos_customers').insert({
        'id': id, 'org_id': orgId, 'branch_id': branchId,
        'name': nameCtrl.text.trim(),
        'phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
        'cnic': cnicCtrl.text.trim().isEmpty ? null : cnicCtrl.text.trim(),
      });
      final newCust = {'id': id, 'name': nameCtrl.text.trim(), 'phone': phoneCtrl.text.trim(), 'cnic': cnicCtrl.text.trim(), '_type': 'pos'};
      setState(() { _posCustomers.add(newCust); _selectedPosCustomer = newCust; _selectedCustomer = null; _customerSearchCtrl.clear(); });
      _showSnack('Customer "${nameCtrl.text.trim()}" added');
    } catch (e) { _showSnack('Failed: $e'); } finally { _checkingOut = false; }
  }

  Future<void> _closeSession() async {
    final opening = (_session['opening_cash'] as num?)?.toDouble() ?? 0;
    double cashSales = 0, cashRefunds = 0, cashExpenses = 0;
    for (final t in _transactions) {
      final pm = ((t['payment_method'] as String?) ?? 'cash').toLowerCase();
      if (pm != 'cash') continue;
      final tot = ((t['total'] as num?)?.toDouble() ?? 0).abs();
      final type = (t['transaction_type'] as String?) ?? 'sale';
      if (type == 'return') {
        cashRefunds += tot;
      } else {
        final paid = (t['amount_paid'] as num?)?.toDouble();
        cashSales += (paid != null && paid < tot) ? paid : tot;
      }
    }
    for (final e in _expenses) {
      cashExpenses += (e['amount'] as num?)?.toDouble() ?? 0;
    }
    final expectedClose = opening + cashSales - cashRefunds - cashExpenses;
    final cashCtrl = TextEditingController(text: expectedClose.toStringAsFixed(2));
    final notesCtrl = TextEditingController();
    Widget ccRow(String label, double val, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: bold ? AppTheme.textPrimary : AppTheme.textSecondary)),
        Text('Rs. ${val.toStringAsFixed(2)}', style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: bold ? AppTheme.primary : AppTheme.textPrimary)),
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
            const Divider(height: 14),
            ccRow('Expected closing cash', expectedClose, bold: true),
          ]),
        ),
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
      _exportSummary();
      widget.onUpdated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  Future<void> _exportSummary() async {
    final orgId = _orgId; if (orgId == null) return;
    final client = Supabase.instance.client;
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
    final openingCash = (_session['opening_cash'] as num?)?.toDouble() ?? 0;
    final closingCash = (_session['closing_cash'] as num?)?.toDouble() ?? 0;
    double totalExpenses = 0; String expRows = '';
    for (final e in _expenses) {
      final ea = (e['amount'] as num?)?.toDouble() ?? 0; totalExpenses += ea;
      final ec = e['category'] as String? ?? '-'; final en = e['note'] as String? ?? '';
      final et = e['created_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(e['created_at'] as String).toLocal()) : '';
      expRows += '<tr style="background:#fff5f5"><td>$et</td><td>$ec</td><td>${en}</td><td style="text-align:right;color:#c0392b;font-weight:bold">-${ea.toStringAsFixed(2)}</td></tr>';
    }
    final cashDiff = totalSales - totalReturns - totalExpenses + openingCash - closingCash;  // +ve = cash short, -ve = cash over
    final branch = _session['branches']?['name'] as String? ?? '-';
    final user = ref.read(currentUserProvider);
    final cashier = user?.name ?? user?.id ?? '-';
    final openedAt = _session['opened_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['opened_at'] as String).toLocal()) : '-';
    final closedAt = _session['closed_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(_session['closed_at'] as String).toLocal()) : 'Open';

    String txnRows = '';
    for (final t in sales) {
      final tid = t['id'] as String;
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      final method = t['payment_method'] as String? ?? '';
      final total = (t['total'] as num?)?.toStringAsFixed(2) ?? '0.00';
      final disc = (t['discount'] as num?)?.toDouble() ?? 0;
      final items = itemsByTxn[tid] ?? [];
      final itemStr = items.map((i) { final q = (i['quantity'] as num?)?.toDouble() ?? 0; final p = (i['unit_price'] as num?)?.toDouble() ?? 0; final d = (i['discount'] as num?)?.toDouble() ?? 0; final n = i['products']?['name'] as String? ?? '-'; return '$n × ${q.toStringAsFixed(0)} @ ${p.toStringAsFixed(2)}${d > 0 ? ' (-${d.toStringAsFixed(2)})' : ''}'; }).join('<br>');
      txnRows += '<tr><td>$time</td><td style="font-size:11px;color:#666">${tid.substring(0, 10)}…</td><td>$customer</td><td style="font-size:11px">$itemStr</td><td>$method</td>${disc > 0 ? '<td style="color:#e67e22">-${disc.toStringAsFixed(2)}</td>' : '<td>-</td>'}<td style="text-align:right;font-weight:bold">$total</td></tr>';
    }
    String retRows = '';
    for (final t in returns) {
      final time = t['transacted_at'] != null ? DateFormat('HH:mm').format(DateTime.parse(t['transacted_at'] as String).toLocal()) : '';
      final refId = t['reference_transaction_id'] as String? ?? '-';
      final refShort = refId.length > 10 ? '${refId.substring(0, 10)}…' : refId;
      final total = ((t['total'] as num?)?.toDouble() ?? 0).abs().toStringAsFixed(2);
      final customer = (t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? 'Walk-in') as String;
      retRows += '<tr style="background:#fff5f5"><td>$time</td><td>$customer</td><td style="font-size:11px;color:#666">← $refShort</td><td style="text-align:right;color:#e74c3c;font-weight:bold">-$total</td></tr>';
    }

    final htmlContent = '''<!DOCTYPE html><html><head><title>POS Session Summary</title>
<style>
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
  <div class="stat"><div class="sl">Total Sales</div><div class="sv green">${totalSales.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Total Refunds</div><div class="sv red">${totalReturns.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Net Sales</div><div class="sv">${(totalSales - totalReturns).toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Customer Account Sale</div><div class="sv blue">${customerAccountSale.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Opening Cash</div><div class="sv">${openingCash.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Closing Cash</div><div class="sv">${closingCash.toStringAsFixed(2)}</div></div>
  <div class="stat"><div class="sl">Cash Difference</div><div class="sv ${cashDiff <= 0 ? 'green' : 'red'}">${cashDiff > 0 ? '-' : '+'}${cashDiff.abs().toStringAsFixed(2)}</div></div>
</div>
${txnRows.isNotEmpty ? '''<h2>Sales Transactions</h2>
<table><thead><tr><th>Time</th><th>Txn #</th><th>Customer</th><th>Items</th><th>Payment</th><th>Discount</th><th>Total</th></tr></thead>
<tbody>$txnRows
<tr class="total-row"><td colspan="6">TOTAL SALES</td><td style="text-align:right">${totalSales.toStringAsFixed(2)}</td></tr>
</tbody></table>''' : ''}
${expRows.isNotEmpty ? '''<h2>Expenses</h2>
<table><thead><tr><th>Time</th><th>Category</th><th>Note</th><th>Amount</th></tr></thead>
<tbody>$expRows
<tr class="total-row"><td colspan="3">TOTAL EXPENSES</td><td style="text-align:right;color:#c0392b">-${totalExpenses.toStringAsFixed(2)}</td></tr>
</tbody></table>''' : ''}
${retRows.isNotEmpty ? '''<h2>Returns &amp; Refunds</h2>
<table><thead><tr><th>Time</th><th>Customer</th><th>Original Txn</th><th>Refund</th></tr></thead>
<tbody>$retRows
<tr class="total-row"><td colspan="3">TOTAL REFUNDS</td><td style="text-align:right;color:#e74c3c">-${totalReturns.toStringAsFixed(2)}</td></tr>
</tbody></table>''' : ''}
<script>window.onload=function(){window.print();}</script>
</body></html>''';

    final blob = html.Blob([htmlContent], 'text/html');
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
    return Scaffold(
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
            TextButton.icon(icon: const Icon(Icons.receipt_long_outlined, size: 18), label: const Text('Expense'), onPressed: _addExpense, style: TextButton.styleFrom(foregroundColor: Colors.red.shade700)),
            const SizedBox(width: 4),
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Summary'), onPressed: _exportSummary),
            const SizedBox(width: 4),
            ElevatedButton.icon(icon: const Icon(Icons.power_settings_new, size: 16), label: const Text('Close Session'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: _closeSession),
          ] else ...[
            TextButton.icon(icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Export Summary'), onPressed: _exportSummary),
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
                              Text('Rs. ' + price.toStringAsFixed(2) + '  |  ' + stockLabel,
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
          // Customer
            Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Customer', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSecondary, letterSpacing: 0.5)),
              const SizedBox(height: 4),
              TextField(
                controller: _customerSearchCtrl,
                enabled: _isOpen,
                decoration: InputDecoration(
                  hintText: _selectedPosCustomer != null ? _selectedPosCustomer!['name'] as String : (_selectedCustomer != null ? _selectedCustomer!['shop_name'] as String : 'Walk-in (optional)'),
                  hintStyle: TextStyle(color: (_selectedPosCustomer ?? _selectedCustomer) != null ? AppTheme.primary : AppTheme.textSecondary, fontWeight: (_selectedPosCustomer ?? _selectedCustomer) != null ? FontWeight.w600 : FontWeight.normal),
                  prefixIcon: Icon(_selectedPosCustomer != null ? Icons.person_pin : Icons.person_outline, size: 18, color: (_selectedPosCustomer ?? _selectedCustomer) != null ? AppTheme.primary : AppTheme.textSecondary),
                  suffixIcon: (_selectedPosCustomer ?? _selectedCustomer) != null ? IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: () => setState(() { _selectedCustomer = null; _selectedPosCustomer = null; _customerSearchCtrl.clear(); })) : null,
                  isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)),
                ),
                onChanged: (q) {
                  final ql = q.toLowerCase();
                  final erpMatches = q.isEmpty ? <Map<String, dynamic>>[] : _customers.where((c) => (c['shop_name'] as String? ?? '').toLowerCase().contains(ql)).take(4).map((c) => {...c, '_type': 'erp'}).toList();
                  final posMatches = q.isEmpty ? <Map<String, dynamic>>[] : _posCustomers.where((c) => (c['name'] as String? ?? '').toLowerCase().contains(ql) || (c['phone'] as String? ?? '').contains(ql)).take(4).map((c) => {...c, '_type': 'pos'}).toList();
                  setState(() { _showCustomerDropdown = q.isNotEmpty; _filteredCustomers = [...posMatches, ...erpMatches]; });
                },
              ),
              if (_showCustomerDropdown)
                Container(margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
                  child: Column(children: [
                    ListTile(dense: true, leading: const Icon(Icons.add_circle, color: AppTheme.primary, size: 20), title: const Text('Quick-add new customer', style: TextStyle(fontSize: 13, color: AppTheme.primary, fontWeight: FontWeight.w600)), onTap: () { setState(() => _showCustomerDropdown = false); _showQuickAddCustomer(); }),
                    if (_filteredCustomers.isNotEmpty) const Divider(height: 1),
                    ..._filteredCustomers.map((cx) {
                      final isPos = cx['_type'] == 'pos';
                      final name = isPos ? cx['name'] as String? ?? '-' : cx['shop_name'] as String? ?? '-';
                      final sub = isPos ? cx['phone'] as String? : cx['code'] as String?;
                      return ListTile(dense: true,
                        leading: Icon(isPos ? Icons.person_pin : Icons.business, size: 18, color: isPos ? Colors.purple : AppTheme.textSecondary),
                        title: Text(name, style: const TextStyle(fontSize: 13)),
                        subtitle: sub != null && sub.isNotEmpty ? Text(sub, style: const TextStyle(fontSize: 11)) : null,
                        trailing: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: isPos ? Colors.purple.withOpacity(0.1) : AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(isPos ? 'POS' : 'ERP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: isPos ? Colors.purple : AppTheme.primary))),
                        onTap: () => setState(() {
                          if (isPos) { _selectedPosCustomer = cx; _selectedCustomer = null; } else { _selectedCustomer = cx; _selectedPosCustomer = null; }
                          _customerSearchCtrl.clear(); _showCustomerDropdown = false;
                        }));
                    }),
                  ])),
            ])),
            // Bill search
            if (_cart.length > 3) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 0), child: TextField(
              decoration: const InputDecoration(hintText: 'Filter bill items...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 5, horizontal: 8)),
              onChanged: (v) => setState(() => _cartSearch = v),
            )),
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
                    itemCount: (_cartSearch.isEmpty ? _cart : _cart.where((it) => (it['name'] as String? ?? '').toLowerCase().contains(_cartSearch.toLowerCase())).toList()).length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final billView = _cartSearch.isEmpty ? _cart : _cart.where((it) => (it['name'] as String? ?? '').toLowerCase().contains(_cartSearch.toLowerCase())).toList();
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
                                    ? (discType == 'percent' ? '  (-${disc.toStringAsFixed(0)}%)' : '  (-${da.toStringAsFixed(2)})')
                                    : '';
                                return Text(qty.toStringAsFixed(0) + ' x Rs. ' + price.toStringAsFixed(2) + discStr,
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary));
                              }),
                            ])),
                            Text('Rs. ' + lineTotal.toStringAsFixed(2),
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
            Container(padding: const EdgeInsets.all(12), decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
              child: Column(children: [
                // Order-level discount
                Row(children: [
                  const Text('Order Discount', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  SizedBox(width: 80, child: TextField(
                    enabled: _isOpen,
                    decoration: const InputDecoration(hintText: '0', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true), textAlign: TextAlign.right,
                    onChanged: (v) => setState(() => _orderDiscount = double.tryParse(v) ?? 0),
                  )),
                  const SizedBox(width: 6),
                  DropdownButton<String>(value: _orderDiscountType, isDense: true, underline: const SizedBox(),
                    items: const [DropdownMenuItem(value: 'fixed', child: Text('Fixed', style: TextStyle(fontSize: 12))), DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 12)))],
                    onChanged: _isOpen ? (v) => setState(() => _orderDiscountType = v!) : null),
                ]),
                const SizedBox(height: 6),
                // Payment
                Row(children: [
                  const Text('Payment', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const Spacer(),
                  if (_isOpen) TextButton.icon(icon: Icon(_splitPayment ? Icons.call_merge : Icons.call_split, size: 15), label: Text(_splitPayment ? 'Single' : 'Split', style: const TextStyle(fontSize: 11)), onPressed: () => setState(() { _splitPayment = !_splitPayment; if (!_splitPayment) _amountPaidCtrl.clear(); })),
                ]),
                SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'cash', label: Text('Cash', style: TextStyle(fontSize: 11))), ButtonSegment(value: 'card', label: Text('Card', style: TextStyle(fontSize: 11))), ButtonSegment(value: 'other', label: Text('Other', style: TextStyle(fontSize: 11)))],
                selected: {_paymentMethod}, onSelectionChanged: _isOpen ? (s) => setState(() => _paymentMethod = s.first) : null,
                style: const ButtonStyle(visualDensity: VisualDensity.compact)),
              if (_paymentMethod == 'other') ...[
                const SizedBox(height: 6),
                TextField(controller: _customPaymentCtrl, decoration: const InputDecoration(hintText: 'Specify payment method…', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)), textCapitalization: TextCapitalization.words),
              ],
              if (_splitPayment) ...[
                const SizedBox(height: 8),
                Row(children: [
                  const Text('Amount Paid', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: _amountPaidCtrl, decoration: const InputDecoration(hintText: '0.00', isDense: true, prefixText: 'Rs. ', contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)), keyboardType: const TextInputType.numberWithOptions(decimal: true), enabled: _isOpen, onChanged: (_) => setState(() {}))),
                ]),
                const SizedBox(height: 6),
                Builder(builder: (_) {
                  final paid = double.tryParse(_amountPaidCtrl.text.trim()) ?? 0;
                  final diff = paid - _cartTotal;
                  final hasCust = _selectedCustomer != null || _selectedPosCustomer != null;
                  if (paid == 0) return const SizedBox.shrink();
                  if (diff == 0) return const Row(children: [Icon(Icons.check_circle, size: 14, color: AppTheme.success), SizedBox(width: 4), Text('Fully paid', style: TextStyle(fontSize: 12, color: AppTheme.success))]);
                  return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: diff < 0 ? Colors.red.shade50 : Colors.green.shade50, borderRadius: BorderRadius.circular(6), border: Border.all(color: diff < 0 ? Colors.red.shade200 : Colors.green.shade200)),
                    child: Row(children: [
                      Icon(diff < 0 ? Icons.account_balance_wallet_outlined : Icons.savings_outlined, size: 16, color: diff < 0 ? Colors.red.shade700 : Colors.green.shade700),
                      const SizedBox(width: 6),
                      Expanded(child: Text(diff < 0 ? 'Balance due Rs. ${(-diff).toStringAsFixed(2)} added to customer account' : 'Credit Rs. ${diff.toStringAsFixed(2)} added to customer account', style: TextStyle(fontSize: 11, color: diff < 0 ? Colors.red.shade700 : Colors.green.shade700, fontWeight: FontWeight.w600))),
                      if (!hasCust) const Text('Select customer to proceed', style: TextStyle(fontSize: 10, color: Colors.orange, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                    ]));
                }),
              ],
                const SizedBox(height: 10),
                // Totals
                if (_totalDiscount > 0) Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Discount', style: TextStyle(fontSize: 12, color: Colors.orange)),
                  Text('- ${_totalDiscount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12, color: Colors.orange, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 4),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Total', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text('Rs. ${_cartTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primary)),
                ]),
                const SizedBox(height: 10),
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
                    label: Builder(builder: (_) { if (_splitPayment && _amountPaidCtrl.text.isNotEmpty) { final paid = double.tryParse(_amountPaidCtrl.text.trim()) ?? 0; final diff = paid - _cartTotal; if (diff < 0) return Text('Complete Sale (Balance: Rs. ${(-diff).toStringAsFixed(2)})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)); if (diff > 0) return Text('Complete Sale (Credit: Rs. ${diff.toStringAsFixed(2)})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)); } return Text(_cart.isEmpty ? 'Add items to checkout' : 'Complete Sale — Rs. ${_cartTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)); }),
                    style: ElevatedButton.styleFrom(backgroundColor: _cart.isNotEmpty && _isOpen ? AppTheme.primary : Colors.grey, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    onPressed: _cart.isNotEmpty && _isOpen && (!_splitPayment || (_amountPaidCtrl.text.isNotEmpty && (() { final paid = double.tryParse(_amountPaidCtrl.text.trim()) ?? 0; final diff = paid - _cartTotal; final needsCust = diff != 0 && _selectedCustomer == null && _selectedPosCustomer == null; return !needsCust; })())) ? _checkout : null,
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
                  Expanded(child: _SessionStat(label: 'Sales Total', value: _transactions.where((t) => (t['transaction_type'] ?? 'sale') == 'sale').fold(0.0, (s, t) => s + ((t['total'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2), color: AppTheme.success)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Opening Cash', value: (_session['opening_cash'] as num?)?.toStringAsFixed(2) ?? '0', color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _SessionStat(label: 'Expenses', value: '${_expenses.length}', color: Colors.red.shade700)),
                  const SizedBox(width: 8),
                  Expanded(child: _SessionStat(label: 'Exp. Total', value: _expenses.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2), color: Colors.red.shade700)),
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
                              Text('-${amt.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
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
                          onTap: isReturn ? null : () async {
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
                            Text('${isReturn ? '-' : ''}${total.abs().toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isReturn ? Colors.red : AppTheme.primary)),
                            if (!isReturn) const Icon(Icons.chevron_right, size: 14, color: AppTheme.textSecondary),
                          ])));
                      }))),
            ],
          ]),
        ),
      ]),
    );
  }

  Future<void> _addExpense() async {
    final amtCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String category = 'Transport';
    const cats = ['Transport', 'Supplies', 'Food & Beverages', 'Utilities', 'Maintenance', 'Miscellaneous', 'Other'];
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx2, setS) => AlertDialog(
      title: const Text('Record Expense'),
      content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: amtCtrl, decoration: const InputDecoration(labelText: 'Amount *', prefixText: 'Rs. '), keyboardType: const TextInputType.numberWithOptions(decimal: true), autofocus: true),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: category, decoration: const InputDecoration(labelText: 'Category'),
          items: cats.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
          onChanged: (v) => setS(() => category = v ?? category)),
        const SizedBox(height: 12),
        TextField(controller: noteCtrl, decoration: const InputDecoration(labelText: 'Note (optional)'), maxLines: 2),
      ])),
      actions: [TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('Save'))],
    )));
    if (ok != true) return;
    final amt = double.tryParse(amtCtrl.text.trim()) ?? 0;
    if (amt <= 0) { _showSnack('Enter a valid amount'); return; }
    final orgId = _orgId; final userId = ref.read(currentUserProvider)?.id;
    try {
      await Supabase.instance.client.from('pos_expenses').insert({
        'id': 'pex_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId ?? '', 'branch_id': _session['branch_id']?.toString() ?? _session['branch_id'] as String? ?? '',
        'session_id': _session['id'], 'amount': amt,
        'category': category, 'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
        'created_by': userId,
      });
      _showSnack('Expense recorded: Rs. ${amt.toStringAsFixed(2)}');
      _loadData();
    } catch (e) { _showSnack('Failed: $e'); }
  }

  // ── Hold Bill ─────────────────────────────────────────────────
  Future<void> _holdBill() async {
    if (_cart.isEmpty) { _showSnack('Cart is empty'); return; }
    final orgId = _orgId;
    final branchId = _session['branch_id'] as String;
    final userId = ref.read(currentUserProvider)?.id;
    final customerName = _selectedPosCustomer?['name'] as String? ?? _selectedCustomer?['shop_name'] as String? ?? 'Walk-in';
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
        _cart.clear(); _orderDiscount = 0; _selectedCustomer = null; _selectedPosCustomer = null;
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
    setState(() {
      _cart = items;
      _orderDiscount = (bill['order_discount'] as num?)?.toDouble() ?? 0;
      _orderDiscountType = (odt == 'percent') ? 'percent' : 'fixed';
      _paymentMethod = const {'cash', 'card', 'other'}.contains(pm) ? pm! : 'cash';
      _stagedProduct = null; _stagedCartIndex = null;
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

  @override Widget build(BuildContext context) {
    final total = (transaction['total'] as num?)?.toDouble() ?? 0;
    final discount = (transaction['discount'] as num?)?.toDouble() ?? 0;
    final subtotal = items.fold(0.0, (s, i) => s + ((i['unit_price'] as double) * (i['quantity'] as double)));
    final customer = (transaction['pos_customers']?['name'] ?? transaction['customers']?['shop_name'] ?? 'Walk-in') as String;
    final method = (transaction['payment_method'] as String? ?? 'cash').toUpperCase();
    final ts = transaction['transacted_at'] != null ? DateFormat('d MMM yyyy  HH:mm').format(DateTime.parse(transaction['transacted_at'] as String).toLocal()) : DateFormat('d MMM yyyy  HH:mm').format(DateTime.now());
    final company = posConfig['pos.company_name']?.isNotEmpty == true ? posConfig['pos.company_name']! : orgName;
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
      Text(branchName, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
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
            Expanded(flex: 2, child: Text(price.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: discAmt > 0 ? Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [Text('-Rs.${discAmt.toStringAsFixed(2)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Colors.orange)), if (discType == 'percent') Text('(${disc.toStringAsFixed(0)}%)', textAlign: TextAlign.right, style: const TextStyle(fontSize: 9, color: AppTheme.textSecondary))]) : const Text('-', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(flex: 2, child: Text(lt.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]));
        }),
      ])),
      const Divider(),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Subtotal', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        Text(subtotal.toStringAsFixed(2), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ]),
      if (discount > 0) ...[
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total Discount', style: TextStyle(fontSize: 13, color: Colors.orange)),
          Text('- ${discount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, color: Colors.orange, fontWeight: FontWeight.w600)),
        ]),
      ],
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('TOTAL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        Text('Rs. ${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.primary)),
      ]),
      const SizedBox(height: 4),
      Text('Payment: $method', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
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
          final posCompany = posConfig['pos.company_name']?.isNotEmpty == true ? posConfig['pos.company_name']! : orgName;
          final posNtn = posConfig['pos.ntn'] ?? '';
          final posContact = posConfig['pos.contact'] ?? '';
          final posFooter = posConfig['pos.footer_note']?.isNotEmpty == true ? posConfig['pos.footer_note']! : (footerNote ?? '');
          final posTerms = posConfig['pos.terms'] ?? '';
          final posLogo = posConfig['pos.logo'] ?? '';
          final amountPaid = (transaction['amount_paid'] as num?)?.toDouble()?.toStringAsFixed(2) ?? '0';
          final balanceChange = (transaction['balance_change'] as num?)?.toDouble()?.toStringAsFixed(2) ?? '0';
          final rows = items.map((i) { final q = i['quantity'] as double; final p = i['unit_price'] as double; final d = i['discount'] as double; final dt = i['discount_type'] as String? ?? 'fixed'; final da = dt == 'percent' ? p * q * (d / 100) : d; final lt = q * p - da; final n = i['name'] as String? ?? '-'; return '<tr><td>$n</td><td style="text-align:center">${q.toStringAsFixed(0)}</td><td style="text-align:right">${p.toStringAsFixed(2)}</td><td style="text-align:right;color:${da > 0 ? "#e67e22" : "#999"}">${da > 0 ? (dt == 'percent' ? "-Rs.${da.toStringAsFixed(2)} <small style='color:#aaa'>(${d.toStringAsFixed(0)}%)</small>" : "-Rs.${da.toStringAsFixed(2)}") : "-"}</td><td style="text-align:right;font-weight:bold">${lt.toStringAsFixed(2)}</td></tr>'; }).join();
          final discRow = discount > 0 ? '<tr><td colspan="4" style="color:#e67e22">Total Discount</td><td style="text-align:right;color:#e67e22">-${discount.toStringAsFixed(2)}</td></tr>' : '';
          final footerHtml = (footerNote != null && footerNote!.isNotEmpty) ? '<p style="text-align:center;color:#888;font-size:11px;border-top:1px dashed #ccc;padding-top:8px;margin-top:8px">$footerNote</p>' : '';
          final content = '<!DOCTYPE html><html><head><title>Receipt</title><style>body{font-family:Arial,sans-serif;padding:20px;max-width:320px;margin:0 auto;font-size:12px}h2,h3{text-align:center;margin:4px 0}table{width:100%;border-collapse:collapse;margin:8px 0}th{background:#f5f5f5;padding:5px 6px;font-size:11px;text-align:left}td{padding:5px 6px;border-bottom:1px solid #eee}.total-row td{font-weight:bold;font-size:13px;border-top:2px solid #333}hr{border:none;border-top:1px dashed #ccc;margin:8px 0}</style></head><body>${posLogo.isNotEmpty ? '<div style=\"text-align:center;margin-bottom:8px\"><img src=\"$posLogo\" style=\"max-height:60px;max-width:200px\"></div>' : ''}<h2>$posCompany</h2><h3 style="font-weight:normal;color:#666">$branchName</h3>${posNtn.isNotEmpty ? '<p style="text-align:center;font-size:11px;color:#666;margin:2px 0">$posNtn</p>' : ''}${posContact.isNotEmpty ? '<p style="text-align:center;font-size:11px;color:#666;margin:2px 0">$posContact</p>' : ''}<p style="text-align:center;margin:4px 0">$ts</p><p style="text-align:center;margin:4px 0">Customer: $customer</p>${(transaction['transaction_number'] as String?)?.isNotEmpty == true ? '<p style="text-align:center;font-size:10px;color:#888;margin:2px 0">Ref: ' + (transaction['transaction_number'] as String) + '</p>' : ''}<hr><table><thead><tr><th>Item</th><th style="text-align:center">Qty</th><th style="text-align:right">Price</th><th style="text-align:right">Disc</th><th style="text-align:right">Total</th></tr></thead><tbody>$rows<tr><td colspan="4" style="color:#666">Subtotal</td><td style="text-align:right">${subtotal.toStringAsFixed(2)}</td></tr>$discRow<tr class="total-row"><td colspan="4">TOTAL</td><td style="text-align:right">Rs. ${total.toStringAsFixed(2)}</td></tr></tbody></table><p style="text-align:center">Payment: $method | Cashier: $cashierName</p>${(() { final ap = (transaction['amount_paid'] as num?)?.toDouble(); final bc = (transaction['balance_change'] as num?)?.toDouble() ?? 0; if (ap == null) return ''; if (bc == 0) return ''; return '<p style="text-align:center;font-size:11px;font-weight:bold">' + (bc < 0 ? 'Balance Due: Rs. ' + (-bc).toStringAsFixed(2) : 'Credit Added: Rs. ' + bc.toStringAsFixed(2)) + '</p>'; })()}${posFooter.isNotEmpty ? '<p style=\"text-align:center;color:#888;font-size:11px;border-top:1px dashed #ccc;padding-top:8px;margin-top:8px\">$posFooter</p>' : ''}${posTerms.isNotEmpty ? '<p style=\"text-align:center;font-size:9px;color:#aaa;margin-top:6px\">$posTerms</p>' : ''}<script>window.print()</script></body></html>';
          final blob = html.Blob([content], 'text/html'); final url = html.Url.createObjectUrlFromBlob(blob); html.window.open(url, '_blank');
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
      // Filter out fully returned transactions
      final returnedIds = await Supabase.instance.client
          .from('pos_transactions')
          .select('reference_transaction_id')
          .eq('org_id', widget.orgId)
          .eq('transaction_type', 'return');
      final Set<String> returned = {for (final r in returnedIds as List) r['reference_transaction_id'] as String? ?? ''};
      setState(() {
        _transactions = (txns as List).map((t) => Map<String, dynamic>.from(t)).where((t) => !returned.contains(t['id'] as String)).toList();
        _loadingTxns = false;
      });
    } catch (e) { setState(() => _loadingTxns = false); }
  }

  Future<void> _loadItems(Map<String, dynamic> txn) async {
    setState(() { _selectedTxn = txn; _loadingItems = true; _txnItems = []; _selected.clear(); _qtyCtrls.forEach((_, c) => c.dispose()); _qtyCtrls.clear(); });
    try {
      final items = await Supabase.instance.client
          .from('pos_transaction_items')
          .select('*, products(name, sku)')
          .eq('transaction_id', txn['id'] as String)
          .gt('quantity', 0);
      setState(() {
        _txnItems = List<Map<String, dynamic>>.from(items);
        for (final it in _txnItems) {
          final id = it['id'] as String;
          _selected[id] = false;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          _qtyCtrls[id] = TextEditingController(text: qty.toStringAsFixed(0));
        }
        _loadingItems = false;
      });
    } catch (e) { setState(() => _loadingItems = false); }
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _q.toLowerCase();
    return _transactions.where((t) {
      final custName = ((t['pos_customers']?['name'] ?? t['customers']?['shop_name'] ?? '') as String).toLowerCase();
      final txnId = (t['id'] as String? ?? '').toLowerCase();
      final txnNum = (t['transaction_number'] as String? ?? '').toLowerCase();
      final phone = (t['pos_customers']?['phone'] as String? ?? '').toLowerCase();
      final matchSearch = q.isEmpty || custName.contains(q) || txnId.contains(q) || txnNum.contains(q) || phone.contains(q);
      final ts = t['transacted_at'] != null ? DateTime.parse(t['transacted_at'] as String).toLocal() : null;
      final matchFrom = _dateFrom == null || (ts != null && !ts.isBefore(_dateFrom!));
      final matchTo = _dateTo == null || (ts != null && !ts.isAfter(_dateTo!.add(const Duration(days: 1))));
      return matchSearch && matchFrom && matchTo;
    }).toList();
  }

  @override Widget build(BuildContext context) {
    final filtered = _filtered;
    final selectedItems = _txnItems.where((it) => _selected[it['id']] == true).toList();
    final returnTotal = selectedItems.fold(0.0, (s, it) { final qty = double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0; final price = (it['unit_price'] as num?)?.toDouble() ?? 0; final disc = (it['discount'] as num?)?.toDouble() ?? 0; final discType = it['discount_type'] as String? ?? 'fixed'; final origQty = (it['quantity'] as num?)?.toDouble() ?? 1; final discAmt = discType == 'percent' ? price * origQty * (disc/100) : disc; final netPrice = price - (origQty > 0 ? discAmt / origQty : 0); return s + qty * netPrice; });
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
                    Text('Rs. ${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
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
                Expanded(child: _txnItems.isEmpty ? const Center(child: Text('No items found', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView(children: _txnItems.map((it) {
                      final id = it['id'] as String;
                      final name = it['products']?['name'] as String? ?? it['name'] as String? ?? '-';
                      final origQty = (it['quantity'] as num?)?.toDouble() ?? 0;
                      final price = (it['unit_price'] as num?)?.toDouble() ?? 0;
                      return CheckboxListTile(dense: true, value: _selected[id] ?? false, onChanged: (v) => setState(() => _selected[id] = v ?? false),
                        title: Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        subtitle: Builder(builder: (_) { final disc = (it['discount'] as num?)?.toDouble() ?? 0; final discType = it['discount_type'] as String? ?? 'fixed'; final discAmt = discType == 'percent' ? price * origQty * (disc/100) : disc; final discLabel = disc > 0 ? (discType == 'percent' ? ' -${disc.toStringAsFixed(0)}%' : ' -Rs.${discAmt.toStringAsFixed(2)}') : ''; final net = origQty * price - discAmt; return Text('${origQty.toStringAsFixed(0)} × Rs. ${price.toStringAsFixed(2)}$discLabel = Rs. ${net.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)); }),
                        secondary: SizedBox(width: 72, child: TextField(
                          controller: _qtyCtrls[id],
                          decoration: InputDecoration(labelText: 'Return qty', isDense: true, filled: true, fillColor: _selected[id] == true ? Colors.orange.withOpacity(0.08) : Colors.grey.withOpacity(0.05)),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          enabled: _selected[id] == true,
                          onChanged: (_) => setState(() {}),
                        )));
                    }).toList())),
                if (selectedItems.isNotEmpty) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [const Text('Refund Total: ', style: TextStyle(fontWeight: FontWeight.w600)), const Spacer(), Text('Rs. ${returnTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.red, fontSize: 15))])),
              ])),
      ])),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.reply, size: 16),
          label: Text('Process Return${selectedItems.isNotEmpty ? ' — Rs. ${returnTotal.toStringAsFixed(2)}' : ''}'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          onPressed: selectedItems.isEmpty ? null : () async {
            final retItems = selectedItems.map((it) { final qty = double.tryParse(_qtyCtrls[it['id']]?.text ?? '0') ?? 0; return {...it, 'return_qty': qty}; }).toList();
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
          Expanded(child: Text('Rs. ${price.toStringAsFixed(2)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: inCart ? AppTheme.primary : AppTheme.textPrimary))),
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
          Text('Rs. ${widget.lineTotal.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.primary)),
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
