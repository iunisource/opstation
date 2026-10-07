// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import '../../../core/widgets/saving_overlay.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';
import '../../../core/permissions/access_control.dart';
import '../widgets/voucher_docs_panel.dart';
import '../../../core/utils/friendly_error.dart';
import 'package:opstation_web/core/widgets/branch_empty_hint.dart';
import 'package:opstation_web/core/widgets/voucher_sort.dart';

class _JvLine {
  static int _seq = 0;
  final String id = 'jvl_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? accountId; String accountName = ''; String accountType = 'coa';
  String? glAccountId; // GL account a party line was loaded with (keeps 1420 advances on 1420)
  final TextEditingController descCtrl   = TextEditingController();
  final TextEditingController debitCtrl  = TextEditingController();
  final TextEditingController creditCtrl = TextEditingController();
  double get debit  => double.tryParse(debitCtrl.text)  ?? 0;
  double get credit => double.tryParse(creditCtrl.text) ?? 0;
  void dispose() { descCtrl.dispose(); debitCtrl.dispose(); creditCtrl.dispose(); }
}

class ErpJournalVoucherScreen extends ConsumerStatefulWidget {
  const ErpJournalVoucherScreen({super.key, this.focusId});
  /// Changing this (a new ?focus= link while the screen is open) re-runs the deep link.
  final String? focusId;
  @override ConsumerState<ErpJournalVoucherScreen> createState() => _State();
}

class _State extends ConsumerState<ErpJournalVoucherScreen> {
  List<Map<String,dynamic>> _vouchers = []; bool _drawerOpen = true, _loadingList = true;
  String _listSearch = ''; OverlayEntry? _ctxOverlay;
  Map<String,dynamic>? _current; DateTime _date = DateTime.now();
  final _dateCtrl = TextEditingController(); final _narCtrl = TextEditingController();
  String _status = 'draft'; List<_JvLine> _lines = [];
  List<Map<String,dynamic>> _coaList = [];
  List<Map<String,dynamic>> _supplierList = [];
  List<Map<String,dynamic>> _customerList = [];
  List<Map<String,dynamic>> _allAccounts = [];
  List<Map<String,dynamic>> _auditTrail = [];
  bool _loadingMaster = true, _saving = false;
  bool _jvSuperviseFlow = false; // org.jv_supervise_flow: docs + non-blocking supervise
  bool _jvApproveFlow = false;   // org.jv_approve_flow: BLOCKING approval before posting
  bool _jvVoidFlow = false;      // org.jv_void_flow: posted JVs are VOIDED (reversal), not deleted
  bool _superviseBusy = false;
  String _statusFilter = 'all'; // all | draft | pending | posted
  final Set<String> _sel = {};   // ticked JVs for bulk approve / supervise
  bool _bulkBusy = false;
  String _supFilter = 'all';    // all | yes | no
  String? _pendingFocusId;
  int _auditSeq = 0;

