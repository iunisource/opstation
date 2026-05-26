// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

class ErpPaymentVoucherScreen extends ConsumerStatefulWidget {
  const ErpPaymentVoucherScreen({super.key});
  @override ConsumerState<ErpPaymentVoucherScreen> createState() => _ErpPaymentVoucherScreenState();
}

class _ErpPaymentVoucherScreenState extends ConsumerState<ErpPaymentVoucherScreen> {
  // Voucher list (drawer)
  List<Map<String, dynamic>> _vouchers = [];
  bool _drawerOpen = true;
  bool _loadingList = true;
  String _listSearch = '';
  Map<String, dynamic>? _currentVoucher;

  // Form state
  final _voucherDateCtrl = TextEditingController();
  String? _cashAccountId;
  String _cashAccountName = '';
  String _cashAccountSearch = '';
  bool _showCashDropdown = false;
  String _status = 'draft';

  // Line items
  List<_VoucherLine> _lines = [];

  // Master data
  List<Map<String, dynamic>> _coaAccounts = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _customers = [];
  bool _loadingMaster = true;
  bool _saving = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override void initState() {
    super.initState();
    _voucherDateCtrl.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
    _loadMaster();
    _loadVouchers();
    _addLine();
  }
  @override void dispose() { _voucherDateCtrl.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _loadMaster() async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final results = await Future.wait([
        Supabase.instance.client.from('chart_of_accounts').select('id, code, name, account_type, account_group').eq('org_id', orgId).order('code'),
        Supabase.instance.client.from('suppliers').select('id, name, code').eq('org_id', orgId).order('name'),
        Supabase.instance.client.from('customers').select('id, shop_name, code').eq('org_id', orgId).order('shop_name'),
      ]);
      setState(() {
        _coaAccounts = List<Map<String, dynamic>>.from(results[0] as List);
        _suppliers = List<Map<String, dynamic>>.from(results[1] as List);
        _customers = List<Map<String, dynamic>>.from(results[2] as List);
        _loadingMaster = false;
      });
    } catch (e) { setState(() => _loadingMaster = false); }
  }

  Future<void> _loadVouchers() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      var q = Supabase.instance.client.from('cpv_vouchers').select().eq('org_id', orgId);
      final branchId = _branchId;
      if (branchId != null) q = q.eq('branch_id', branchId);
      final rows = await q.order('created_at', ascending: false).limit(100);
      setState(() { _vouchers = List<Map<String, dynamic>>.from(rows); _loadingList = false; });
    } catch (_) { setState(() => _loadingList = false); }
  }

  void _addLine() => setState(() => _lines.add(_VoucherLine()));

  void _removeLine(int i) { setState(() => _lines.removeAt(i)); if (_lines.isEmpty) _addLine(); }

  double get _total => _lines.fold(0, (s, l) => s + (l.amount ?? 0));

  List<Map<String, dynamic>> get _allAccounts {
    return [
      ..._coaAccounts.map((a) => {'id': a['id'], 'label': '${a['code'] ?? ''} — ${a['name']}', 'sub': a['account_type'] ?? '', 'type': 'coa', 'raw': a}),
      ..._suppliers.map((s) => {'id': s['id'], 'label': '${s['code'] ?? ''} — ${s['name']}', 'sub': 'Supplier', 'type': 'supplier', 'raw': s}),
      ..._customers.map((c) => {'id': c['id'], 'label': '${c['code'] ?? ''} — ${c['shop_name']}', 'sub': 'Customer', 'type': 'customer', 'raw': c}),
    ];
  }

  List<Map<String, dynamic>> get _cashAccounts => _coaAccounts
      .where((a) => ['BANK', 'CASH IN HAND'].contains(a['account_type']))
      .map((a) => {'id': a['id'], 'label': '${a['code'] ?? ''} — ${a['name']}', 'type': a['account_type']})
      .toList();

  List<Map<String, dynamic>> _filterCash(String q) {
    if (q.isEmpty) return _cashAccounts;
    final ql = q.toLowerCase();
    return _cashAccounts.where((a) => (a['label'] as String).toLowerCase().contains(ql)).toList();
  }

  Future<void> _newVoucher() async {
    setState(() {
      _currentVoucher = null; _cashAccountId = null; _cashAccountName = '';
      _voucherDateCtrl.text = DateFormat('yyyy-MM-dd').format(DateTime.now());
      _status = 'draft'; _lines = []; _addLine();
    });
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    final orgId = _orgId; if (orgId == null) return;
    try {
      final lines = await Supabase.instance.client.from('cpv_voucher_lines')
          .select().eq('voucher_id', v['id'] as String).order('line_order');
      setState(() {
        _currentVoucher = v;
        _voucherDateCtrl.text = v['voucher_date'] as String? ?? '';
        _cashAccountId = v['cash_account_id'] as String?;
        _cashAccountName = v['cash_account_name'] as String? ?? '';
        _status = v['status'] as String? ?? 'draft';
        _lines = (lines as List).map((l) {
          final vl = _VoucherLine();
          vl.accountId = l['account_id'] as String?;
          vl.accountName = l['account_name'] as String? ?? '';
          vl.accountType = l['account_type'] as String? ?? 'coa';
          vl.descCtrl.text = l['description'] as String? ?? '';
          vl.amtCtrl.text = (l['amount'] as num?)?.toStringAsFixed(2) ?? '';
          return vl;
        }).toList();
        if (_lines.isEmpty) _addLine();
      });
    } catch (e) { _snack('Failed to load: $e'); }
  }

  Future<void> _save() async {
    if (_cashAccountId == null) { _snack('Select a cash account'); return; }
    if (_lines.every((l) => l.accountId == null)) { _snack('Add at least one line'); return; }
    final orgId = _orgId; final branchId = _branchId ?? ''; final userId = ref.read(currentUserProvider)?.id;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final validLines = _lines.where((l) => l.accountId != null).toList();
      final total = validLines.fold<double>(0, (s, l) => s + (l.amount ?? 0));
      final dateStr = _voucherDateCtrl.text.trim();
      if (_currentVoucher == null) {
        // Generate voucher number
        final count = await client.from('cpv_vouchers').select('id').eq('org_id', orgId!);
        final vNum = 'CPV-${DateTime.now().year}-${((count as List).length + 1).toString().padLeft(4, '0')}';
        final vid = 'cpv_${DateTime.now().millisecondsSinceEpoch}';
        await client.from('cpv_vouchers').insert({
          'id': vid, 'org_id': orgId, 'branch_id': branchId,
          'voucher_number': vNum, 'voucher_date': dateStr,
          'cash_account_id': _cashAccountId, 'cash_account_name': _cashAccountName,
          'status': _status, 'total_amount': total, 'created_by': userId,
        });
        for (var i = 0; i < validLines.length; i++) {
          final l = validLines[i];
          await client.from('cpv_voucher_lines').insert({
            'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_$i',
            'voucher_id': vid, 'account_type': l.accountType,
            'account_id': l.accountId, 'account_name': l.accountName,
            'description': l.descCtrl.text.trim(), 'amount': l.amount ?? 0, 'line_order': i,
          });
        }
        _snack('Voucher $vNum created');
      } else {
        final vid = _currentVoucher!['id'] as String;
        await client.from('cpv_vouchers').update({
          'voucher_date': dateStr, 'cash_account_id': _cashAccountId,
          'cash_account_name': _cashAccountName, 'status': _status, 'total_amount': total,
        }).eq('id', vid);
        await client.from('cpv_voucher_lines').delete().eq('voucher_id', vid);
        for (var i = 0; i < validLines.length; i++) {
          final l = validLines[i];
          await client.from('cpv_voucher_lines').insert({
            'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_$i',
            'voucher_id': vid, 'account_type': l.accountType,
            'account_id': l.accountId, 'account_name': l.accountName,
            'description': l.descCtrl.text.trim(), 'amount': l.amount ?? 0, 'line_order': i,
          });
        }
        _snack('Voucher updated');
      }
      await _loadVouchers();
    } catch (e) { _snack('Failed: $e'); }
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final filteredVouchers = _listSearch.isEmpty ? _vouchers : _vouchers.where((v) {
      final q = _listSearch.toLowerCase();
      return (v['voucher_number'] as String? ?? '').toLowerCase().contains(q) ||
             (v['cash_account_name'] as String? ?? '').toLowerCase().contains(q);
    }).toList();
    final cashFiltered = _filterCash(_cashAccountSearch);

    return Container(color: AppTheme.background, child: Row(children: [
      // ── DRAWER ─────────────────────────────────────────────────────
      AnimatedContainer(duration: const Duration(milliseconds: 200),
        width: _drawerOpen ? 280 : 40,
        decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          InkWell(onTap: () => setState(() => _drawerOpen = !_drawerOpen),
            child: Container(height: 48, padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right, color: AppTheme.textSecondary, size: 20),
                if (_drawerOpen) ...[const SizedBox(width: 6), const Expanded(child: Text('Vouchers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))],
                if (_drawerOpen) ElevatedButton.icon(icon: const Icon(Icons.add, size: 14), label: const Text('New', style: TextStyle(fontSize: 11)), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero), onPressed: _newVoucher),
              ]))),
          if (_drawerOpen) ...[
            Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: TextField(
              decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 15), isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 6, horizontal: 8)),
              onChanged: (v) => setState(() => _listSearch = v),
            )),
            Expanded(child: _loadingList ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : filteredVouchers.isEmpty ? const Center(child: Text('No vouchers', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
              : ListView.builder(itemCount: filteredVouchers.length, itemBuilder: (_, i) {
                  final v = filteredVouchers[i];
                  final isSelected = _currentVoucher?['id'] == v['id'];
                  final isPosted = v['status'] == 'posted';
                  return InkWell(onTap: () => _loadVoucher(v), child: Container(
                    color: isSelected ? AppTheme.primary.withOpacity(0.08) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(v['voucher_number'] as String? ?? 'Draft', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: isSelected ? AppTheme.primary : AppTheme.textPrimary))),
                        Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: (isPosted ? Colors.green : Colors.orange).withOpacity(0.1), borderRadius: BorderRadius.circular(3)), child: Text(isPosted ? 'Posted' : 'Draft', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: isPosted ? Colors.green : Colors.orange))),
                      ]),
                      Text(v['cash_account_name'] as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
                      Text('Rs. ${(v['total_amount'] as num?)?.toStringAsFixed(2) ?? '0.00'}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                    ]),
                  ));
                })),
          ],
        ])),
      // ── MAIN FORM ──────────────────────────────────────────────────
      Expanded(child: Column(children: [
        // Header bar
        Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(20, 12, 20, 12), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const Icon(Icons.receipt_long_outlined, color: AppTheme.primary, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_currentVoucher?['voucher_number'] as String? ?? 'New Voucher', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(_status == 'posted' ? 'Posted' : 'Draft', style: TextStyle(fontSize: 11, color: _status == 'posted' ? Colors.green : Colors.orange, fontWeight: FontWeight.w600)),
            ])),
            // Status toggle
            if (_status == 'draft') OutlinedButton.icon(icon: const Icon(Icons.check_circle_outline, size: 14), label: const Text('Post', style: TextStyle(fontSize: 12)), onPressed: () { setState(() => _status = 'posted'); _save(); }, style: OutlinedButton.styleFrom(foregroundColor: Colors.green, side: const BorderSide(color: Colors.green))),
            if (_status == 'posted') OutlinedButton.icon(icon: const Icon(Icons.undo, size: 14), label: const Text('Unpost', style: TextStyle(fontSize: 12)), onPressed: () => setState(() => _status = 'draft'), style: OutlinedButton.styleFrom(foregroundColor: Colors.orange, side: const BorderSide(color: Colors.orange))),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined, size: 16),
              label: const Text('Save'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
              onPressed: _saving ? null : _save,
            ),
          ])),
        // Voucher header fields
        Container(color: Colors.white, padding: const EdgeInsets.fromLTRB(20, 12, 20, 12), decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            // Voucher Number
            SizedBox(width: 160, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Voucher No.', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(_currentVoucher?['voucher_number'] as String? ?? '(auto)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
            ])),
            const SizedBox(width: 16),
            // Date
            SizedBox(width: 160, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Voucher Date *', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              TextField(controller: _voucherDateCtrl, decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), hintText: 'YYYY-MM-DD')),
            ])),
            const SizedBox(width: 16),
            // Cash Account
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Cash Account Name *', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              GestureDetector(onTap: () => setState(() => _showCashDropdown = !_showCashDropdown),
                child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    Expanded(child: Text(_cashAccountName.isNotEmpty ? _cashAccountName : 'Select Cash Account', style: TextStyle(fontSize: 13, color: _cashAccountName.isEmpty ? Colors.grey : AppTheme.textPrimary))),
                    Icon(_showCashDropdown ? Icons.expand_less : Icons.expand_more, size: 16, color: AppTheme.textSecondary),
                  ]))),
              if (_showCashDropdown) Container(margin: const EdgeInsets.only(top: 2), constraints: const BoxConstraints(maxHeight: 200), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]),
                child: Column(children: [
                  Padding(padding: const EdgeInsets.all(8), child: TextField(
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Search cash accounts...', isDense: true, prefixIcon: Icon(Icons.search, size: 14)),
                    onChanged: (v) => setState(() => _cashAccountSearch = v),
                  )),
                  Expanded(child: ListView(children: cashFiltered.map((a) => ListTile(dense: true,
                    title: Text(a['label'] as String, style: const TextStyle(fontSize: 12)),
                    subtitle: Text(a['type'] as String, style: const TextStyle(fontSize: 10)),
                    onTap: () => setState(() { _cashAccountId = a['id'] as String; _cashAccountName = a['label'] as String; _showCashDropdown = false; _cashAccountSearch = ''; }),
                  )).toList())),
                ])),
            ])),
          ])),
        // Table header
        Container(color: const Color(0xFFF8F9FA), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: const [
            SizedBox(width: 32),
            Expanded(flex: 4, child: Text('Account / Party', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            SizedBox(width: 8),
            Expanded(flex: 3, child: Text('Description', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            SizedBox(width: 8),
            SizedBox(width: 120, child: Text('Amount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary), textAlign: TextAlign.right)),
            SizedBox(width: 36),
          ])),
        const Divider(height: 1),
        // Lines
        Expanded(child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
          itemCount: _lines.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (_, i) => _LineRow(
            key: ValueKey(_lines[i].id),
            line: _lines[i],
            allAccounts: _allAccounts,
            lineNumber: i + 1,
            onRemove: () => _removeLine(i),
            onAddNext: i == _lines.length - 1 ? _addLine : null,
            onChanged: () => setState(() {}),
          ),
        )),
        // Footer
        Container(decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppTheme.border))), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [
            TextButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('Add Line'), onPressed: _addLine),
            const Spacer(),
            Text('Total:', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
            const SizedBox(width: 12),
            Text('Rs. ${_total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          ])),
      ])),
    ]));
  }
}

