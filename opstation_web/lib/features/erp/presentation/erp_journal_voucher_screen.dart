// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class _JvLine {
  final String id = 'jvl_${DateTime.now().microsecondsSinceEpoch}';
  String? accountId; String accountName = '';
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
  List<Map<String,dynamic>> _coaList = []; bool _loadingMaster = true, _saving = false;

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
    WidgetsBinding.instance.addPostFrameCallback((_) { _loadMaster(); _loadVouchersAndAutoSelect(); });
    _addLine(); _addLine();
  }
  @override void dispose() { _ctxOverlay?.remove(); _dateCtrl.dispose(); _narCtrl.dispose(); for (final l in _lines) l.dispose(); super.dispose(); }
  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadMaster() async {
    final orgId = _orgId;
    if (orgId == null) { await Future.delayed(const Duration(milliseconds: 500)); if (mounted) _loadMaster(); return; }
    try {
      final res  = await Supabase.instance.client.rpc('get_voucher_master', params: {'p_org_id': orgId});
      final data = res as Map<String,dynamic>;
      final coa  = List<Map<String,dynamic>>.from((data['coa'] as List?) ?? []);
      if (mounted) setState(() { _coaList = coa; _loadingMaster = false; });
    } catch (e) { if (mounted) setState(() => _loadingMaster = false); }
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

  void _addLine() => setState(() => _lines.add(_JvLine()));
  void _removeLine(int i) { setState(() { _lines[i].dispose(); _lines.removeAt(i); }); if (_lines.length < 2) _addLine(); }
  void _newVoucher() {
    for (final l in _lines) l.dispose();
    setState(() { _current = null; _status = 'draft'; _lines = [_JvLine(), _JvLine()];
      _date = DateTime.now(); _dateCtrl.text = DateFormat('dd MMM yyyy').format(_date); _narCtrl.clear(); });
  }

  Future<void> _loadVoucher(Map<String,dynamic> v) async {
    try {
      final rows = await Supabase.instance.client.from('journal_lines').select().eq('entry_id', v['id'] as String).order('line_order');
      for (final l in _lines) l.dispose();
      final newLines = (rows as List).map((r) {
        final l = _JvLine(); l.accountId = r['account_id'] as String?;
        final coa = _coaList.firstWhere((a) => a['id'] == l.accountId, orElse: () => {});
        l.accountName = coa.isNotEmpty ? '${coa['code'] ?? ''} — ${coa['name'] ?? ''}' : (l.accountId ?? '');
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
    } catch (e) { _snack('Load error: $e'); }
  }

  Future<void> _save({bool post = false}) async {
    final valid = _lines.where((l) => l.accountId != null && (l.debit + l.credit) > 0).toList();
    if (valid.isEmpty) { _snack('Add at least one account line'); return; }
    if (post && !_balanced) { _snack('Debits must equal credits to post'); return; }
    final orgId = _orgId; if (orgId == null) { _snack('Not authenticated'); return; }
    final bid = _branchId ?? ''; final userId = ref.read(currentUserProvider)?.id ?? '';
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final newSt   = post ? 'posted' : 'draft';
      final nar     = _narCtrl.text.trim();
      String eId, eNum;
      if (_current == null) {
        final cnt = await client.from('journal_entries').select('id').eq('org_id', orgId).eq('reference_type', 'jv');
        final seq  = ((cnt as List).length + 1).toString().padLeft(4, '0');
        eNum = 'JV-' + DateTime.now().year.toString() + '-' + seq;
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
        await client.from('journal_lines').insert({
          'id': eId + '_' + (i+1).toString(), 'entry_id': eId, 'org_id': orgId, 'branch_id': bid,
          'account_id': l.accountId, 'debit': l.debit, 'credit': l.credit,
          'description': l.descCtrl.text.trim(), 'line_order': i+1,
          'created_at': DateTime.now().toIso8601String(),
        });
      }
      final updated = await client.from('journal_entries').select().eq('id', eId).single();
      if (mounted) setState(() { _current = updated; _status = newSt; });
      _snack(post ? 'JV ' + eNum + ' posted ✓' : 'Draft saved');
      await _loadVouchers();
    } catch (e) { _snack('Save failed: ' + e.toString()); }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _delete() async {
    if (_current == null) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete Journal Voucher?'),
      content: const Text('This removes all GL lines and cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red))],
    ));
    if (ok != true) return;
    try {
      final id = _current!['id'] as String;
      await Supabase.instance.client.from('journal_lines').delete().eq('entry_id', id);
      await Supabase.instance.client.from('journal_entries').delete().eq('id', id);
      _snack('Deleted'); _newVoucher(); await _loadVouchers();
    } catch (e) { _snack('Delete failed: ' + e.toString()); }
  }

  List<Map<String,dynamic>> _filterCoa(String q) {
    final l3 = _coaList.where((a) => (a['level'] as int? ?? 0) == 3).toList();
    if (q.isEmpty) return l3.take(30).toList();
    final ql = q.toLowerCase();
    return l3.where((a) => (a['name'] as String? ?? '').toLowerCase().contains(ql) || (a['code'] as String? ?? '').toLowerCase().contains(ql)).take(50).toList();
  }

  @override Widget build(BuildContext context) {
    final fmt = NumberFormat('#,##0.00');
    final filtered = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      final q = _listSearch.toLowerCase();
      return (v['entry_number'] as String? ?? '').toLowerCase().contains(q) || (v['description'] as String? ?? '').toLowerCase().contains(q);
    }).toList();

    return Container(color: AppTheme.background, child: Row(children: [
      if (_drawerOpen) Container(width: 300,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          Container(padding: const EdgeInsets.fromLTRB(10,10,10,8),
            decoration: BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Journal Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                ElevatedButton.icon(icon: const Icon(Icons.add, size: 13), label: const Text('New', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero),
                  onPressed: _newVoucher),
              ]),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search JVs...', prefixIcon: Icon(Icons.search, size: 15), isDense: true),
                onChanged: (v) => setState(() => _listSearch = v)),
            ])),
          Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
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
          decoration: BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            IconButton(icon: Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, size: 18), onPressed: () => setState(() => _drawerOpen = !_drawerOpen), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_current?['entry_number'] as String? ?? 'New Journal Voucher', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              if (_current != null) Text(_isLocked ? '🔒 Posted & Locked' : '✏️ Draft', style: TextStyle(fontSize: 10, color: _isLocked ? Colors.green : Colors.orange, fontWeight: FontWeight.w600)),
            ])),
            if (_current != null && !_isLocked) IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 18), onPressed: _delete, tooltip: 'Delete'),
            const SizedBox(width: 8),
            if (!_isLocked) ...[
              OutlinedButton(onPressed: _saving ? null : () => _save(post: false), child: const Text('Save Draft', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('Post'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                onPressed: (_canPost && !_saving) ? () => _save(post: true) : null),
            ],
          ])),
        Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              InkWell(onTap: _isLocked ? null : () async {
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
              TextField(controller: _narCtrl, enabled: !_isLocked,
                decoration: InputDecoration(hintText: 'Enter narration...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFBDBDBD))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFBDBDBD))))),
            ])),
          ]),
          const SizedBox(height: 20),
          Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)), child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: const BorderRadius.vertical(top: Radius.circular(10))),
              child: const Row(children: [
                SizedBox(width: 30, child: Text('#', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                Expanded(flex: 5, child: Text('Account', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                Expanded(flex: 3, child: Text('Description', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                SizedBox(width: 120, child: Text('Debit (Dr)', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 8),
                SizedBox(width: 120, child: Text('Credit (Cr)', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600))),
                SizedBox(width: 30),
              ])),
            for (var i = 0; i < _lines.length; i++) _buildLine(i, fmt),
            if (!_isLocked) Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TextButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('Add Line', style: TextStyle(fontSize: 12)), onPressed: _addLine)),
            Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _balanced && _totalDr > 0 ? Colors.green.withOpacity(0.05) : (_totalDr > 0 ? Colors.red.withOpacity(0.04) : AppTheme.background),
                border: Border(top: BorderSide(color: AppTheme.border)),
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
                      : Tooltip(message: 'Unbalanced', child: Icon(Icons.error, color: Colors.red, size: 20)))
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

  Widget _buildLine(int i, NumberFormat fmt) {
    final l = _lines[i];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 30, child: Padding(padding: const EdgeInsets.only(top: 8), child: Text('${i+1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)))),
        Expanded(flex: 5, child: _JvAccPicker(key: ValueKey(l.id), line: l, filterFn: _filterCoa, enabled: !_isLocked,
          onPick: (a) => setState(() { l.accountId = a['id'] as String?; l.accountName = (a['code'] ?? '') + ' — ' + (a['name'] ?? ''); }))),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: TextField(controller: l.descCtrl, enabled: !_isLocked,
          decoration: const InputDecoration(hintText: 'Note', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            border: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: TextField(controller: l.debitCtrl, enabled: !_isLocked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.debit > 0, fillColor: Colors.blue.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.debit > 0 ? Colors.blue.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.creditCtrl.clear(); setState(() {}); })),
        const SizedBox(width: 8),
        SizedBox(width: 120, child: TextField(controller: l.creditCtrl, enabled: !_isLocked, textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(hintText: '—', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            filled: l.credit > 0, fillColor: Colors.orange.withOpacity(0.04),
            border: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFFE0E0E0))),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: l.credit > 0 ? Colors.orange.shade300 : const Color(0xFFE0E0E0)))),
          style: const TextStyle(fontSize: 12),
          onChanged: (v) { if (v.isNotEmpty && (double.tryParse(v) ?? 0) > 0) l.debitCtrl.clear(); setState(() {}); })),
        SizedBox(width: 30, child: _isLocked ? const SizedBox() : IconButton(
          icon: const Icon(Icons.close, size: 14, color: Colors.red), onPressed: () => _removeLine(i),
          padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
      ]),
    );
  }
}