  String? get _orgId    => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }
  bool get _isLocked => _status == 'posted';
  double get _totalDr => _lines.fold(0, (s,l) => s + l.debit);
  double get _totalCr => _lines.fold(0, (s,l) => s + l.credit);
  bool get _balanced  => (_totalDr - _totalCr).abs() < 0.005 && _totalDr > 0;
  bool get _canPost   => _balanced && _lines.where((l) => l.accountId != null).length >= 2;

  @override void initState() {
    super.initState();
    _dateCtrl.text = DateFormat('dd MMM yyyy').format(_date);
    _lines = [_JvLine(), _JvLine()];
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadMaster(); _loadVouchersAndAutoSelect(); _ensureAccessReady(); _loadJvFlag(); });
  }
  @override void dispose() { _ctxOverlay?.remove(); _dateCtrl.dispose(); _narCtrl.dispose(); for (final l in _lines) l.dispose(); super.dispose(); }
  @override
  void didUpdateWidget(covariant ErpJournalVoucherScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusId != oldWidget.focusId && widget.focusId != null) _loadVouchersAndAutoSelect();
  }
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadJvFlag([int tries = 0]) async {
    final orgId = _orgId;
    // On a cold load the user/org can populate a beat after mount. Retry a few
    // times instead of silently leaving the flags off (which hid the panel).
    if (orgId == null) {
      if (tries >= 10) return;
      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) _loadJvFlag(tries + 1);
      return;
    }
    try {
      final rows = await Supabase.instance.client.from('app_config').select('key,value')
          .eq('org_id', orgId).inFilter('key', ['org.jv_supervise_flow', 'org.jv_approve_flow', 'org.jv_void_flow']);
      final m = {for (final r in (rows as List)) r['key'] as String: r['value'] as String?};
      if (mounted) setState(() {
        _jvSuperviseFlow = m['org.jv_supervise_flow'] == 'true';
        _jvApproveFlow = m['org.jv_approve_flow'] == 'true';
        _jvVoidFlow = m['org.jv_void_flow'] == 'true';
      });
    } catch (_) {}
  }

  // Blocking approval (org.jv_approve_flow): a non-admin can't post to the GL —
  // they submit the JV for approval; an admin then posts it.
  Future<void> _submitForApproval() async {
    if (!_canPost) { _snack('Debits must equal credits before submitting'); return; }
    await _save(post: false, submitForApproval: true);
  }

  // Non-blocking supervise mark on a JV (org.jv_supervise_flow). The JV posts to
  // the GL regardless — this only records that an admin reviewed it.
  Future<void> _supervise() async {
    if (!_isAdmin) { _snack('You are not allowed to supervise'); return; }
    final id = _current?['id'] as String?; if (id == null || _superviseBusy) return;
    setState(() => _superviseBusy = true);
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name;
    final now = DateTime.now().toUtc().toIso8601String();
    String? sigUrl; String? stampUrl;
    try { final u = await Supabase.instance.client.from('users').select('signature_url').eq('id', userId ?? '').maybeSingle(); sigUrl = u?['signature_url'] as String?; } catch (_) {}
    try { final s = await Supabase.instance.client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.stamp_url').maybeSingle(); stampUrl = s?['value'] as String?; } catch (_) {}
    try {
      await Supabase.instance.client.from('journal_entries').update({
        'supervised_by': userId, 'supervised_at': now, 'supervised_by_name': userName,
        'supervised_signature_url': sigUrl, 'supervised_stamp_url': stampUrl,
      }).eq('id', id);
      if (mounted) setState(() {
        _current!['supervised_by'] = userId; _current!['supervised_at'] = now;
        _current!['supervised_by_name'] = userName;
      });
      for (final v in _vouchers) {
        if (v['id'] == id) { v['supervised_at'] = now; v['supervised_by'] = userId; v['supervised_by_name'] = userName; }
      }
      _snack('Marked as supervised');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
    finally { if (mounted) setState(() => _superviseBusy = false); }
  }

  Future<void> _clearSupervision() async {
    if (!_isAdmin) return;
    final id = _current?['id'] as String?; if (id == null) return;
    try {
      await Supabase.instance.client.from('journal_entries').update({
        'supervised_by': null, 'supervised_at': null, 'supervised_by_name': null,
        'supervised_signature_url': null, 'supervised_stamp_url': null,
      }).eq('id', id);
      if (mounted) setState(() {
        _current!['supervised_by'] = null; _current!['supervised_at'] = null; _current!['supervised_by_name'] = null;
      });
      for (final v in _vouchers) {
        if (v['id'] == id) { v['supervised_at'] = null; v['supervised_by'] = null; v['supervised_by_name'] = null; }
      }
      _snack('Supervision cleared');
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  Widget _jvSuperviseBlock() {
    final supervisedAt = _current?['supervised_at'] as String?;
    final by = _current?['supervised_by_name'] as String?;
    if (supervisedAt != null) {
      String when = supervisedAt;
      try { when = DateFormat('d MMM yyyy').format(DateTime.parse(supervisedAt).toLocal()); } catch (_) {}
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withOpacity(0.35))),
        child: Row(children: [
          const Icon(Icons.verified_user, size: 16, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text('Supervised${by != null && by.isNotEmpty ? ' by $by' : ''} · $when', style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600))),
          if (_isAdmin) TextButton(onPressed: _clearSupervision, child: const Text('Clear', style: TextStyle(fontSize: 12))),
        ]),
      );
    }
    if (!_isAdmin) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
        child: const Row(children: [
          Icon(Icons.verified_user_outlined, size: 15, color: Colors.orange), SizedBox(width: 8),
          Text('Awaiting supervision', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );
    }
    return OutlinedButton.icon(
      onPressed: _superviseBusy ? null : _supervise,
      icon: _superviseBusy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.verified_user_outlined, size: 16),
      label: const Text('Supervise', style: TextStyle(fontSize: 12)),
    );
  }

  // Cold-refresh access fix: currentUserProvider can populate without notifying
  // accessProvider's watch, so accessProvider stays parked on its first (null-user)
  // run and access never resolves. Invalidating it forces a re-read of the
  // now-populated user. Capped poll; stops as soon as access is resolved.
  void _ensureAccessReady([int tries = 0]) {
    if (!mounted) return;
    final a = ref.read(accessSyncProvider);
    if (a != null && a.role != null) return;
    if (tries >= 25) return;
    ref.invalidate(accessProvider);
    Future.delayed(const Duration(milliseconds: 300), () => _ensureAccessReady(tries + 1));
  }

  static String _typeLabel(dynamic t) {
    switch (t) {
      case 'asset':     return 'Asset Account';
      case 'liability': return 'Liability Account';
      case 'equity':    return 'Equity Account';
      case 'revenue':   return 'Revenue Account';
      case 'expense':   return 'Expense Account';
      default:          return 'COA';
    }
  }

  Future<void> _loadMaster() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadMaster(); return; }
    try {
      final res  = await Supabase.instance.client.rpc('get_voucher_master', params: {'p_org_id': orgId});
      final data = res as Map<String,dynamic>;
      final coa  = List<Map<String,dynamic>>.from((data['coa']       as List?) ?? []);
      final sup  = List<Map<String,dynamic>>.from((data['suppliers'] as List?) ?? []);
      final cus  = List<Map<String,dynamic>>.from((data['customers'] as List?) ?? []);
      final all = <Map<String,dynamic>>[
        // Postable leaves only: Level-4 detail accounts, or a Level-3 that has no
        // Level-4 beneath it. Never a parent/group (matches the DB post guard and
        // the CPV/CRV pickers), so an amount can't be posted to e.g. a Level-2
        // "Misc Expenses" group.
        ...coa.where((a) => !coa.any((b) => b['parent_id'] == a['id']) && ((a['level'] is num ? (a['level'] as num).toInt() : int.tryParse('${a['level']}') ?? 0) >= 3)).map((a) => {
          'id': a['id'],
          'label': "${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}",
          'sub': _typeLabel(a['account_type']),
          'account_type': a['account_type'],
          'type': 'coa',
        }),
        ...sup.map((s) => {
          'id': s['id'],
          'label': "${s['code'] != null ? '${s['code']} — ' : ''}${s['name']}",
          'sub': 'Supplier', 'type': 'supplier',
        }),
        ...cus.map((c) => {
          'id': c['id'],
          'label': "${c['code'] != null ? '${c['code']} — ' : ''}${c['shop_name'] ?? ''}",
          'sub': 'Customer', 'type': 'customer',
        }),
      ];
      if (mounted) setState(() { _coaList = coa; _supplierList = sup; _customerList = cus; _allAccounts = all; _loadingMaster = false; });
    } catch (e) { if (mounted) { _snack('Load error: $e'); setState(() => _loadingMaster = false); } }
  }

  List<Map<String,dynamic>> _filterAccounts(String q) {
    if (q.isEmpty) return _allAccounts.take(50).toList();
    return _allAccounts.where((a) =>
      matchesQuery('${a['label'] ?? ''} ${a['sub'] ?? ''}', q)
    ).take(200).toList();
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      var q = Supabase.instance.client.from('journal_entries').select().eq('org_id', orgId).eq('reference_type', 'jv');
      final bid = _branchId; if (bid != null) q = q.eq('branch_id', bid);
      final rows = await q.order('created_at', ascending: false).limit(200);
      // Void reversals (JV-…-VOID) are bookkeeping twins of a voided JV — keep
      // them out of the voucher list; they show on ledgers.
      if (mounted) setState(() { _vouchers = List<Map<String,dynamic>>.from(rows).where((r) => r['reverses_id'] == null).toList(); _loadingList = false; });
      ref.invalidate(jvPendingCountProvider); // keep the nav badge in step
    } catch (e) { if (mounted) setState(() => _loadingList = false); }
  }

  Future<void> _loadVouchersAndAutoSelect() async {
    await _loadVouchers(); if (!mounted) return;
    final href = html.window.location.href; final qIdx = href.indexOf('?'); if (qIdx == -1) return;
    final params = Uri.splitQueryString(href.substring(qIdx + 1)); final targetId = params['id'];
    if (targetId != null) { final m = _vouchers.where((v) => v['entry_number'] == targetId).toList(); if (m.isNotEmpty) _loadVoucher(m.first); }
    // Global search deep-link: ?focus=<journal_entries.id>
    final focusId = params['focus'];
    if (focusId != null) { final m = _vouchers.where((v) => v['id'] == focusId).toList(); if (m.isNotEmpty) _loadVoucher(m.first); }
  }

  void _showCtxMenu(Offset pos, Map<String,dynamic> v) {
    _ctxOverlay?.remove();
    _ctxOverlay = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque,
        onTap: () { _ctxOverlay?.remove(); _ctxOverlay = null; },
        onSecondaryTap: () { _ctxOverlay?.remove(); _ctxOverlay = null; })),
      Positioned(left: pos.dx, top: pos.dy, child: Material(elevation: 8, borderRadius: BorderRadius.circular(8),
        child: IntrinsicWidth(child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(onTap: () {
            final num = v['entry_number'] as String? ?? '';
            final href = html.window.location.href; final hIdx = href.indexOf('#');
            final origin = hIdx != -1 ? href.substring(0, hIdx) : href;
            html.window.open(origin + '#/financials/journal-vouchers?id=' + num, '_blank');
            _ctxOverlay?.remove(); _ctxOverlay = null;
          }, child: const Padding(padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.open_in_new, size: 15, color: AppTheme.textSecondary), SizedBox(width: 10),
              Text('Open in new tab', style: TextStyle(fontSize: 13))]))),
        ])))),
    ]));
    Overlay.of(context).insert(_ctxOverlay!);
  }

  void _addLine() {
    final nl = _JvLine();
    setState(() { _lines.add(nl); _pendingFocusId = nl.id; });
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => _pendingFocusId = null); });
  }
  void _removeLine(int i) { setState(() { _lines[i].dispose(); _lines.removeAt(i); }); if (_lines.length < 2) _addLine(); }
  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() { _current = null; _status = 'draft'; _lines = [_JvLine(), _JvLine()];
      _auditTrail = []; _date = DateTime.now(); _dateCtrl.text = DateFormat('dd MMM yyyy').format(_date); _narCtrl.clear(); });
  }

  Future<void> _loadVoucher(Map<String,dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('journal_lines').select().eq('entry_id', v['id'] as String).order('line_order');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) {
        final l = _JvLine();
        l.accountType = r['account_type'] as String? ?? 'coa';
        final pid = r['party_id'] as String?;
        final savedAccId = r['account_id'] as String?;
        // Lines written by SQL/imports often carry the party on party_id but a
        // generic account_type ('coa' / 'liability' / null). Infer the party type
        // so the vendor/customer link survives a re-save.
        if (pid != null && l.accountType != 'supplier' && l.accountType != 'customer') {
          final acc = savedAccId ?? '';
          if (pid.startsWith('sup_') || acc.endsWith('_2110') || _supplierList.any((s) => s['id'] == pid)) {
            l.accountType = 'supplier';
          } else if (pid.startsWith('cust_') || acc.endsWith('_1210') || _customerList.any((c) => c['id'] == pid)) {
            l.accountType = 'customer';
          }
        }
        if ((l.accountType == 'supplier' || l.accountType == 'customer') && pid != null) {
          l.accountId = pid;            // restore the picker selection to the actual party
          l.glAccountId = savedAccId;
        } else {
          l.accountId = savedAccId;
        }
        final savedName = r['account_name'] as String?;
        if (savedName != null && savedName.isNotEmpty) {
          l.accountName = savedName;
        } else {
          final m = _allAccounts.firstWhere((a) => a['id'] == l.accountId, orElse: () => {});
          l.accountName = m.isNotEmpty ? (m['label'] as String? ?? '') : (l.accountId ?? '');
        }
        l.descCtrl.text = r['description'] as String? ?? '';
        final dr = (r['debit']  as num? ?? 0).toDouble(); final cr = (r['credit'] as num? ?? 0).toDouble();
        if (dr > 0) l.debitCtrl.text  = dr.toStringAsFixed(2);
        if (cr > 0) l.creditCtrl.text = cr.toStringAsFixed(2);
        return l;
      }).toList();
      final d = DateTime.tryParse(v['entry_date'] as String? ?? '') ?? DateTime.now();
      if (mounted) setState(() { _current = v; _status = v['status'] as String? ?? 'draft';
        _lines = newLines.isEmpty ? [_JvLine(), _JvLine()] : newLines;
        _date = d; _dateCtrl.text = DateFormat('dd MMM yyyy').format(d);
        _narCtrl.text = v['description'] as String? ?? ''; });
      _loadAudit(v['id'] as String);
      if (!_jvSuperviseFlow && !_jvApproveFlow) _loadJvFlag(); // ensure flags are set when a voucher opens
    } catch (e) { _snack('Load error: $e'); }
  }

  Future<void> _save({bool post = false, bool submitForApproval = false}) async {
    // Guard: with the blocking approval flow on, only an admin may post to the GL.
    if (post && _jvApproveFlow && !_isAdmin) { _snack('This JV must be approved by an admin before posting.'); return; }
    final valid = _lines.where((l) => l.accountId != null && (l.debit + l.credit) > 0).toList();
    if (valid.isEmpty) { _snack('Add at least one account line'); return; }
    // A line with an amount but no account is counted in the on-screen Dr/Cr
    // totals (_balanced) yet is NOT inserted below — posting it would write an
    // unbalanced entry. Block it so the posted lines always balance.
    final dangling = _lines.where((l) => l.accountId == null && (l.debit + l.credit) > 0).toList();
    if (dangling.isNotEmpty) { _snack('A line has an amount but no account selected — pick an account or clear the amount.'); return; }
    if (post) {
      final pDr = valid.fold<double>(0, (s, l) => s + l.debit);
      final pCr = valid.fold<double>(0, (s, l) => s + l.credit);
      if (pDr <= 0 || (pDr - pCr).abs() >= 0.005) { _snack('Debits must equal credits to post'); return; }
    }
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    final bid = _branchId ?? ''; final userId = ref.read(currentUserProvider)?.id ?? '';
    final apId = 'coa_' + orgId + '_2110';   // Accounts Payable control account
    final arId = 'coa_' + orgId + '_1210';   // Accounts Receivable control account
    setState(() => _saving = true);
    SavingOverlay.show(context, label: post ? 'Posting…' : 'Saving…');
    try {
      final client = Supabase.instance.client;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final newSt   = post ? 'posted' : 'draft';
      final nar     = _narCtrl.text.trim();
      final wasNew  = _current == null;
      final userName = ref.read(currentUserProvider)?.name;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      // Approval bookkeeping (only meaningful when org.jv_approve_flow is on):
      // posting stamps approved; submitting stamps pending; a plain draft clears it.
      final Map<String, dynamic> approvalFields = !_jvApproveFlow ? {} : {
        'approval_status': post ? 'approved' : (submitForApproval ? 'pending' : null),
        if (post) 'approved_by': userId,
        if (post) 'approved_by_name': userName,
        if (post) 'approved_at': nowIso,
      };
      String eId, eNum;
      if (wasNew) {
        final yr = DateTime.now().year.toString();
        final ex = await client.from('journal_entries').select('entry_number')
            .eq('org_id', orgId).eq('reference_type', 'jv').like('entry_number', 'JV-$yr-%');
        int mx = 0;
        for (final r in (ex as List)) {
          final n = int.tryParse((r['entry_number'] as String? ?? '').split('-').last) ?? 0;
          if (n > mx) mx = n;
        }
        final seq  = (mx + 1).toString().padLeft(4, '0');
        eNum = 'JV-$yr-$seq';
        eId  = 'jv_' + DateTime.now().millisecondsSinceEpoch.toString();
      } else {
        eId  = _current!['id'] as String; eNum = _current!['entry_number'] as String? ?? '';
      }
      // Build the entry header + resolved lines and persist through the ATOMIC,
      // balance-guarded server writer save_journal_entry (one transaction:
      // upsert header, replace lines, RAISE on post if debits != credits). The
      // old path inserted the header then each line as separate calls, which
      // could leave a half-written unbalanced entry on a mid-loop failure.
      final entryJson = <String, dynamic>{
        'id': eId, 'org_id': orgId, 'branch_id': bid,
        'entry_number': eNum, 'entry_date': dateStr,
        'description': nar.isEmpty ? eNum : nar,
        'reference_type': 'jv', 'reference_id': eId, 'reference_number': eNum,
        'status': newSt, 'is_system_generated': false, 'created_by': userId,
        ...approvalFields,
      };
      final linesJson = <Map<String, dynamic>>[];
      for (var i = 0; i < valid.length; i++) {
        final l = valid[i];
        final isParty = l.accountType == 'supplier' || l.accountType == 'customer';
        // Supplier advances live on 1420 (Advances to Suppliers); keep them there
        // on re-save instead of folding them into the AP control.
        final keepAdv = l.accountType == 'supplier' && (l.glAccountId ?? '').endsWith('_1420');
        final glAcc   = keepAdv ? l.glAccountId
                      : l.accountType == 'supplier' ? apId
                      : l.accountType == 'customer' ? arId
                      : l.accountId;
        linesJson.add({
          'account_id': glAcc,
          'account_type': l.accountType,
          'account_name': l.accountName,
          'party_id': isParty ? l.accountId : null,
          'debit': l.debit, 'credit': l.credit,
          'description': l.descCtrl.text.trim(), 'line_order': i + 1,
        });
      }
      // Safety net: never let a re-save silently strip a vendor/customer link.
      // If the saved version had party-linked lines and this save would replace
      // them with bare AP/AR control lines (no party), refuse.
      if (!wasNew) {
        final oldRows = await client.from('journal_lines').select('party_id, account_id, debit, credit').eq('entry_id', eId);
        final oldParties = <String>{for (final r in (oldRows as List)) if (r['party_id'] != null) r['party_id'] as String};
        final newParties = <String>{for (final j in linesJson) if (j['party_id'] != null) j['party_id'] as String};
        final lost = oldParties.difference(newParties);
        final bareCtrl = linesJson.where((j) => j['party_id'] == null &&
            ['_2110', '_1210', '_1420'].any((sfx) => (j['account_id'] as String? ?? '').endsWith(sfx))).length;
        if (lost.isNotEmpty && bareCtrl > 0) {
          throw 'Not saved: ${lost.length} vendor/customer link(s) would be lost — $bareCtrl line(s) now post to Accounts Payable/Receivable with no party. Pick the vendor/customer on those lines, then save again.';
        }
      }
      await client.rpc('save_journal_entry', params: {'p_entry': entryJson, 'p_lines': linesJson});
      final updated = await client.from('journal_entries').select().eq('id', eId).single();
      if (mounted) setState(() { _current = updated; _status = newSt; });
      if (wasNew) _logAudit('created', notes: 'Total Dr: ' + money(_totalDr) + '  •  ' + valid.length.toString() + ' lines');
      if (post)   _logAudit('posted',  notes: 'Total Dr: ' + money(_totalDr) + '  •  ' + valid.length.toString() + ' lines');
      _snack(post ? 'JV ' + eNum + ' posted ✓' : 'Draft saved');
      await _loadVouchers();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    SavingOverlay.hide();
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    if (_deleteBlocked) { _snack('Void flow is on — a JV that was posted can only be voided, not deleted.'); return; }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Journal Voucher?'),
      content: const Text('This removes all GL lines and cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      final id = _current!['id'] as String;
      // Atomic, server-checked delete (SQL 328): refuses when void flow is on and
      // the JV was ever posted.
      await Supabase.instance.client.rpc('delete_journal_voucher', params: {'p_id': id});
      _snack('Deleted'); _newVoucher(); await _loadVouchers();
    } catch (e) { _snack('Delete failed: ' + e.toString()); }
  }

  bool get _isVoided => _current?['is_voided'] == true;
  /// Has this JV ever hit the books? (posted now, or posted earlier then unlocked)
  bool get _everPosted => _isLocked || _isVoided || _current?['posted_at'] != null ||
      _auditTrail.any((a) => a['action'] == 'posted' || a['action'] == 'unlocked');
  /// Void flow ON: anything that was ever posted can only be voided, never deleted.
  bool get _deleteBlocked => _jvVoidFlow && _everPosted;

  /// org.jv_void_flow: a POSTED JV is voided — kept on record, marked VOIDED,
  /// and a mirror reversal (JV-…-VOID) is posted on the same date (SQL 325).
  Future<void> _void() async {
    if (_current == null || _isVoided) return;
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
      title: Text('Void ${_current!['entry_number'] ?? 'JV'}?'),
      content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('The JV stays on record marked VOIDED, and a reversing entry is posted on the same date, '
            'so every ledger it touched goes back to as if it never happened. This cannot be undone.',
            style: TextStyle(fontSize: 13)),
        const SizedBox(height: 12),
        TextField(controller: reasonCtrl, autofocus: true, maxLines: 2, onChanged: (_) => setD(() {}),
            decoration: const InputDecoration(labelText: 'Reason (required)', border: OutlineInputBorder())),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: reasonCtrl.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
          child: const Text('Void'),
        ),
      ],
    )));
    if (ok != true) return;
    final u = ref.read(currentUserProvider);
    try {
      final id = _current!['id'] as String;
      final revNo = await Supabase.instance.client.rpc('void_journal_voucher', params: {
        'p_id': id, 'p_reason': reasonCtrl.text.trim(), 'p_user': u?.id, 'p_user_name': u?.name,
      });
      _logAudit('voided', notes: 'Reason: ${reasonCtrl.text.trim()} · reversal $revNo');
      final fresh = await Supabase.instance.client.from('journal_entries').select().eq('id', id).single();
      if (mounted) setState(() => _current = fresh);
      _snack('Voided — reversal $revNo posted');
      await _loadVouchers();
    } catch (e) {
      final m = e.toString();
      _snack(m.contains('void_journal_voucher') || m.contains('is_voided') ? 'Run SQL 325 in Supabase first.' : 'Void failed: $m');
    }
  }

  Future<void> _unlockVoucher() async {
    if (_current == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Unlock Voucher?'),
      content: const Text('This will set the voucher back to Draft and allow editing.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), child: const Text('Unlock')),
      ],
    ));
    if (ok != true || !mounted) return;
    try {
      await Supabase.instance.client.from('journal_entries').update({'status': 'draft'}).eq('id', _current!['id'] as String);
      setState(() { _status = 'draft'; _current = {..._current!, 'status': 'draft'}; });
      _logAudit('unlocked', notes: 'Voucher reopened for editing');
      _snack('Voucher unlocked for editing');
    } catch (e) { _snack('Failed: ' + e.toString()); }
  }

  // ── Audit trail ────────────────────────────────────────────────
  Future<void> _loadAudit(String entryId) async {
    try {
      final rows = await Supabase.instance.client.from('jv_audit_trail').select().eq('entry_id', entryId).order('performed_at');
      if (mounted) setState(() => _auditTrail = List<Map<String,dynamic>>.from(rows));
    } catch (_) {}
  }

  // ── Bulk actions (admins): approve pending JVs when the approval flow is on,
  // supervise posted JVs when the supervision flow is on. ──────────────────
  bool _isPendingJv(Map v) => v['status'] != 'posted' && v['approval_status'] == 'pending';
  bool _isSupPendingJv(Map v) => v['status'] == 'posted' && v['supervised_at'] == null;

  Future<void> _auditMany(List<String> ids, String action, String notes) async {
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    try {
      await Supabase.instance.client.from('jv_audit_trail').insert([
        for (final id in ids)
          {
            'id': 'aud_${action}_${DateTime.now().microsecondsSinceEpoch}_${_auditSeq++}',
            'entry_id': id, 'action': action, 'performed_by': userId, 'performed_by_name': userName,
            'performed_at': DateTime.now().toUtc().toIso8601String(), 'notes': notes,
          }
      ]);
    } catch (_) {/* audit is best-effort */}
  }

  Future<bool> _confirmBulk(String title, String body, String button) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title), content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(button)),
      ],
    ));
    return ok == true;
  }

  /// Approve & post pending JVs. Each one is checked for balanced, non-zero
  /// lines first; unbalanced ones are skipped and reported.
  Future<void> _bulkApprove({Set<String>? onlyIds}) async {
    if (!_isAdmin || !_jvApproveFlow || _bulkBusy) return;
    final ids = _vouchers.where(_isPendingJv).map((v) => v['id'] as String)
        .where((id) => onlyIds == null || onlyIds.contains(id)).toList();
    if (ids.isEmpty) { _snack('Nothing pending approval'); return; }
    if (!await _confirmBulk(onlyIds == null ? 'Approve all pending?' : 'Approve selected?',
        'Approve and post ${ids.length} journal voucher(s) to the ledger? Any JV whose debits and credits do not match is skipped.',
        'Approve & post ${ids.length}')) return;
    setState(() => _bulkBusy = true);
    final client = Supabase.instance.client;
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name;
    final now = DateTime.now().toUtc().toIso8601String();
    final ok = <String>[]; final skipped = <String>[];
    try {
      final lines = await client.from('journal_lines').select('entry_id, debit, credit').inFilter('entry_id', ids);
      final dr = <String, double>{}, cr = <String, double>{};
      for (final l in (lines as List)) {
        final e = '${l['entry_id']}';
        dr[e] = (dr[e] ?? 0) + ((l['debit'] as num?)?.toDouble() ?? 0);
        cr[e] = (cr[e] ?? 0) + ((l['credit'] as num?)?.toDouble() ?? 0);
      }
      for (final id in ids) {
        final d = dr[id] ?? 0, c = cr[id] ?? 0;
        if (d > 0 && (d - c).abs() < 0.005) { ok.add(id); } else { skipped.add(id); }
      }
      for (var i = 0; i < ok.length; i += 100) {
        final chunk = ok.sublist(i, i + 100 > ok.length ? ok.length : i + 100);
        await client.from('journal_entries').update({
          'status': 'posted', 'approval_status': 'approved',
          'approved_by': userId, 'approved_by_name': userName, 'approved_at': now,
        }).inFilter('id', chunk);
      }
      if (ok.isNotEmpty) await _auditMany(ok, 'posted', 'Bulk approved & posted by ${userName ?? 'admin'}');
      final numbers = {for (final v in _vouchers) v['id']: v['entry_number']};
      _snack('Approved & posted ${ok.length}'
          '${skipped.isEmpty ? '' : ' · skipped ${skipped.length} unbalanced: ${skipped.map((i) => numbers[i] ?? i).join(', ')}'}');
    } catch (e) { _snack(friendlyError('Bulk approve failed', e)); }
    _sel.removeAll(ok);
    await _loadVouchers();
    if (_current != null && ok.contains(_current!['id'])) {
      try {
        final u = await client.from('journal_entries').select().eq('id', _current!['id'] as String).single();
        if (mounted) setState(() { _current = u; _status = 'posted'; });
      } catch (_) {}
    }
    if (mounted) setState(() => _bulkBusy = false);
  }

  /// Mark posted JVs as supervised (review mark only; ledger unaffected).
  Future<void> _bulkSupervise({Set<String>? onlyIds}) async {
    if (!_isAdmin || !_jvSuperviseFlow || _bulkBusy) return;
    final ids = _vouchers.where(_isSupPendingJv).map((v) => v['id'] as String)
        .where((id) => onlyIds == null || onlyIds.contains(id)).toList();
    if (ids.isEmpty) { _snack('Nothing pending supervision'); return; }
    if (!await _confirmBulk(onlyIds == null ? 'Supervise all pending?' : 'Supervise selected?',
        'Mark ${ids.length} posted journal voucher(s) as supervised? This is a review mark only — it does not change the ledger.',
        'Supervise ${ids.length}')) return;
    setState(() => _bulkBusy = true);
    final client = Supabase.instance.client;
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name;
    final now = DateTime.now().toUtc().toIso8601String();
    String? sigUrl; String? stampUrl;
    try { final u = await client.from('users').select('signature_url').eq('id', userId ?? '').maybeSingle(); sigUrl = u?['signature_url'] as String?; } catch (_) {}
    try { final st = await client.from('app_config').select('value').eq('org_id', _orgId ?? '').eq('key', 'org.stamp_url').maybeSingle(); stampUrl = st?['value'] as String?; } catch (_) {}
    try {
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        await client.from('journal_entries').update({
          'supervised_by': userId, 'supervised_at': now, 'supervised_by_name': userName,
          'supervised_signature_url': sigUrl, 'supervised_stamp_url': stampUrl,
        }).inFilter('id', chunk);
      }
      await _auditMany(ids, 'supervised', 'Bulk supervised by ${userName ?? 'admin'}');
      final idset = ids.toSet();
      if (mounted) setState(() {
        for (final v in _vouchers) {
          if (idset.contains(v['id'])) { v['supervised_at'] = now; v['supervised_by'] = userId; v['supervised_by_name'] = userName; }
        }
        if (_current != null && idset.contains(_current!['id'])) {
          _current!['supervised_at'] = now; _current!['supervised_by'] = userId; _current!['supervised_by_name'] = userName;
        }
        _sel.removeAll(ids);
      });
      _snack('Supervised ${ids.length} JV(s)');
    } catch (e) { _snack(friendlyError('Bulk supervise failed', e)); }
    if (mounted) setState(() => _bulkBusy = false);
  }

  Future<void> _logAudit(String action, {String? notes}) async {
    if (_current == null) return;
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    try {
      await Supabase.instance.client.from('jv_audit_trail').insert({
        'id': 'aud_${action}_${DateTime.now().microsecondsSinceEpoch}_${_auditSeq++}',
        'entry_id': _current!['id'] as String,
        'action': action,
        'performed_by': userId,
        'performed_by_name': userName,
        'performed_at': DateTime.now().toUtc().toIso8601String(),
        'notes': notes,
      });
      await _loadAudit(_current!['id'] as String);
    } catch (e) { _snack('Audit log error: $e'); }
  }

  void _showAuditTrail() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Audit Trail'),
      content: SizedBox(width: 420, child: _auditTrail.isEmpty
          ? const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No audit records yet.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(
              shrinkWrap: true,
              itemCount: _auditTrail.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = _auditTrail[i];
                final raw = e['performed_at'] as String? ?? '';
                final at = raw.length >= 16 ? raw.substring(0, 16).replaceAll('T', ' ') : raw;
                final who = e['performed_by_name'] as String? ?? 'Unknown';
                final notes = e['notes'] as String? ?? '';
                return ListTile(
                  dense: true,
                  leading: Icon(_auditIcon(e['action'] as String? ?? ''), size: 18, color: _auditColor(e['action'] as String? ?? '')),
                  title: Text((e['action'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  subtitle: Text('$who  •  $at${notes.isNotEmpty ? '\n$notes' : ''}', style: const TextStyle(fontSize: 11)),
                  isThreeLine: notes.isNotEmpty,
                );
              },
            )),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ));
  }

  IconData _auditIcon(String action) {
    if (action == 'created') return Icons.add_circle_outline;
    if (action == 'posted') return Icons.lock_outline;
    if (action == 'unlocked') return Icons.lock_open_outlined;
    if (action == 'document_added') return Icons.attach_file;
    if (action == 'document_removed') return Icons.delete_outline;
    return Icons.info_outline;
  }
  Color _auditColor(String action) {
    if (action == 'created') return Colors.blue;
    if (action == 'posted') return Colors.green;
    if (action == 'unlocked') return Colors.orange;
    if (action == 'document_added') return Colors.teal;
    if (action == 'document_removed') return Colors.red;
    return Colors.grey;
  }

  void _print() {
    if (_current == null) { _snack('Save the voucher first'); return; }
    final lines = _lines.where((l) => l.accountId != null && (l.debit + l.credit) > 0).toList();
    final rawPostedAt = _current!['posted_at'] as String?;
    final postedInfo = rawPostedAt != null
        ? rawPostedAt.replaceAll('T', ' ').substring(0, rawPostedAt.length > 16 ? 16 : rawPostedAt.length)
        : '_______________';
    // Posted-by footprint: latest 'posted' entry in the audit trail.
    String postedBy = '';
    for (final e in _auditTrail) {
      if ((e['action'] as String? ?? '') == 'posted') {
        final n = (e['performed_by_name'] as String? ?? '').trim();
        if (n.isNotEmpty) { postedBy = n; break; }
      }
    }
    String esc(String? v) => (v ?? '').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    String when(dynamic iso) {
      final d = DateTime.tryParse('${iso ?? ''}');
      return d == null ? '' : DateFormat('d MMM yyyy, HH:mm').format(d.toLocal());
    }
    // Footprints: whatever has happened by the time this is printed.
    String preparedBy = '';
    for (final e in _auditTrail.reversed) {
      if ((e['action'] as String? ?? '') == 'created') {
        preparedBy = (e['performed_by_name'] as String? ?? '').trim();
        if (preparedBy.isNotEmpty) break;
      }
    }
    final c = _current!;
    final approvedBy = (c['approved_by_name'] as String?)?.trim();
    final approved = approvedBy != null && approvedBy.isNotEmpty && c['approval_status'] == 'approved';
    final supBy = (c['supervised_by_name'] as String?)?.trim();
    final supervised = c['supervised_at'] != null;
    String block(String label, String who, String at, {String? sig, String? stamp, bool done = true}) =>
        '<div class="fp${done ? '' : ' pending'}">'
        '${sig != null && sig.isNotEmpty ? '<img class="sig" src="${esc(sig)}">' : '<div class="sig-space"></div>'}'
        '<div class="line"></div><b>${esc(who)}</b><span>$label${at.isEmpty ? '' : ' · ${esc(at)}'}</span>'
        '${stamp != null && stamp.isNotEmpty ? '<img class="stamp" src="${esc(stamp)}">' : ''}</div>';
    final footprints = [
      block('Prepared by', preparedBy.isNotEmpty ? preparedBy : ' ', when(c['created_at'])),
      if (_jvApproveFlow || approved)
        approved
            ? block('Approved by', approvedBy ?? '', when(c['approved_at']))
            : block('Approved by', ' ', c['approval_status'] == 'pending' ? 'awaiting approval' : '', done: false),
      rawPostedAt != null || _status == 'posted'
          ? block('Posted by', postedBy.isNotEmpty ? postedBy : (approved ? (approvedBy ?? '—') : '—'), when(rawPostedAt))
          : block('Posted by', ' ', 'not posted yet', done: false),
      if (_jvSuperviseFlow || supervised)
        supervised
            ? block('Supervised by', supBy?.isNotEmpty == true ? supBy! : '—', when(c['supervised_at']),
                sig: c['supervised_signature_url'] as String?, stamp: c['supervised_stamp_url'] as String?)
            : block('Supervised by', ' ', 'awaiting supervision', done: false),
    ].join();
    final postedLine = footprints;
    // Same green trust badge as on screen (shield ✓ + who · when).
    const shield = '<svg width="14" height="14" viewBox="0 0 24 24" style="vertical-align:-2px;margin-right:6px"><path fill="#2f855a" d="M12 1 3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm-2 16-4-4 1.41-1.41L10 14.17l6.59-6.59L18 9l-8 8z"/></svg>';
    String badge(String text) => '<span class="trust">$shield${esc(text)}</span>';
    String day(dynamic iso) {
      final d = DateTime.tryParse('${iso ?? ''}');
      return d == null ? '' : DateFormat('d MMM yyyy').format(d.toLocal());
    }
    final badges = [
      if (approved) badge('Approved by $approvedBy · ${day(c['approved_at'])}'),
      if (supervised) badge('Supervised${supBy?.isNotEmpty == true ? ' by $supBy' : ''} · ${day(c['supervised_at'])}'),
    ].join();
    final htmlStr = '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Journal Voucher</title><style>@page{margin:0}
      body{font-family:-apple-system,Segoe UI,Arial,sans-serif;padding:20px;color:#2d3748}
      h2{text-align:center;color:#1a56db;margin-bottom:4px;letter-spacing:.5px}
      table.grid{width:100%;border-collapse:collapse;margin-top:14px;font-size:13px}
      table.grid th,table.grid td{padding:9px 10px;text-align:left}
      table.grid thead th{background:#1a56db;color:#fff;font-weight:600;border:none}
      table.grid tbody td{border-bottom:1px solid #e2e8f0}
      table.grid tbody tr:nth-child(even) td{background:#f8fafc}
      table.grid tfoot td{border-top:2px solid #1a56db;background:#f0f4ff}
      .total{font-weight:700}.num{text-align:right}
      .meta td{border:none;font-size:11px;padding:1px 10px 1px 0}
      .footer{margin-top:40px;display:flex;justify-content:space-between;font-size:12px;line-height:1.5}
      .fps{margin-top:36px;display:flex;gap:18px}
      .trusts{margin:8px 0 2px;display:flex;flex-wrap:wrap;gap:8px}
      .trust{display:inline-flex;align-items:center;padding:5px 12px;border-radius:8px;background:rgba(56,161,105,.08);border:1px solid rgba(56,161,105,.35);color:#2f855a;font-size:12px;font-weight:600;-webkit-print-color-adjust:exact;print-color-adjust:exact}
      .fp{flex:1;position:relative;font-size:11.5px;line-height:1.45}
      .fp .line{border-top:1px solid #718096;margin-bottom:4px}
      .fp b{display:block;font-size:12.5px;color:#1a202c;min-height:16px}
      .fp span{color:#718096}
      .fp.pending b{color:#a0aec0}
      .fp .sig{height:42px;max-width:150px;object-fit:contain;display:block}
      .fp .sig-space{height:42px}
      .fp .stamp{position:absolute;right:4px;top:-6px;height:58px;opacity:.85}
      @media print{.no-print{display:none}@page{margin:0}body{padding:15mm 20mm}}
    </style></head><body>
    <div class="no-print" style="margin-bottom:16px"><button onclick="window.print()">Print</button></div>
    <h2>Journal Voucher</h2>
    ${_isVoided ? '<div style="text-align:center;color:#c53030;font-weight:800;letter-spacing:2px;border:2px solid #c53030;padding:4px;margin:6px auto;max-width:520px">VOIDED${_current?['void_reason'] != null ? ' — ' + esc('${_current!['void_reason']}') : ''}</div>' : ''}
    <table class="meta" style="border:none;margin-bottom:5px"><tr>
      <td><b>Voucher#:</b> ${_current!['entry_number'] ?? ''}</td>
      <td><b>Date:</b> ${DateFormat('dd MMM yyyy').format(_date)}</td>
      <td><b>Status:</b> ${_isVoided ? '<span style="color:#c53030;font-weight:800">VOIDED</span>' : _status.toUpperCase()}</td>
    </tr><tr><td colspan="3"><b>Narration:</b> ${_narCtrl.text}</td></tr></table>
    ${badges.isEmpty ? '' : '<div class="trusts">$badges</div>'}
    <table class="grid"><thead><tr><th style="width:30px">#</th><th>Account</th><th>Description</th><th class="num" style="width:120px">Debit</th><th class="num" style="width:120px">Credit</th></tr></thead><tbody>
    ${lines.asMap().entries.map((e) => '<tr><td>${e.key + 1}</td><td>${e.value.accountName}</td><td>${e.value.descCtrl.text}</td><td class="num">${e.value.debit > 0 ? money(e.value.debit) : ''}</td><td class="num">${e.value.credit > 0 ? money(e.value.credit) : ''}</td></tr>').join()}
    </tbody><tfoot><tr><td colspan="3" class="total num">Total:</td><td class="total num">${money(_totalDr)}</td><td class="total num">${money(_totalCr)}</td></tr></tfoot></table>
    <div class="fps">$postedLine</div>
    </body></html>''';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  List<Widget> _bulkButtons(int pendingCount, int supPending) {
    if (!_isAdmin) return const [];
    final selPending = _vouchers.where((v) => _sel.contains(v['id']) && _isPendingJv(v)).map((v) => v['id'] as String).toSet();
    final selSup = _vouchers.where((v) => _sel.contains(v['id']) && _isSupPendingJv(v)).map((v) => v['id'] as String).toSet();
    Widget outlined(String label, IconData icon, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(width: double.infinity, child: OutlinedButton.icon(
        onPressed: _bulkBusy ? null : onTap,
        icon: _bulkBusy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)))));
    Widget filled(String label, IconData icon, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(width: double.infinity, child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
        onPressed: _bulkBusy ? null : onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)))));
    return [
      if (_jvApproveFlow && pendingCount > 0) outlined('Approve all pending ($pendingCount)', Icons.done_all, () => _bulkApprove()),
      if (_jvApproveFlow && selPending.isNotEmpty) filled('Approve selected (${selPending.length})', Icons.playlist_add_check, () => _bulkApprove(onlyIds: selPending)),
      if (_jvSuperviseFlow && supPending > 0) outlined('Supervise all pending ($supPending)', Icons.verified_user_outlined, () => _bulkSupervise()),
      if (_jvSuperviseFlow && selSup.isNotEmpty) filled('Supervise selected (${selSup.length})', Icons.playlist_add_check, () => _bulkSupervise(onlyIds: selSup)),
    ];
  }

  Widget _wrapOrRow(bool narrow, List<Widget> kids) => narrow
      ? Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 6, children: kids)
      : Row(children: kids);
  Widget _titleBox(bool narrow, Widget child) => narrow ? SizedBox(width: double.infinity, child: child) : Expanded(child: child);
  Widget _flexOrNot(bool expand, Widget child) => expand ? Expanded(child: child) : child;
  Widget _flexOrBox(bool expand, double width, Widget child) => expand ? Expanded(child: child) : SizedBox(width: width, child: child);

  Widget _jvDateField(bool editable) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Date *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
    const SizedBox(height: 4),
    InkWell(onTap: !editable ? null : () async {
      final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
      if (d != null) setState(() { _date = d; _dateCtrl.text = DateFormat('dd MMM yyyy').format(d); });
    }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFBDBDBD)), borderRadius: BorderRadius.circular(6)),
      child: Row(children: [const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary), const SizedBox(width: 6), Text(DateFormat('dd MMM yyyy').format(_date), style: const TextStyle(fontSize: 13))]))),
  ]);

  @override Widget build(BuildContext context) {
    // Branch toggle: reload the list for the new branch and start a fresh JV so
    // one from the previous branch is never edited / posted under the new one.
    ref.listen(selectedBranchProvider, (prev, next) {
      if (prev?['id'] != next?['id']) {
        _sel.clear();
        _newVoucher();
        _loadVouchers();
      }
    });
    final fmt = const MoneyFmt();
    final access = ref.watch(accessSyncProvider);
    final accessReady = access != null && access.role != null;
    final canAdd = access?.canAddDoc('jv') ?? false;
    final canEdit = access?.canEditDoc('jv') ?? false;
    final canDeleteJv = access?.canDelete() ?? false;
    final canWrite = _current == null ? canAdd : (canAdd || canEdit);
    final editable = !_isLocked && canWrite;
    bool isPending(Map v) => v['status'] != 'posted' && v['approval_status'] == 'pending';
    final filtered = _vouchers.where((v) {
      if (_listSearch.isNotEmpty && !matchesQuery('${v['entry_number'] ?? ''} ${v['description'] ?? ''}', _listSearch)) return false;
      final posted = v['status'] == 'posted';
      switch (_statusFilter) {
        case 'draft': if (posted || isPending(v)) return false; break;
        case 'pending': if (!isPending(v)) return false; break;
        case 'posted': if (!posted || v['is_voided'] == true) return false; break;
        case 'voided': if (v['is_voided'] != true) return false; break;
      }
      if (_jvSuperviseFlow && _supFilter != 'all') {
        final sup = v['supervised_at'] != null;
        if (_supFilter == 'yes' ? !sup : (sup || !posted)) return false;
      }
      return true;
    }).toList();
    final pendingCount = _vouchers.where(isPending).length;
    final supPending = _vouchers.where((v) => v['status'] == 'posted' && v['supervised_at'] == null).length;
    Widget chip(String label, String value, String current, ValueChanged<String> onTap, {int count = 0}) {
      final active = value == current;
      return GestureDetector(onTap: () => setState(() => onTap(value)), child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: active ? AppTheme.primary : AppTheme.background, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? AppTheme.primary : AppTheme.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
          if (count > 0) ...[
            const SizedBox(width: 4),
            Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: active ? Colors.white.withOpacity(0.25) : Colors.orange, borderRadius: BorderRadius.circular(8)),
              child: Text('$count', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white))),
          ],
        ])));
    }

    // Phone: the list and the voucher take turns on the full screen.
    final narrow = MediaQuery.of(context).size.width < 720;
    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: narrow ? MediaQuery.of(context).size.width : 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10,10,10,8),
            decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Journal Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                if (!accessReady) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                else if (canAdd) ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: () { _newVoucher(); if (narrow) setState(() => _drawerOpen = false); }),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search JVs...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 5, runSpacing: 5, children: [
                chip('All', 'all', _statusFilter, (v) => _statusFilter = v),
                chip('Draft', 'draft', _statusFilter, (v) => _statusFilter = v),
                if (_jvApproveFlow) chip('Pending approval', 'pending', _statusFilter, (v) => _statusFilter = v, count: pendingCount),
                chip('Posted', 'posted', _statusFilter, (v) => _statusFilter = v),
                if (_jvVoidFlow || _vouchers.any((v) => v['is_voided'] == true))
                  chip('Voided', 'voided', _statusFilter, (v) => _statusFilter = v),
              ])),
              if (_jvSuperviseFlow) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Text('Supervision', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 6),
                  Expanded(child: Wrap(spacing: 5, runSpacing: 5, children: [
                    chip('All', 'all', _supFilter, (v) => _supFilter = v),
                    chip('Supervised', 'yes', _supFilter, (v) => _supFilter = v),
                    chip('Pending', 'no', _supFilter, (v) => _supFilter = v, count: supPending),
                  ])),
                ]),
              ],
              ..._bulkButtons(pendingCount, supPending),
            ])),
          Expanded(child: _loadingList ? const Center(child: BrandSpinner())
            : filtered.isEmpty ? const Center(child: BranchEmptyHint('No vouchers', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : VoucherSortedList(items: filtered, builder: (vsRows) => ListView.builder(itemCount: vsRows.length, itemBuilder: (_, i) {
                final v = vsRows[i]; final sel = _current?['id'] == v['id']; final posted = v['status'] == 'posted';
                return GestureDetector(
                  onSecondaryTapDown: (d) => _showCtxMenu(d.globalPosition, v),
                  child: InkWell(onTap: () { _loadVoucher(v); if (narrow) setState(() => _drawerOpen = false); }, child: Container(
                    color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        if (_isAdmin && ((_jvApproveFlow && _isPendingJv(v)) || (_jvSuperviseFlow && _isSupPendingJv(v)))) ...[
                          InkWell(
                            onTap: () => setState(() {
                              final id = v['id'] as String;
                              if (!_sel.remove(id)) _sel.add(id);
                            }),
                            child: Tooltip(
                              message: _isPendingJv(v) ? 'Tick to approve' : 'Tick to supervise',
                              child: Icon(_sel.contains(v['id']) ? Icons.check_box : Icons.check_box_outline_blank,
                                  size: 16, color: _sel.contains(v['id']) ? AppTheme.primary : Colors.orange)),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(child: Text(v['entry_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                        if (_jvSuperviseFlow && posted) ...[
                          v['supervised_at'] != null
                              ? Tooltip(message: 'Supervised${v['supervised_by_name'] != null ? ' by ${v['supervised_by_name']}' : ''}',
                                  child: const Icon(Icons.verified_user, size: 13, color: Colors.green))
                              : const Tooltip(message: 'Awaiting supervision',
                                  child: Icon(Icons.verified_user_outlined, size: 13, color: Colors.orange)),
                          const SizedBox(width: 4),
                        ],
                        Builder(builder: (_) {
                          final pend = isPending(v);
                          final voided = v['is_voided'] == true;
                          final c = voided ? Colors.red : (posted ? Colors.green : (pend ? Colors.deepOrange : Colors.orange));
                          return Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(3)),
                            child: Text(voided ? 'Voided' : (posted ? 'Posted' : (pend ? 'Pending approval' : 'Draft')), style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700)));
                        }),
                      ]),
                      Text(v['entry_date'] as String? ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                      Text(v['description'] as String? ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    ]),
                  )));
              }))),
        ])),

      if (!(narrow && _drawerOpen)) Expanded(child: Column(children: [
        Container(padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 16, vertical: 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: _wrapOrRow(narrow, [
            _titleBox(narrow, Row(children: [
            IconButton(icon: Icon(narrow ? Icons.list : (_drawerOpen ? Icons.chevron_left : Icons.chevron_right), size: 18), tooltip: narrow ? 'All vouchers' : null, onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            ConstrainedBox(constraints: BoxConstraints(maxWidth: narrow ? MediaQuery.of(context).size.width - 80 : 420), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_current?['entry_number'] as String? ?? 'New Journal Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
              if (_current != null) Text(_isVoided ? '⛔ Voided${_current?['void_reason'] != null ? ' — ${_current!['void_reason']}' : ''}' : (_isLocked ? '🔒 Posted & Locked' : '✏️ Draft'),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: _isVoided ? Colors.red : (_isLocked ? Colors.green : Colors.orange), fontWeight: FontWeight.w600)),
            ])),
            ])),
            if (_current != null) IconButton(icon: const Icon(Icons.history_outlined, size: 20), onPressed: _showAuditTrail, tooltip: 'Audit Trail'),
            if (_current != null) IconButton(icon: const Icon(Icons.print_outlined, size: 20), onPressed: _print, tooltip: 'Print'),
            // Void flow ON: anything ever posted (incl. unlocked) is voided, never
            // deleted; only never-posted drafts can be deleted.
            if (_current != null && canDeleteJv && !_deleteBlocked)
              IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red), onPressed: _delete, tooltip: 'Delete'),
            if (_current != null && canDeleteJv && _jvVoidFlow && _isLocked && !_isVoided)
              IconButton(icon: const Icon(Icons.block, size: 20, color: Colors.red), onPressed: _void, tooltip: 'Void (posts a reversal)'),
            if (_current != null && canDeleteJv && _deleteBlocked && !_isLocked && !_isVoided)
              const Tooltip(message: 'This JV was posted before. With void flow on it can\'t be deleted — post it again, then use Void.',
                child: Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.info_outline, size: 18, color: Colors.orange))),
            const SizedBox(width: 8),
            if (!_isLocked && canWrite) ...[
              OutlinedButton(onPressed: _saving ? null : () => _save(post: false), child: const Text('Save Draft', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 8),
              if (_jvApproveFlow && !_isAdmin)
                ElevatedButton.icon(
                  icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_outlined, size: 16),
                  label: const Text('Submit for approval'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  onPressed: (_canPost && !_saving) ? _submitForApproval : null)
              else
                ElevatedButton.icon(
                  icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
                  label: Text((_jvApproveFlow && _current?['approval_status'] == 'pending') ? 'Approve & Post' : 'Post'),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                  onPressed: (_canPost && !_saving) ? () => _save(post: true) : null),
            ],
            if (_isLocked && _isVoided)
              Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: Colors.red.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.withOpacity(0.3))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.block, size: 14, color: Colors.red), const SizedBox(width: 4),
                  Text('Voided${_current?['voided_by_name'] != null ? ' by ${_current!['voided_by_name']}' : ''}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700, fontSize: 13))])),
            if (_isLocked && !_isVoided) Row(mainAxisSize: MainAxisSize.min, children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withOpacity(0.3))),
                child: const Row(children: [Icon(Icons.lock, size: 14, color: Colors.green), SizedBox(width: 4), Text('Posted', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w700, fontSize: 13))])),
              if (canEdit) const SizedBox(width: 8),
              if (canEdit) OutlinedButton.icon(icon: const Icon(Icons.lock_open_outlined, size: 14), label: const Text('Unlock', style: TextStyle(fontSize: 12)), onPressed: _unlockVoucher,
                style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, side: const BorderSide(color: Colors.orange), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8))),
            ]),
          ])),
        Expanded(child: !accessReady
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(height: 10),
              Text('Checking access...', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]))
          : SingleChildScrollView(padding: EdgeInsets.all(narrow ? 10 : 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Flex(direction: narrow ? Axis.vertical : Axis.horizontal, crossAxisAlignment: narrow ? CrossAxisAlignment.stretch : CrossAxisAlignment.end, children: [
            if (narrow) Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Voucher No.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(_current?['entry_number'] as String? ?? '(auto)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.primary)),
              ])),
              Expanded(child: _jvDateField(editable)),
            ]),
            if (narrow) const SizedBox(height: 10),
            if (!narrow) SizedBox(width: 160, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Voucher No.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_current?['entry_number'] as String? ?? '(auto)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ])),
            if (!narrow) const SizedBox(width: 20),
            if (!narrow) SizedBox(width: 170, child: _jvDateField(editable)),
            if (!narrow) const SizedBox(width: 20),
            _flexOrNot(!narrow, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Narration', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              TextField(controller: _narCtrl, enabled: editable,
                decoration: InputDecoration(hintText: 'Enter narration...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFBDBDBD))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFBDBDBD))))),
            ])),
          ]),
          const SizedBox(height: 20),
          if (_loadingMaster) const Padding(padding: EdgeInsets.only(bottom: 10), child: Row(children: [SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 8), Text('Loading accounts...', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))])),
          Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)), child: Column(children: [
            if (!narrow) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(10))),
              child: const Row(children: [
                SizedBox(width: 30, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                Expanded(flex: 5, child: Text('Account / Party', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                Expanded(flex: 3, child: Text('Description', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                SizedBox(width: 120, child: Text('Debit (Dr)', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                SizedBox(width: 120, child: Text('Credit (Cr)', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 30),
              ])),
            for (var i = 0; i < _lines.length; i++) _JvLineWidget(
              key: ValueKey('jvline_${_lines[i].id}'),
              line: _lines[i], lineNum: i + 1,
              filterFn: _filterAccounts, locked: !editable,
              autoFocus: _lines[i].id == _pendingFocusId,
              onRemove: () => _removeLine(i),
              onNextLine: i == _lines.length - 1 ? _addLine : () {},
              onChanged: () => setState(() {}),
            ),
            if (editable) Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add Line', style: TextStyle(fontSize: 12)), onPressed: _addLine)),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _balanced && _totalDr > 0 ? Colors.green.withOpacity(0.05) : (_totalDr > 0 ? Colors.red.withOpacity(0.04) : AppTheme.background),
                border: const Border(top: BorderSide(color: AppTheme.border)),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10))),
              child: Row(children: [
                if (!narrow) const Expanded(child: SizedBox()),
                _flexOrBox(narrow, 120, Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('Total Dr', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  Text(fmt.format(_totalDr), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))])),
                const SizedBox(width: 16),
                _flexOrBox(narrow, 120, Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('Total Cr', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  Text(fmt.format(_totalCr), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))])),
                SizedBox(width: 46, child: Center(child: _totalDr > 0
                  ? (_balanced ? const Tooltip(message: 'Balanced', child: Icon(Icons.check_circle, color: Colors.green, size: 20))
                      : const Tooltip(message: 'Unbalanced', child: Icon(Icons.error, color: Colors.red, size: 20)))
                  : const SizedBox())),
              ])),
          ])),
          if (_totalDr > 0 && !_balanced) Padding(padding: const EdgeInsets.only(top: 10),
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.shade200)),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.red.shade700), const SizedBox(width: 10),
                Expanded(child: Text('Difference: ' + fmt.format((_totalDr - _totalCr).abs()) + ' — must be 0 to post',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w600))),
              ]))),
          if (_jvApproveFlow && _current != null && _current?['approval_status'] == 'pending' && !_isLocked) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.4))),
              child: Row(children: [
                Icon(Icons.hourglass_top, size: 16, color: Colors.orange.shade800),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  _isAdmin
                      ? 'Submitted for approval — review the lines, then "Approve & Post" to post it to the ledger.'
                      : 'Awaiting admin approval — this JV has not posted to the ledger yet.',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade900, fontWeight: FontWeight.w600))),
              ]),
            ),
          ],
          if (_jvSuperviseFlow && _current != null) ...[
            const SizedBox(height: 20),
            _jvSuperviseBlock(),
          ],
          // Support documents show under EITHER review flow (supervision or approval).
          if (_jvSuperviseFlow || _jvApproveFlow) ...[
            const SizedBox(height: 16),
            if (_current != null)
              VoucherDocsPanel(
                voucherType: 'JV',
                voucherId: _current!['id'] as String,
                voucherNumber: _current!['entry_number'] as String? ?? '-',
                bucket: 'jv-documents',
                orgId: _orgId ?? '',
                userId: ref.read(currentUserProvider)?.id,
                canWrite: canWrite,
                onAudit: (action, fileName) => _logAudit(action, notes: fileName),
              )
            else
              // A JV has no record (and no id to attach files to) until it's saved
              // once. Show the panel up front with a one-tap save so attachments
              // feel available from the start, like the other vouchers.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                child: Row(children: [
                  const Icon(Icons.attach_file, size: 18, color: AppTheme.textSecondary),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Support Documents — save the JV as a draft to start attaching files.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))),
                  if (canWrite)
                    ElevatedButton.icon(
                      onPressed: _saving ? null : () => _save(post: false),
                      icon: const Icon(Icons.save_outlined, size: 15),
                      label: const Text('Save draft', style: TextStyle(fontSize: 12)),
                      style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
                    ),
                ]),
              ),
          ],
        ]))),
      ])),
    ]));
  }
}

class _JvLineWidget extends StatefulWidget {
  final _JvLine line; final int lineNum;
  final List<Map<String,dynamic>> Function(String) filterFn;
  final bool locked; final bool autoFocus;
  final VoidCallback onRemove, onNextLine, onChanged;
  const _JvLineWidget({super.key, required this.line, required this.lineNum, required this.filterFn,
    required this.locked, required this.onRemove, required this.onNextLine, required this.onChanged, this.autoFocus = false});
  @override State<_JvLineWidget> createState() => _JvLineWidgetState();
}

class _JvLineWidgetState extends State<_JvLineWidget> {
  bool _showDrop = false; String _q = '';
  final _accFocus = FocusNode(); final _descFocus = FocusNode();
  final _debitFocus = FocusNode(); final _creditFocus = FocusNode();
  final _accCtrl = TextEditingController();

  @override void initState() {
    super.initState();
    _accCtrl.text = widget.line.accountName;
    _accFocus.addListener(() { if (!_accFocus.hasFocus) Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_accFocus.hasFocus) setState(() => _showDrop = false); }); });
    if (widget.autoFocus) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _accFocus.requestFocus(); });
  }
  @override void dispose() { _accFocus.dispose(); _descFocus.dispose(); _debitFocus.dispose(); _creditFocus.dispose(); _accCtrl.dispose(); super.dispose(); }

  Color _typeColor(String t) {
    switch (t) {
      case 'supplier': return Colors.blue;
      case 'customer': return Colors.purple;
      case 'asset': return Colors.blue;
      case 'liability': return Colors.red;
      case 'equity': return Colors.purple;
      case 'revenue': return Colors.green;
      case 'expense': return Colors.orange;
      default: return AppTheme.primary;
    }
  }

  void _pick(Map<String,dynamic> a) {
    widget.line.accountId = a['id'] as String?;
    widget.line.accountName = a['label'] as String? ?? '';
    widget.line.accountType = a['type'] as String? ?? 'coa';
    _accCtrl.text = widget.line.accountName;
    setState(() { _showDrop = false; _q = ''; });
    widget.onChanged();
    _descFocus.requestFocus();
  }

  @override Widget build(BuildContext context) {
    final filtered = widget.filterFn(_q);
    final l = widget.line;
    final narrow = MediaQuery.of(context).size.width < 720;
    final account = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _accCtrl, focusNode: _accFocus, enabled: !widget.locked,
            decoration: InputDecoration(hintText: 'Search account, supplier, customer...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              border: OutlineInputBorder(borderSide: BorderSide(color: l.accountId != null ? Colors.green : const Color(0xFFE0E0E0))),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.accountId != null ? Colors.green : const Color(0xFFE0E0E0))),
              suffixIcon: l.accountId != null ? const Icon(Icons.check_circle, size: 14, color: Colors.green) : null),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) { setState(() { _q = v; _showDrop = true; }); if (v != l.accountName) { l.accountId = null; l.accountName = v; l.accountType = 'coa'; widget.onChanged(); } },
            onTap: () => setState(() { _q = _accCtrl.text == l.accountName ? '' : _accCtrl.text; _showDrop = true; }),
            onSubmitted: (_) { if (filtered.isNotEmpty) _pick(filtered.first); }),
          if (_showDrop && filtered.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 200), margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
            child: ListView(shrinkWrap: true, children: filtered.map((a) {
              final t = a['type'] as String? ?? 'coa';
              final c = _typeColor(t == 'coa' ? (a['account_type'] as String? ?? '') : t);
              return InkWell(onTap: () => _pick(a), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(3)),
                  child: Text(a['sub'] as String? ?? t, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700))),
                const SizedBox(width: 6),
                Expanded(child: Tooltip(message: a['label'] as String? ?? '', waitDuration: const Duration(milliseconds: 400), child: Text(a['label'] as String? ?? '', style: const TextStyle(fontSize: 12), softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis))),
              ])));
            }).toList())),
        ]);
    final note = TextField(controller: l.descCtrl, focusNode: _descFocus, enabled: !widget.locked,
          decoration: const InputDecoration(hintText: 'Note', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12), textInputAction: TextInputAction.next,
          onSubmitted: (_) => _debitFocus.requestFocus());
    final debit = TextField(controller: l.debitCtrl, focusNode: _debitFocus, enabled: !widget.locked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.debit > 0, fillColor: Colors.blue.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.debit > 0 ? Colors.blue.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.creditCtrl.clear(); widget.onChanged(); },
          onSubmitted: (_) => widget.onNextLine());
    final credit = TextField(controller: l.creditCtrl, focusNode: _creditFocus, enabled: !widget.locked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.credit > 0, fillColor: Colors.orange.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.credit > 0 ? Colors.orange.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.debitCtrl.clear(); widget.onChanged(); },
          onSubmitted: (_) => widget.onNextLine());
    final remove = SizedBox(width: 30, child: widget.locked ? const SizedBox() : IconButton(
          icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: widget.onRemove,
          padding: EdgeInsets.zero, visualDensity: VisualDensity.compact));
    Widget lbl(String t) => Padding(padding: const EdgeInsets.only(bottom: 2),
        child: Text(t, style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)));
    if (narrow) {
      // Phone: one card per line — account, note, then Dr / Cr side by side.
      return Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 22, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${widget.lineNum}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
            Expanded(child: account),
            remove,
          ]),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(left: 22, right: 30), child: note),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(left: 22, right: 30), child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [lbl('Debit (Dr)'), debit])),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [lbl('Credit (Cr)'), credit])),
          ])),
        ]),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 30, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${widget.lineNum}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
        Expanded(flex: 5, child: account),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: note),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: debit),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: credit),
        remove,
      ]),
    );
  }
}
