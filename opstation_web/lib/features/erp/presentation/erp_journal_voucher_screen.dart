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

class _JvLine {
  static int _seq = 0;
  final String id = 'jvl_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
  String? accountId; String accountName = ''; String accountType = 'coa';
  final TextEditingController descCtrl   = TextEditingController();
  final TextEditingController debitCtrl  = TextEditingController();
  final TextEditingController creditCtrl = TextEditingController();
  double get debit  => double.tryParse(debitCtrl.text)  ?? 0;
  double get credit => double.tryParse(creditCtrl.text) ?? 0;
  void dispose() { descCtrl.dispose(); debitCtrl.dispose(); creditCtrl.dispose(); }
}

class ErpJournalVoucherScreen extends ConsumerStatefulWidget {
  const ErpJournalVoucherScreen({super.key});
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
  String? _pendingFocusId;
  int _auditSeq = 0;

  String? get _orgId    => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _status == 'posted';
  double get _totalDr => _lines.fold(0, (s,l) => s + l.debit);
  double get _totalCr => _lines.fold(0, (s,l) => s + l.credit);
  bool get _balanced  => (_totalDr - _totalCr).abs() < 0.005 && _totalDr > 0;
  bool get _canPost   => _balanced && _lines.where((l) => l.accountId != null).length >= 2;

