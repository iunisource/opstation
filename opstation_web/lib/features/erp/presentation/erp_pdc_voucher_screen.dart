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
import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';

/// PDC Voucher — post-dated / cheque-in-hand register.
///
/// Header = the holding account the cheques are recorded against (e.g. Cheques
/// in Hand), kept for records only. The Party/Account (customer) is PER LINE.
/// Pending lines are MEMO-ONLY (no GL → no balance/aging impact). Clearing a
/// line spawns a posted CRV (Dr deposit bank / Cr that line's customer 1210),
/// mirroring the Receipt Vouchers posting. Bouncing is status-only.
class ErpPdcVoucherScreen extends ConsumerStatefulWidget {
  const ErpPdcVoucherScreen({super.key});
  @override
  ConsumerState<ErpPdcVoucherScreen> createState() =>
      _ErpPdcVoucherScreenState();
}

class _ErpPdcVoucherScreenState extends ConsumerState<ErpPdcVoucherScreen> {
  final _fmt = const MoneyFmt();

  List<Map<String, dynamic>> _vouchers = [];
  bool _loadingList = true;
  bool _drawerOpen = true;
  String _listSearch = '';

  Map<String, dynamic>? _currentVoucher;
  String? _cashAccountId; // holding account (Cheques in Hand)
  String _cashAccountName = '';
  final _remarksCtrl = TextEditingController();
  DateTime _voucherDate = DateTime.now();
  List<_ChequeLine> _lines = [];
  final Set<String> _deletedLineIds = {};

