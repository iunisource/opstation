import 'dart:async';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show networkImage;
import '../pdf/payment_advice_pdf.dart';
import '../../../core/pdf/pdf_output.dart';

/// Payment Advice — a non-financial processing slip listing parties to pay,
/// their bank details, amount due and amount to be paid, with a grand total.
/// Optional approval flow (toggle + approver list in Admin Settings). Nothing
/// posts to the general ledger.
class ErpPaymentAdviceScreen extends ConsumerStatefulWidget {
  const ErpPaymentAdviceScreen({super.key});

  @override
  ConsumerState<ErpPaymentAdviceScreen> createState() =>
      _ErpPaymentAdviceScreenState();
}

class _Party {
  final String id;
  final String name;
  final String type; // 'customer' | 'supplier' | 'other' (free text)
  final String bank;
  final double balance;
  final DateTime? lastPayment;
  const _Party(this.id, this.name, this.type, this.bank, this.balance,
      [this.lastPayment]);
}

class _PaLine {
  String? partyId;
  String partyType = 'supplier';
  String partyName = '';
  /// Collapsed lines render as a single summary row above the entry area.
  bool collapsed = false;
  final TextEditingController bankCtrl = TextEditingController();
  final TextEditingController dueCtrl = TextEditingController();
  final TextEditingController payCtrl = TextEditingController();
  DateTime? lastPayment;
  void dispose() {
    bankCtrl.dispose();
    dueCtrl.dispose();
    payCtrl.dispose();
  }
}