class _JvAccPicker extends StatefulWidget {
  final _JvLine line; final List<Map<String,dynamic>> Function(String) filterFn;
  final bool enabled; final void Function(Map<String,dynamic>) onPick;
  const _JvAccPicker({super.key, required this.line, required this.filterFn, required this.enabled, required this.onPick});
  @override State<_JvAccPicker> createState() => _JvAccPickerState();
}

class _JvAccPickerState extends State<_JvAccPicker> {
  final _ctrl = TextEditingController(); final _focus = FocusNode();
  bool _open = false; List<Map<String,dynamic>> _res = [];
  @override void initState() { super.initState(); _ctrl.text = widget.line.accountName;
    _focus.addListener(() { if (!_focus.hasFocus) Future.delayed(const Duration(milliseconds: 180), () { if (mounted) setState(() => _open = false); }); }); }
  @override void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }
  Color _tc(String t) { switch(t) { case 'asset': return Colors.blue; case 'liability': return Colors.red; case 'equity': return Colors.purple; case 'revenue': return Colors.green; case 'expense': return Colors.orange; default: return Colors.grey; } }
  @override Widget build(BuildContext ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    TextField(controller: _ctrl, focusNode: _focus, enabled: widget.enabled,
      decoration: InputDecoration(hintText: 'Search account...', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        border: OutlineInputBorder(borderSide: BorderSide(color: widget.line.accountId != null ? Colors.green : const Color(0xFFE0E0E0))),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: widget.line.accountId != null ? Colors.green : const Color(0xFFE0E0E0))),
        suffixIcon: widget.line.accountId != null ? const Icon(Icons.check_circle, size: 14, color: Colors.green) : null),
      style: const TextStyle(fontSize: 12),
      onChanged: (v) { setState(() { _res = widget.filterFn(v); _open = true; if (v != widget.line.accountName) { widget.line.accountId = null; widget.line.accountName = v; } }); },
      onTap: () => setState(() { _res = widget.filterFn(_ctrl.text); _open = true; })),
    if (_open && _res.isNotEmpty) Container(constraints: const BoxConstraints(maxHeight: 200), margin: const EdgeInsets.only(top: 2),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
      child: ListView(shrinkWrap: true, children: _res.map((a) {
        final tc = _tc(a['account_type'] as String? ?? '');
        return InkWell(onTap: () { widget.onPick(a); _ctrl.text = (a['code'] ?? '') + ' — ' + (a['name'] ?? ''); setState(() => _open = false); _focus.unfocus(); },
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: tc.withOpacity(0.1), borderRadius: BorderRadius.circular(3)),
              child: Text(a['account_type'] as String? ?? '', style: TextStyle(fontSize: 9, color: tc, fontWeight: FontWeight.w700))),
            const SizedBox(width: 6),
            Text(a['code'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Expanded(child: Text(a['name'] as String? ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          ])));
      }).toList())),
  ]);
}