  List<Map<String, dynamic>> _coaList = [];
  List<Map<String, dynamic>> _customers = []; // {id, label, name}
  bool _loadingMaster = true;
  bool _saving = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;
  bool get _hasClearedLine => _lines.any((l) => l.status == 'cleared');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMaster();
      _loadVouchers();
    });
    _addLine();
  }

  @override
  void dispose() {
    _remarksCtrl.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── Loading ───────────────────────────────────────────────────────────────
  Future<void> _loadMaster() async {
    final orgId = _orgId;
    if (orgId == null) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _loadMaster();
      return;
    }
    try {
      final res = await Supabase.instance.client
          .rpc('get_voucher_master', params: {'p_org_id': orgId});
      final data = res as Map<String, dynamic>;
      final coa = List<Map<String, dynamic>>.from((data['coa'] as List?) ?? []);
      final cus =
          List<Map<String, dynamic>>.from((data['customers'] as List?) ?? []);
      final customers = cus.map((c) {
        final code = c['code'];
        final name = (c['shop_name'] as String?) ?? '';
        return {
          'id': c['id'],
          'name': name,
          'label': '${code != null ? '$code — ' : ''}$name',
        };
      }).toList();
      if (mounted) {
        setState(() {
          _coaList = coa;
          _customers = customers;
          _loadingMaster = false;
        });
      }
    } catch (e) {
      if (mounted) {
        _snack('Load error: $e');
        setState(() => _loadingMaster = false);
      }
    }
  }

  List<Map<String, dynamic>> get _cashAccounts => _coaList
      .where((a) =>
          !_coaList.any((b) => b['parent_id'] == a['id']) &&
          (a['account_group'] == 'Current Assets'))
      .map((a) => {
            'id': a['id'],
            'label':
                '${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}',
          })
      .toList();

  Future<void> _loadVouchers() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loadingList = true);
    try {
      var q = Supabase.instance.client
          .from('pdc_vouchers')
          .select()
          .eq('org_id', orgId);
      final bid = _branchId;
      if (bid != null) q = q.eq('branch_id', bid);
      final rows = await q.order('created_at', ascending: false).limit(200);
      if (mounted) {
        setState(() {
          _vouchers = List<Map<String, dynamic>>.from(rows);
          _loadingList = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _loadVoucher(Map<String, dynamic> v) async {
    try {
      final rows = await Supabase.instance.client
          .from('pdc_voucher_lines')
          .select()
          .eq('voucher_id', v['id'] as String)
          .order('line_order');
      final lines = (rows as List).map((r) {
        final l = _ChequeLine(id: r['id'] as String);
        l.customerId = r['customer_id'] as String?;
        l.customerName = r['customer_name'] as String? ?? '';
        l.bankCtrl.text = r['bank'] as String? ?? '';
        l.descCtrl.text = r['description'] as String? ?? '';
        l.chequeNoCtrl.text = r['cheque_no'] as String? ?? '';
        l.amtCtrl.text = (r['amount'] as num?)?.toStringAsFixed(2) ?? '';
        final cd = r['cheque_date'] as String?;
        l.chequeDate = cd != null ? DateTime.tryParse(cd) : null;
        l.status = r['status'] as String? ?? 'pending';
        l.bankAccountId = r['bank_account_id'] as String?;
        l.bankAccountName = r['bank_account_name'] as String?;
        l.clearedCrvId = r['cleared_crv_id'] as String?;
        return l;
      }).toList();
      if (!mounted) return;
      setState(() {
        for (final l in _lines) {
          l.dispose();
        }
        _currentVoucher = v;
        _cashAccountId = v['cash_account_id'] as String?;
        _cashAccountName = v['cash_account_name'] as String? ?? '';
        _remarksCtrl.text = v['remarks'] as String? ?? '';
        _voucherDate = DateTime.tryParse(v['voucher_date'] as String? ?? '') ??
            DateTime.now();
        _lines = lines.isEmpty ? [_ChequeLine()] : lines;
        _deletedLineIds.clear();
      });
    } catch (e) {
      _snack('Failed to load: $e');
    }
  }

  void _newVoucher() {
    setState(() {
      for (final l in _lines) {
        l.dispose();
      }
      _currentVoucher = null;
      _cashAccountId = null;
      _cashAccountName = '';
      _remarksCtrl.clear();
      _voucherDate = DateTime.now();
      _lines = [_ChequeLine()];
      _deletedLineIds.clear();
    });
  }

  // ── Line management ─────────────────────────────────────────────────────────
  void _addLine() {
    final nl = _ChequeLine();
    setState(() => _lines.add(nl));
  }

  void _removeLine(int i) {
    final l = _lines[i];
    if (l.status != 'pending') return;
    setState(() {
      if (!l.id.startsWith('pdcl_new_')) _deletedLineIds.add(l.id);
      l.dispose();
      _lines.removeAt(i);
    });
    if (_lines.isEmpty) _addLine();
  }

  double get _total =>
      _lines.fold(0.0, (s, l) => s + (double.tryParse(l.amtCtrl.text) ?? 0));

  // ── Party (customer) picker for a line ───────────────────────────────────────
  Future<void> _pickParty(int i) async {
    if (_lines[i].status != 'pending') return;
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dCtx) {
        String q = '';
        return StatefulBuilder(builder: (dCtx, setS) {
          final filtered = q.isEmpty
              ? _customers.take(100).toList()
              : _customers
                  .where((c) => matchesQuery('${c['label'] ?? ''}', q))
                  .take(300)
                  .toList();
          return AlertDialog(
            title: const Text('Select Party / Account'),
            content: SizedBox(
              width: 460,
              height: 460,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: 'Search customer...',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true),
                  onChanged: (v) => setS(() => q = v),
                  onSubmitted: (_) {
                    if (filtered.isNotEmpty) {
                      Navigator.of(dCtx, rootNavigator: true).pop(filtered.first);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('No results',
                              style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, idx) {
                            final c = filtered[idx];
                            return InkWell(
                              onTap: () => Navigator.of(dCtx, rootNavigator: true)
                                  .pop(c),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 10),
                                child: Text(c['label'] as String,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                            );
                          },
                        ),
                ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () =>
                      Navigator.of(dCtx, rootNavigator: true).pop(),
                  child: const Text('Cancel')),
            ],
          );
        });
      },
    );
    if (picked != null) {
      setState(() {
        _lines[i].customerId = picked['id'] as String;
        _lines[i].customerName = picked['name'] as String;
      });
      _lines[i].bankFocus.requestFocus();
    }
  }

  // ── Save (NO GL — memo only) ─────────────────────────────────────────────────
  Future<void> _save() async {
    if (_cashAccountId == null) {
      _snack('Select the cheques-in-hand account first');
      return;
    }
    final valid = _lines
        .where((l) =>
            l.customerId != null && (double.tryParse(l.amtCtrl.text) ?? 0) > 0)
        .toList();
    if (valid.isEmpty) {
      _snack('Add at least one cheque (party + amount)');
      return;
    }
    final orgId = _orgId;
    final bid = _branchId;
    final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final total = valid.fold<double>(
          0, (s, l) => s + (double.tryParse(l.amtCtrl.text) ?? 0));
      final dateStr = DateFormat('yyyy-MM-dd').format(_voucherDate);
      String vid;
      if (_currentVoucher == null) {
        final cnt =
            await client.from('pdc_vouchers').select('id').eq('org_id', orgId);
        final vNum =
            'PDC-${DateTime.now().year}-${((cnt as List).length + 1).toString().padLeft(4, '0')}';
        vid = 'pdc_${DateTime.now().millisecondsSinceEpoch}';
        await client.from('pdc_vouchers').insert({
          'id': vid,
          'org_id': orgId,
          'branch_id': bid,
          'voucher_number': vNum,
          'voucher_date': dateStr,
          'cash_account_id': _cashAccountId,
          'cash_account_name': _cashAccountName,
          'remarks': _remarksCtrl.text.trim(),
          'total_amount': total,
          'status': 'open',
          'created_by': userId,
        });
        _snack('$vNum saved');
      } else {
        vid = _currentVoucher!['id'] as String;
        await client.from('pdc_vouchers').update({
          'voucher_date': dateStr,
          'cash_account_id': _cashAccountId,
          'cash_account_name': _cashAccountName,
          'remarks': _remarksCtrl.text.trim(),
          'total_amount': total,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', vid);
        _snack('Saved');
      }

      for (final delId in _deletedLineIds) {
        await client.from('pdc_voucher_lines').delete().eq('id', delId);
      }
      _deletedLineIds.clear();

      for (var i = 0; i < _lines.length; i++) {
        final l = _lines[i];
        final amt = double.tryParse(l.amtCtrl.text) ?? 0;
        if (l.status == 'pending' && (l.customerId == null || amt <= 0)) {
          continue; // skip incomplete pending rows
        }
        final lineId = l.id.startsWith('pdcl_new_')
            ? 'pdcl_${DateTime.now().microsecondsSinceEpoch}_$i'
            : l.id;
        l.id = lineId;
        await client.from('pdc_voucher_lines').upsert({
          'id': lineId,
          'voucher_id': vid,
          'org_id': orgId,
          'line_order': i,
          'customer_id': l.customerId,
          'customer_name': l.customerName,
          'bank': l.bankCtrl.text.trim(),
          'description': l.descCtrl.text.trim(),
          'cheque_no': l.chequeNoCtrl.text.trim(),
          'cheque_date': l.chequeDate != null
              ? DateFormat('yyyy-MM-dd').format(l.chequeDate!)
              : null,
          'amount': amt,
          'status': l.status,
          'bank_account_id': l.bankAccountId,
          'bank_account_name': l.bankAccountName,
          'cleared_crv_id': l.clearedCrvId,
          'cleared_at': l.clearedAt?.toIso8601String(),
        });
      }

      final created =
          await client.from('pdc_vouchers').select().eq('id', vid).single();
      if (mounted) setState(() => _currentVoucher = created);
      await _loadVouchers();
    } catch (e) {
      _snack('Failed: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  // ── Clear a cheque line → spawn a posted CRV + post GL ───────────────────────
  Future<void> _clearLine(int index) async {
    if (_currentVoucher == null) {
      _snack('Save the voucher first');
      return;
    }
    final line = _lines[index];
    if (line.status != 'pending') return;
    if (line.customerId == null) {
      _snack('This line has no party selected');
      return;
    }
    final amt = double.tryParse(line.amtCtrl.text) ?? 0;
    if (amt <= 0) {
      _snack('Cheque amount must be greater than zero');
      return;
    }

    String? bankId;
    String bankName = '';
    DateTime clearDate = DateTime.now();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setS) => AlertDialog(
          title: const Text('Clear Cheque'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${line.customerName} • Rs. ${_fmt.format(amt)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                const Text('Deposit / Bank account *',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _SearchableList(
                  value: bankName,
                  hint: 'Select bank / cash account',
                  items: _cashAccounts,
                  onSelect: (a) => setS(() {
                    bankId = a['id'] as String;
                    bankName = a['label'] as String;
                  }),
                ),
                const SizedBox(height: 14),
                const Text('Clearance date *',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                InkWell(
                  onTap: () async {
                    final p = await showDatePicker(
                        context: dCtx,
                        initialDate: clearDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100));
                    if (p != null) setS(() => clearDate = p);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFBDBDBD)),
                        borderRadius: BorderRadius.circular(4)),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(DateFormat('dd MMM yyyy').format(clearDate),
                              style: const TextStyle(fontSize: 13)),
                          const Icon(Icons.calendar_today,
                              size: 13, color: AppTheme.textSecondary),
                        ]),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(dCtx, rootNavigator: true).pop(false),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success),
              onPressed: () {
                if (bankId == null) return;
                Navigator.of(dCtx, rootNavigator: true).pop(true);
              },
              child: const Text('Confirm clearance'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || bankId == null) return;

    final orgId = _orgId;
    final bid = _branchId ?? '';
    final userId = ref.read(currentUserProvider)?.id;
    final userName = ref.read(currentUserProvider)?.name ?? '';
    if (orgId == null) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final dateStr = DateFormat('yyyy-MM-dd').format(clearDate);
      final pdcNum = _currentVoucher!['voucher_number'] as String? ?? '';

      // 1) Spawn the posted CRV header + one customer line.
      final yr = DateTime.now().year.toString();
      final ex = await client.from('crv_vouchers').select('voucher_number').eq('org_id', orgId).like('voucher_number', 'CRV-$yr-%');
      int mx = 0;
      for (final r in (ex as List)) { final n = int.tryParse((r['voucher_number'] as String? ?? '').split('-').last) ?? 0; if (n > mx) mx = n; }
      final vNum =
          'CRV-$yr-${(mx + 1).toString().padLeft(4, '0')}';
      final crvId = 'crv_${DateTime.now().millisecondsSinceEpoch}';
      await client.from('crv_vouchers').insert({
        'id': crvId,
        'org_id': orgId,
        'branch_id': bid,
        'voucher_number': vNum,
        'voucher_date': dateStr,
        'cash_account_id': bankId,
        'cash_account_name': bankName,
        'status': 'posted',
        'total_amount': amt,
        'created_by': userId,
        'posted_by': userId,
        'posted_at': DateTime.now().toIso8601String(),
        'posted_by_name': userName,
      });
      await client.from('crv_voucher_lines').insert({
        'id': 'cpvl_${DateTime.now().microsecondsSinceEpoch}_0',
        'voucher_id': crvId,
        'account_type': 'customer',
        'account_id': line.customerId,
        'account_name': line.customerName,
        'description':
            'Cheque clearance — $pdcNum${line.chequeNoCtrl.text.trim().isNotEmpty ? ' / Chq ${line.chequeNoCtrl.text.trim()}' : ''}',
        'amount': amt,
        'line_order': 0,
      });

      // 2) Post GL — mirrors _postCrvToGL in Receipt Vouchers.
      final arId = 'coa_' + orgId + '_1210';
      final eId = 'je_crv_' + crvId;
      await client.from('journal_entries').insert({
        'id': eId,
        'org_id': orgId,
        'branch_id': bid,
        'entry_number': 'CRV-' + vNum,
        'entry_date': dateStr,
        'description': 'Cash Receipt: ' + vNum,
        'reference_type': 'crv',
        'reference_id': crvId,
        'reference_number': vNum,
        'status': 'posted',
        'is_system_generated': true,
        'created_at': DateTime.now().toIso8601String(),
        'posted_at': DateTime.now().toIso8601String(),
      });
      await client.from('journal_lines').insert({
        'id': eId + '_0',
        'entry_id': eId,
        'org_id': orgId,
        'branch_id': bid,
        'account_id': bankId,
        'debit': amt,
        'credit': 0.0,
        'line_order': 0,
      });
      await client.from('journal_lines').insert({
        'id': eId + '_1',
        'entry_id': eId,
        'org_id': orgId,
        'branch_id': bid,
        'account_id': arId,
        'debit': 0.0,
        'credit': amt,
        'line_order': 1,
        'party_id': line.customerId,
      });

      // 3) Mark the cheque line cleared + link the CRV.
      await client.from('pdc_voucher_lines').update({
        'status': 'cleared',
        'bank_account_id': bankId,
        'bank_account_name': bankName,
        'cleared_crv_id': crvId,
        'cleared_at': DateTime.now().toIso8601String(),
      }).eq('id', line.id);

      setState(() {
        line.status = 'cleared';
        line.bankAccountId = bankId;
        line.bankAccountName = bankName;
        line.clearedCrvId = crvId;
        line.clearedAt = DateTime.now();
      });
      final allDone =
          _lines.every((l) => l.status == 'cleared' || l.status == 'bounced');
      await client.from('pdc_vouchers').update({
        'status': allDone ? 'cleared' : 'open',
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', _currentVoucher!['id'] as String);

      _snack('Cheque cleared • $vNum posted ✓');
      await _loadVouchers();
    } catch (e) {
      _snack('Clearance failed: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _bounceLine(int index) async {
    final line = _lines[index];
    if (line.status != 'pending' || _currentVoucher == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark Cheque Bounced?'),
        content: const Text(
            'Marks the cheque bounced. No ledger or aging impact (it was never posted).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Mark Bounced')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .from('pdc_voucher_lines')
          .update({'status': 'bounced'}).eq('id', line.id);
      setState(() => line.status = 'bounced');
      _snack('Cheque marked bounced');
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  Future<void> _delete() async {
    if (_currentVoucher == null) return;
    if (_hasClearedLine) {
      _snack('Cannot delete: this voucher has cleared cheques.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Voucher?'),
        content: const Text('This removes the voucher and its pending cheques.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .from('pdc_vouchers')
          .delete()
          .eq('id', _currentVoucher!['id'] as String);
      _snack('Deleted');
      _newVoucher();
      await _loadVouchers();
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  // ── Print ─────────────────────────────────────────────────────────────────
  void _print() {
    if (_currentVoucher == null) {
      _snack('Save the voucher first');
      return;
    }
    final v = _currentVoucher!;
    final rows = _lines
        .where((l) =>
            l.customerId != null && (double.tryParse(l.amtCtrl.text) ?? 0) > 0)
        .toList();
    final body = rows.asMap().entries.map((e) {
      final l = e.value;
      final cd = l.chequeDate != null
          ? DateFormat('dd MMM yyyy').format(l.chequeDate!)
          : '-';
      final amt = double.tryParse(l.amtCtrl.text) ?? 0;
      return '<tr><td>${e.key + 1}</td><td>${l.customerName}</td><td>${l.bankCtrl.text}</td>'
          '<td>${l.descCtrl.text}</td><td>${l.chequeNoCtrl.text}</td><td>$cd</td>'
          '<td style="text-transform:capitalize">${l.status}</td>'
          '<td style="text-align:right">${_fmt.format(amt)}</td></tr>';
    }).join();
    final html_str =
        '''<!DOCTYPE html><html><head><meta charset="UTF-8"><title>PDC Voucher</title><style>
      body{font-family:Arial,sans-serif;padding:20px;color:#333}h2{text-align:center;color:#1a56db}
      table{width:100%;border-collapse:collapse;margin-top:16px}th,td{border:1px solid #ddd;padding:7px;text-align:left;font-size:11px}
      th{background:#f0f4ff;font-weight:600}.total{font-weight:700;font-size:1.1em}.footer{margin-top:40px;display:flex;justify-content:space-between}
      @media print{.no-print{display:none}@page{margin:0}body{padding:15mm 20mm}}
    </style></head><body>
    <div class="no-print" style="margin-bottom:16px"><button onclick="window.print()">&#x1F5A8; Print</button></div>
    <h2>PDC Voucher (Cheques in Hand)</h2>
    <table style="border:none;margin-bottom:5px;width:100%"><tr>
      <td style="border:none;padding:1px 10px 1px 0;font-size:10px;white-space:nowrap"><b>Voucher#:</b> ${v['voucher_number'] ?? ''}</td>
      <td style="border:none;padding:1px 10px;font-size:10px;white-space:nowrap"><b>Date:</b> ${v['voucher_date'] ?? ''}</td>
      <td style="border:none;padding:1px 10px;font-size:10px"><b>Account:</b> $_cashAccountName</td>
      <td style="border:none;padding:1px 0;font-size:10px;white-space:nowrap"><b>Status:</b> ${(v['status'] as String? ?? 'open').toUpperCase()}</td>
    </tr></table>
    ${_remarksCtrl.text.trim().isNotEmpty ? '<div style="font-size:11px;margin-bottom:6px"><b>Remarks:</b> ${_remarksCtrl.text.trim()}</div>' : ''}
    <table><thead><tr><th>#</th><th>Party/Account</th><th>Bank</th><th>Description</th><th>Cheque No.</th><th>Cheque Date</th><th>Status</th><th style="text-align:right">Amount (Rs.)</th></tr></thead><tbody>
    $body
    </tbody><tfoot><tr><td colspan="7" class="total" style="text-align:right">Total:</td><td class="total" style="text-align:right">Rs. ${_fmt.format(_total)}</td></tr></tfoot></table>
    <div class="footer"><div>Received by: _______________</div><div>Approved by: _______________</div></div>
    </body></html>''';
    final blob = html.Blob([html_str], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  Color _statusColor(String s) => s == 'cleared'
      ? Colors.green
      : s == 'bounced'
          ? AppTheme.danger
          : Colors.orange;

  @override
  Widget build(BuildContext context) {
    final filtered = _listSearch.isEmpty
        ? _vouchers
        : _vouchers.where((v) {
            return matchesQuery('${v['voucher_number'] ?? ''} ${v['cash_account_name'] ?? ''}', _listSearch);
          }).toList();

    return Container(
      color: AppTheme.background,
      child: Row(children: [
        // Drawer / list
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: _drawerOpen ? 250 : 36,
          decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(right: BorderSide(color: AppTheme.border))),
          child: Column(children: [
            InkWell(
              onTap: () => setState(() => _drawerOpen = !_drawerOpen),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  Icon(_drawerOpen ? Icons.chevron_left : Icons.chevron_right,
                      size: 18, color: AppTheme.textSecondary),
                  if (_drawerOpen) ...[
                    const SizedBox(width: 6),
                    const Expanded(
                        child: Text('PDC Vouchers',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700))),
                    ElevatedButton.icon(
                        icon: const Icon(Icons.add, size: 13),
                        label: const Text('New', style: TextStyle(fontSize: 11)),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            minimumSize: Size.zero),
                        onPressed: _newVoucher),
                  ],
                ]),
              ),
            ),
            if (_drawerOpen) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: TextField(
                    decoration: const InputDecoration(
                        hintText: 'Search...',
                        prefixIcon: Icon(Icons.search, size: 14),
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 5, horizontal: 8)),
                    onChanged: (v) => setState(() => _listSearch = v)),
              ),
              Expanded(
                child: _loadingList
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : filtered.isEmpty
                        ? const Center(
                            child: Text('No vouchers',
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.textSecondary)))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final v = filtered[i];
                              final sel = _currentVoucher?['id'] == v['id'];
                              final st = v['status'] as String? ?? 'open';
                              return InkWell(
                                onTap: () => _loadVoucher(v),
                                child: Container(
                                  color: sel
                                      ? AppTheme.primary.withOpacity(0.07)
                                      : null,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          Expanded(
                                              child: Text(
                                                  v['voucher_number']
                                                          as String? ??
                                                      'Draft',
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w700,
                                                      color: sel
                                                          ? AppTheme.primary
                                                          : AppTheme
                                                              .textPrimary))),
                                          Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                  color: _statusColor(st)
                                                      .withOpacity(0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(3)),
                                              child: Text(st,
                                                  style: TextStyle(
                                                      fontSize: 9,
                                                      color: _statusColor(st),
                                                      fontWeight:
                                                          FontWeight.w700))),
                                        ]),
                                        Text(
                                            v['cash_account_name'] as String? ??
                                                '',
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.textSecondary),
                                            overflow: TextOverflow.ellipsis),
                                        Text(
                                            'Rs. ${_fmt.format((v['total_amount'] as num?)?.toDouble() ?? 0)}',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: sel
                                                    ? AppTheme.primary
                                                    : AppTheme.textPrimary)),
                                      ]),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ]),
        ),
        // Detail
        Expanded(
          child: Column(children: [
            // Top bar
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: Row(children: [
                const Icon(Icons.request_quote_outlined, color: AppTheme.primary),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                        _currentVoucher?['voucher_number'] as String? ??
                            'New PDC Voucher',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700))),
                if (_currentVoucher != null)
                  IconButton(
                      icon: const Icon(Icons.print_outlined, size: 20),
                      onPressed: _print,
                      tooltip: 'Print'),
                if (_currentVoucher != null && !_hasClearedLine)
                  IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: Colors.red),
                      onPressed: _delete,
                      tooltip: 'Delete'),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10)),
                  onPressed: _saving ? null : _save,
                ),
              ]),
            ),
            // Header fields
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppTheme.border))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                    width: 150,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Voucher Date *',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          InkWell(
                            onTap: () async {
                              final p = await showDatePicker(
                                  context: context,
                                  initialDate: _voucherDate,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100));
                              if (p != null) setState(() => _voucherDate = p);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: const Color(0xFFBDBDBD)),
                                  borderRadius: BorderRadius.circular(4)),
                              child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                        DateFormat('dd MMM yyyy')
                                            .format(_voucherDate),
                                        style: const TextStyle(fontSize: 13)),
                                    const Icon(Icons.calendar_today,
                                        size: 13,
                                        color: AppTheme.textSecondary),
                                  ]),
                            ),
                          ),
                        ])),
                const SizedBox(width: 12),
                Expanded(
                    flex: 2,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Cheques-in-Hand Account *',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          _SearchableList(
                            value: _cashAccountName,
                            hint: 'Select holding account (e.g. Cheques in Hand)',
                            items: _cashAccounts,
                            onSelect: (a) => setState(() {
                              _cashAccountId = a['id'] as String;
                              _cashAccountName = a['label'] as String;
                            }),
                          ),
                        ])),
                const SizedBox(width: 12),
                Expanded(
                    flex: 2,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Remarks',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          TextField(
                              controller: _remarksCtrl,
                              decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 9),
                                  border: OutlineInputBorder()),
                              style: const TextStyle(fontSize: 13)),
                        ])),
              ]),
            ),
            // Table header
            Container(
              color: const Color(0xFFF8F9FA),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(children: const [
                SizedBox(width: 24),
                Expanded(
                    flex: 3,
                    child: Text('Party/Account',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                SizedBox(width: 6),
                SizedBox(
                    width: 110,
                    child: Text('Bank',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                SizedBox(width: 6),
                Expanded(
                    flex: 3,
                    child: Text('Description',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                SizedBox(width: 6),
                SizedBox(
                    width: 100,
                    child: Text('Cheque No.',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                SizedBox(width: 6),
                SizedBox(
                    width: 120,
                    child: Text('Cheque Date',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary))),
                SizedBox(width: 6),
                SizedBox(
                    width: 100,
                    child: Text('Amount',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary),
                        textAlign: TextAlign.right)),
                SizedBox(width: 6),
                SizedBox(width: 140, child: Text('')),
              ]),
            ),
            const Divider(height: 1),
            // Lines
            Expanded(
              child: _loadingMaster
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 12),
                      Text('Loading...',
                          style: TextStyle(color: AppTheme.textSecondary))
                    ]))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (_, i) => _ChequeLineRow(
                        key: ValueKey('pdcline_${_lines[i].id}'),
                        line: _lines[i],
                        lineNum: i + 1,
                        fmt: _fmt,
                        onPickParty: () => _pickParty(i),
                        onPickDate: () async {
                          final p = await showDatePicker(
                              context: context,
                              initialDate:
                                  _lines[i].chequeDate ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100));
                          if (p != null) {
                            setState(() => _lines[i].chequeDate = p);
                            _lines[i].amtFocus.requestFocus();
                          }
                        },
                        onAmountSubmitted: () {
                          if (i == _lines.length - 1) {
                            _addLine();
                          }
                        },
                        onRemove: () => _removeLine(i),
                        onClear: () => _clearLine(i),
                        onBounce: () => _bounceLine(i),
                        onChanged: () => setState(() {}),
                      ),
                    ),
            ),
            // Footer
            Container(
              decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: AppTheme.border))),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                TextButton.icon(
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('Add Cheque'),
                    onPressed: _addLine),
                const Spacer(),
                Text(
                    '${_lines.where((l) => l.customerId != null && (double.tryParse(l.amtCtrl.text) ?? 0) > 0).length} cheques',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
                const SizedBox(width: 16),
                const Text('Total:',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Text('Rs. ${_fmt.format(_total)}',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primary)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ── Cheque line model ─────────────────────────────────────────────────────────
class _ChequeLine {
  String id;
  String? customerId;
  String customerName = '';
  final TextEditingController bankCtrl = TextEditingController();
  final TextEditingController descCtrl = TextEditingController();
  final TextEditingController chequeNoCtrl = TextEditingController();
  final TextEditingController amtCtrl = TextEditingController();
  final FocusNode bankFocus = FocusNode();
  final FocusNode descFocus = FocusNode();
  final FocusNode chequeNoFocus = FocusNode();
  final FocusNode amtFocus = FocusNode();
  DateTime? chequeDate;
  String status;
  String? bankAccountId;
  String? bankAccountName;
  String? clearedCrvId;
  DateTime? clearedAt;

  _ChequeLine({String? id, this.status = 'pending'})
      : id = id ?? 'pdcl_new_${DateTime.now().microsecondsSinceEpoch}';

  void dispose() {
    bankCtrl.dispose();
    descCtrl.dispose();
    chequeNoCtrl.dispose();
    amtCtrl.dispose();
    bankFocus.dispose();
    descFocus.dispose();
    chequeNoFocus.dispose();
    amtFocus.dispose();
  }
}

// ── Cheque line row ───────────────────────────────────────────────────────────
class _ChequeLineRow extends StatelessWidget {
  final _ChequeLine line;
  final int lineNum;
  final MoneyFmt fmt;
  final VoidCallback onPickParty;
  final VoidCallback onPickDate;
  final VoidCallback onAmountSubmitted;
  final VoidCallback onRemove;
  final VoidCallback onClear;
  final VoidCallback onBounce;
  final VoidCallback onChanged;
  const _ChequeLineRow({
    super.key,
    required this.line,
    required this.lineNum,
    required this.fmt,
    required this.onPickParty,
    required this.onPickDate,
    required this.onAmountSubmitted,
    required this.onRemove,
    required this.onClear,
    required this.onBounce,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final locked = line.status != 'pending';
    final dateStr = line.chequeDate != null
        ? DateFormat('dd MMM yyyy').format(line.chequeDate!)
        : 'Pick date';
    final stColor = line.status == 'cleared'
        ? Colors.green
        : line.status == 'bounced'
            ? AppTheme.danger
            : Colors.orange;
    const fieldDeco = InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        border: OutlineInputBorder());

    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(
          width: 24,
          child: Text('$lineNum',
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      // Party/Account
      Expanded(
        flex: 3,
        child: InkWell(
          onTap: locked ? null : onPickParty,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFBDBDBD)),
                borderRadius: BorderRadius.circular(4)),
            child: Row(children: [
              Expanded(
                  child: Text(
                      line.customerName.isNotEmpty
                          ? line.customerName
                          : 'Select Party/Account',
                      style: TextStyle(
                          fontSize: 12.5,
                          color: line.customerName.isEmpty
                              ? Colors.grey
                              : AppTheme.textPrimary),
                      overflow: TextOverflow.ellipsis)),
              if (!locked)
                const Icon(Icons.arrow_drop_down,
                    size: 18, color: AppTheme.textSecondary),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 110,
        child: TextField(
          controller: line.bankCtrl,
          focusNode: line.bankFocus,
          enabled: !locked,
          textInputAction: TextInputAction.next,
          decoration: fieldDeco.copyWith(hintText: 'Bank'),
          style: const TextStyle(fontSize: 12.5),
          onSubmitted: (_) => line.descFocus.requestFocus(),
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        flex: 3,
        child: TextField(
          controller: line.descCtrl,
          focusNode: line.descFocus,
          enabled: !locked,
          textInputAction: TextInputAction.next,
          decoration: fieldDeco.copyWith(hintText: 'Description'),
          style: const TextStyle(fontSize: 12.5),
          onSubmitted: (_) => line.chequeNoFocus.requestFocus(),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 100,
        child: TextField(
          controller: line.chequeNoCtrl,
          focusNode: line.chequeNoFocus,
          enabled: !locked,
          decoration: fieldDeco.copyWith(hintText: 'Chq #'),
          style: const TextStyle(fontSize: 12.5),
          onSubmitted: (_) => onPickDate(),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 120,
        child: InkWell(
          onTap: locked ? null : onPickDate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFBDBDBD)),
                borderRadius: BorderRadius.circular(4)),
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                      child: Text(dateStr,
                          style: TextStyle(
                              fontSize: 12,
                              color: line.chequeDate == null
                                  ? Colors.grey
                                  : AppTheme.textPrimary),
                          overflow: TextOverflow.ellipsis)),
                  const Icon(Icons.calendar_today,
                      size: 12, color: AppTheme.textSecondary),
                ]),
          ),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 100,
        child: TextField(
          controller: line.amtCtrl,
          focusNode: line.amtFocus,
          enabled: !locked,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
          ],
          decoration: fieldDeco.copyWith(hintText: '0.00'),
          style: const TextStyle(fontSize: 12.5),
          onChanged: (_) => onChanged(),
          onSubmitted: (_) => onAmountSubmitted(),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 140,
        child: locked
            ? Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: stColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(
                      line.status == 'cleared' ? 'Cleared ✓' : 'Bounced',
                      style: TextStyle(
                          fontSize: 11,
                          color: stColor,
                          fontWeight: FontWeight.w700)),
                ),
              )
            : Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(
                    onPressed: onClear,
                    style: TextButton.styleFrom(
                        foregroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero),
                    child: const Text('Clear', style: TextStyle(fontSize: 12))),
                TextButton(
                    onPressed: onBounce,
                    style: TextButton.styleFrom(
                        foregroundColor: AppTheme.danger,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: Size.zero),
                    child:
                        const Text('Bounce', style: TextStyle(fontSize: 12))),
                IconButton(
                    icon: const Icon(Icons.close, size: 15),
                    color: AppTheme.textSecondary,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: onRemove),
              ]),
      ),
    ]);
  }
}