class _ErpPaymentAdviceScreenState
    extends ConsumerState<ErpPaymentAdviceScreen> {
  bool _loading = true;
  String _stage = 'starting';
  String? _partyWarning;
  String? _error;
  bool _saving = false;

  // Settings
  bool _approvalEnabled = false;
  // Admin Settings: print signature images on the Payment Advice.
  bool _sigEnabled = false;
  // Admin Settings: faint "approved by" watermark grid on the print.
  bool _approvalMarkEnabled = false;
  // Signature on file per user id — used when an advice has no snapshot
  // (e.g. approved before signatures were captured).
  final Map<String, String?> _sigOnFile = {};
  Set<String> _approvers = {};

  // Data
  List<Map<String, dynamic>> _advices = [];
  final List<_Party> _parties = [];
  final Map<String, _Party> _partyById = {};
  bool _balancesLoaded = false;
  bool _showArchived = false;

  // Editor state
  bool _editing = false;
  // Admin is editing an already-approved advice (audit-logged on save).
  bool _adminEditing = false;
  // Lines as they were when the advice was opened — for the edit audit diff.
  List<Map<String, dynamic>> _origLines = [];
  int _auditTick = 0;
  Map<String, dynamic>? _current; // null = new
  final List<_PaLine> _lines = [];
  DateTime _date = DateTime.now();
  final TextEditingController _noteCtrl = TextEditingController();
  String _search = '';

  SupabaseClient get _db => Supabase.instance.client;

  void _setStage(String st) {
    if (!mounted) return;
    setState(() => _stage = st);
  }

  /// Time-box any Supabase query so a stalled request can never hang the load.
  Future<T> _timed<T>(Future<T> f) =>
      f.timeout(const Duration(seconds: 25));

  /// Saved advices, with one retry — the first request after the page wakes
  /// can be slow; a second attempt usually returns immediately.
  Future<List> _loadAdvicesWithRetry(String orgId) async {
    Future<List> q() async => (await _timed(_db
        .from('payment_advices')
        .select()
        .eq('org_id', orgId)
        .order('created_at', ascending: false)
        .limit(500))) as List;
    try {
      return await q();
    } catch (_) {
      return await q();
    }
  }

  static String _short(Object e) =>
      e is TimeoutException ? 'timed out' : e.toString().split('\n').first;

  /// Fetch a party table; if the bank_details column doesn't exist yet
  /// (migration not run), retry without it so the screen still works.
  Future<List> _selectParties(String table, String fullSel, String baseSel,
      String orgId, String orderCol) async {
    try {
      final r = await _timed(_db
          .from(table)
          .select(fullSel)
          .eq('org_id', orgId)
          .order(orderCol)
          .limit(5000));
      return r as List;
    } catch (_) {
      final r = await _timed(_db
          .from(table)
          .select(baseSel)
          .eq('org_id', orgId)
          .order(orderCol)
          .limit(5000));
      return r as List;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() {
        _error = 'No organization on the current session.';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Settings (approval toggle + approver list) from app_config.
      // Best-effort: never let a settings hiccup block the whole screen.
      _setStage('settings');
      try {
        final cfgRows = await _timed(_db
            .from('app_config')
            .select('key, value')
            .eq('org_id', orgId)
            .inFilter('key', ['org.pa_approval_enabled', 'org.pa_approvers', 'org.pa_signatures', 'org.pa_approval_watermark']));
        final cfg = <String, String>{};
        for (final r in cfgRows as List) {
          cfg[r['key'] as String] = (r['value'] as String?) ?? '';
        }
        _approvalEnabled = cfg['org.pa_approval_enabled'] == 'true';
        _sigEnabled = cfg['org.pa_signatures'] == 'true';
        _approvalMarkEnabled = cfg['org.pa_approval_watermark'] == 'true';
        final ap = (cfg['org.pa_approvers'] ?? '').trim();
        _approvers = ap.isEmpty
            ? <String>{}
            : ap.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      } catch (_) {
        _approvalEnabled = false;
        _approvers = <String>{};
      }

      // Saved advices + party master load IN PARALLEL, and none of them is
      // fatal: a slow query yields an empty list + a warning banner instead of
      // replacing the whole screen with a TimeoutException.
      _parties.clear();
      _partyById.clear();
      _setStage('advices, customers & suppliers');
      _partyWarning = null;
      final results = await Future.wait<List>([
        _loadAdvicesWithRetry(orgId).catchError((e) {
          _partyWarning = 'Saved payment advices could not be loaded (${_short(e)}).';
          return <dynamic>[];
        }),
        _selectParties('customers', 'id, shop_name, bank_details', 'id, shop_name',
                orgId, 'shop_name')
            .catchError((e) {
          _partyWarning = 'Customers could not be loaded: $e';
          return <dynamic>[];
        }),
        _selectParties('suppliers', 'id, name, bank_details', 'id, name', orgId,
                'name')
            .catchError((e) {
          _partyWarning = 'Suppliers could not be loaded: $e';
          return <dynamic>[];
        }),
      ]);
      _advices = List<Map<String, dynamic>>.from(results[0]);
      final custs = results[1];
      final sups = results[2];

      // Build parties immediately with balance 0 so the page renders fast.
      // Balances come from heavy org-wide RPCs — fetch them in the background
      // (Amount Due is editable, so a missing/late balance never blocks use).
      for (final c in custs as List) {
        final id = c['id'] as String;
        final p = _Party(id, (c['shop_name'] as String?) ?? '(customer)',
            'customer', (c['bank_details'] as String?) ?? '', 0);
        _parties.add(p);
        _partyById['customer:$id'] = p;
      }
      for (final s in sups as List) {
        final id = s['id'] as String;
        final p = _Party(id, (s['name'] as String?) ?? '(supplier)', 'supplier',
            (s['bank_details'] as String?) ?? '', 0);
        _parties.add(p);
        _partyById['supplier:$id'] = p;
      }

      _setStage('done');
      setState(() => _loading = false);
      // Non-blocking: fill balances when they arrive.
      _loadBalancesInBackground(orgId);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Fetch party balances off the critical path and merge them into the party
  /// list. Best-effort and time-boxed so a slow/absent RPC never hangs the UI.
  Future<void> _loadBalancesInBackground(String orgId) async {
    try {
      // Current NET balance per party from the posted GL (folds in advances /
      // prepayments, so a fully-paid supplier reads 0 — not its old payable).
      final net = await _loadPartyNet(orgId)
          .timeout(const Duration(seconds: 20), onTimeout: () => <String, double>{});
      final lastPay = await _loadLastPayments(orgId)
          .timeout(const Duration(seconds: 20), onTimeout: () => <String, DateTime>{});
      if (!mounted) return;
      final rebuilt = _parties.map((p) {
        final raw = net[p.id];
        // net = credit - debit. Supplier payable is a credit balance (positive);
        // customer receivable is a debit balance, so negate for customers.
        final bal = raw == null
            ? p.balance
            : (p.type == 'customer' ? -raw : raw);
        final lp = lastPay['${p.type}:${p.id}'] ?? p.lastPayment;
        return _Party(p.id, p.name, p.type, p.bank, bal, lp);
      }).toList();
      setState(() {
        _parties
          ..clear()
          ..addAll(rebuilt);
        _partyById.clear();
        for (final p in _parties) {
          _partyById['${p.type}:${p.id}'] = p;
        }
        _balancesLoaded = true;
      });
    } catch (_) {
      // ignore — balances are optional
    }
  }

  /// Latest posted payment date per party ('type:id' -> date). Best-effort.
  Future<Map<String, DateTime>> _loadLastPayments(String orgId) async {
    try {
      final rows =
          await _db.rpc('rpc_party_last_payment', params: {'p_org_id': orgId});
      final out = <String, DateTime>{};
      for (final r in rows as List) {
        final key = r['party_key'] as String?;
        final d = DateTime.tryParse((r['last_payment'] as String?) ?? '');
        if (key != null && d != null) out[key] = d;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// Current net (credit - debit) per party id from the posted GL. Positive =
  /// supplier payable; for customers the caller negates it to get receivable.
  Future<Map<String, double>> _loadPartyNet(String orgId) async {
    try {
      final rows =
          await _db.rpc('rpc_party_net_balances', params: {'p_org': orgId});
      final out = <String, double>{};
      for (final r in rows as List) {
        final id = r['party_id'] as String?;
        if (id != null) out[id] = (r['net'] as num?)?.toDouble() ?? 0;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.superAdmin ||
        r == WebUserRole.masterAdmin ||
        r == WebUserRole.admin;
  }

  bool get _canApprove {
    final me = ref.read(currentUserProvider);
    if (me == null) return false;
    return _approvalEnabled && _approvers.contains(me.id);
  }

  /// Admins and listed approvers can moderate (reject / archive).
  bool get _canModerate {
    final me = ref.read(currentUserProvider);
    if (me == null) return false;
    return _isAdmin || _approvers.contains(me.id);
  }

  double get _grandTotal =>
      _lines.fold(0.0, (s, l) => s + (double.tryParse(l.payCtrl.text.trim()) ?? 0));

  // ── Editor open / close ────────────────────────────────────────────────
  void _newAdvice() {
    for (final l in _lines) {
      l.dispose();
    }
    _lines
      ..clear()
      ..add(_PaLine());
    _current = null;
    _adminEditing = false;
    _origLines = [];
    _date = DateTime.now();
    _noteCtrl.text = '';
    setState(() => _editing = true);
  }

  Future<void> _openAdvice(Map<String, dynamic> a) async {
    setState(() => _loading = true);
    try {
      final lines = await _db
          .from('payment_advice_lines')
          .select()
          .eq('advice_id', a['id'])
          .order('line_order');
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      _adminEditing = false;
      _origLines = List<Map<String, dynamic>>.from(lines as List);
      for (final r in lines) {
        final ln = _PaLine()
          ..partyId = r['party_id'] as String?
          ..partyType = (r['party_type'] as String?) ?? 'supplier'
          ..partyName = (r['party_name'] as String?) ?? '';
        ln.bankCtrl.text = (r['bank_details'] as String?) ?? '';
        ln.dueCtrl.text = _numStr(r['amount_due']);
        ln.payCtrl.text = _numStr(r['amount_to_pay']);
        ln.lastPayment =
            DateTime.tryParse((r['last_payment_date'] as String?) ?? '');
        ln.collapsed = true;
        _lines.add(ln);
      }
      if (_lines.isEmpty) _lines.add(_PaLine());
      _current = a;
      if (_sigEnabled) {
        for (final k in const ['created_by', 'approved_by']) {
          final uid = a[k] as String?;
          if (uid != null && !_sigOnFile.containsKey(uid)) {
            _sigOnFile[uid] = await _signatureOf(uid);
          }
        }
      }
      _date = DateTime.tryParse(a['advice_date'] as String? ?? '') ?? DateTime.now();
      _noteCtrl.text = (a['note'] as String?) ?? '';
      setState(() {
        _editing = true;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool get _isApproved => (_current?['status'] as String?) == 'approved';
  bool get _isRejected => (_current?['status'] as String?) == 'rejected';
  bool get _isVoid => (_current?['status'] as String?) == 'void';
  // Approved, rejected and voided advices are final — read-only.
  bool get _isLocked => _isApproved || _isRejected || _isVoid;
  // An admin can reopen an APPROVED advice for editing (audit-logged).
  bool get _readOnly => _isLocked && !_adminEditing;
  bool get _canAdminEdit => _isApproved && _isAdmin && !_adminEditing;
  // Pending or approved advices can be voided by admins / approvers.
  bool get _canVoid {
    final st = _current?['status'] as String?;
    return _current != null && _canModerate && (st == 'pending' || st == 'approved');
  }

  String _numStr(dynamic v) {
    final d = (v as num?)?.toDouble() ?? 0;
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d.toStringAsFixed(2);
  }

  // ── Party picker ───────────────────────────────────────────────────────
  Future<void> _pickParty(_PaLine line) async {
    if (_readOnly) return;
    // Parties already on this advice (other lines) can't be picked again.
    final taken = <String>{
      for (final l in _lines)
        if (l != line && l.partyId != null) _lineKey(l),
    };
    final picked = await showDialog<_Party>(
      context: context,
      builder: (_) => _PartyPickerDialog(parties: _parties, taken: taken),
    );
    if (picked == null) return;
    if (taken.contains(_partyKey(picked.type, picked.id, picked.name))) {
      _snack('${picked.name} is already on this advice.');
      return;
    }
    setState(() {
      line.partyId = picked.id;
      line.partyType = picked.type;
      line.partyName = picked.name;
      line.lastPayment = picked.lastPayment;
      line.bankCtrl.text = picked.bank; // editable; empty if none on profile
      line.dueCtrl.text = picked.balance == 0 ? '' : _numStr(picked.balance);
      if (line.payCtrl.text.trim().isEmpty && picked.balance != 0) {
        line.payCtrl.text = _numStr(picked.balance);
      }
    });
  }

  /// Identity of a party on the advice: master parties by id, free-text
  /// parties by (case-insensitive) name.
  static String _partyKey(String type, String? id, String name) =>
      type == 'other' ? 'other:${name.trim().toLowerCase()}' : '$type:$id';
  static String _lineKey(_PaLine l) => _partyKey(l.partyType, l.partyId, l.partyName);

  void _insertBullet(TextEditingController c) {
    final t = c.text;
    final needsNl = t.isNotEmpty && !t.endsWith('\n');
    c.text = '$t${needsNl ? '\n' : ''}• ';
    c.selection = TextSelection.fromPosition(
        TextPosition(offset: c.text.length));
    setState(() {});
  }

  // ── Save / approve ─────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_saving) return;
    final me = ref.read(currentUserProvider);
    final orgId = me?.orgId;
    if (orgId == null) return;

    final valid =
        _lines.where((l) => l.partyId != null && l.partyName.isNotEmpty).toList();
    if (valid.isEmpty) {
      _snack('Add at least one party.');
      return;
    }
    final seen = <String>{};
    for (final l in valid) {
      if (!seen.add(_lineKey(l))) {
        _snack('${l.partyName} is on this advice twice — remove one before saving.');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final isNew = _current == null;
      final total = _grandTotal;
      String adviceId;
      String number = (_current?['advice_number'] as String?) ?? '';
      if (isNew) {
        number = await _nextNumber(orgId);
        adviceId = 'pa_${DateTime.now().millisecondsSinceEpoch}';
        final status = _approvalEnabled ? 'pending' : 'approved';
        final autoApproved = !_approvalEnabled;
        await _db.from('payment_advices').insert({
          'id': adviceId,
          'org_id': orgId,
          'advice_number': number,
          'advice_date': DateFormat('yyyy-MM-dd').format(_date),
          'status': status,
          'note': _noteCtrl.text.trim(),
          'grand_total': total,
          'created_by': me?.id,
          'created_by_name': me?.name,
          // With no approval flow the slip is approved on creation, so record
          // the creator as the approver instead of leaving "Approved by" blank.
          if (autoApproved) 'approved_by': me?.id,
          if (autoApproved) 'approved_by_name': me?.name,
          if (autoApproved) 'approved_at': DateTime.now().toUtc().toIso8601String(),
        });
        final mySig = await _signatureOf(me?.id);
        await _stampSignatures(adviceId, {
          'created_signature_url': mySig,
          if (autoApproved) 'approved_signature_url': mySig,
          if (autoApproved) 'approved_stamp_url': await _orgStamp(orgId),
        });
      } else {
        adviceId = _current!['id'] as String;
        await _db.from('payment_advices').update({
          'advice_date': DateFormat('yyyy-MM-dd').format(_date),
          'note': _noteCtrl.text.trim(),
          'grand_total': total,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', adviceId);
        await _db.from('payment_advice_lines').delete().eq('advice_id', adviceId);
      }

      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < valid.length; i++) {
        final l = valid[i];
        rows.add({
          'id': 'pal_${DateTime.now().microsecondsSinceEpoch}_$i',
          'advice_id': adviceId,
          'org_id': orgId,
          'party_type': l.partyType,
          'party_id': l.partyId,
          'party_name': l.partyName,
          'bank_details': l.bankCtrl.text.trim(),
          'amount_due': double.tryParse(l.dueCtrl.text.trim()) ?? 0,
          'amount_to_pay': double.tryParse(l.payCtrl.text.trim()) ?? 0,
          'last_payment_date': l.lastPayment == null
              ? null
              : DateFormat('yyyy-MM-dd').format(l.lastPayment!),
          'line_order': i,
        });
      }
      try {
        await _db.from('payment_advice_lines').insert(rows);
      } catch (e) {
        // If the last_payment_date column isn't present yet (migration 274 not
        // applied), retry without it so saving never breaks.
        if (e.toString().contains('last_payment_date')) {
          for (final r in rows) {
            r.remove('last_payment_date');
          }
          await _db.from('payment_advice_lines').insert(rows);
        } else {
          rethrow;
        }
      }

      final wasAdminEdit = _adminEditing;
      await _audit(
        adviceId,
        isNew ? 'created' : (wasAdminEdit ? 'edited_after_approval' : 'saved'),
        isNew
            ? '$number created · ${valid.length} part${valid.length == 1 ? 'y' : 'ies'} · Rs ${_numStr(total)}'
            : _editDiff(valid, total),
      );

      if (!mounted) return;
      setState(() {
        _editing = false;
        _adminEditing = false;
        _saving = false;
      });
      await _loadAll();
      _snack(wasAdminEdit ? 'Approved advice updated (logged in audit trail).' : 'Payment advice saved.');
    } catch (e) {
      setState(() => _saving = false);
      _snack('Save failed: $e');
    }
  }

  Future<void> _approve() async {
    if (_current == null || _saving) return;
    final me = ref.read(currentUserProvider);
    setState(() => _saving = true);
    try {
      await _db.from('payment_advices').update({
        'status': 'approved',
        'approved_by': me?.id,
        'approved_by_name': me?.name,
        'approved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _current!['id']);
      await _stampSignatures(_current!['id'] as String, {
        'approved_signature_url': await _signatureOf(me?.id),
        'approved_stamp_url': await _orgStamp(me?.orgId),
      });
      await _audit(_current!['id'] as String, 'approved', 'Approved by ${me?.name ?? ''}');
      if (!mounted) return;
      setState(() {
        _editing = false;
        _saving = false;
      });
      await _loadAll();
      _snack('Payment advice approved.');
    } catch (e) {
      setState(() => _saving = false);
      _snack('Approve failed: $e');
    }
  }

  Future<void> _reject() async {
    if (_current == null || _saving) return;
    // Only a pending advice can be rejected; approved is final (archive only).
    if ((_current!['status'] as String?) != 'pending') {
      _snack('Only a pending advice can be rejected.');
      return;
    }
    final reason = await _askRejectReason();
    if (reason == null) return; // cancelled
    final me = ref.read(currentUserProvider);
    setState(() => _saving = true);
    try {
      await _db.from('payment_advices').update({
        'status': 'rejected',
        'rejected_by': me?.id,
        'rejected_by_name': me?.name,
        'rejected_at': DateTime.now().toUtc().toIso8601String(),
        'reject_reason': reason.trim().isEmpty ? null : reason.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _current!['id']);
      await _audit(_current!['id'] as String, 'rejected',
          reason.trim().isEmpty ? 'Rejected' : 'Rejected: ${reason.trim()}');
      if (!mounted) return;
      setState(() {
        _editing = false;
        _saving = false;
      });
      await _loadAll();
      _snack('Payment advice rejected.');
    } catch (e) {
      setState(() => _saving = false);
      _snack('Reject failed: $e');
    }
  }

  /// Best-effort audit entry in voucher_audit_log (type 'PA').
  Future<void> _audit(String adviceId, String action, String details) async {
    final me = ref.read(currentUserProvider);
    try {
      await _db.from('voucher_audit_log').insert({
        'id': 'val_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': me?.orgId,
        'voucher_id': adviceId,
        'voucher_type': 'PA',
        'action': action,
        'details': details,
        'performed_by': me?.id,
        'performed_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {/* logging must never block the action */}
    _auditTick++;
  }

  /// Human-readable summary of what changed vs. the lines as opened.
  String _editDiff(List<_PaLine> now, double newTotal) {
    double n(dynamic v) => (v as num?)?.toDouble() ?? 0;
    final before = <String, Map<String, dynamic>>{
      for (final r in _origLines) '${r['party_type']}:${r['party_id']}': r,
    };
    final after = <String, _PaLine>{
      for (final l in now) '${l.partyType}:${l.partyId}': l,
    };
    final parts = <String>[];
    for (final e in after.entries) {
      final o = before[e.key];
      final pay = double.tryParse(e.value.payCtrl.text.trim()) ?? 0;
      final due = double.tryParse(e.value.dueCtrl.text.trim()) ?? 0;
      if (o == null) {
        parts.add('+ ${e.value.partyName} (pay ${_numStr(pay)})');
        continue;
      }
      final ch = <String>[];
      if ((n(o['amount_to_pay']) - pay).abs() >= 0.005) {
        ch.add('pay ${_numStr(o['amount_to_pay'])} → ${_numStr(pay)}');
      }
      if ((n(o['amount_due']) - due).abs() >= 0.005) {
        ch.add('due ${_numStr(o['amount_due'])} → ${_numStr(due)}');
      }
      if (((o['bank_details'] as String?) ?? '').trim() != e.value.bankCtrl.text.trim()) {
        ch.add('bank details changed');
      }
      if (ch.isNotEmpty) parts.add('${e.value.partyName}: ${ch.join(', ')}');
    }
    for (final e in before.entries) {
      if (!after.containsKey(e.key)) parts.add('− ${e.value['party_name'] ?? ''}');
    }
    final oldTotal = n(_current?['grand_total']);
    if ((oldTotal - newTotal).abs() >= 0.005) {
      parts.add('Total ${_numStr(oldTotal)} → ${_numStr(newTotal)}');
    }
    final oldDate = (_current?['advice_date'] as String?) ?? '';
    final newDate = DateFormat('yyyy-MM-dd').format(_date);
    if (oldDate.isNotEmpty && !oldDate.startsWith(newDate)) parts.add('Date $oldDate → $newDate');
    if (((_current?['note'] as String?) ?? '').trim() != _noteCtrl.text.trim()) parts.add('Note changed');
    return parts.isEmpty ? 'No changes' : parts.join(' · ');
  }

  Future<void> _void() async {
    if (_current == null || _saving || !_canVoid) return;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => StatefulBuilder(
        builder: (dlg, setDlg) => AlertDialog(
          title: Text('Void ${_current!['advice_number'] ?? 'payment advice'}?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'A voided advice stays on record (marked VOIDED) but can no longer be edited or paid against.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setDlg(() {}),
              decoration: const InputDecoration(
                  labelText: 'Reason (required)', border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dlg, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.pop(dlg, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              child: const Text('Void'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final reason = ctrl.text.trim();
    final me = ref.read(currentUserProvider);
    final now = DateTime.now().toUtc().toIso8601String();
    setState(() => _saving = true);
    try {
      await _db.from('payment_advices').update({
        'status': 'void',
        'voided_by': me?.id,
        'voided_by_name': me?.name,
        'voided_at': now,
        'void_reason': reason,
        'updated_at': now,
      }).eq('id', _current!['id']);
      await _audit(_current!['id'] as String, 'voided', 'Voided: $reason');
      if (!mounted) return;
      setState(() {
        _editing = false;
        _adminEditing = false;
        _saving = false;
      });
      await _loadAll();
      _snack('Payment advice voided.');
    } catch (e) {
      setState(() => _saving = false);
      _snack(e.toString().contains('voided_')
          ? 'Void needs the database update — run 286_payment_advice_void.sql.'
          : 'Void failed: $e');
    }
  }

  Future<String?> _askRejectReason() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: const Text('Reject payment advice'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dlg, false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(dlg, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    return ok == true ? ctrl.text : null;
  }

  /// Signature + stamp are SNAPSHOTTED onto the advice when the user acts, so
  /// the printed slip carries the signature that was on file at that moment
  /// (typed names alone are too easy to alter).
  Future<String?> _signatureOf(String? userId) async {
    if (userId == null) return null;
    try {
      final u = await _db.from('users').select('signature_url').eq('id', userId).maybeSingle();
      final v = (u?['signature_url'] as String?)?.trim();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _orgStamp(String? orgId) async {
    if (orgId == null) return null;
    try {
      final s = await _db.from('app_config').select('value')
          .eq('org_id', orgId).eq('key', 'org.stamp_url').maybeSingle();
      final v = (s?['value'] as String?)?.trim();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// Best-effort write of the signature columns (skipped quietly if the
  /// migration adding them hasn't been run yet).
  Future<void> _stampSignatures(String adviceId, Map<String, dynamic> cols) async {
    final clean = {for (final e in cols.entries) if (e.value != null) e.key: e.value};
    if (clean.isEmpty) return;
    try {
      await _db.from('payment_advices').update(clean).eq('id', adviceId);
    } catch (_) {}
  }

  Future<String> _nextNumber(String orgId) async {
    final rows = await _db
        .from('payment_advices')
        .select('advice_number')
        .eq('org_id', orgId);
    var maxSeq = 0;
    for (final r in rows as List) {
      final m = RegExp(r'(\d+)$').firstMatch((r['advice_number'] as String?) ?? '');
      if (m != null) {
        final v = int.tryParse(m.group(1)!) ?? 0;
        if (v > maxSeq) maxSeq = v;
      }
    }
    return 'PA-${DateTime.now().year}-${(maxSeq + 1).toString().padLeft(4, '0')}';
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _setArchived(Map<String, dynamic> a, bool archived) async {
    if (!_canModerate) {
      _snack('Only admins and approvers can archive payment advices.');
      return;
    }
    try {
      await _db.from('payment_advices').update({
        'is_archived': archived,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', a['id']);
      await _audit(a['id'] as String, archived ? 'archived' : 'unarchived', '');
      if (!mounted) return;
      setState(() => a['is_archived'] = archived);
      _snack(archived ? 'Archived.' : 'Unarchived.');
    } catch (e) {
      _snack('Could not ${archived ? 'archive' : 'unarchive'}: $e');
    }
  }

  int get _pendingCount =>
      _advices.where((a) => a['status'] == 'pending').length;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 12 : 28),
      child: _loading
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text('Loading payment advice — $_stage…',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ]),
            )
          : _error != null
              ? _errorView()
              : _editing
                  ? _editor()
                  : _list(),
    );
  }

  Widget _errorView() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
          const SizedBox(height: 10),
          SelectableText(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFDC2626))),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              onPressed: _loadAll,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry')),
        ]),
      );

  // ── List view ──────────────────────────────────────────────────────────
  Widget _list() {
    final q = _search.trim().toLowerCase();
    final base = _advices.where((a) {
      final archived = (a['is_archived'] as bool?) ?? false;
      return _showArchived ? archived : !archived;
    });
    final shown = q.isEmpty
        ? base.toList()
        : base.where((a) {
            final s = '${a['advice_number'] ?? ''} ${a['created_by_name'] ?? ''} '
                    '${a['status'] ?? ''}'
                .toLowerCase();
            return s.contains(q);
          }).toList();
    // NOTE: never put Spacer/Expanded inside a Wrap — Wrap is not a Flex, and
    // in release builds that mismatch breaks the render tree instead of
    // throwing a readable error (this froze the whole app on first render).
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                const Text('Payment Advice',
                    style:
                        TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                if (_pendingCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: AppTheme.warning.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(999)),
                    child: Text('$_pendingCount pending approval',
                        style: const TextStyle(
                            color: AppTheme.warning,
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _newAdvice,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Payment Advice'),
          ),
        ],
      ),
      const SizedBox(height: 4),
      const Text('Non-financial processing slip — does not post to accounts.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      if (_partyWarning != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.12),
              borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(
              child: Text(_partyWarning!,
                  style: const TextStyle(fontSize: 12, color: AppTheme.warning)),
            ),
            TextButton.icon(
              onPressed: _loading ? null : _loadAll,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        decoration: InputDecoration(
          hintText: 'Search advices…',
          prefixIcon: const Icon(Icons.search, size: 18),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onChanged: (v) => setState(() => _search = v),
      ),
      const SizedBox(height: 8),
      Row(children: [
        FilterChip(
          label: Text(_showArchived ? 'Showing archived' : 'Show archived'),
          selected: _showArchived,
          onSelected: (v) => setState(() => _showArchived = v),
          avatar: Icon(
              _showArchived ? Icons.inventory_2 : Icons.inventory_2_outlined,
              size: 16),
        ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: shown.isEmpty
            ? Center(
                child: Text(
                    _showArchived
                        ? 'No archived payment advices.'
                        : 'No payment advices yet.',
                    style: const TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: shown.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _adviceCard(shown[i]),
              ),
      ),
    ]);
  }

  Widget _adviceCard(Map<String, dynamic> a) {
    final status = (a['status'] as String?) ?? 'approved';
    final pending = status == 'pending';
    final rejected = status == 'rejected';
    final voided = status == 'void';
    final statusColor = voided
        ? AppTheme.textSecondary
        : rejected
            ? AppTheme.danger
            : (pending ? AppTheme.warning : AppTheme.success);
    final statusLabel = voided
        ? 'Voided'
        : rejected
            ? 'Rejected'
            : (pending ? 'Pending' : 'Approved');
    final date = a['advice_date'] != null
        ? DateFormat('d MMM yyyy')
            .format(DateTime.tryParse(a['advice_date'] as String) ?? DateTime.now())
        : '-';
    return InkWell(
      onTap: () => _openAdvice(a),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a['advice_number'] as String? ?? '-',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(height: 2),
              Text(
                '$date · by ${a['created_by_name'] ?? '—'}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ]),
          ),
          Text('Rs ${_numStr(a['grand_total'])}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(statusLabel,
                style: TextStyle(
                    color: statusColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 4),
          _printMenu(a, size: 20),
          if (_canModerate)
          IconButton(
            onPressed: () => _setArchived(a, !((a['is_archived'] as bool?) ?? false)),
            icon: Icon(
                ((a['is_archived'] as bool?) ?? false)
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
                size: 20),
            color: AppTheme.textSecondary,
            tooltip: ((a['is_archived'] as bool?) ?? false)
                ? 'Unarchive'
                : 'Archive',
          ),
        ]),
      ),
    );
  }

  // ── Editor view ────────────────────────────────────────────────────────
  Widget _editor() {
    final readOnly = _readOnly;
    final narrow = MediaQuery.of(context).size.width < 760;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(
          onPressed: () => setState(() {
            _editing = false;
            _adminEditing = false;
          }),
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
        ),
        Expanded(
          child: Text(
            _current == null
                ? 'New Payment Advice'
                : '${_current!['advice_number']}'
                    '${_isVoid ? ' (Voided)' : _isRejected ? ' (Rejected)' : _adminEditing ? ' (Approved — admin edit)' : _isApproved ? ' (Approved)' : _current!['status'] == 'pending' ? ' (Pending)' : ''}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        if (_current != null) _printMenu(_current!),
      ]),
      const SizedBox(height: 8),
      Expanded(
        child: SingleChildScrollView(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date + note
                Wrap(spacing: 16, runSpacing: 12, children: [
                  _dateField(readOnly),
                  SizedBox(
                    width: narrow ? double.infinity : 360,
                    child: TextField(
                      controller: _noteCtrl,
                      enabled: !readOnly,
                      decoration: InputDecoration(
                        labelText: 'Note (optional)',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 18),
                // Parties in their own order: a parked party opens IN PLACE
                // (where it sits in the list), not at the bottom.
                for (var i = 0; i < _lines.length; i++)
                  if (_lines[i].collapsed) ...[
                    _collapsedRow(i, readOnly),
                    const SizedBox(height: 6),
                  ] else ...[
                    const SizedBox(height: 4),
                    _lineCard(i, readOnly, narrow),
                    const SizedBox(height: 10),
                  ],
                if (!readOnly) ...[
                  Wrap(spacing: 10, runSpacing: 8, children: [
                    if (!_lines.any((l) => !l.collapsed))
                      OutlinedButton.icon(
                        onPressed: () => setState(() => _lines.add(_PaLine())),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add party'),
                      ),
                    OutlinedButton.icon(
                      onPressed: _suggestParties,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('Suggest by balance'),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),
                _grandTotalBar(),
                const SizedBox(height: 20),
                _footprints(),
                if (_current != null) ...[
                  const SizedBox(height: 12),
                  _PaAuditTrail(
                      key: ValueKey('pa_audit_${_current!['id']}_$_auditTick'),
                      adviceId: _current!['id'] as String),
                ],
                const SizedBox(height: 24),
              ]),
        ),
      ),
      _actionBar(readOnly),
    ]);
  }

  Widget _dateField(bool readOnly) {
    return InkWell(
      onTap: readOnly
          ? null
          : () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2024),
                lastDate: DateTime(DateTime.now().year + 1),
              );
              if (d != null) setState(() => _date = d);
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.calendar_today, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(DateFormat('d MMM yyyy').format(_date)),
        ]),
      ),
    );
  }

  Widget _lineCard(int i, bool readOnly, bool narrow) {
    final l = _lines[i];
    final amounts = Row(children: [
      Expanded(
        child: _amountField('Amount Due', l.dueCtrl, enabled: !readOnly),
      ),
      const SizedBox(width: 12),
      Expanded(
        // Amount to pay stays editable until approved.
        child: _amountField('Amount to Pay', l.payCtrl,
            enabled: !readOnly, onChanged: (_) => setState(() {})),
      ),
    ]);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: readOnly ? null : () => _pickParty(l),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(children: [
                  Icon(
                      l.partyType == 'customer'
                          ? Icons.store_outlined
                          : l.partyType == 'other'
                              ? Icons.edit_note_outlined
                              : Icons.local_shipping_outlined,
                      size: 18,
                      color: AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.partyName.isEmpty ? 'Select party…' : l.partyName,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: l.partyName.isEmpty
                            ? AppTheme.textSecondary
                            : AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  if (l.partyName.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: AppTheme.background,
                          borderRadius: BorderRadius.circular(4)),
                      child: Text(l.partyType == 'other' ? 'free text' : l.partyType,
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.textSecondary)),
                    ),
                  if (!readOnly) const Icon(Icons.expand_more, size: 18),
                ]),
              ),
            ),
          ),
          if (!readOnly && _lines.length > 1)
            IconButton(
              onPressed: () => setState(() {
                _lines[i].dispose();
                _lines.removeAt(i);
              }),
              icon: const Icon(Icons.delete_outline, size: 20),
              color: AppTheme.textSecondary,
              tooltip: 'Remove',
            ),
        ]),
        const SizedBox(height: 12),
        // Bank details (free text, multiline) + bullet helper.
        Row(children: [
          const Text('Bank Details',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const Spacer(),
          if (!readOnly)
            TextButton.icon(
              onPressed: () => _insertBullet(l.bankCtrl),
              icon: const Icon(Icons.format_list_bulleted, size: 16),
              label: const Text('Bullet'),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: const Size(0, 30)),
            ),
        ]),
        const SizedBox(height: 4),
        TextField(
          controller: l.bankCtrl,
          enabled: !readOnly,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            hintText:
                'Bank name, account title, account no, IBAN…\n(auto-filled from profile if set)',
            isDense: true,
            filled: true,
            fillColor: readOnly ? AppTheme.background : Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        const SizedBox(height: 12),
        amounts,
        if (l.partyId != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.history, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(
              l.lastPayment == null
                  ? 'No prior payment on record'
                  : 'Last paid: ${DateFormat('d MMM yyyy').format(l.lastPayment!)}',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ]),
        ],
        if (!readOnly) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: l.partyId == null ? null : () => _parkLine(l),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Done — add another'),
            ),
          ),
        ],
      ]),
    );
  }

  /// Collapse a finished line into a one-row summary and open a fresh entry
  /// card below it, so the same area is reused for the next party.
  void _parkLine(_PaLine l) {
    setState(() {
      l.collapsed = true;
      if (!_lines.any((x) => !x.collapsed)) _lines.add(_PaLine());
    });
  }

  /// Suggest parties whose balance is at or above a user-given threshold, and
  /// add the selected ones as parked lines (bank / due / pay / last-paid
  /// pre-filled). Amounts stay editable afterwards.
  Future<void> _suggestParties() async {
    if (_readOnly) return;
    // Pull balances LIVE right now so the suggestion reflects current
    // outstanding amounts (a payment made elsewhere since this screen opened
    // would otherwise show stale). Last-payment dates are reference only.
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId != null) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      await _loadBalancesInBackground(orgId);
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!_balancesLoaded) {
      _snack('Balances are still loading — try again in a moment.');
      return;
    }
    final existing = <String>{
      for (final l in _lines)
        if (l.partyId != null) _lineKey(l),
    };
    final picked = await showDialog<List<_Party>>(
      context: context,
      builder: (_) => _SuggestDialog(parties: _parties, alreadyAdded: existing),
    );
    if (picked == null || picked.isEmpty) return;
    setState(() {
      // Drop an untouched empty entry card so the parked list reads cleanly.
      _lines.removeWhere(
          (x) => !x.collapsed && x.partyId == null && x.payCtrl.text.isEmpty);
      for (final p in picked) {
        final l = _PaLine()
          ..partyId = p.id
          ..partyType = p.type
          ..partyName = p.name
          ..lastPayment = p.lastPayment
          ..collapsed = true;
        l.bankCtrl.text = p.bank;
        l.dueCtrl.text = p.balance == 0 ? '' : _numStr(p.balance);
        l.payCtrl.text = p.balance == 0 ? '' : _numStr(p.balance);
        _lines.add(l);
      }
      if (!_lines.any((x) => !x.collapsed)) _lines.add(_PaLine());
    });
  }

  Widget _collapsedRow(int i, bool readOnly) {
    final l = _lines[i];
    final due = double.tryParse(l.dueCtrl.text.trim()) ?? 0;
    final pay = double.tryParse(l.payCtrl.text.trim()) ?? 0;
    return InkWell(
      onTap: readOnly
          ? null
          : () => setState(() {
                // Re-open this line; drop an untouched empty entry card so
                // only one card is open at a time.
                _lines.removeWhere((x) =>
                    !x.collapsed && x.partyId == null && x != l);
                for (final x in _lines) {
                  if (x != l && !x.collapsed) x.collapsed = true;
                }
                l.collapsed = false;
              }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Icon(
              l.partyType == 'customer'
                  ? Icons.store_outlined
                  : l.partyType == 'other'
                      ? Icons.edit_note_outlined
                      : Icons.local_shipping_outlined,
              size: 16,
              color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.partyName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (l.lastPayment != null)
                    Text(
                        'Last paid ${DateFormat('d MMM yyyy').format(l.lastPayment!)}',
                        style: const TextStyle(
                            fontSize: 10.5, color: AppTheme.textSecondary)),
                ]),
          ),
          const SizedBox(width: 8),
          Text('Due ${_numStr(due)}',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(width: 12),
          Text('Pay Rs ${_numStr(pay)}',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (!readOnly) ...[
            const SizedBox(width: 4),
            IconButton(
              onPressed: () => setState(() {
                _lines[i].dispose();
                _lines.removeAt(i);
                if (_lines.isEmpty) _lines.add(_PaLine());
              }),
              icon: const Icon(Icons.close, size: 16),
              color: AppTheme.textSecondary,
              tooltip: 'Remove',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ]),
      ),
    );
  }

  // ── Print / PDF ────────────────────────────────────────────────────────
  /// Print button with two copies: the standard slip, and an Accounts copy
  /// that leaves out the party's current balance / payable (Amount due).
  Widget _printMenu(Map<String, dynamic> a, {double size = 24}) =>
      PopupMenuButton<bool>(
        tooltip: 'Print / PDF',
        icon: Icon(Icons.print_outlined, size: size, color: AppTheme.textSecondary),
        onSelected: (acc) => _print(a, accountsCopy: acc),
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: false,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.print_outlined),
              title: Text('Print'),
              subtitle: Text('With amount due'),
            ),
          ),
          PopupMenuItem(
            value: true,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.account_balance_outlined),
              title: Text('Accounts copy'),
              subtitle: Text('Without balance / payable'),
            ),
          ),
        ],
      );

  Future<void> _print(Map<String, dynamic> a, {bool accountsCopy = false}) async {
    try {
      final rows = await _db
          .from('payment_advice_lines')
          .select()
          .eq('advice_id', a['id'])
          .order('line_order');
      final lines = [
        for (final r in rows as List)
          PaymentAdvicePdfLine(
            partyName: (r['party_name'] as String?) ?? '',
            partyType: (r['party_type'] as String?) ?? '',
            bankDetails: (r['bank_details'] as String?) ?? '',
            amountDue: ((r['amount_due'] as num?) ?? 0).toDouble(),
            amountToPay: ((r['amount_to_pay'] as num?) ?? 0).toDouble(),
            lastPayment:
                DateTime.tryParse((r['last_payment_date'] as String?) ?? ''),
          ),
      ];
      // Signatures: the snapshot taken when the user acted; for advices made
      // before signatures existed, fall back to the user's signature on file.
      final status = (a['status'] as String?) ?? 'approved';
      final createdSigUrl = (a['created_signature_url'] as String?) ??
          await _signatureOf(a['created_by'] as String?);
      final approvedSigUrl = (a['approved_signature_url'] as String?) ??
          (status == 'approved' || status == 'void'
              ? await _signatureOf(a['approved_by'] as String?)
              : null);
      final stampUrl = (a['approved_stamp_url'] as String?) ??
          (a['approved_by'] != null ? await _orgStamp(a['org_id'] as String?) : null);
      Future<pw.ImageProvider?> img(String? url) async {
        if (url == null || url.isEmpty) return null;
        try {
          return await networkImage(url);
        } catch (_) {
          return null;
        }
      }
      final sigs = _sigEnabled
          ? await Future.wait([img(createdSigUrl), img(approvedSigUrl), img(stampUrl)])
          : <pw.ImageProvider?>[
              null,
              // The watermark grid can carry the approver's signature even when
              // the signature boxes are switched off.
              _approvalMarkEnabled ? await img(approvedSigUrl) : null,
              null,
            ];
      final bytes = await PaymentAdvicePdf.build(
        orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation',
        adviceNumber: (a['advice_number'] as String?) ?? '',
        adviceDate:
            DateTime.tryParse(a['advice_date'] as String? ?? '') ?? DateTime.now(),
        status: (a['status'] as String?) ?? 'approved',
        note: (a['note'] as String?) ?? '',
        lines: lines,
        grandTotal: ((a['grand_total'] as num?) ?? 0).toDouble(),
        createdBy: (a['created_by_name'] as String?) ?? '—',
        createdAt: DateTime.tryParse(a['created_at'] as String? ?? ''),
        approvedBy: a['approved_by_name'] as String?,
        approvedAt: DateTime.tryParse(a['approved_at'] as String? ?? ''),
        accountsCopy: accountsCopy,
        qrUrl: (a['public_token'] as String?)?.isNotEmpty == true
            ? '${html.window.location.origin}/#/pa/${a['public_token']}'
            : null,
        createdSignature: sigs[0],
        approvedSignature: _sigEnabled ? sigs[1] : null,
        approvedStamp: sigs[2],
        approvalWatermark: _approvalMarkEnabled,
        approvalMarkSignature: sigs[1],
        voidedBy: a['voided_by_name'] as String?,
        voidedAt: DateTime.tryParse(a['voided_at'] as String? ?? ''),
        voidReason: a['void_reason'] as String?,
      );
      await outputPdf(bytes,
          'Payment Advice ${a['advice_number'] ?? ''}${accountsCopy ? ' Accounts copy' : ''}',
          date: DateTime.tryParse(a['advice_date'] as String? ?? ''));
    } catch (e) {
      _snack('Print failed: $e');
    }
  }

  Widget _amountField(String label, TextEditingController c,
      {required bool enabled, ValueChanged<String>? onChanged}) {
    return TextField(
      controller: c,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixText: 'Rs ',
        isDense: true,
        filled: true,
        fillColor: enabled ? Colors.white : AppTheme.background,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _grandTotalBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Text('GRAND TOTAL',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        const Spacer(),
        Text('Rs ${_grandTotal.toStringAsFixed(_grandTotal == _grandTotal.roundToDouble() ? 0 : 2)}',
            style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: AppTheme.primary)),
      ]),
    );
  }

  Widget _footprints() {
    final a = _current;
    final createdBy = a?['created_by_name'] as String? ??
        ref.read(currentUserProvider)?.name ??
        '—';
    final createdAt = a?['created_at'] != null
        ? DateFormat('d MMM yyyy, HH:mm')
            .format(DateTime.tryParse(a!['created_at'] as String)!.toLocal())
        : '—';
    final status = (a?['status'] as String?) ?? 'approved';
    final isApproved = status == 'approved';
    // Fallback for older rows saved before the auto-approve stamp: an approved
    // slip with no approver recorded was approved on creation, so show the
    // creator rather than a blank.
    final approvedBy = (a?['approved_by_name'] as String?) ??
        (isApproved ? createdBy : null);
    final approvedAt = a?['approved_at'] != null
        ? DateFormat('d MMM yyyy, HH:mm')
            .format(DateTime.tryParse(a!['approved_at'] as String)!.toLocal())
        : (isApproved ? createdAt : null);
    Widget foot(String label, String who, String when, [String? sigUrl]) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text(who, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(when,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
            if (_sigEnabled && sigUrl != null && sigUrl.isNotEmpty) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: 44,
                width: 140,
                child: Image.network(sigUrl,
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            ],
          ]),
        );
    final box = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        foot('CREATED BY', createdBy, createdAt,
            (a?['created_signature_url'] as String?) ?? _sigOnFile[a?['created_by']]),
        if (status == 'rejected')
          foot(
              'REJECTED BY',
              (a?['rejected_by_name'] as String?) ?? '—',
              a?['rejected_at'] != null
                  ? DateFormat('d MMM yyyy, HH:mm').format(
                      DateTime.tryParse(a!['rejected_at'] as String)!.toLocal())
                  : '—')
        else
          foot('APPROVED BY', approvedBy ?? '—',
              approvedAt ?? (status == 'pending' ? 'Awaiting approval' : '—'),
              (a?['approved_signature_url'] as String?) ??
                  (isApproved ? _sigOnFile[a?['approved_by']] : null)),
      ]),
    );
    if (_sigEnabled || !_isAdmin || a == null) return box;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      box,
      const SizedBox(height: 6),
      const Text(
          'Signature images are off. Turn on "Signatures on Payment Advice print" in Admin Settings (Financials).',
          style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
  }

  Widget _actionBar(bool readOnly) {
    final pending = _current?['status'] == 'pending';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          if (readOnly) ...[
            Expanded(
              child: Text(
                  _isVoid
                      ? 'Voided${_current?['voided_by_name'] != null ? ' by ${_current!['voided_by_name']}' : ''}'
                          '${(_current?['void_reason'] as String?)?.isNotEmpty == true ? ' — ${_current!['void_reason']}' : ''}'
                      : _isRejected
                          ? 'This advice was rejected — it can only be archived.'
                          : 'This advice is approved and locked.',
                  style: const TextStyle(color: AppTheme.textSecondary)),
            ),
            if (_canVoid) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : _void,
                icon: const Icon(Icons.block, size: 18),
                label: const Text('Void'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    side: const BorderSide(color: AppTheme.danger),
                    minimumSize: const Size(0, 48)),
              ),
            ],
            if (_canAdminEdit) ...[
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _saving ? null : () => setState(() => _adminEditing = true),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit (admin)'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            ],
          ] else ...[
            if (_adminEditing) ...[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : () => _openAdvice(_current!),
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Cancel edit'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(_adminEditing
                    ? 'Save changes (logged)'
                    : _approvalEnabled && _current == null
                        ? 'Save & send for approval'
                        : 'Save'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            ),
            if (pending && _canModerate) ...[
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _reject,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: const BorderSide(color: AppTheme.danger),
                      minimumSize: const Size(0, 48)),
                ),
              ),
            ],
            if (pending && _canVoid) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _saving ? null : _void,
                icon: const Icon(Icons.block, size: 18),
                label: const Text('Void'),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    side: const BorderSide(color: AppTheme.danger),
                    minimumSize: const Size(0, 48)),
              ),
            ],
            if (pending && _canApprove) ...[
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _approve,
                  icon: const Icon(Icons.verified_outlined, size: 18),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.success,
                      minimumSize: const Size(0, 48)),
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

