// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../../core/widgets/adaptive_table.dart';
import '../../../core/widgets/adaptive_master_detail.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpCustomerLedgerScreen extends ConsumerStatefulWidget {
  const ErpCustomerLedgerScreen({super.key});
  @override
  ConsumerState<ErpCustomerLedgerScreen> createState() => _ErpCustomerLedgerScreenState();
}

class _ErpCustomerLedgerScreenState extends ConsumerState<ErpCustomerLedgerScreen> {
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _selectedCustomer;
  List<Map<String, dynamic>> _filteredCustomers = [];
  bool _loadingCustomers = true;
  bool _showDropdown = false;
  int _highlightIndex = -1;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _pendingCheques = [];
  List<String> _errors = [];
  bool _loading = false;

  DateTime? _dateFrom;
  DateTime? _dateTo;
  String _typeFilter = 'All';
  final _entrySearchCtrl = TextEditingController();

  static const _types = ['All', 'Sales Invoice', 'Sale Return', 'POS Sale', 'POS Payment', 'POS Return', 'POS Refund (Cash)', 'Receipt (CRV)', 'Payment (CPV)', 'Journal (JV)'];

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _searchCtrl.addListener(_onSearchChanged);
    _entrySearchCtrl.addListener(() => setState(() {}));
    _searchFocus.addListener(() { if (_searchFocus.hasFocus) setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredCustomers = _customers; }); });
  }

  @override
  void dispose() { _searchCtrl.dispose(); _searchFocus.dispose(); _entrySearchCtrl.dispose(); super.dispose(); }

  void _onSearchChanged() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _highlightIndex = -1;
      _showDropdown = true;
      _filteredCustomers = q.isEmpty ? _customers : _customers.where((c) =>
          (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
          (c['code'] as String? ?? '').toLowerCase().contains(q)).toList();
    });
  }

  void _selectCustomer(Map<String, dynamic> c) {
    setState(() {
      _selectedCustomer = c; _entries = []; _pendingCheques = []; _showDropdown = false; _highlightIndex = -1;
      _searchCtrl.text = '${c['shop_name']}${c['code'] != null ? ' (${c['code']})' : ''}';
    });
    _persist();
    _loadLedger(c['id'] as String);
    _loadPendingCheques(c['id'] as String);
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  Future<void> _loadCustomers() async {
    final orgId = _orgId; if (orgId == null) { setState(() => _loadingCustomers = false); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const pageSize = 1000;
      while (true) {
        final page = await Supabase.instance.client.from('customers')
            .select('id, shop_name, code, source').eq('org_id', orgId)
            .order('shop_name').range(from, from + pageSize - 1);
        final list = List<Map<String, dynamic>>.from(page);
        all.addAll(list);
        if (list.length < pageSize) break;
        from += pageSize;
        if (from > 100000) break;
      }
      if (mounted) setState(() { _customers = all; _filteredCustomers = _customers; _loadingCustomers = false; });
      _restoreState();
    } catch (e) {
      if (mounted) setState(() => _loadingCustomers = false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Customers load error: $e'), behavior: SnackBarBehavior.floating));
    }
  }

  void _restoreState() {
    try {
      // Global-search deep link: /erp/customer-ledger?focus=<customer_id>
      // takes priority over the saved (localStorage) selection.
      final href = html.window.location.href;
      final qIdx = href.indexOf('?');
      if (qIdx != -1) {
        final focusId = Uri.splitQueryString(href.substring(qIdx + 1))['focus'];
        if (focusId != null && focusId.isNotEmpty) {
          final fm = _customers.where((c) => c['id'] == focusId).toList();
          if (fm.isNotEmpty) { _selectCustomer(fm.first); return; }
        }
      }
      final s = html.window.localStorage;
      final cid = s['ledger_customer_id'];
      if (cid == null || cid.isEmpty) return;
      final m = _customers.where((c) => c['id'] == cid).toList();
      if (m.isEmpty) return;
      final dfStr = s['ledger_date_from'];
      final dtStr = s['ledger_date_to'];
      if (dfStr != null && dfStr.isNotEmpty) _dateFrom = DateTime.tryParse(dfStr);
      if (dtStr != null && dtStr.isNotEmpty) _dateTo = DateTime.tryParse(dtStr);
      final tf = s['ledger_type_filter'];
      if (tf != null && _types.contains(tf)) _typeFilter = tf;
      _selectCustomer(m.first);
    } catch (_) {}
  }

  void _persist() {
    try {
      final s = html.window.localStorage;
      if (_selectedCustomer != null) s['ledger_customer_id'] = _selectedCustomer!['id'] as String;
      else s.remove('ledger_customer_id');
      if (_dateFrom != null) s['ledger_date_from'] = _dateFrom!.toIso8601String();
      else s.remove('ledger_date_from');
      if (_dateTo != null) s['ledger_date_to'] = _dateTo!.toIso8601String();
      else s.remove('ledger_date_to');
      s['ledger_type_filter'] = _typeFilter;
    } catch (_) {}
  }

  Future<void> _loadLedger(String customerId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() { _loading = true; _entries = []; _errors = []; });
    final client = Supabase.instance.client;
    final List<Map<String, dynamic>> entries = [];
    final List<String> errors = [];

    String extractDate(Map v, List<String> fields) {
      for (final f in fields) {
        final val = v[f];
        if (val == null) continue;
        String? s;
        if (val is String && val.isNotEmpty) s = val;
        else if (val is DateTime) s = val.toIso8601String();
        else { final t = val.toString(); if (t.isNotEmpty && t != 'null') s = t; }
        if (s != null && DateTime.tryParse(s) != null) return s;
      }
      return '';
    }

    // 1. Sales Invoices -> Debit
    try {
      // Org-wide: a customer's receivable is owed to the org, not a branch.
      final sis = await client.from('sales_invoices').select('*, sales_orders(remarks)')
          .eq('org_id', orgId).eq('customer_id', customerId);
      for (final si in sis as List) {
        final total = ((si['total'] ?? si['total_amount'] ?? si['grand_total'] ?? si['net_amount']) as num?)?.toDouble() ?? 0;
        final vno = ((si['invoice_number'] ?? si['voucher_number'] ?? si['si_number'] ?? '') as String);
        final date = extractDate(si as Map, const ['voucher_date', 'invoice_date', 'si_date', 'date', 'posted_at', 'created_at']);
        if (total > 0) {
          final siRmk = (si['remarks'] as String?)?.trim() ?? '';
          final soRmk = (si['sales_orders']?['remarks'] as String?)?.trim() ?? '';
          final rmk = siRmk.isNotEmpty ? siRmk : soRmk;
          entries.add({
            'date': date, 'voucher': vno,
            'description': rmk,
            'debit': total, 'credit': 0.0, 'id': si['id'] as String?, 'type': 'Sales Invoice',
          });
        }
      }
    } catch (e) { errors.add('SI: ' + e.toString()); }

    // 2. POS Transactions -> Sale or Return
    try {
      final List posTxns = await client.from('pos_transactions').select('*')
          .eq('org_id', orgId).eq('customer_id', customerId);
      final posMap = <String, Map<String, dynamic>>{};
      for (final t in posTxns as List) {
        final tid = t['id'];
        if (tid is String) posMap[tid] = Map<String, dynamic>.from(t as Map);
      }
      for (final t in posTxns) {
        final ttotalRaw = (t['total'] as num?)?.toDouble() ?? 0;
        final ttype = (t['transaction_type'] as String?) ?? 'sale';
        if (ttype == 'expense' || ttotalRaw == 0) continue;
        final vnoRaw = ((t['transaction_number'] ?? '') as String);
        final tid = (t['id'] as String? ?? '');
        final shortTid = tid.length > 8 ? tid.substring(tid.length - 8) : tid;
        final vno = vnoRaw.isNotEmpty ? vnoRaw : ('POS-' + shortTid);
        final isReturn = ttype == 'return' || ttotalRaw < 0;
        final amt = ttotalRaw.abs();
        String refTrxNo = '';
        Map<String, dynamic>? origTxn;
        if (isReturn) {
          for (final f in const ['reference_transaction_id', 'original_transaction_id', 'parent_transaction_id', 'ref_transaction_id', 'reference_id']) {
            final refId = t[f];
            if (refId is String && refId.isNotEmpty) {
              final orig = posMap[refId];
              if (orig != null) {
                origTxn = orig;
                refTrxNo = (orig['transaction_number'] as String?) ?? '';
              }
              break;
            }
          }
        }

        // A customer ledger should be a COMPLETE account of the relationship,
        // not just the unpaid slice — so every POS transaction is shown at full
        // value, followed by whatever was settled on the spot. The balance then
        // nets to what is actually outstanding.
        //
        //   Cash sale 4,940 →  Dr 4,940 (sale)  then  Cr 4,940 (cash paid)  → bal 0
        //   Credit sale     →  Dr full          , no settlement line         → bal = full
        //   Part-paid 5,000/2,000 → Dr 5,000, Cr 2,000                       → bal 3,000
        //
        // Previously the ledger debited the full total and never credited the
        // cash paid, so a cash sale looked like an unpaid receivable (Hamza
        // Abbas Bakhsh: 4,940 cash sale showing as 4,940 owed, while POS Customer
        // History and the GL both correctly said 0.00).
        //
        // The settlement line is SYNTHESISED from amount_paid, not read from a
        // document: post_pos_money books a cash sale straight to Dr Cash / Cr POS
        // Sales with no CRV, so nothing else in this ledger credits it and there
        // is no double-count risk.
        final dateStr = ((t['transacted_at'] ?? t['created_at'] ?? '') as String);

        if (isReturn) {
          // Full return value credited back to the customer…
          entries.add({
            'date': dateStr,
            'voucher': vno,
            'description': refTrxNo.isNotEmpty ? 'Ref ' + refTrxNo : '',
            'debit': 0.0,
            'credit': amt,
            'id': tid.isNotEmpty ? tid : null, 'type': 'POS Return',
          });
          // …less the part handed back in cash from the drawer, which never
          // touched the account. Only the credit portion of the ORIGINAL sale
          // stays on the ledger.
          double cashRefund = amt;
          if (origTxn != null) {
            final origTotal = (origTxn['total'] as num?)?.toDouble() ?? 0;
            final origPaid = (origTxn['amount_paid'] as num?)?.toDouble() ?? origTotal;
            final arPortion = (origTotal - origPaid).clamp(0.0, amt).toDouble();
            cashRefund = amt - arPortion;
          } else {
            cashRefund = 0; // original unknown — leave the credit on the account
          }
          if (cashRefund > 0) {
            entries.add({
              'date': dateStr,
              'voucher': vno,
              'description': 'Cash refund',
              'debit': cashRefund,
              'credit': 0.0,
              'id': tid.isNotEmpty ? tid : null, 'type': 'POS Refund (Cash)',
            });
          }
        } else {
          // The sale, at full value.
          entries.add({
            'date': dateStr,
            'voucher': vno,
            'description': '',
            'debit': amt,
            'credit': 0.0,
            'id': tid.isNotEmpty ? tid : null, 'type': 'POS Sale',
          });
          // Whatever was paid at the till, settling it then and there.
          final paid = ((t['amount_paid'] as num?)?.toDouble() ?? amt).clamp(0.0, amt).toDouble();
          if (paid > 0) {
            entries.add({
              'date': dateStr,
              'voucher': vno,
              'description': 'Paid at POS',
              'debit': 0.0,
              'credit': paid,
              'id': tid.isNotEmpty ? tid : null, 'type': 'POS Payment',
            });
          }
        }
      }
    } catch (e) { errors.add('POS: ' + e.toString()); }

    // 3. Sale Return Invoices (SRI) -> Credit
    String? sriTable;
    int sriRows = 0;
    int sriAdded = 0;
    Map? firstSriRow;
    for (final tbl in const ['sales_return_invoices', 'sale_return_invoices', 'sales_returns', 'sale_returns', 'sri_vouchers', 'srn_vouchers', 'sri']) {
      try {
        final rows = await client.from(tbl).select('*')
            .eq('org_id', orgId).eq('customer_id', customerId);
        sriTable = tbl;
        sriRows = (rows as List).length;
        if (sriRows > 0) firstSriRow = rows.first as Map;
        for (final sr in rows) {
          final total = ((sr['total'] ?? sr['total_amount'] ?? sr['grand_total'] ?? sr['amount'] ?? sr['net_amount'] ?? sr['return_total'] ?? sr['refund_amount'] ?? sr['value'] ?? sr['subtotal']) as num?)?.toDouble() ?? 0;
          final vno = ((sr['invoice_number'] ?? sr['return_number'] ?? sr['srn_number'] ?? sr['sri_number'] ?? sr['voucher_number'] ?? sr['return_no'] ?? '') as String);
          final date = extractDate(sr as Map, const ['return_date', 'invoice_date', 'voucher_date', 'sri_date', 'srn_date', 'date', 'posted_at', 'created_at']);
          if (total > 0) {
            entries.add({
              'date': date, 'voucher': vno,
              'description': (sr['remarks'] as String?)?.trim() ?? '',
              'debit': 0.0, 'credit': total, 'id': sr['id'] as String?, 'type': 'Sale Return',
            });
            sriAdded++;
          }
        }
        break;
      } catch (_) { continue; }
    }
    // SRI diagnostics removed: a customer with no sale returns is a normal
    // state, not an error worth surfacing in a banner. Real load exceptions are
    // still reported via the catch blocks above. (sriTable/sriRows/sriAdded/
    // firstSriRow remain assigned in the loop but are no longer read -- the
    // resulting analyzer infos are harmless and do not fail the build.)

    // 4. CRV -> Credit (customer paid us)
    try {
      final crvVouchers = await client.from('crv_vouchers')
          .select('*').eq('org_id', orgId).eq('status', 'posted');
      final crvIds = (crvVouchers as List).map((v) => v['id'] as String).toList();
      if (crvIds.isNotEmpty) {
        final crvLines = await client.from('crv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', customerId).eq('account_type', 'customer').inFilter('voucher_id', crvIds);
        final crvMap = {for (final v in crvVouchers) v['id'] as String: v};
        Map? firstNoDate;
        for (final line in crvLines as List) {
          final v = crvMap[line['voucher_id'] as String]; if (v == null) continue;
          final date = extractDate(v as Map, const ['voucher_date', 'value_date', 'transaction_date', 'date', 'posted_at', 'posted_date', 'created_at', 'created_date', 'updated_at']);
          if (date.isEmpty && firstNoDate == null) firstNoDate = v;
          entries.add({
            'date': date,
            'voucher': (v['voucher_number'] as String?) ?? '',
            'description': (line['description'] as String?)?.trim() ?? '',
            'debit': 0.0, 'credit': (line['amount'] as num?)?.toDouble() ?? 0,
            'id': v['id'] as String?, 'type': 'Receipt (CRV)',
          });
        }
        if (firstNoDate != null) {
          final fields = firstNoDate.keys.toList().join(', ');
          errors.add('CRV missing date. Available fields: ' + fields);
          for (final f in const ['voucher_date', 'posted_at', 'created_at']) {
            errors.add('CRV.' + f + ' = ' + (firstNoDate[f]?.toString() ?? 'null'));
          }
        }
      }
    } catch (e) { errors.add('CRV: ' + e.toString()); }

    // 5. CPV -> Debit (we paid customer)
    try {
      final cpvVouchers = await client.from('cpv_vouchers')
          .select('*').eq('org_id', orgId).eq('status', 'posted');
      final cpvIds = (cpvVouchers as List).map((v) => v['id'] as String).toList();
      if (cpvIds.isNotEmpty) {
        final cpvLines = await client.from('cpv_voucher_lines')
            .select('amount, description, voucher_id')
            .eq('account_id', customerId).eq('account_type', 'customer').inFilter('voucher_id', cpvIds);
        final cpvMap = {for (final v in cpvVouchers) v['id'] as String: v};
        for (final line in cpvLines as List) {
          final v = cpvMap[line['voucher_id'] as String]; if (v == null) continue;
          final date = extractDate(v as Map, const ['voucher_date', 'value_date', 'transaction_date', 'date', 'posted_at', 'posted_date', 'created_at', 'created_date', 'updated_at']);
          entries.add({
            'date': date,
            'voucher': (v['voucher_number'] as String?) ?? '',
            'description': (line['description'] as String?)?.trim() ?? '',
            'debit': (line['amount'] as num?)?.toDouble() ?? 0,
            'credit': 0.0, 'id': v['id'] as String?, 'type': 'Payment (CPV)',
          });
        }
      }
    } catch (e) { errors.add('CPV: ' + e.toString()); }

    // 6. Journal Vouchers (JV) touching this party (posted only)
    try {
      final jvHeaders = await client.from('journal_entries')
          .select('id, entry_number, entry_date, description, posted_at, created_at, status, reference_type')
          .eq('org_id', orgId)
          .inFilter('reference_type', const ['jv', 'opening_jv', 'opening_balance'])
          .eq('status', 'posted');
      final jvMap = {for (final v in jvHeaders as List) v['id'] as String: v};
      if (jvMap.isNotEmpty) {
        final jvLines = await client.from('journal_lines')
            .select('entry_id, debit, credit, description, party_id, account_type')
            .eq('party_id', customerId).inFilter('entry_id', jvMap.keys.toList());
        for (final line in jvLines as List) {
          final v = jvMap[line['entry_id'] as String]; if (v == null) continue;
          final refType = (v['reference_type'] as String?) ?? 'jv';
          final isOpening = refType == 'opening_jv' || refType == 'opening_balance';
          final date = extractDate(v as Map, const ['entry_date', 'posted_at', 'created_at']);
          final vno = (v['entry_number'] as String?) ?? '';
          final lineDesc = (line['description'] as String?) ?? '';
          entries.add({
            'date': date, 'voucher': vno,
            'description': lineDesc.isNotEmpty ? lineDesc : ((v['description'] as String?)?.trim() ?? ''),
            'debit': (line['debit'] as num?)?.toDouble() ?? 0,
            'credit': (line['credit'] as num?)?.toDouble() ?? 0,
            'id': v['id'] as String?, 'type': isOpening ? 'Opening Balance' : 'Journal (JV)',
          });
        }
      }
    } catch (e) { errors.add('JV: ' + e.toString()); }

    // Dart's sort is not stable, so entries sharing a timestamp (a POS sale and
    // the payment that settles it are written with the same transacted_at) could
    // otherwise come out payment-first, making the running balance dip negative.
    // _seq orders them: the document line, then its settlement.
    int seqOf(Map<String, dynamic> e) {
      switch (e['type'] as String? ?? '') {
        case 'POS Payment':
        case 'POS Refund (Cash)':
          return 1; // settlement always follows the document it settles
        default:
          return 0;
      }
    }
    entries.sort((a, b) {
      final d = (a['date'] as String).compareTo(b['date'] as String);
      if (d != 0) return d;
      return seqOf(a).compareTo(seqOf(b));
    });
    double bal = 0;
    for (final e in entries) { bal += (e['debit'] as double) - (e['credit'] as double); e['balance'] = bal; }
    setState(() { _entries = entries; _loading = false; _errors = errors; });
  }

  // Pending post-dated cheques (BRV lines) for the selected customer. These are
  // memo-only: they have no GL entry, so they are NOT part of _entries / balance
  // / aging. Shown in a separate card so collections are visible.
  Future<void> _loadPendingCheques(String customerId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;
      // Customer is per-LINE in the PDC schema, so filter the lines directly.
      final lines = await client
          .from('pdc_voucher_lines')
          .select('voucher_id, bank, description, cheque_no, cheque_date, amount, status')
          .eq('org_id', orgId)
          .eq('customer_id', customerId)
          .eq('status', 'pending');
      final lineList = List<Map<String, dynamic>>.from(lines as List);
      if (lineList.isEmpty) {
        if (mounted) setState(() => _pendingCheques = []);
        return;
      }
      final vids =
          lineList.map((l) => l['voucher_id'] as String).toSet().toList();
      final hdrs = await client
          .from('pdc_vouchers')
          .select('id, voucher_number')
          .inFilter('id', vids);
      final numById = {
        for (final h in hdrs as List)
          h['id'] as String: (h['voucher_number'] as String? ?? '')
      };
      final list = lineList
          .map((l) => {
                'voucher_number': numById[l['voucher_id']] ?? '',
                'bank': l['bank'] as String? ?? '',
                'description': l['description'] as String? ?? '',
                'cheque_no': l['cheque_no'] as String? ?? '',
                'cheque_date': l['cheque_date'] as String?,
                'amount': (l['amount'] as num?)?.toDouble() ?? 0.0,
              })
          .toList();
      list.sort((a, b) => (a['cheque_date'] as String? ?? '')
          .compareTo(b['cheque_date'] as String? ?? ''));
      if (mounted) setState(() => _pendingCheques = list);
    } catch (_) {
      if (mounted) setState(() => _pendingCheques = []);
    }
  }

  Widget _buildPdcCard() {
    final total =
        _pendingCheques.fold<double>(0, (s, c) => s + (c['amount'] as double));
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.orange.withOpacity(0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          child: Row(children: [
            const Icon(Icons.schedule, size: 16, color: Colors.orange),
            const SizedBox(width: 8),
            const Text('Pending Cheques (PDC)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(width: 10),
            const Expanded(
                child: Text(
                    'Memo only — not included in the balance or aging until cleared',
                    style:
                        TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            Text('Rs. ${total.toStringAsFixed(2)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Colors.orange)),
          ]),
        ),
        const Divider(height: 1),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _pendingCheques.length,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: AppTheme.border),
            itemBuilder: (_, i) {
              final c = _pendingCheques[i];
              final cd = c['cheque_date'] as String?;
              final dt = cd != null ? DateTime.tryParse(cd) : null;
              final dateStr = dt != null ? DateFormat('d MMM yy').format(dt) : '-';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Row(children: [
                  SizedBox(
                      width: 110,
                      child: Text(c['voucher_number'] as String,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600))),
                  SizedBox(
                      width: 90,
                      child: Text(dateStr,
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary))),
                  Expanded(
                      child: Text(
                          [
                            if ((c['cheque_no'] as String? ?? '').isNotEmpty)
                              'Chq ${c['cheque_no']}',
                            if ((c['bank'] as String? ?? '').isNotEmpty)
                              c['bank'] as String,
                            if ((c['description'] as String? ?? '').isNotEmpty)
                              c['description'] as String,
                          ].join(' • '),
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis)),
                  Text('Rs. ${(c['amount'] as double).toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }

  List<Map<String, dynamic>> get _displayEntries {
    var list = _entries.where((e) {
      if (_typeFilter != 'All' && e['type'] != _typeFilter) return false;
      final ds = e['date'] as String? ?? '';
      if (ds.length >= 10) {
        final d = DateTime.tryParse(ds);
        if (d != null) {
          if (_dateFrom != null && d.isBefore(_dateFrom!)) return false;
          if (_dateTo != null && d.isAfter(_dateTo!.add(const Duration(days: 1)))) return false;
        }
      }
      final q = _entrySearchCtrl.text.toLowerCase();
      if (q.isNotEmpty) {
        if (!(e['description'] as String).toLowerCase().contains(q) && !(e['voucher'] as String).toLowerCase().contains(q)) return false;
      }
      return true;
    }).toList();
    // Recalculate running balance for filtered view
    double rb = 0;
    return list.map((e) { rb += (e['debit'] as double) - (e['credit'] as double); return {...e, 'display_balance': rb}; }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(selectedBranchProvider);
    final display = _displayEntries;
    double totalDebit = 0, totalCredit = 0;
    for (final e in display) { totalDebit += e['debit'] as double; totalCredit += e['credit'] as double; }
    final netBal = totalDebit - totalCredit;
    final maxDrop = _filteredCustomers.length.clamp(0, 50);

    return GestureDetector(
      onTap: () { if (_showDropdown) setState(() => _showDropdown = false); },
      child: Container(
        color: AppTheme.background, padding: context.pagePadding,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Desktop: title left, actions pinned hard right (a Wrap with
          // spaceBetween collapses to "buttons hugging the title" once the title
          // is narrow). Mobile: title on its own line, actions wrapping beneath.
          if (context.isMobile) ...[
            Text('Customer Ledger', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            if (_selectedCustomer != null && _entries.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_outlined, size: 15),
                    label: Text(
                      _dateFrom == null && _dateTo == null ? 'Date Range'
                        : '${_dateFrom == null ? '…' : DateFormat('d MMM').format(_dateFrom!)} – ${_dateTo == null ? '…' : DateFormat('d MMM').format(_dateTo!)}',
                      style: const TextStyle(fontSize: 12)),
                    onPressed: _pickDateRange,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                  ),
                  OutlinedButton.icon(
                    icon: _agingLoading
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.hourglass_bottom_outlined, size: 16, color: Colors.orange.shade800),
                    label: Text('Show Aging', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                    onPressed: _agingLoading ? null : _showAging,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      side: BorderSide(color: Colors.orange.shade300)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.print_outlined, size: 16),
                    label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
                    onPressed: _printLedger,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                  ),
                  OutlinedButton.icon(
                    icon: Icon(Icons.table_chart_outlined, size: 16, color: Colors.green.shade700),
                    label: Text('Export Excel', style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
                    onPressed: _exportCsv,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), side: BorderSide(color: Colors.green.shade300)),
                  ),
                ]),
            ],
          ] else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Customer Ledger', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                Text(branch == null ? 'All Branches' : 'Branch: ${branch['name']}',
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
              ]),
              const Spacer(),
              if (_selectedCustomer != null && _entries.isNotEmpty)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.calendar_today_outlined, size: 15),
                    label: Text(
                      _dateFrom == null && _dateTo == null ? 'Date Range'
                        : '${_dateFrom == null ? '…' : DateFormat('d MMM').format(_dateFrom!)} – ${_dateTo == null ? '…' : DateFormat('d MMM').format(_dateTo!)}',
                      style: const TextStyle(fontSize: 12)),
                    onPressed: _pickDateRange,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                  ),
                  OutlinedButton.icon(
                    icon: _agingLoading
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.hourglass_bottom_outlined, size: 16, color: Colors.orange.shade800),
                    label: Text('Show Aging', style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                    onPressed: _agingLoading ? null : _showAging,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      side: BorderSide(color: Colors.orange.shade300)),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.print_outlined, size: 16),
                    label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
                    onPressed: _printLedger,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                  ),
                  OutlinedButton.icon(
                    icon: Icon(Icons.table_chart_outlined, size: 16, color: Colors.green.shade700),
                    label: Text('Export Excel', style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
                    onPressed: _exportCsv,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), side: BorderSide(color: Colors.green.shade300)),
                  ),
                ]),
            ]),
          const SizedBox(height: 16),
          if (_errors.isNotEmpty) Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.shade300)),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_errors.join(' | '), style: TextStyle(fontSize: 11, color: Colors.orange.shade900))),
              IconButton(icon: Icon(Icons.close, size: 14, color: Colors.orange.shade700), onPressed: () => setState(() => _errors = []), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 340, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Focus(
                onKeyEvent: (_, event) {
                  if (!_showDropdown || event is! KeyDownEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowDown) { setState(() => _highlightIndex = (_highlightIndex + 1).clamp(0, maxDrop - 1)); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp) { setState(() => _highlightIndex = (_highlightIndex - 1).clamp(0, maxDrop - 1)); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.enter && _highlightIndex >= 0 && _highlightIndex < maxDrop) { _selectCustomer(_filteredCustomers[_highlightIndex]); return KeyEventResult.handled; }
                  if (event.logicalKey == LogicalKeyboardKey.escape) { setState(() => _showDropdown = false); return KeyEventResult.handled; }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _searchCtrl, focusNode: _searchFocus,
                  decoration: InputDecoration(
                    labelText: 'Search Customer', hintText: 'Name or code...',
                    prefixIcon: const Icon(Icons.search, size: 18), isDense: true,
                    suffixIcon: _selectedCustomer != null ? IconButton(icon: const Icon(Icons.close, size: 16),
                        onPressed: () { setState(() { _selectedCustomer = null; _entries = []; _pendingCheques = []; _searchCtrl.clear(); _showDropdown = false; }); try { html.window.localStorage.remove('ledger_customer_id'); } catch (_) {} }) : null,
                  ),
                  onTap: () => setState(() { _showDropdown = true; if (_searchCtrl.text.isEmpty) _filteredCustomers = _customers; }),
                ),
              ),
              if (_showDropdown && _filteredCustomers.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 260), width: 340,
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))]),
                  child: ListView.separated(
                    shrinkWrap: true, itemCount: maxDrop, separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _filteredCustomers[i]; final hi = i == _highlightIndex;
                      return InkWell(
                        onTap: () => _selectCustomer(c),
                        child: Container(
                          color: hi ? AppTheme.primary.withOpacity(0.08) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(children: [
                            Expanded(child: Text(c['shop_name'] as String? ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
                            if (c['source'] == 'pos') Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.purple.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                              child: const Text('POS', style: TextStyle(fontSize: 10, color: Colors.purple, fontWeight: FontWeight.w700)),
                            ),
                            if (c['code'] != null) Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(4)),
                              child: Text(c['code'] as String, style: TextStyle(fontSize: 10, color: AppTheme.primary, fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
            ])),
            if (_selectedCustomer != null) ...[
              if (_dateFrom != null || _dateTo != null) ...[
                const SizedBox(width: 6),
                TextButton(onPressed: () => setState(() { _dateFrom = null; _dateTo = null; }), child: const Text('Clear', style: TextStyle(fontSize: 12))),
              ],
            ],
          ]),
          const SizedBox(height: 12),
          if (_selectedCustomer != null && _entries.isNotEmpty) ...[
            // Three stats in a Row give ~70px each on a phone — enough to stack
            // "N-e-t" vertically. Wrap gives them a real width instead.
            AdaptiveKpiRow(children: [
              _Stat(label: 'Total Debit', value: 'Rs. ${totalDebit.toStringAsFixed(2)}', color: AppTheme.primary),
              _Stat(label: 'Total Credit', value: 'Rs. ${totalCredit.toStringAsFixed(2)}', color: Colors.green.shade700),
              _Stat(label: 'Net Balance', value: 'Rs. ${netBal.toStringAsFixed(2)}', color: netBal > 0 ? AppTheme.danger : Colors.green.shade700),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: _entrySearchCtrl, decoration: const InputDecoration(hintText: 'Search entries...', prefixIcon: Icon(Icons.search, size: 16), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 8)))),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  value: _typeFilter, isDense: true,
                  items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(fontSize: 12)))).toList(),
                  onChanged: (v) { setState(() => _typeFilter = v ?? 'All'); _persist(); },
                )),
              ),
            ]),
            const SizedBox(height: 12),
          ],
          if (!_loading && _selectedCustomer != null && _pendingCheques.isNotEmpty) _buildPdcCard(),
          if (_loading) const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_selectedCustomer == null) Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.person_search_outlined, size: 52, color: AppTheme.textSecondary.withOpacity(0.3)),
            const SizedBox(height: 12),
            const Text('Search and select a customer to view their ledger', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          ])))
          else Expanded(child: AdaptiveTable<Map<String, dynamic>>(
            rows: display,
            empty: const Center(child: Text('No transactions found.', style: TextStyle(color: AppTheme.textSecondary))),
            columns: [
              AdaptiveColumn(
                label: 'Date', width: 90,
                cell: (e) {
                  final dt = DateTime.tryParse(e['date'] as String? ?? '');
                  return Text(dt != null ? DateFormat('d MMM yy').format(dt) : '-', style: const TextStyle(fontSize: 12));
                },
              ),
              // Voucher is the card title on mobile: it is the thing you scan for.
              AdaptiveColumn(
                label: 'Voucher', width: 100, isTitle: true,
                cell: (e) => MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openVoucher(e),
                    child: Text(e['voucher'] as String? ?? '',
                      style: TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                      overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              AdaptiveColumn(
                label: 'Description', width: null,
                cell: (e) => Text(e['description'] as String, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
              ),
              AdaptiveColumn(
                label: 'Type', width: 80,
                cell: (e) {
                  final type = e['type'] as String;
                  return Align(alignment: Alignment.centerLeft, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: _typeColor(type).withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                    child: Text(type, style: TextStyle(fontSize: 9, color: _typeColor(type), fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                  ));
                },
              ),
              AdaptiveColumn(
                label: 'Debit', width: 110, align: TextAlign.right,
                cell: (e) {
                  final d = e['debit'] as double;
                  return Text(d > 0 ? 'Rs. ${d.toStringAsFixed(2)}' : '-',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: d > 0 ? AppTheme.primary : Colors.black26));
                },
              ),
              AdaptiveColumn(
                label: 'Credit', width: 110, align: TextAlign.right,
                cell: (e) {
                  final c = e['credit'] as double;
                  return Text(c > 0 ? 'Rs. ${c.toStringAsFixed(2)}' : '-',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c > 0 ? Colors.green.shade700 : Colors.black26));
                },
              ),
              // Balance is the trailing figure on the mobile card — the number
              // a shopkeeper or an owner actually opens the ledger to see.
              AdaptiveColumn(
                label: 'Balance', width: 110, align: TextAlign.right, isTrailing: true,
                cell: (e) {
                  final b = e['display_balance'] as double;
                  return Text('Rs. ${b.toStringAsFixed(2)}',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: b > 0 ? AppTheme.danger : Colors.green.shade700));
                },
              ),
            ],
            footer: display.isEmpty ? null : Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                border: const Border(top: BorderSide(color: AppTheme.border)),
              ),
              child: Row(children: [
                Expanded(child: Text('${display.length} entries', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                Text('Rs. ${netBal.toStringAsFixed(2)}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: netBal > 0 ? AppTheme.danger : Colors.green.shade700)),
              ]),
            ),
          )),
        ]),
      ),
    );
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'Sales Invoice': return Colors.indigo;
      case 'POS Sale': return Colors.purple;
      case 'POS Return': return Colors.deepOrange;
      case 'Sale Return': return Colors.amber.shade800;
      case 'Receipt (CRV)': return Colors.green;
      case 'Payment (CPV)': return Colors.orange;
      case 'Journal (JV)': return Colors.teal;
      default: return AppTheme.textSecondary;
    }
  }

  /// The date-range picker, lifted out of the old inline button so the header
  /// group and any future caller share one implementation.
  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: (_dateFrom != null && _dateTo != null)
          ? DateTimeRange(start: _dateFrom!, end: _dateTo!) : null,
    );
    if (picked != null && mounted) {
      setState(() { _dateFrom = picked.start; _dateTo = picked.end; });
    }
  }

  /// Aging for the selected customer, straight from `rpc_customer_aging` — the
  /// same RPC Customer 360 and the Aging report use, so the buckets cannot drift
  /// from those screens.
  ///
  /// Deliberately fetches BEFORE showing anything. The previous version showed a
  /// spinner dialog and then popped it, but `Navigator.of(context)` here is the
  /// screen's navigator, not the dialog's — so the pop unwound the go_router
  /// route instead, leaving a white screen.
  bool _agingLoading = false;

  Future<void> _showAging() async {
    final cust = _selectedCustomer;
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (cust == null || orgId == null || _agingLoading) return;
    final custId = cust['id'] as String;

    setState(() => _agingLoading = true);

    // The RPC returns FIVE buckets: cur (0-30), b1 (31-60), b2 (61-90),
    // b3 (91-120), b4 (120+). Reading b1..b4 as if they were 0-30..60+ shifted
    // every figure one bucket and silently dropped `cur` — the popup showed
    // 31-60's value under "Current" and lost 15,010 entirely.
    double cur = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, net = 0;
    final items = <Map<String, dynamic>>[];
    String? err;
    try {
      final client = Supabase.instance.client;
      final asOf = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final params = {'p_org_id': orgId, 'p_as_of': asOf};

      final agg = await client.rpc('rpc_customer_aging', params: params) as List;
      for (final a in agg) {
        if ((a as Map)['customer_id'] == custId) {
          cur = (a['cur'] as num?)?.toDouble() ?? 0;
          b1 = (a['b1'] as num?)?.toDouble() ?? 0;
          b2 = (a['b2'] as num?)?.toDouble() ?? 0;
          b3 = (a['b3'] as num?)?.toDouble() ?? 0;
          b4 = (a['b4'] as num?)?.toDouble() ?? 0;
          net = (a['total'] as num?)?.toDouble() ?? 0;
          break;
        }
      }
      // Drill-down is best-effort: the buckets are the point.
      try {
        final det = await client.rpc('rpc_customer_aging_detail', params: params) as List;
        for (final d in det) {
          final m = d as Map;
          if (m['customer_id'] != custId) continue;
          items.add({
            'voucher': (m['reference_number'] as String?) ?? '-',
            'date': DateTime.tryParse('${m['ref_date']}'),
            'amount': (m['open_amt'] as num?)?.toDouble() ?? 0,
            'age': (m['age_days'] as num?)?.toInt() ?? 0,
          });
        }
        items.sort((a, b) => (b['age'] as int).compareTo(a['age'] as int));
      } catch (_) {}
    } catch (e) {
      err = '$e';
    }

    if (!mounted) return;
    setState(() => _agingLoading = false);

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Aging — ${cust['shop_name'] ?? ''}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          Text('As of ${DateFormat('d MMM yyyy').format(DateTime.now())}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w400)),
        ]),
        content: SizedBox(
          width: context.isMobile ? double.maxFinite : 520,
          child: err != null
            ? Text('Could not load aging: $err',
                style: const TextStyle(fontSize: 12, color: AppTheme.danger))
            : SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Plain Wrap, not AdaptiveKpiRow: inside a dialog the width is
                // unbounded, and Expanded in an unbounded Row throws.
                LayoutBuilder(builder: (_, c) {
                  final w = c.maxWidth.isFinite
                      ? (c.maxWidth - 10) / 2
                      : 150.0;
                  // Same five buckets and the same boundaries as the Customer
                  // Aging report, so the two can never disagree.
                  return Wrap(spacing: 10, runSpacing: 10, children: [
                    SizedBox(width: w, child: _AgeBucket(label: 'Current (0–30)', value: cur, color: Colors.green.shade700)),
                    SizedBox(width: w, child: _AgeBucket(label: '31–60 days', value: b1, color: Colors.orange)),
                    SizedBox(width: w, child: _AgeBucket(label: '61–90 days', value: b2, color: Colors.deepOrange)),
                    SizedBox(width: w, child: _AgeBucket(label: '91–120 days', value: b3, color: Colors.red.shade600)),
                    SizedBox(width: w, child: _AgeBucket(label: '120+ days', value: b4, color: AppTheme.danger)),
                  ]);
                }),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.background,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(children: [
                    const Text('Total Outstanding', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('Rs. ${net.toStringAsFixed(2)}',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                            color: net > 0 ? AppTheme.danger : Colors.green.shade700)),
                  ]),
                ),
                if (items.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Open documents',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                  const SizedBox(height: 6),
                  for (final it in items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        SizedBox(width: 104, child: Text(it['voucher'] as String,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis)),
                        Expanded(child: Text(
                            it['date'] == null ? '-' : DateFormat('d MMM yy').format(it['date'] as DateTime),
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
                        Text('${it['age']}d  ',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                                color: (it['age'] as int) > 60 ? AppTheme.danger
                                     : (it['age'] as int) > 30 ? Colors.deepOrange
                                     : AppTheme.textSecondary)),
                        Text('Rs. ${(it['amount'] as double).toStringAsFixed(2)}',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                ],
              ])),
        ),
        actions: [
          TextButton(
            // Pop the DIALOG's navigator, not the screen's.
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _exportCsv() {
    final display = _displayEntries;
    if (display.isEmpty || _selectedCustomer == null) return;
    final branch = ref.read(selectedBranchProvider);
    final buf = StringBuffer();
    String esc(String s) => '"' + s.replaceAll('"', '""') + '"';
    final cust = _selectedCustomer!;
    final custLabel = '${cust['shop_name']}${cust['code'] != null ? ' (${cust['code']})' : ''}';
    buf.writeln('Customer Ledger');
    buf.writeln('Customer,' + esc(custLabel));
    buf.writeln('Branch,' + esc((branch?['name'] as String?) ?? 'All Branches'));
    if (_dateFrom != null) buf.writeln('From,' + DateFormat('yyyy-MM-dd').format(_dateFrom!));
    if (_dateTo != null) buf.writeln('To,' + DateFormat('yyyy-MM-dd').format(_dateTo!));
    buf.writeln('Generated,' + DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
    buf.writeln('');
    buf.writeln('Date,Voucher,Description,Type,Debit,Credit,Balance');
    double td = 0, tc = 0;
    for (final e in display) {
      final ds = e['date'] as String? ?? '';
      final dt = DateTime.tryParse(ds); final date = dt != null ? DateFormat('yyyy-MM-dd').format(dt) : '';
      td += e['debit'] as double; tc += e['credit'] as double;
      buf.writeln([date, esc(e['voucher'] as String? ?? ''), esc(e['description'] as String), esc(e['type'] as String), (e['debit'] as double).toStringAsFixed(2), (e['credit'] as double).toStringAsFixed(2), (e['display_balance'] as double).toStringAsFixed(2)].join(','));
    }
    buf.writeln(',,,Total,' + td.toStringAsFixed(2) + ',' + tc.toStringAsFixed(2) + ',' + (td - tc).toStringAsFixed(2));
    final csvContent = String.fromCharCode(0xFEFF) + buf.toString();
    final blob = html.Blob([csvContent], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final safeName = (cust['shop_name'] as String).replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final filename = 'ledger_' + safeName + '_' + DateFormat('yyyyMMdd').format(DateTime.now()) + '.csv';
    final anchor = html.AnchorElement(href: url)..download = filename..style.display = 'none';
    html.document.body!.append(anchor);
    anchor.click();
    Future.delayed(const Duration(seconds: 5), () { anchor.remove(); html.Url.revokeObjectUrl(url); });
  }

  Future<void> _openVoucher(Map<String, dynamic> entry) async {
    final id = entry['id'] as String?;
    final type = entry['type'] as String;
    if (id == null || id.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No voucher ID to open')));
      return;
    }
    if (type == 'Journal (JV)') {
      final vno = entry['voucher'] as String? ?? '';
      final href = html.window.location.href; final hIdx = href.indexOf('#');
      final origin = hIdx != -1 ? href.substring(0, hIdx) : href;
      html.window.open(origin + '#/financials/journal-vouchers?id=' + vno, '_blank');
      return;
    }
    Map<String, dynamic>? voucher;
    List<dynamic> lines = [];
    String? err;
    try {
      final client = Supabase.instance.client;
      switch (type) {
        case 'Sales Invoice':
          voucher = await client.from('sales_invoices').select('*, customers(shop_name, code)').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('sales_invoice_items').select('*, products(name, sku)').eq('invoice_id', id);
          break;
        case 'Sale Return':
          voucher = await client.from('sales_return_invoices').select('*, customers(shop_name, code)').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('sales_return_invoice_items').select('*, products(name, sku)').eq('invoice_id', id);
          break;
        case 'POS Sale':
        case 'POS Return':
          voucher = await client.from('pos_transactions').select('*, customers(shop_name, code)').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('pos_transaction_items').select('*, products(name, sku)').eq('transaction_id', id);
          break;
        case 'Receipt (CRV)':
          voucher = await client.from('crv_vouchers').select('*').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('crv_voucher_lines').select('*').eq('voucher_id', id);
          break;
        case 'Payment (CPV)':
          voucher = await client.from('cpv_vouchers').select('*').eq('id', id).maybeSingle();
          if (voucher != null) lines = await client.from('cpv_voucher_lines').select('*').eq('voucher_id', id);
          break;
      }
    } catch (e) { err = e.toString(); }
    if (!mounted) return;
    final v = voucher;
    if (v == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load: ' + (err ?? 'not found'))));
      return;
    }
    // Related-document cross-refs + creator name.
    final refs = <String, String>{};
    String? creator;
    try {
      final client = Supabase.instance.client;
      final cb = v['created_by'] as String?;
      if (cb != null && cb.isNotEmpty) {
        final u = await client.from('users').select('name').eq('id', cb).maybeSingle();
        creator = u?['name'] as String?;
      }
      if (type == 'Sales Invoice') {
        final soId = v['so_id'] as String?;
        if (soId != null && soId.isNotEmpty) {
          final r = await client.from('sales_orders').select('voucher_number').eq('id', soId).maybeSingle();
          final n = r?['voucher_number'] as String?;
          if (n != null && n.isNotEmpty) refs['SO'] = n;
        }
        final doId = v['do_id'] as String?;
        if (doId != null && doId.isNotEmpty) {
          final r = await client.from('delivery_orders').select('voucher_number').eq('id', doId).maybeSingle();
          final n = r?['voucher_number'] as String?;
          if (n != null && n.isNotEmpty) refs['DC'] = n;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    await showDialog(context: context, builder: (ctx) => _buildVoucherDialog(ctx, type, v, lines, refs, creator));
  }

  Widget _metaChip(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: AppTheme.textSecondary),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ]);

  Widget _buildVoucherDialog(BuildContext ctx, String type, Map<String, dynamic> v, List<dynamic> lines, Map<String, String> refs, String? creator) {
    final isPR = type == 'Receipt (CRV)' || type == 'Payment (CPV)';
    final vNum = ((v['voucher_number'] ?? v['invoice_number'] ?? v['transaction_number'] ?? '') as String);
    final dateStr = ((v['voucher_date'] ?? v['invoice_date'] ?? v['transacted_at'] ?? v['created_at'] ?? '') as String);
    final dt = DateTime.tryParse(dateStr);
    final dateFmt = dt != null ? DateFormat('d MMM yyyy').format(dt) : '-';
    final cust = v['customers'];
    final customerName = (cust is Map ? cust['shop_name'] as String? : null) ?? '';
    final customerCode = (cust is Map ? cust['code'] as String? : null) ?? '';
    double total = 0;
    if (isPR) {
      for (final ln in lines) { total += ((ln['amount']) as num?)?.toDouble() ?? 0; }
    } else {
      total = ((v['grand_total'] ?? v['total'] ?? v['total_amount'] ?? v['net_amount']) as num?)?.toDouble() ?? 0;
    }
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(type, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(ctx, rootNavigator: true).pop()),
              ]),
              const SizedBox(height: 4),
              Text(vNum, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              const SizedBox(height: 8),
              Wrap(spacing: 18, runSpacing: 6, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 5),
                  Text(dateFmt, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                if (customerName.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person, size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 5),
                  Text(customerName + (customerCode.isNotEmpty ? ' (' + customerCode + ')' : ''), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                if (v['status'] != null) Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFE3F2FD), borderRadius: BorderRadius.circular(10)),
                  child: Text((v['status'] as String).toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                ),
                for (final e in refs.entries) _metaChip(Icons.link, e.key + ': ' + e.value),
                if (creator != null && creator.isNotEmpty) _metaChip(Icons.badge_outlined, 'By ' + creator),
              ]),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Flexible(child: SingleChildScrollView(child: isPR ? _prLines(lines) : _prodLines(lines))),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Builder(builder: (_) {
                double subtotal = 0;
                if (!isPR) {
                  for (final ln in lines) {
                    final q = ((ln['qty'] ?? ln['quantity'] ?? ln['qty_delivered'] ?? ln['qty_received']) as num?)?.toDouble() ?? 0;
                    final p = ((ln['unit_price'] ?? ln['price'] ?? ln['unit_cost']) as num?)?.toDouble() ?? 0;
                    subtotal += q * p;
                  }
                }
                final discount = subtotal - total;
                final showBreakdown = !isPR && discount > 0.01;
                const lbl = TextStyle(fontSize: 13, color: AppTheme.textSecondary);
                Widget ln(String l, String val, {bool strong = false}) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        Text(l, style: strong ? const TextStyle(fontSize: 15, fontWeight: FontWeight.w600) : lbl),
                        const SizedBox(width: 8),
                        Text('Rs. ' + val, style: strong
                            ? const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)
                            : lbl),
                      ]),
                    );
                return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
                  if (showBreakdown) ln('Subtotal:', subtotal.toStringAsFixed(2)),
                  if (showBreakdown) ln('Discount:', '-' + discount.toStringAsFixed(2)),
                  ln('Total:', total.toStringAsFixed(2), strong: true),
                ]);
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _prLines(List<dynamic> lines) {
    if (lines.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary))));
    return Column(children: [
      Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: const [
        Expanded(flex: 3, child: Text('Account / Party', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 3, child: Text('Description', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Amount', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ])),
      ...lines.map((line) {
        final amount = ((line['amount']) as num?)?.toDouble() ?? 0;
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(flex: 3, child: Text((line['account_name'] as String?) ?? '', style: const TextStyle(fontSize: 12))),
            Expanded(flex: 3, child: Text((line['description'] as String?) ?? '', style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text('Rs. ' + amount.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        );
      }),
    ]);
  }

  Widget _prodLines(List<dynamic> lines) {
    if (lines.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No lines', style: TextStyle(color: AppTheme.textSecondary))));
    return Column(children: [
      Container(color: const Color(0xFFF5F5F5), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: const [
        Expanded(flex: 4, child: Text('Product', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 1, child: Text('Qty', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Price', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Disc', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
        Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
      ])),
      ...lines.map((line) {
        final qty = ((line['qty'] ?? line['quantity'] ?? line['qty_delivered'] ?? line['qty_received']) as num?)?.toDouble() ?? 0;
        final price = ((line['unit_price'] ?? line['price'] ?? line['unit_cost']) as num?)?.toDouble() ?? 0;
        final gross = qty * price;
        final storedTotal = (line['line_total'] ?? line['total'] ?? line['amount']) as num?;
        double lineTotal;
        if (storedTotal != null) {
          lineTotal = storedTotal.toDouble();
        } else {
          final dt = line['discount_type'] as String?;
          final draw = ((line['discount']) as num?)?.toDouble() ?? 0;
          lineTotal = gross - (dt == 'percent' ? gross * draw / 100 : draw);
        }
        final lineDisc = gross - lineTotal;
        final prod = line['products'];
        final prodName = (prod is Map ? prod['name'] as String? : null) ?? (line['product_name'] as String?) ?? (line['description'] as String?) ?? '';
        return Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE)))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            Expanded(flex: 4, child: Text(prodName, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 1, child: Text(qty % 1 == 0 ? qty.toInt().toString() : qty.toString(), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text('Rs. ' + price.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
            Expanded(flex: 2, child: Text(lineDisc.abs() < 0.01 ? '—' : 'Rs. ' + lineDisc.toStringAsFixed(2), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: lineDisc.abs() < 0.01 ? AppTheme.textSecondary : AppTheme.danger))),
            Expanded(flex: 2, child: Text('Rs. ' + lineTotal.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        );
      }),
    ]);
  }

  void _printLedger() {
    try {
      final display = _displayEntries;
      if ((display.isEmpty && _pendingCheques.isEmpty) || _selectedCustomer == null) return;
      final branch = ref.read(selectedBranchProvider);
      double td = 0, tc = 0;
      for (final e in display) { td += e['debit'] as double; tc += e['credit'] as double; }
      final netBal = td - tc;
      final cust = _selectedCustomer!;
      final customerName = (cust['shop_name'] as String?) ?? '';
      final customerCode = (cust['code'] as String?) ?? '';
      final branchName = (branch?['name'] as String?) ?? 'All Branches';
      final genTime = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
      final codeStr = customerCode.isNotEmpty ? ' (' + customerCode + ')' : '';
      final periodStr = (_dateFrom != null || _dateTo != null)
        ? (_dateFrom != null ? DateFormat('d MMM yy').format(_dateFrom!) : 'Beginning') + ' to ' + (_dateTo != null ? DateFormat('d MMM yy').format(_dateTo!) : 'Today')
        : '';
      final balColor = netBal > 0 ? '#c62828' : '#2e7d32';

      // Pending PDC cheques memo block (mirrors the on-screen yellow card).
      String pdcBlock = '';
      if (_pendingCheques.isNotEmpty) {
        double pdcTotal = 0;
        final pb = StringBuffer();
        for (final c in _pendingCheques) {
          final amt = c['amount'] as double;
          pdcTotal += amt;
          final cd = c['cheque_date'] as String?;
          final dt = cd != null ? DateTime.tryParse(cd) : null;
          final cdStr = dt != null ? DateFormat('d MMM yy').format(dt) : '-';
          final detail = [
            if ((c['cheque_no'] as String? ?? '').isNotEmpty) 'Chq ' + (c['cheque_no'] as String),
            if ((c['bank'] as String? ?? '').isNotEmpty) (c['bank'] as String),
            if ((c['description'] as String? ?? '').isNotEmpty) (c['description'] as String),
          ].join(' • ');
          pb.write('<tr><td>' + (c['voucher_number'] as String) + '</td><td>' + cdStr + '</td><td>' + detail + '</td><td class="num">Rs. ' + amt.toStringAsFixed(2) + '</td></tr>');
        }
        pdcBlock = '<div class="pdc"><div class="pdc-head"><span class="pdc-title">Pending Cheques (PDC)</span>'
          '<span class="pdc-note">Memo only &mdash; not included in the balance or aging until cleared</span>'
          '<span class="pdc-total">Rs. ' + pdcTotal.toStringAsFixed(2) + '</span></div>'
          '<table class="pdc-table"><thead><tr><th>Voucher</th><th>Cheque Date</th><th>Details</th><th class="num">Amount</th></tr></thead>'
          '<tbody>' + pb.toString() + '</tbody></table></div>';
      }

      final rowsBuf = StringBuffer();
      for (final e in display) {
        final ds = e['date'] as String? ?? '';
        final dt = DateTime.tryParse(ds);
        final date = dt != null ? DateFormat('d MMM yy').format(dt) : '-';
        final debit = e['debit'] as double;
        final credit = e['credit'] as double;
        final bal = e['display_balance'] as double;
        final dStr = debit > 0 ? 'Rs. ' + debit.toStringAsFixed(2) : '-';
        final cStr = credit > 0 ? 'Rs. ' + credit.toStringAsFixed(2) : '-';
        rowsBuf.write('<tr><td>' + date + '</td><td>' + (e['voucher'] as String? ?? '') + '</td><td>' + (e['description'] as String) + '</td><td><span class="badge">' + (e['type'] as String) + '</span></td><td class="num">' + dStr + '</td><td class="num">' + cStr + '</td><td class="num bold">Rs. ' + bal.toStringAsFixed(2) + '</td></tr>');
      }

      final htmlDoc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Customer Ledger - ' + customerName + '</title>'
        '<style>'
        '@page { margin: 0.5cm; } '
        'body { font-family: Arial, sans-serif; padding: 16px; font-size: 10px; color: #000; margin: 0; } '
        '.header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 2px solid #000; padding-bottom: 8px; margin-bottom: 10px; } '
        'h1 { font-size: 18px; margin: 0 0 4px 0; } '
        '.info { font-size: 10px; margin: 2px 0; } '
        '.stats { display: flex; gap: 10px; margin: 8px 0 12px 0; } '
        '.stat { padding: 6px 10px; border: 1px solid #ddd; border-radius: 4px; } '
        '.stat-label { font-size: 8px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; } '
        '.stat-value { font-weight: 800; font-size: 12px; margin-top: 2px; } '
        '.debit { color: #1976d2; } .credit { color: #2e7d32; } '
        '.bal { color: ' + balColor + '; } '
        'table { width: 100%; border-collapse: collapse; } '
        'th, td { padding: 4px 6px; border-bottom: 1px solid #ddd; text-align: left; font-size: 9.5px; } '
        'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
        '.num { text-align: right; white-space: nowrap; } .bold { font-weight: 800; } '
        '.badge { display: inline-block; padding: 1px 5px; border-radius: 3px; background: #eee; font-size: 8px; font-weight: 700; } '
        'tfoot td { font-weight: 800; background: #f5f5f5; border-top: 2px solid #000; border-bottom: none; padding: 6px; } '
        '.pdc { border: 1px solid #f0c040; background: #fff8e1; border-radius: 6px; padding: 8px 10px; margin: 0 0 12px 0; } '
        '.pdc-head { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; } '
        '.pdc-title { font-weight: 800; font-size: 11px; color: #b26a00; } '
        '.pdc-note { flex: 1; font-size: 8.5px; color: #777; } '
        '.pdc-total { font-weight: 800; font-size: 11px; color: #b26a00; } '
        '.pdc-table th, .pdc-table td { border-bottom: 1px solid #f0e0b0; font-size: 9px; padding: 3px 6px; text-align: left; } '
        '.pdc-table th { background: #fdf3d6; border-bottom: 1px solid #e0c060; } '
        '</style></head><body>'
        '<div class="header"><div><h1>Customer Ledger</h1>'
        '<div class="info"><strong>Customer:</strong> ' + customerName + codeStr + '</div>'
        '<div class="info"><strong>Branch:</strong> ' + branchName + '</div>'
        + (periodStr.isNotEmpty ? '<div class="info"><strong>Period:</strong> ' + periodStr + '</div>' : '') +
        '</div><div style="text-align: right;"><div class="info">Generated: ' + genTime + '</div></div></div>'
        '<div class="stats">'
        '<div class="stat"><div class="stat-label">Total Debit</div><div class="stat-value debit">Rs. ' + td.toStringAsFixed(2) + '</div></div>'
        '<div class="stat"><div class="stat-label">Total Credit</div><div class="stat-value credit">Rs. ' + tc.toStringAsFixed(2) + '</div></div>'
        '<div class="stat"><div class="stat-label">Net Balance</div><div class="stat-value bal">Rs. ' + netBal.toStringAsFixed(2) + '</div></div>'
        '</div>' + pdcBlock + '<table>'
        '<thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th>Type</th><th class="num">Debit</th><th class="num">Credit</th><th class="num">Balance</th></tr></thead>'
        '<tbody>' + rowsBuf.toString() + '</tbody>'
        '<tfoot><tr><td colspan="4">' + display.length.toString() + ' entries</td><td class="num debit">Rs. ' + td.toStringAsFixed(2) + '</td><td class="num credit">Rs. ' + tc.toStringAsFixed(2) + '</td><td class="num bal">Rs. ' + netBal.toStringAsFixed(2) + '</td></tr></tfoot>'
        '</table></body></html>';

      // Original method used across vouchers: blob URL in new tab
      final blob = html.Blob([htmlDoc], 'text/html;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print error: ' + e.toString())));
    }
  }
}

class _Stat extends StatelessWidget {
  final String label, value; final Color color;
  const _Stat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
    ]),
  );
}

/// One aging bucket. No fixed width — AdaptiveKpiRow sizes it, so it is two-up
/// on a phone and four-across on desktop.
class _AgeBucket extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  const _AgeBucket({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: color.withOpacity(0.07),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withOpacity(0.25)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary),
          maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 2),
      Text('Rs. ${value.toStringAsFixed(0)}',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color),
          maxLines: 1, overflow: TextOverflow.ellipsis),
    ]),
  );
}