  @override void initState() {
    super.initState();
    _dateCtrl.text = DateFormat('dd MMM yyyy').format(_date);
    _lines = [_JvLine(), _JvLine()];
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadMaster(); _loadVouchersAndAutoSelect(); _ensureAccessReady(); });
  }
  @override void dispose() { _ctxOverlay?.remove(); _dateCtrl.dispose(); _narCtrl.dispose(); for (final l in _lines) l.dispose(); super.dispose(); }
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

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
      if (mounted) setState(() { _vouchers = List<Map<String,dynamic>>.from(rows); _loadingList = false; });
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
        if ((l.accountType == 'supplier' || l.accountType == 'customer') && pid != null) {
          l.accountId = pid;            // restore the picker selection to the actual party
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
    } catch (e) { _snack('Load error: $e'); }
  }

  Future<void> _save({bool post = false}) async {
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
        await client.from('journal_entries').insert({
          'id': eId, 'org_id': orgId, 'branch_id': bid,
          'entry_number': eNum, 'entry_date': dateStr,
          'description': nar.isEmpty ? eNum : nar,
          'reference_type': 'jv', 'reference_id': eId, 'reference_number': eNum,
          'status': newSt, 'is_system_generated': false, 'created_by': userId,
          'created_at': DateTime.now().toIso8601String(),
          if (post) 'posted_at': DateTime.now().toIso8601String(),
        });
      } else {
        eId  = _current!['id'] as String; eNum = _current!['entry_number'] as String? ?? '';
        await client.from('journal_entries').update({
          'entry_date': dateStr, 'description': nar.isEmpty ? eNum : nar,
          'status': newSt, if (post) 'posted_at': DateTime.now().toIso8601String(),
        }).eq('id', eId);
      }
      await client.from('journal_lines').delete().eq('entry_id', eId);
      for (var i = 0; i < valid.length; i++) {
        final l = valid[i];
        final isParty = l.accountType == 'supplier' || l.accountType == 'customer';
        final glAcc   = l.accountType == 'supplier' ? apId
                      : l.accountType == 'customer' ? arId
                      : l.accountId;
        await client.from('journal_lines').insert({
          'id': eId + '_' + (i+1).toString(), 'entry_id': eId, 'org_id': orgId, 'branch_id': bid,
          'account_id': glAcc,
          'account_type': l.accountType,
          'account_name': l.accountName,
          'party_id': isParty ? l.accountId : null,
          'debit': l.debit, 'credit': l.credit,
          'description': l.descCtrl.text.trim(), 'line_order': i+1,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
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
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Journal Voucher?'),
      content: const Text('This removes all GL lines and cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete'))],
    ));
    if (ok != true) return;
    try {
      final id = _current!['id'] as String;
      await Supabase.instance.client.from('journal_lines').delete().eq('entry_id', id);
      await Supabase.instance.client.from('journal_entries').delete().eq('id', id);
      _snack('Deleted'); _newVoucher(); await _loadVouchers();
    } catch (e) { _snack('Delete failed: ' + e.toString()); }
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
        'performed_at': DateTime.now().toIso8601String(),
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
                  title: Text((e['action'] as String? ?? '').toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
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
    return Icons.info_outline;
  }
  Color _auditColor(String action) {
    if (action == 'created') return Colors.blue;
    if (action == 'posted') return Colors.green;
    if (action == 'unlocked') return Colors.orange;
    return Colors.grey;
  }

  void _print() {
    if (_current == null) { _snack('Save the voucher first'); return; }
    final lines = _lines.where((l) => l.accountId != null && (l.debit + l.credit) > 0).toList();
    final rawPostedAt = _current!['posted_at'] as String?;
    final postedInfo = rawPostedAt != null
        ? rawPostedAt.replaceAll('T', ' ').substring(0, rawPostedAt.length > 16 ? 16 : rawPostedAt.length)
        : '_______________';
    final htmlStr = '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Journal Voucher</title><style>
      body{font-family:Arial,sans-serif;padding:20px;color:#333}h2{text-align:center;color:#1a56db;margin-bottom:4px}
      table{width:100%;border-collapse:collapse;margin-top:14px}th,td{border:1px solid #ddd;padding:8px;text-align:left}
      th{background:#f0f4ff;font-weight:600}.total{font-weight:700}.num{text-align:right}
      .meta td{border:none;font-size:11px;padding:1px 10px 1px 0}
      .footer{margin-top:40px;display:flex;justify-content:space-between;font-size:12px}
      @media print{.no-print{display:none}@page{margin:0}body{padding:15mm 20mm}}
    </style></head><body>
    <div class="no-print" style="margin-bottom:16px"><button onclick="window.print()">Print</button></div>
    <h2>Journal Voucher</h2>
    <table class="meta" style="border:none;margin-bottom:5px"><tr>
      <td><b>Voucher#:</b> ${_current!['entry_number'] ?? ''}</td>
      <td><b>Date:</b> ${DateFormat('dd MMM yyyy').format(_date)}</td>
      <td><b>Status:</b> ${_status.toUpperCase()}</td>
    </tr><tr><td colspan="3"><b>Narration:</b> ${_narCtrl.text}</td></tr></table>
    <table><thead><tr><th style="width:30px">#</th><th>Account</th><th>Description</th><th class="num" style="width:120px">Debit</th><th class="num" style="width:120px">Credit</th></tr></thead><tbody>
    ${lines.asMap().entries.map((e) => '<tr><td>${e.key + 1}</td><td>${e.value.accountName}</td><td>${e.value.descCtrl.text}</td><td class="num">${e.value.debit > 0 ? money(e.value.debit) : ''}</td><td class="num">${e.value.credit > 0 ? money(e.value.credit) : ''}</td></tr>').join()}
    </tbody><tfoot><tr><td colspan="3" class="total num">Total:</td><td class="total num">${money(_totalDr)}</td><td class="total num">${money(_totalCr)}</td></tr></tfoot></table>
    <div class="footer"><div>Prepared by: _______________</div><div>Approved by: _______________</div><div>Posted: $postedInfo</div></div>
    </body></html>''';
    final blob = html.Blob([htmlStr], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override Widget build(BuildContext context) {
    final fmt = const MoneyFmt();
    final access = ref.watch(accessSyncProvider);
    final accessReady = access != null && access.role != null;
    final canAdd = access?.canAddDoc('jv') ?? false;
    final canEdit = access?.canEditDoc('jv') ?? false;
    final canDeleteJv = access?.canDelete() ?? false;
    final canWrite = _current == null ? canAdd : (canAdd || canEdit);
    final editable = !_isLocked && canWrite;
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      return matchesQuery('${v['entry_number'] ?? ''} ${v['description'] ?? ''}', _listSearch);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
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
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search JVs...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: BrandSpinner())
            : filtered.isEmpty ? const Center(child: Text('No vouchers', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
            : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
                final v = filtered[i]; final sel = _current?['id'] == v['id']; final posted = v['status'] == 'posted';
                return GestureDetector(
                  onSecondaryTapDown: (d) => _showCtxMenu(d.globalPosition, v),
                  child: InkWell(onTap: () => _loadVoucher(v), child: Container(
                    color: sel ? AppTheme.primary.withOpacity(0.07) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(v['entry_number'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(color: (posted ? Colors.green : Colors.orange).withOpacity(0.1), borderRadius: BorderRadius.circular(3)),
                          child: Text(posted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 9, color: posted ? Colors.green : Colors.orange, fontWeight: FontWeight.w700))),
                      ]),
                      Text(v['entry_date'] as String? ?? '', style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                      Text(v['description'] as String? ?? '', style: TextStyle(fontSize: 11, color: sel ? AppTheme.primary : AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                    ]),
                  )));
              })),
        ])),

      Expanded(child: Column(children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_current?['entry_number'] as String? ?? 'New Journal Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              if (_current != null) Text(_isLocked ? '🔒 Posted & Locked' : '✏️ Draft', style: TextStyle(fontSize: 10, color: _isLocked ? Colors.green : Colors.orange, fontWeight: FontWeight.w600)),
            ])),
            if (_current != null) IconButton(icon: const Icon(Icons.history_outlined, size: 20), onPressed: _showAuditTrail, tooltip: 'Audit Trail'),
            if (_current != null) IconButton(icon: const Icon(Icons.print_outlined, size: 20), onPressed: _print, tooltip: 'Print'),
            if (_current != null && canDeleteJv) IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red), onPressed: _delete, tooltip: 'Delete'),
            const SizedBox(width: 8),
            if (!_isLocked && canWrite) ...[
              OutlinedButton(onPressed: _saving ? null : () => _save(post: false), child: const Text('Save Draft', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('Post'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                onPressed: (_canPost && !_saving) ? () => _save(post: true) : null),
            ],
            if (_isLocked) Row(mainAxisSize: MainAxisSize.min, children: [
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
          : SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(width: 160, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Voucher No.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_current?['entry_number'] as String? ?? '(auto)', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ])),
            const SizedBox(width: 20),
            SizedBox(width: 170, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Date *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              InkWell(onTap: !editable ? null : () async {
                final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (d != null) setState(() { _date = d; _dateCtrl.text = DateFormat('dd MMM yyyy').format(d); });
              }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: const Color(0xFFBDBDBD)), borderRadius: BorderRadius.circular(6)),
                child: Row(children: [const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary), const SizedBox(width: 6), Text(DateFormat('dd MMM yyyy').format(_date), style: const TextStyle(fontSize: 13))]))),
            ])),
            const SizedBox(width: 20),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                const Expanded(child: SizedBox()),
                SizedBox(width: 120, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  const Text('Total Dr', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
                  Text(fmt.format(_totalDr), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))])),
                const SizedBox(width: 16),
                SizedBox(width: 120, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
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
                Text('Difference: ' + fmt.format((_totalDr - _totalCr).abs()) + ' — must be 0 to post',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w600)),
              ]))),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 30, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${widget.lineNum}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
        ])),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: TextField(controller: l.descCtrl, focusNode: _descFocus, enabled: !widget.locked,
          decoration: const InputDecoration(hintText: 'Note', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12), textInputAction: TextInputAction.next,
          onSubmitted: (_) => _debitFocus.requestFocus())),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: TextField(controller: l.debitCtrl, focusNode: _debitFocus, enabled: !widget.locked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.debit > 0, fillColor: Colors.blue.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.debit > 0 ? Colors.blue.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.creditCtrl.clear(); widget.onChanged(); },
          onSubmitted: (_) => widget.onNextLine())),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: TextField(controller: l.creditCtrl, focusNode: _creditFocus, enabled: !widget.locked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.credit > 0, fillColor: Colors.orange.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.credit > 0 ? Colors.orange.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.debitCtrl.clear(); widget.onChanged(); },
          onSubmitted: (_) => widget.onNextLine())),
        SizedBox(width: 30, child: widget.locked ? const SizedBox() : IconButton(
          icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: widget.onRemove,
          padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
      ]),
    );
  }
}