// ── Party picker dialog ────────────────────────────────────────────────────
class _PartyPickerDialog extends StatefulWidget {
  final List<_Party> parties;
  // Keys of parties already on the advice — shown greyed out, not pickable.
  final Set<String> taken;
  const _PartyPickerDialog({required this.parties, this.taken = const {}});

  @override
  State<_PartyPickerDialog> createState() => _PartyPickerDialogState();
}

class _PartyPickerDialogState extends State<_PartyPickerDialog> {
  String _q = '';
  String _type = 'all'; // all | customer | supplier

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = widget.parties.where((p) {
      if (_type != 'all' && p.type != _type) return false;
      if (q.isEmpty) return true;
      return p.name.toLowerCase().contains(q);
    }).toList();
    final typed = _q.trim();
    // Offer the typed text as a free-text party (someone not in the customer
    // or supplier master), unless it exactly matches a master party.
    final showFree = typed.isNotEmpty &&
        !widget.parties.any((p) => p.name.trim().toLowerCase() == typed.toLowerCase());
    final freeTaken = widget.taken.contains('other:${typed.toLowerCase()}');
    final mq = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: mq.width < 500 ? mq.width - 32 : 460,
        height: mq.height < 640 ? mq.height * 0.85 : 560,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(children: [
              Row(children: [
                const Text('Select party',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 8),
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search, or type a new name…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  border:
                      OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                _chip('All', 'all'),
                const SizedBox(width: 6),
                _chip('Customers', 'customer'),
                const SizedBox(width: 6),
                _chip('Suppliers', 'supplier'),
              ]),
            ]),
          ),
          const Divider(height: 1),
          if (showFree)
            ListTile(
              dense: true,
              enabled: !freeTaken,
              tileColor: AppTheme.primary.withOpacity(0.06),
              leading: const Icon(Icons.edit_note_outlined, size: 20, color: AppTheme.primary),
              title: Text('Add "$typed" as a free-text party',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  freeTaken ? 'Already on this advice' : 'Not linked to a customer or supplier — enter bank details and amounts yourself',
                  style: const TextStyle(fontSize: 11)),
              onTap: freeTaken
                  ? null
                  : () => Navigator.pop(
                      context,
                      _Party('ft_${DateTime.now().microsecondsSinceEpoch}', typed, 'other', '', 0)),
            ),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(showFree ? 'No matching customer or supplier' : 'No matches'))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      final isTaken = widget.taken.contains('${p.type}:${p.id}');
                      return ListTile(
                        dense: true,
                        enabled: !isTaken,
                        leading: Icon(
                            p.type == 'customer'
                                ? Icons.store_outlined
                                : Icons.local_shipping_outlined,
                            size: 20,
                            color: AppTheme.primary),
                        title: Text(p.name),
                        subtitle: Text(
                          isTaken
                              ? 'Already on this advice'
                              : p.balance != 0
                                  ? '${p.type} · due Rs ${p.balance.toStringAsFixed(0)}'
                                  : p.type,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: isTaken ? null : () => Navigator.pop(context, p),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String label, String val) {
    final sel = _type == val;
    return InkWell(
      onTap: () => setState(() => _type = val),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: sel ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: sel ? Colors.white : AppTheme.textPrimary)),
      ),
    );
  }
}

