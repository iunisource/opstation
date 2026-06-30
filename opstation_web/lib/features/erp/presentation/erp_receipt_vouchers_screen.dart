// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpReceiptVouchersScreen extends ConsumerStatefulWidget {
  const ErpReceiptVouchersScreen({super.key});
  @override ConsumerState<ErpReceiptVouchersScreen> createState() => _ErpReceiptVouchersScreenState();
}

class _ErpReceiptVouchersScreenState extends ConsumerState<ErpReceiptVouchersScreen> {
  List<Map<String, dynamic>> _vouchers = [];
  bool _drawerOpen = true;
  bool _loadingList = true;
  String _listSearch = '';
  Map<String, dynamic>? _currentVoucher;

  final _voucherDateCtrl = TextEditingController();
  DateTime _voucherDate = DateTime.now();
  String? _cashAccountId;
  String _cashAccountName = '';
  String _cashAccSearch = '';
  bool _showCashDrop = false;
  String _status = 'draft';

  List<_VLine> _lines = [];
  String? _pendingFocusId;
  List<Map<String, dynamic>> _auditTrail = [];
  List<Map<String, dynamic>> _coaList = [];
  List<Map<String, dynamic>> _supplierList = [];
  List<Map<String, dynamic>> _customerList = [];
  List<Map<String, dynamic>> _allAccounts = [];
  bool _loadingMaster = true;
  bool _saving = false;
  OverlayEntry? _ctxOverlay;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _isLocked => _status == 'posted';

