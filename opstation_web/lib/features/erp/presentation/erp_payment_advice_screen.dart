import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../pdf/payment_advice_pdf.dart';

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
  final String type; // 'customer' | 'supplier'
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
  Set<String> _approvers = {};

  // Data
  List<Map<String, dynamic>> _advices = [];
  final List<_Party> _parties = [];
  final Map<String, _Party> _partyById = {};
  bool _balancesLoaded = false;
  bool _showArchived = false;

  // Editor state
  bool _editing = false;
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
      f.timeout(const Duration(seconds: 10));

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
            .inFilter('key', ['org.pa_approval_enabled', 'org.pa_approvers']));
        final cfg = <String, String>{};
        for (final r in cfgRows as List) {
          cfg[r['key'] as String] = (r['value'] as String?) ?? '';
        }
        _approvalEnabled = cfg['org.pa_approval_enabled'] == 'true';
        final ap = (cfg['org.pa_approvers'] ?? '').trim();
        _approvers = ap.isEmpty
            ? <String>{}
            : ap.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
      } catch (_) {
        _approvalEnabled = false;
        _approvers = <String>{};
      }

      // Saved advices (time-boxed so a slow/absent table can't hang the page).
      _setStage('advices');
      final adv = await _timed(_db
          .from('payment_advices')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: false)
          .limit(500));
      _advices = List<Map<String, dynamic>>.from(adv as List);

      // Party master — resilient to the bank_details column not existing yet
      // (falls back to a select without it) and time-boxed.
      _parties.clear();
      _partyById.clear();
      // Load both party tables IN PARALLEL and never let one block the other:
      // a slow/locked table just yields an empty list + a warning banner.
      _setStage('customers & suppliers');
      _partyWarning = null;
      final results = await Future.wait<List>([
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
      final custs = results[0];
      final sups = results[1];

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

  bool get _canApprove {
    final me = ref.read(currentUserProvider);
    if (me == null) return false;
    return _approvalEnabled && _approvers.contains(me.id);
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
      for (final r in lines as List) {
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

  String _numStr(dynamic v) {
    final d = (v as num?)?.toDouble() ?? 0;
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d.toStringAsFixed(2);
  }

  // ── Party picker ───────────────────────────────────────────────────────
  Future<void> _pickParty(_PaLine line) async {
    if (_isApproved) return;
    final picked = await showDialog<_Party>(
      context: context,
      builder: (_) => _PartyPickerDialog(parties: _parties),
    );
    if (picked == null) return;
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
    setState(() => _saving = true);
    try {
      final isNew = _current == null;
      final total = _grandTotal;
      String adviceId;
      String number;
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
          if (autoApproved) 'approved_at': DateTime.now().toIso8601String(),
        });
      } else {
        adviceId = _current!['id'] as String;
        await _db.from('payment_advices').update({
          'advice_date': DateFormat('yyyy-MM-dd').format(_date),
          'note': _noteCtrl.text.trim(),
          'grand_total': total,
          'updated_at': DateTime.now().toIso8601String(),
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

      if (!mounted) return;
      setState(() {
        _editing = false;
        _saving = false;
      });
      await _loadAll();
      _snack('Payment advice saved.');
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
        'approved_at': DateTime.now().toIso8601String(),
      }).eq('id', _current!['id']);
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
    try {
      await _db.from('payment_advices').update({
        'is_archived': archived,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', a['id']);
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
          child: Text(_partyWarning!,
              style: const TextStyle(fontSize: 12, color: AppTheme.warning)),
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
              color: (pending ? AppTheme.warning : AppTheme.success)
                  .withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(pending ? 'Pending' : 'Approved',
                style: TextStyle(
                    color: pending ? AppTheme.warning : AppTheme.success,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => _print(a),
            icon: const Icon(Icons.print_outlined, size: 20),
            color: AppTheme.textSecondary,
            tooltip: 'Print / PDF',
          ),
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
    final readOnly = _isApproved;
    final narrow = MediaQuery.of(context).size.width < 760;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        IconButton(
          onPressed: () => setState(() => _editing = false),
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
        ),
        Expanded(
          child: Text(
            _current == null
                ? 'New Payment Advice'
                : '${_current!['advice_number']}'
                    '${readOnly ? ' (Approved)' : _current!['status'] == 'pending' ? ' (Pending)' : ''}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        if (_current != null)
          IconButton(
            onPressed: () => _print(_current!),
            icon: const Icon(Icons.print_outlined),
            tooltip: 'Print / PDF',
          ),
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
                // Parked (collapsed) parties: one line each, above the entry area.
                for (var i = 0; i < _lines.length; i++)
                  if (_lines[i].collapsed) ...[
                    _collapsedRow(i, readOnly),
                    const SizedBox(height: 6),
                  ],
                // Open entry cards (normally just one).
                for (var i = 0; i < _lines.length; i++)
                  if (!_lines[i].collapsed) ...[
                    const SizedBox(height: 6),
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
                      child: Text(l.partyType,
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
    if (_isApproved) return;
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
        if (l.partyId != null) '${l.partyType}:${l.partyId}',
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
  Future<void> _print(Map<String, dynamic> a) async {
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
      );
      await Printing.layoutPdf(
          name: 'Payment Advice ${a['advice_number'] ?? ''}',
          onLayout: (_) async => bytes);
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
    Widget foot(String label, String who, String when) => Expanded(
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
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        foot('CREATED BY', createdBy, createdAt),
        foot('APPROVED BY', approvedBy ?? '—',
            approvedAt ?? (status == 'pending' ? 'Awaiting approval' : '—')),
      ]),
    );
  }

  Widget _actionBar(bool readOnly) {
    final pending = _current?['status'] == 'pending';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          if (readOnly)
            const Expanded(
              child: Text('This advice is approved and locked.',
                  style: TextStyle(color: AppTheme.textSecondary)),
            )
          else ...[
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
                label: Text(_approvalEnabled && _current == null
                    ? 'Save & send for approval'
                    : 'Save'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
              ),
            ),
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
  const _PartyPickerDialog({required this.parties});

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
                  hintText: 'Search parties…',
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
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('No matches'))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p = shown[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                            p.type == 'customer'
                                ? Icons.store_outlined
                                : Icons.local_shipping_outlined,
                            size: 20,
                            color: AppTheme.primary),
                        title: Text(p.name),
                        subtitle: Text(
                          p.balance != 0
                              ? '${p.type} · due Rs ${p.balance.toStringAsFixed(0)}'
                              : p.type,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => Navigator.pop(context, p),
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