// ── Suggest-by-balance dialog ──────────────────────────────────────────────
class _SuggestDialog extends StatefulWidget {
  final List<_Party> parties;
  final Set<String> alreadyAdded; // 'type:id'
  const _SuggestDialog({required this.parties, required this.alreadyAdded});

  @override
  State<_SuggestDialog> createState() => _SuggestDialogState();
}

class _SuggestDialogState extends State<_SuggestDialog> {
  final TextEditingController _thrCtrl =
      TextEditingController(text: '1000');
  double _threshold = 1000;
  String _type = 'all'; // all | customer | supplier
  final Set<String> _selected = {};

  @override
  void dispose() {
    _thrCtrl.dispose();
    super.dispose();
  }

  String _numStr(double d) =>
      d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);

  List<_Party> get _matches {
    final list = widget.parties.where((p) {
      if (widget.alreadyAdded.contains('${p.type}:${p.id}')) return false;
      if (_type != 'all' && p.type != _type) return false;
      return p.balance >= _threshold;
    }).toList()
      ..sort((a, b) => b.balance.compareTo(a.balance));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    final shown = _matches;
    final allKeys = shown.map((p) => '${p.type}:${p.id}').toSet();
    final allSelected =
        allKeys.isNotEmpty && _selected.containsAll(allKeys);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: mq.width < 560 ? mq.width - 32 : 520,
        height: mq.height < 680 ? mq.height * 0.88 : 600,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(children: [
              Row(children: [
                const Text('Suggest parties by balance',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _thrCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Balance at or above',
                      prefixText: 'Rs ',
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onChanged: (v) => setState(() {
                      _threshold = double.tryParse(v.trim()) ?? 0;
                      _selected.removeWhere((k) => !_matches
                          .any((p) => '${p.type}:${p.id}' == k));
                    }),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _chip('All', 'all'),
                const SizedBox(width: 6),
                _chip('Customers', 'customer'),
                const SizedBox(width: 6),
                _chip('Suppliers', 'supplier'),
                const Spacer(),
                Text('${shown.length} match${shown.length == 1 ? '' : 'es'}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ]),
            ]),
          ),
          const Divider(height: 1),
          if (shown.isNotEmpty)
            CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: allSelected,
              title: Text(allSelected ? 'Clear all' : 'Select all',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              onChanged: (_) => setState(() {
                if (allSelected) {
                  _selected.removeAll(allKeys);
                } else {
                  _selected.addAll(allKeys);
                }
              }),
            ),
          const Divider(height: 1),
          Expanded(
            child: shown.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No parties at or above this balance.\n'
                        'Lower the threshold, or balances may still be loading.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      final key = '${p.type}:${p.id}';
                      return CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _selected.contains(key),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(key);
                          } else {
                            _selected.remove(key);
                          }
                        }),
                        title: Text(p.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${p.type} · current balance Rs ${_numStr(p.balance)}'
                          '${p.lastPayment == null ? '' : ' · last paid ${DateFormat('d MMM yyyy').format(p.lastPayment!)} (ref)'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        secondary: Icon(
                            p.type == 'customer'
                                ? Icons.store_outlined
                                : Icons.local_shipping_outlined,
                            size: 20,
                            color: AppTheme.primary),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: Text(
                    _selected.isEmpty
                        ? 'Select parties to add'
                        : '${_selected.length} selected',
                    style: const TextStyle(color: AppTheme.textSecondary)),
              ),
              ElevatedButton.icon(
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        final chosen = widget.parties
                            .where((p) =>
                                _selected.contains('${p.type}:${p.id}'))
                            .toList();
                        Navigator.pop(context, chosen);
                      },
                icon: const Icon(Icons.add, size: 18),
                label: Text('Add ${_selected.length}'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String label, String val) {
    final sel = _type == val;
    return InkWell(
      onTap: () => setState(() {
        _type = val;
        _selected.removeWhere(
            (k) => !_matches.any((p) => '${p.type}:${p.id}' == k));
      }),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: sel ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: sel ? Colors.white : AppTheme.textPrimary)),
      ),
    );
  }
}