  @override void initState() {
    super.initState();
    _voucherDate = DateTime.now(); _voucherDateCtrl.text = DateFormat('dd MMM yyyy').format(_voucherDate);
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadMaster(); _loadVouchersAndAutoSelect(); });
    _addLine();
  }
  @override void dispose() { _ctxOverlay?.remove(); _voucherDateCtrl.dispose(); for (final l in _lines) l.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadMaster() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadMaster(); return; }
    try {
      final res  = await Supabase.instance.client.rpc('get_voucher_master', params: {'p_org_id': orgId});
      final data = res as Map<String, dynamic>;
      final coa  = List<Map<String, dynamic>>.from((data['coa']       as List?) ?? []);
      final sup  = List<Map<String, dynamic>>.from((data['suppliers'] as List?) ?? []);
      final cus  = List<Map<String, dynamic>>.from((data['customers'] as List?) ?? []);
      final all = <Map<String, dynamic>>[
        ...coa.map((a) => {'id': a['id'], 'label': '${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}', 'sub': _typeLabel(a['account_type']), 'type': 'coa'}),
        ...sup.map((s) => {'id': s['id'], 'label': '${s['code'] != null ? '${s['code']} — ' : ''}${s['name']}', 'sub': 'Supplier', 'type': 'supplier'}),
        ...cus.map((c) => {'id': c['id'], 'label': '${c['code'] != null ? '${c['code']} — ' : ''}${c['shop_name'] ?? ''}', 'sub': 'Customer', 'type': 'customer'}),
      ];
      if (mounted) setState(() { _coaList = coa; _supplierList = sup; _customerList = cus; _allAccounts = all; _loadingMaster = false; });
    } catch (e) { if (mounted) { _snack('Load error: $e'); setState(() => _loadingMaster = false); } }
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      var q = Supabase.instance.client.from('crv_vouchers').select().eq('org_id', orgId);
      final bid = _branchId;
      if (bid != null) q = q.eq('branch_id', bid);
      final rows = await q.order('created_at', ascending: false).limit(200);
      if (mounted) setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (_) { if (mounted) setState(() => _loadingList = false); }
  }

  void _addLine() { final nl = _VLine(); setState(() { _lines.add(nl); _pendingFocusId = nl.id; }); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => _pendingFocusId = null); }); }

  void _removeLine(int i) { setState(() { _lines[i].dispose(); _lines.removeAt(i); }); if (_lines.isEmpty) _addLine(); }

  double get _total => _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amtCtrl.text) ?? 0));

  List<Map<String, dynamic>> _filterAccounts(String q) {
    if (q.isEmpty) return _allAccounts.take(50).toList();
    final ql = q.toLowerCase();
    return _allAccounts.where((a) =>
      (a['label'] as String).toLowerCase().contains(ql) ||
      (a['sub'] as String).toLowerCase().contains(ql)
    ).take(200).toList();
  }

  List<Map<String, dynamic>> get _cashAccounts => _coaList.where((a) => !_coaList.any((b) => b['parent_id'] == a['id']) && (a['account_group'] == 'Current Assets')).map((a) => {'id': a['id'], 'label': '${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}', 'type': a['account_type'] as String? ?? ''}).toList();

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


  Future<void> _loadVouchersAndAutoSelect() async {
    await _loadVouchers();
    if (!mounted) return;
    final href = html.window.location.href;
    final qIdx = href.indexOf('?');
    if (qIdx == -1) return;
    final params = Uri.splitQueryString(href.substring(qIdx + 1));
    final targetId = params['id'];
    if (targetId != null) {
      final matches = _vouchers.where((v) => v['voucher_number'] == targetId).toList();
      if (matches.isNotEmpty) _loadVoucher(matches.first);
    }
  }

  void _showCtxMenu(Offset pos, Map<String, dynamic> v) {
    _ctxOverlay?.remove();
    _ctxOverlay = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () { _ctxOverlay?.remove(); _ctxOverlay = null; },
        onSecondaryTap: () { _ctxOverlay?.remove(); _ctxOverlay = null; },
      )),
      Positioned(left: pos.dx, top: pos.dy, child: Material(
        elevation: 8, borderRadius: BorderRadius.circular(8),
        child: IntrinsicWidth(child: Column(mainAxisSize: MainAxisSize.min, children: [
          InkWell(
            onTap: () {
              final vNum = v['voucher_number'] as String? ?? '';
              final href = html.window.location.href;
              final hashIdx = href.indexOf('#');
              final origin = hashIdx != -1 ? href.substring(0, hashIdx) : href;
              html.window.open('${origin}#/erp/receipt-vouchers?id=${vNum}', '_blank');
              _ctxOverlay?.remove(); _ctxOverlay = null;
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.open_in_new, size: 15, color: AppTheme.textSecondary),
                const SizedBox(width: 10),
                const Text('Open in new tab', style: TextStyle(fontSize: 13)),
              ]),
            ),
          ),
        ])),
      )),
    ]));
    Overlay.of(context).insert(_ctxOverlay!);
  }

  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() { _currentVoucher = null; _cashAccountId = null; _cashAccountName = ''; _status = 'draft'; _lines = [_VLine()]; _voucherDate = DateTime.now(); _voucherDateCtrl.text = DateFormat('dd MMM yyyy').format(_voucherDate); });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('crv_voucher_lines').select().eq('voucher_id', v['id'] as String).order('line_order');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) { final l = _VLine(); l.accountId = r['account_id'] as String?; l.accountName = r['account_name'] as String? ?? ''; l.accountType = r['account_type'] as String? ?? 'coa'; l.descCtrl.text = r['description'] as String? ?? ''; l.amtCtrl.text = (r['amount'] as num?)?.toStringAsFixed(2) ?? ''; return l; }).toList();
      if (mounted) { setState(() { _currentVoucher = v; _cashAccountId = v['cash_account_id'] as String?; _cashAccountName = v['cash_account_name'] as String? ?? ''; _status = v['status'] as String? ?? 'draft'; _lines = newLines.isEmpty ? [_VLine()] : newLines; _voucherDate = (() { final s = (v['voucher_date'] as String?) ?? ''; final iso = DateTime.tryParse(s); if (iso != null) return iso; try { return DateFormat('dd MMM yyyy').parse(s); } catch (_) {} return DateTime.now(); })(); _voucherDateCtrl.text = DateFormat('dd MMM yyyy').format(_voucherDate); }); _loadAudit(v['id'] as String); }
    } catch (e) { _snack('Load error: $e'); }
  }

  Future<void> _save({bool post = false}) async {
    if (_cashAccountId == null) { _snack('Select a cash account first'); return; }
    final validLines = _lines.where((l) => l.accountId != null).toList();
    if (validLines.isEmpty) { _snack('Add at least one line item'); return; }
    final orgId = _orgId; final bid = _branchId ?? ''; final userId = ref.read(currentUserProvider)?.id;
        final userName = ref.read(currentUserProvider)?.name ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final total = validLines.fold<double>(0, (s, l) => s + (double.tryParse(l.amtCtrl.text) ?? 0));
      final newStatus = post ? 'posted' : 'draft';
      final dateStr = DateFormat('yyyy-MM-dd').format(_voucherDate);
      if (_currentVoucher == null) {
        final yr = DateTime.now().year.toString();
        final ex = await client.from('crv_vouchers').select('voucher_number').eq('org_id', orgId!).like('voucher_number', 'CRV-$yr-%');
        int mx = 0;
        for (final r in (ex as List)) { final n = int.tryParse((r['voucher_number'] as String? ?? '').split('-').last) ?? 0; if (n > mx) mx = n; }
        final vNum = 'CRV-$yr-${(mx + 1).toString().padLeft(4, '0')}';
        final vid = 'crv_${DateTime.now().millisecondsSinceEpoch}';
        await client.from('crv_vouchers').insert({'id': vid, 'org_id': orgId, 'branch_id': bid, 'voucher_number': vNum, 'voucher_date': dateStr, 'cash_account_id': _cashAccountId, 'cash_account_name': _cashAccountName, 'status': newStatus, 'total_amount': total, 'created_by': userId, 'posted_by': post ? userId : null, 'posted_at': post ? DateTime.now().toIso8601String() : null, 'posted_by_name': post ? userName : null});
        for (var i = 0; i < validLines.length; i++) { final l = validLines[i]; await client.from('crv_voucher_lines').insert({'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_$i', 'voucher_id': vid, 'account_type': l.accountType, 'account_id': l.accountId, 'account_name': l.accountName, 'description': l.descCtrl.text.trim(), 'amount': double.tryParse(l.amtCtrl.text) ?? 0, 'line_order': i}); }
        final created = await client.from('crv_vouchers').select().eq('id', vid).single();
        setState(() { _currentVoucher = created; _status = newStatus; }); _logAudit('created', notes: 'Total: Rs. \${_total.toStringAsFixed(2)}  •  \${_lines.where((l) => l.accountId != null).length} lines  •  \$_cashAccountName');
        _snack(post ? 'Voucher $vNum posted ✓' : 'Voucher $vNum saved');
      } else {
        final vid = _currentVoucher!['id'] as String;
        await client.from('crv_vouchers').update({'voucher_date': dateStr, 'cash_account_id': _cashAccountId, 'cash_account_name': _cashAccountName, 'status': newStatus, 'total_amount': total, 'posted_by': post ? userId : null, 'posted_at': post ? DateTime.now().toIso8601String() : null, 'posted_by_name': post ? userName : null}).eq('id', vid);
        await client.from('crv_voucher_lines').delete().eq('voucher_id', vid);
        for (var i = 0; i < validLines.length; i++) { final l = validLines[i]; await client.from('crv_voucher_lines').insert({'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_$i', 'voucher_id': vid, 'account_type': l.accountType, 'account_id': l.accountId, 'account_name': l.accountName, 'description': l.descCtrl.text.trim(), 'amount': double.tryParse(l.amtCtrl.text) ?? 0, 'line_order': i}); }
        setState(() { _status = newStatus; _currentVoucher = {..._currentVoucher!, 'status': newStatus}; }); if (post) _logAudit('posted', notes: 'Total: Rs. \${_total.toStringAsFixed(2)}  •  \${_lines.where((l) => l.accountId != null).length} lines');
        _snack(post ? 'Voucher posted ✓' : 'Saved');
      }
      if (post && orgId != null) await _postCrvToGL(orgId!, bid, dateStr, validLines, total);
      await _loadVouchers();
    } catch (e) { _snack('Failed: $e'); }
    setState(() => _saving = false);
  }


  Future<void> _postCrvToGL(String orgId, String bid, String dateStr, List<_VLine> lines, double total) async {
    final cashCoaId = _cashAccountId;
    if (cashCoaId == null || cashCoaId.isEmpty) { _snack('GL error: no cash account'); return; }
      final arId       = 'coa_' + orgId + '_1210';
      final incentiveId = 'coa_' + orgId + '_4310';
    final vid    = _currentVoucher?['id']            as String? ?? '';
    final vNum   = _currentVoucher?['voucher_number'] as String? ?? '';
    final eId    = 'je_crv_' + vid;
    final client = Supabase.instance.client;
    try {
      // Idempotent re-post. journal_entries has no UPDATE policy by design
      // (GL entries are immutable), so we DELETE any prior GL for this voucher
      // then INSERT fresh — never upsert. This makes re-posting fully replace
      // the previous entry instead of erroring on the update branch or duplicating.
      final prior = await client.from('journal_entries').select('id')
          .eq('org_id', orgId).eq('reference_type', 'crv').eq('reference_id', vid);
      for (final e in (prior as List)) {
        await client.from('journal_lines').delete().eq('entry_id', e['id'] as String);
      }
      await client.from('journal_lines').delete().eq('entry_id', eId);
      await client.from('journal_entries').delete()
          .eq('org_id', orgId).eq('reference_type', 'crv').eq('reference_id', vid);
      await client.from('journal_entries').delete().eq('id', eId);
      await client.from('journal_entries').insert({
        'id': eId, 'org_id': orgId, 'branch_id': bid,
        'entry_number': 'CRV-' + vNum,
        'entry_date': dateStr,
        'description': 'Cash Receipt: ' + vNum,
        'reference_type': 'crv', 'reference_id': vid,
        'reference_number': vNum,
        'status': 'posted', 'is_system_generated': true,
        'created_at': DateTime.now().toIso8601String(),
        'posted_at': DateTime.now().toIso8601String(),
      });
      await client.from('journal_lines').insert({
        'id': eId + '_0', 'entry_id': eId, 'org_id': orgId, 'branch_id': bid,
        'account_id': cashCoaId, 'debit': total, 'credit': 0.0, 'line_order': 0,
      });
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final amt   = double.tryParse(l.amtCtrl.text) ?? 0.0;
        if (amt == 0) continue;
        final accId = l.accountType == 'customer' ? arId : l.accountType == 'supplier' ? incentiveId : (l.accountId ?? arId);
        await client.from('journal_lines').insert({
          'id': eId + '_' + (i+1).toString(), 'entry_id': eId, 'org_id': orgId, 'branch_id': bid,
          'account_id': accId, 'debit': 0.0, 'credit': amt, 'line_order': i + 1,
          // Attribute the receivable/party leg so it nets against the customer
          // (or supplier) in the ledger & aging. GL-account lines stay null.
          'party_id': (l.accountType == 'customer' || l.accountType == 'supplier') ? l.accountId : null,
        });
      }
    } catch (e) { _snack('GL error: ' + e.toString()); }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete Voucher?'), content: const Text('This cannot be undone.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red))]));
    if (ok != true) return;
    try {
      if (_currentVoucher != null) { await Supabase.instance.client.from('crv_vouchers').delete().eq('id', _currentVoucher!['id'] as String); _snack('Deleted'); _newVoucher(); await _loadVouchers(); }
    } catch (e) { _snack('Failed: $e'); }
  }

  Future<void> _loadAudit(String voucherId) async {
    try {
      final rows = await Supabase.instance.client.from('crv_audit_trail').select().eq('voucher_id', voucherId).order('performed_at');
      if (mounted) setState(() => _auditTrail = List<Map<String, dynamic>>.from(rows));
    } catch (_) {}
  }

  Future<void> _logAudit(String action, {String? notes}) async {
    if (_currentVoucher == null) return;
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    try {
      await Supabase.instance.client.from('crv_audit_trail').insert({
        'id': 'aud_${DateTime.now().microsecondsSinceEpoch}',
        'voucher_id': _currentVoucher!['id'] as String,
        'action': action,
        'performed_by': userId,
        'performed_by_name': userName,
        'performed_at': DateTime.now().toIso8601String(),
        'notes': notes,
      });
      await _loadAudit(_currentVoucher!['id'] as String);
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
                return ListTile(
                  dense: true,
                  leading: Icon(_auditIcon(e['action'] as String? ?? ''), size: 18, color: _auditColor(e['action'] as String? ?? '')),
                  title: Text((e['action'] as String? ?? '').toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  subtitle: Text('$who  •  $at', style: const TextStyle(fontSize: 11)),
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

    Future<void> _unlockVoucher() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Unlock Voucher?'),
      content: const Text('This will set the voucher back to Draft and allow editing.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Unlock'), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange)),
      ],
    ));
    if (ok != true || !mounted) return;
    try {
      await Supabase.instance.client.from('crv_vouchers').update({'status': 'draft'}).eq('id', _currentVoucher!['id'] as String);
      setState(() { _status = 'draft'; _currentVoucher = {..._currentVoucher!, 'status': 'draft'}; }); _logAudit('unlocked', notes: 'Voucher reopened for editing');
      _snack('Voucher unlocked for editing');
    } catch (e) { _snack('Failed: $e'); }
  }

  void _print() {
    if (_currentVoucher == null) { _snack('Save the voucher first'); return; }
    final lines = _lines.where((l) => l.accountId != null).toList();
    final postedBy = _currentVoucher!['posted_by_name'] as String? ?? '_______________';
    final rawPostedAt = _currentVoucher!['posted_at'] as String?;
    final postedAtStr = rawPostedAt != null ? '  (' + rawPostedAt.replaceAll('T', ' ').substring(0, rawPostedAt.length > 16 ? 16 : rawPostedAt.length) + ')' : '';
    final html_str = '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Receipt Voucher</title><style>
      body{font-family:Arial,sans-serif;padding:20px;color:#333}h2{text-align:center;color:#1a56db}
      table{width:100%;border-collapse:collapse;margin-top:16px}th,td{border:1px solid #ddd;padding:8px;text-align:left}
      th{background:#f0f4ff;font-weight:600}.total{font-weight:700;font-size:1.1em}.footer{margin-top:40px;display:flex;justify-content:space-between}
      @media print{.no-print{display:none}@page{margin:0}body{padding:15mm 20mm}}
    </style></head><body>
    <div class="no-print" style="margin-bottom:16px"><button onclick="window.print()">&#x1F5A8; Print</button></div>
    <h2>Cash Receipt Voucher</h2>
    <table style="border:none;margin-bottom:5px;width:100%"><tr><td style="border:none;padding:1px 10px 1px 0;font-size:10px;white-space:nowrap"><b>Voucher#:</b> ${_currentVoucher!['voucher_number'] ?? ''}</td><td style="border:none;padding:1px 10px;font-size:10px;white-space:nowrap"><b>Date:</b> ${_currentVoucher!['voucher_date'] ?? ''}</td><td style="border:none;padding:1px 10px;font-size:10px"><b>Cash A/c:</b> $_cashAccountName</td><td style="border:none;padding:1px 0;font-size:10px;white-space:nowrap"><b>Status:</b> ${_status.toUpperCase()}</td></tr></table>
    <table><thead><tr><th>#</th><th>Account / Party</th><th>Description</th><th style="text-align:right">Amount (Rs.)</th></tr></thead><tbody>
    ${lines.asMap().entries.map((e) => '<tr><td>${e.key + 1}</td><td>${e.value.accountName}</td><td>${e.value.descCtrl.text}</td><td style="text-align:right">${double.tryParse(e.value.amtCtrl.text)?.toStringAsFixed(2) ?? '0.00'}</td></tr>').join()}
    </tbody><tfoot><tr><td colspan="3" class="total" style="text-align:right">Total:</td><td class="total" style="text-align:right">Rs. ${_total.toStringAsFixed(2)}</td></tr></tfoot></table>
    <div class="footer"><div>Prepared by: _______________</div><div>Approved by: _______________</div><div>Posted by: $postedBy$postedAtStr</div></div>
    </body></html>''';
    final blob = html.Blob([html_str], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) { final q = _listSearch.toLowerCase(); return (v['voucher_number'] as String? ?? '').toLowerCase().contains(q) || (v['cash_account_name'] as String? ?? '').toLowerCase().contains(q); }).toList();
    final cashFiltered = _cashAccSearch.isEmpty ? _cashAccounts : _cashAccounts.where((a) => (a['label'] as String).toLowerCase().contains(_cashAccSearch.toLowerCase())).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      // ── DRAWER ─────────────────────────────────────────────────
      AnimatedContainer(duration: const Duration(milliseconds: 200), width: _drawerOpen ? 260 : 36, decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
        InkWell(onTap: () => setState(() => _drawerOpen = !_drawerOpen), child: Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18, color: AppTheme.textSecondary), if (_drawerOpen) ...[const SizedBox(width: 6), const Expanded(child: Text('Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))), ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero), onPressed: _newVoucher)]]))),
        if (_drawerOpen) ...[
          Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: TextField(decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 14), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 5, horizontal: 8)), onChanged: (v) => setState(() => _listSearch = v))),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2)) : filtered.isEmpty ? const Center(child: Text('No vouchers', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))) : ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
            final v = filtered[i]; final sel = _currentVoucher?['id'] == v['id']; final posted = v['status'] == 'posted';
            return GestureDetector(onSecondaryTapDown: (d) => _showCtxMenu(d.globalPosition, v), child: InkWell(onTap: () => _loadVoucher(v), child: Container(color: sel ? AppTheme.primary.withOpacity(0.07) : null, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text(v['voucher_number'] as String? ?? 'Draft', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sel ? AppTheme.primary : AppTheme.textPrimary))), Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: (posted ? Colors.green : Colors.orange).withOpacity(0.1), borderRadius: BorderRadius.circular(3)), child: Text(posted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 9, color: posted ? Colors.green : Colors.orange, fontWeight: FontWeight.w700)))]),
              Text(v['cash_account_name'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
              Text('Rs. ${(v['total_amount'] as num?)?.toStringAsFixed(2) ?? '0.00'}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sel ? AppTheme.primary : AppTheme.textPrimary)),
            ]))));
          })),
        ],
      ])),
      // ── MAIN AREA ───────────────────────────────────────────────
      Expanded(child: Column(children: [
        // Top bar
        Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(16, 10, 16, 10), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))), child: Row(children: [
          const Icon(Icons.receipt_long_outlined, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_currentVoucher?['voucher_number'] as String? ?? 'New Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: (_isLocked ? Colors.green : Colors.orange).withOpacity(0.1), borderRadius: BorderRadius.circular(4)), child: Text(_isLocked ? '🔒 Posted & Locked' : '✏️ Draft', style: TextStyle(fontSize: 11, color: _isLocked ? Colors.green : Colors.orange, fontWeight: FontWeight.w600)))]),
          ])),
          if (_currentVoucher != null) IconButton(icon: const Icon(Icons.history_outlined, size: 20), onPressed: _showAuditTrail, tooltip: 'Audit Trail'),
          if (_currentVoucher != null) IconButton(icon: const Icon(Icons.print_outlined, size: 20), onPressed: _print, tooltip: 'Print'),
          if (_currentVoucher != null) IconButton(icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red), onPressed: _delete, tooltip: 'Delete'),
          const SizedBox(width: 8),
          if (!_isLocked) ElevatedButton.icon(
            icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
            label: const Text('Post'),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            onPressed: _saving ? null : () => _save(post: true),
          ),
          if (_isLocked) Row(mainAxisSize: MainAxisSize.min, children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withOpacity(0.3))), child: const Row(children: [Icon(Icons.lock, size: 14, color: Colors.green), SizedBox(width: 4), Text('Posted', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w700, fontSize: 13))])),
            const SizedBox(width: 8),
            OutlinedButton.icon(icon: const Icon(Icons.lock_open_outlined, size: 14), label: const Text('Unlock', style: TextStyle(fontSize: 12)), onPressed: _unlockVoucher, style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, side: const BorderSide(color: Colors.orange), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8))),
          ]),
        ])),
        // Header fields
        Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(16, 10, 16, 10), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))), child: Row(children: [
          SizedBox(width: 140, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Voucher No.', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)), const SizedBox(height: 3), Text(_currentVoucher?['voucher_number'] as String? ?? '(auto)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary))])),
          const SizedBox(width: 12),
          SizedBox(width: 150, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Voucher Date *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)), const SizedBox(height: 3), InkWell(onTap: _isLocked ? null : () async { final p = await showDatePicker(context: context, initialDate: _voucherDate, firstDate: DateTime(2020), lastDate: DateTime(2100)); if (p != null) setState(() { _voucherDate = p; _voucherDateCtrl.text = DateFormat('dd MMM yyyy').format(p); }); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), decoration: BoxDecoration(border: Border.all(color: const Color(0xFFBDBDBD)), borderRadius: BorderRadius.circular(4)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(DateFormat('dd MMM yyyy').format(_voucherDate), style: const TextStyle(fontSize: 13)), const Icon(Icons.calendar_today, size: 13, color: AppTheme.textSecondary)])))])),
          const SizedBox(width: 12),
          // Cash Account with proper dropdown
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Cash Account *', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            if (!_isLocked) _SearchableDropdown(
              value: _cashAccountName,
              hint: 'Select cash account (BANK / CASH IN HAND)',
              items: _cashAccounts,
              onSelect: (a) => setState(() { _cashAccountId = a['id'] as String; _cashAccountName = a['label'] as String; }),
            )
            else Text(_cashAccountName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ])),
        ])),
        // Table header
        Container(color: const Color(0xFFF8F9FA), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7), child: Row(children: const [
          SizedBox(width: 28),
          Expanded(flex: 4, child: Text('Account / Party', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Description', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 8),
          SizedBox(width: 130, child: Text('Amount (Rs.)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
          SizedBox(width: 30),
        ])),
        const Divider(height: 1),
        // Lines
        Expanded(child: _loadingMaster
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading accounts...', style: TextStyle(color: AppTheme.textSecondary))]))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
              itemCount: _lines.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (_, i) => _LineWidget(
                key: ValueKey('line_${_lines[i].id}'),
                line: _lines[i], lineNum: i + 1,
                allAccounts: _allAccounts, filterFn: _filterAccounts,
                locked: _isLocked,
                autoFocus: _lines[i].id == _pendingFocusId,
                onRemove: () => _removeLine(i),
                onNextLine: i == _lines.length - 1 ? _addLine : () {},
                onChanged: () => setState(() {}),
              ),
            )),
        // Footer
        Container(decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppTheme.border))), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), child: Row(children: [
          if (!_isLocked) TextButton.icon(icon: const Icon(Icons.add, size: 15), label: const Text('Add Line'), onPressed: _addLine),
          const Spacer(),
          Text('${_lines.where((l) => l.accountId != null).length} lines', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(width: 16),
          const Text('Total:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Text('Rs. ${_total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
        ])),
      ])),
    ]));
  }
}

// ── Searchable dropdown (proper overlay) ────────────────────────────────────
class _SearchableDropdown extends StatefulWidget {
  final String value, hint;
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>> onSelect;
  const _SearchableDropdown({required this.value, required this.hint, required this.items, required this.onSelect});
  @override State<_SearchableDropdown> createState() => _SearchableDropdownState();
}

class _SearchableDropdownState extends State<_SearchableDropdown> {
  bool _open = false;
  String _q = '';

  List<Map<String, dynamic>> get _filtered => _q.isEmpty ? widget.items : widget.items.where((a) => (a['label'] as String).toLowerCase().contains(_q.toLowerCase())).toList();

  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    InkWell(onTap: () => setState(() => _open = !_open), child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(border: Border.all(color: _open ? AppTheme.primary : AppTheme.border), borderRadius: BorderRadius.circular(6)), child: Row(children: [Expanded(child: Text(widget.value.isNotEmpty ? widget.value : widget.hint, style: TextStyle(fontSize: 13, color: widget.value.isEmpty ? Colors.grey : AppTheme.textPrimary), overflow: TextOverflow.ellipsis)), Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: AppTheme.textSecondary)]))),
    if (_open) Container(margin: const EdgeInsets.only(top: 2), constraints: const BoxConstraints(maxHeight: 220), decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 4))]), child: Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search...', isDense: true, prefixIcon: Icon(Icons.search, size: 14), contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8)), onChanged: (v) => setState(() => _q = v))),
      Expanded(child: _filtered.isEmpty ? const Center(child: Text('No results', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))) : ListView(children: _filtered.map((a) => InkWell(onTap: () { widget.onSelect(a); setState(() { _open = false; _q = ''; }); }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(3)), child: Text(a['type'] as String? ?? '', style: const TextStyle(fontSize: 9, color: AppTheme.primary, fontWeight: FontWeight.w700))), const SizedBox(width: 6), Explained(child: Tooltip(message: a['label'] as String, waitDuration: const Duration(milliseconds: 400), child: Text(a['label'] as String, style: const TextStyle(fontSize: 12), softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis)))])))).toList())),
    ])),
  ]);
}

class Explained extends StatelessWidget {
  final Widget child;
  const Explained({super.key, required this.child});
  @override Widget build(BuildContext context) => Expanded(child: child);
}

// ── Line model ───────────────────────────────────────────────────────────────
class _VLine {
  final String id = 'vl_${DateTime.now().microsecondsSinceEpoch}';
  String? accountId; String accountName = ''; String accountType = 'coa';
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController amtCtrl = TextEditingController();
  void dispose() { descCtrl.dispose(); amtCtrl.dispose(); }
}

// ── Line widget ──────────────────────────────────────────────────────────────
class _LineWidget extends StatefulWidget {
  final _VLine line; final int lineNum;
  final List<Map<String, dynamic>> allAccounts;
  final List<Map<String, dynamic>> Function(String) filterFn;
  final bool locked;
  final bool autoFocus;
  final VoidCallback onRemove, onNextLine, onChanged;
  const _LineWidget({super.key, required this.line, required this.lineNum, required this.allAccounts, required this.filterFn, required this.locked, required this.onRemove, required this.onNextLine, required this.onChanged, this.autoFocus = false});
  @override State<_LineWidget> createState() => _LineWidgetState();
}

class _LineWidgetState extends State<_LineWidget> {
  bool _showDrop = false;
  String _q = '';
  final _accFocus = FocusNode();
  final _descFocus = FocusNode();
  final _amtFocus = FocusNode();
  final _accCtrl = TextEditingController();

  @override void initState() { super.initState(); _accCtrl.text = widget.line.accountName; _accFocus.addListener(() { if (!_accFocus.hasFocus) Future.delayed(const Duration(milliseconds: 160), () { if (mounted && !_accFocus.hasFocus) setState(() => _showDrop = false); }); }); if (widget.autoFocus) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _accFocus.requestFocus(); }); }
  @override void dispose() { _accFocus.dispose(); _descFocus.dispose(); _amtFocus.dispose(); _accCtrl.dispose(); super.dispose(); }

  void _pick(Map<String, dynamic> a) {
    widget.line.accountId = a['id'] as String;
    widget.line.accountName = a['label'] as String;
    widget.line.accountType = a['type'] as String;
    _accCtrl.text = a['label'] as String;
    setState(() { _showDrop = false; _q = ''; });
    widget.onChanged();
    _descFocus.requestFocus();
  }

  @override Widget build(BuildContext context) {
    final filtered = widget.filterFn(_q);
    return Container(decoration: BoxDecoration(color: widget.locked ? Colors.grey.shade50 : Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border.withOpacity(0.5))), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 20, child: Center(child: Text('${widget.lineNum}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
      const SizedBox(width: 8),
      Expanded(flex: 4, child: Column(children: [
        TextField(controller: _accCtrl, focusNode: _accFocus, enabled: !widget.locked,
          decoration: InputDecoration(hintText: 'Search account, supplier, customer...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7), suffixIcon: widget.line.accountId != null ? const Icon(Icons.check_circle, color: Colors.green, size: 14) : null),
          onChanged: (v) { setState(() { _q = v; _showDrop = v.isNotEmpty || _accFocus.hasFocus; }); },
          onTap: () => setState(() => _showDrop = true),
          onSubmitted: (_) { if (filtered.isNotEmpty) _pick(filtered.first); },
        ),
        if (_showDrop && filtered.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 160), margin: const EdgeInsets.only(top: 2), decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6)]), child: ListView(shrinkWrap: true, children: filtered.map((a) {
          final t = a['type'] as String;
          final c = t == 'supplier' ? Colors.blue : t == 'customer' ? Colors.purple : AppTheme.primary;
          return InkWell(onTap: () => _pick(a), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(3)), child: Text(a['sub'] as String? ?? t, style: TextStyle(fontSize: 9, color: c, fontWeight: FontWeight.w700))), const SizedBox(width: 6), Expanded(child: Tooltip(message: a['label'] as String, waitDuration: const Duration(milliseconds: 400), child: Text(a['label'] as String, style: const TextStyle(fontSize: 12), softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis)))])));
        }).toList())),
      ])),
      const SizedBox(width: 8),
      Expanded(flex: 3, child: TextField(controller: widget.line.descCtrl, focusNode: _descFocus, enabled: !widget.locked, decoration: const InputDecoration(hintText: 'Description', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7)), onChanged: (_) => widget.onChanged(), textInputAction: TextInputAction.next, onSubmitted: (_) => _amtFocus.requestFocus())),
      const SizedBox(width: 8),
      SizedBox(width: 130, child: TextField(
        controller: widget.line.amtCtrl, focusNode: _amtFocus, enabled: !widget.locked,
        textAlign: TextAlign.right,
        decoration: const InputDecoration(hintText: '0.00', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7), prefixText: 'Rs. ', prefixStyle: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onChanged: (_) => widget.onChanged(),
        onSubmitted: (_) => widget.onNextLine(),
      )),
      const SizedBox(width: 4),
      SizedBox(width: 26, child: widget.locked ? const SizedBox() : IconButton(icon: const Icon(Icons.close, size: 13), onPressed: widget.onRemove, color: Colors.red.shade300, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
    ]));
  }
}