// ── Line data model ─────────────────────────────────────────────────────────
class _VoucherLine {
  final String id = 'vl_${DateTime.now().microsecondsSinceEpoch}_${(1000 * (DateTime.now().microsecond / 1000000)).round()}';
  String? accountId;
  String accountName = '';
  String accountType = 'coa';
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController amtCtrl = TextEditingController();
  double? get amount => double.tryParse(amtCtrl.text);
  void dispose() { descCtrl.dispose(); amtCtrl.dispose(); }
}

// ── Line Row Widget ─────────────────────────────────────────────────────────
class _LineRow extends StatefulWidget {
  final _VoucherLine line;
  final List<Map<String, dynamic>> allAccounts;
  final int lineNumber;
  final VoidCallback onRemove;
  final VoidCallback? onAddNext;
  final VoidCallback onChanged;
  const _LineRow({super.key, required this.line, required this.allAccounts, required this.lineNumber, required this.onRemove, this.onAddNext, required this.onChanged});
  @override State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  bool _showDrop = false;
  String _accSearch = '';
  late FocusNode _accFocus, _descFocus, _amtFocus;
  late TextEditingController _accCtrl;
  OverlayEntry? _overlay;

  @override void initState() {
    super.initState();
    _accCtrl = TextEditingController(text: widget.line.accountName);
    _accFocus = FocusNode()..addListener(() { if (_accFocus.hasFocus) { setState(() { _showDrop = true; _accSearch = ''; _accCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _accCtrl.text.length); }); } else { Future.delayed(const Duration(milliseconds: 150), () { if (mounted) setState(() => _showDrop = false); }); } });
    _descFocus = FocusNode();
    _amtFocus = FocusNode();
  }
  @override void dispose() { _accFocus.dispose(); _descFocus.dispose(); _amtFocus.dispose(); _accCtrl.dispose(); super.dispose(); }

  List<Map<String, dynamic>> get _filtered {
    final q = _accSearch.toLowerCase();
    if (q.isEmpty) return widget.allAccounts.take(20).toList();
    return widget.allAccounts.where((a) => (a['label'] as String).toLowerCase().contains(q) || (a['sub'] as String).toLowerCase().contains(q)).take(15).toList();
  }

  void _selectAccount(Map<String, dynamic> acc) {
    setState(() {
      widget.line.accountId = acc['id'] as String;
      widget.line.accountName = acc['label'] as String;
      widget.line.accountType = acc['type'] as String;
      _accCtrl.text = acc['label'] as String;
      _showDrop = false;
    });
    widget.onChanged();
    _descFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border.withOpacity(0.6))),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 24, child: Center(child: Text('${widget.lineNumber}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)))),
        const SizedBox(width: 8),
        // Account field with dropdown
        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _accCtrl,
            focusNode: _accFocus,
            decoration: InputDecoration(
              hintText: 'Search account, supplier, customer...',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              suffixIcon: widget.line.accountId != null ? const Icon(Icons.check_circle, color: Colors.green, size: 14) : null,
            ),
            onChanged: (v) => setState(() { _accSearch = v; _showDrop = true; }),
            onSubmitted: (_) {
              final filtered = _filtered;
              if (filtered.isNotEmpty) _selectAccount(filtered.first);
            },
          ),
          if (_showDrop && _filtered.isNotEmpty) Container(
            constraints: const BoxConstraints(maxHeight: 180),
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: AppTheme.border), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8)]),
            child: ListView(shrinkWrap: true, children: _filtered.map((a) {
              final type = a['type'] as String;
              final color = type == 'supplier' ? Colors.blue : type == 'customer' ? Colors.purple : AppTheme.primary;
              return InkWell(
                onTap: () => _selectAccount(a),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [
                  Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1), decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(3)), child: Text(a['sub'] as String, style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 6),
                  Expanded(child: Text(a['label'] as String, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
                ])),
              );
            }).toList()),
          ),
        ])),
        const SizedBox(width: 8),
        // Description
        Expanded(flex: 3, child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (e) { if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter) _amtFocus.requestFocus(); },
          child: TextField(
            controller: widget.line.descCtrl,
            focusNode: _descFocus,
            decoration: const InputDecoration(hintText: 'Description', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
            onChanged: (_) => widget.onChanged(),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _amtFocus.requestFocus(),
          ),
        )),
        const SizedBox(width: 8),
        // Amount
        SizedBox(width: 120, child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter) {
              if (widget.onAddNext != null) { widget.onAddNext!(); }
              else { _accFocus.requestFocus(); }
            }
          },
          child: TextField(
            controller: widget.line.amtCtrl,
            focusNode: _amtFocus,
            textAlign: TextAlign.right,
            decoration: const InputDecoration(hintText: '0.00', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), prefixText: 'Rs. ', prefixStyle: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            onChanged: (_) => widget.onChanged(),
            onSubmitted: (_) { if (widget.onAddNext != null) widget.onAddNext!(); else _accFocus.requestFocus(); },
          ),
        )),
        const SizedBox(width: 8),
        SizedBox(width: 28, child: IconButton(icon: const Icon(Icons.close, size: 14), onPressed: widget.onRemove, color: Colors.red.shade300, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact)),
      ]),
    );
  }
}