// ── Audit trail ──────────────────────────────────────────────────────────
class _PaAuditTrail extends StatelessWidget {
  final String adviceId;
  const _PaAuditTrail({super.key, required this.adviceId});

  static const _labels = {
    'created': 'Created',
    'saved': 'Edited',
    'approved': 'Approved',
    'rejected': 'Rejected',
    'edited_after_approval': 'Edited after approval (admin)',
    'voided': 'Voided',
    'archived': 'Archived',
    'unarchived': 'Unarchived',
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: Supabase.instance.client
          .from('voucher_audit_log')
          .select('action, details, performed_by, performed_at')
          .eq('voucher_id', adviceId)
          .eq('voucher_type', 'PA')
          .order('performed_at', ascending: false)
          .limit(50),
      builder: (ctx, snap) {
        final rows = snap.hasData ? List<Map<String, dynamic>>.from(snap.data!) : const <Map<String, dynamic>>[];
        return FutureBuilder<Map<String, String>>(
          future: _names(rows),
          builder: (ctx, ns) {
            final names = ns.data ?? const <String, String>{};
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('AUDIT TRAIL',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppTheme.textSecondary)),
                const SizedBox(height: 8),
                if (rows.isEmpty)
                  Text(snap.connectionState == ConnectionState.waiting ? 'Loading…' : 'No activity logged yet.',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                else
                  for (final r in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.history,
                            size: 14,
                            color: (r['action'] == 'voided' || r['action'] == 'rejected')
                                ? AppTheme.danger
                                : r['action'] == 'edited_after_approval'
                                    ? AppTheme.warning
                                    : AppTheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              '${_labels[r['action']] ?? r['action']}'
                              '${names[r['performed_by']] != null ? ' · ${names[r['performed_by']]}' : ''}',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                            if (((r['details'] as String?) ?? '').isNotEmpty)
                              Text(r['details'] as String,
                                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                          ]),
                        ),
                        Text(
                          r['performed_at'] == null
                              ? ''
                              : DateFormat('d MMM yyyy, HH:mm').format(
                                  DateTime.parse(r['performed_at'] as String).toLocal()),
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                        ),
                      ]),
                    ),
              ]),
            );
          },
        );
      },
    );
  }

  static Future<Map<String, String>> _names(List<Map<String, dynamic>> rows) async {
    final ids = rows.map((r) => r['performed_by'] as String?).whereType<String>().toSet().toList();
    if (ids.isEmpty) return {};
    try {
      final us = await Supabase.instance.client.from('users').select('id, name').inFilter('id', ids);
      return {for (final u in us as List) u['id'] as String: (u['name'] as String?) ?? ''};
    } catch (_) {
      return {};
    }
  }
}