// ── Searchable list (holding-account + deposit-account picker) ────────────────
class _SearchableList extends StatefulWidget {
  final String value, hint;
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>> onSelect;
  const _SearchableList(
      {required this.value,
      required this.hint,
      required this.items,
      required this.onSelect});
  @override
  State<_SearchableList> createState() => _SearchableListState();
}

class _SearchableListState extends State<_SearchableList> {
  bool _open = false;
  String _q = '';

  List<Map<String, dynamic>> get _filtered => _q.isEmpty
      ? widget.items
      : widget.items
          .where((a) => matchesQuery('${a['label'] ?? ''}', _q))
          .toList();

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
              border: Border.all(
                  color: _open ? AppTheme.primary : AppTheme.border),
              borderRadius: BorderRadius.circular(6)),
          child: Row(children: [
            Expanded(
                child: Text(
                    widget.value.isNotEmpty ? widget.value : widget.hint,
                    style: TextStyle(
                        fontSize: 13,
                        color: widget.value.isEmpty
                            ? Colors.grey
                            : AppTheme.textPrimary),
                    overflow: TextOverflow.ellipsis)),
            Icon(_open ? Icons.expand_less : Icons.expand_more,
                size: 16, color: AppTheme.textSecondary),
          ]),
        ),
      ),
      if (_open)
        Container(
          margin: const EdgeInsets.only(top: 2),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(6)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Search...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 14),
                    contentPadding:
                        EdgeInsets.symmetric(vertical: 6, horizontal: 8)),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            Flexible(
              child: _filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No results',
                          style: TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary)))
                  : ListView(
                      shrinkWrap: true,
                      children: _filtered
                          .map((a) => InkWell(
                                onTap: () {
                                  widget.onSelect(a);
                                  setState(() {
                                    _open = false;
                                    _q = '';
                                  });
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  child: Text(a['label'] as String,
                                      style: const TextStyle(fontSize: 12.5),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ))
                          .toList()),
            ),
          ]),
        ),
    ]);
  }
}
