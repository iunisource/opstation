import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:opstation_web/core/utils/unique_id.dart';
import '../../../core/format/money.dart';
import '../../../core/layout/main_layout.dart' show selectedBranchProvider;
import '../../../core/permissions/access_control.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/account_picker.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../auth/auth_controller.dart';
import 'duplicate_ref_guard.dart';
import 'opening_date_guard.dart';

/// Quick "Record payment" for one customer: a Receipt Voucher (CRV) in a small
/// dialog, customer already chosen, posted in one step. It writes exactly what
/// the Receipt Vouchers screen writes (same tables, same numbering, same
/// post_crv posting), so the result is an ordinary receipt voucher.
///
/// Returns the posted voucher number, or null when cancelled or not allowed.
Future<String?> showCustomerReceiptDialog(
  BuildContext context,
  WidgetRef ref, {
  required Map<String, dynamic> customer,
  double outstanding = 0,
}) async {
  // Recording a receipt needs "add" permission on Receipt Vouchers here.
  AccessControl? ac;
  try { ac = await ref.read(accessProvider.future); } catch (_) {}
  final bid = ref.read(selectedBranchProvider)?['id'] as String?;
  if (!context.mounted) return null;
  if (ac == null || !ac.canAddDocAt('crv', bid)) {
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('No access'),
        content: const Text(
            'You do not have access to Receipt Vouchers, so you cannot record a payment here. Please ask an administrator to give you access.'),
        actions: [ElevatedButton(onPressed: () => Navigator.of(dctx).pop(), child: const Text('OK'))],
      ),
    );
    return null;
  }
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CustomerReceiptDialog(customer: customer, outstanding: outstanding),
  );
}

class _CustomerReceiptDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> customer;
  final double outstanding;
  const _CustomerReceiptDialog({required this.customer, required this.outstanding});
  @override
  ConsumerState<_CustomerReceiptDialog> createState() => _CustomerReceiptDialogState();
}

class _CustomerReceiptDialogState extends ConsumerState<_CustomerReceiptDialog> {
  final _amtCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  List<Map<String, dynamic>> _cash = [];
  String? _cashId;
  DateTime _date = DateTime.now();
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _msg; // inline message (validation / save errors)

  String get _custLabel {
    final c = widget.customer;
    final code = c['code'];
    return '${code != null ? '$code — ' : ''}${c['shop_name'] ?? ''}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amtCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    if (orgId == null) {
      setState(() { _loading = false; _loadError = 'No organization'; });
      return;
    }
    try {
      final client = Supabase.instance.client;
      final rows = List<Map<String, dynamic>>.from(
          await client.from('chart_of_accounts').select().eq('org_id', orgId).order('code') as List);
      // Same rule as the Receipt Vouchers screen: leaf accounts in Current Assets.
      final parentIds = <String>{
        for (final a in rows) if (a['parent_id'] != null) a['parent_id'].toString()
      };
      final cash = rows
          .where((a) => a['is_active'] != false && !parentIds.contains(a['id'].toString()) && a['account_group'] == 'Current Assets')
          .toList();
      // Start from the account this user used for their last receipt.
      String? last;
      try {
        final r = await client.from('crv_vouchers').select('cash_account_id')
            .eq('org_id', orgId).eq('created_by', user?.id ?? '')
            .order('created_at', ascending: false).limit(1);
        if ((r as List).isNotEmpty) last = r.first['cash_account_id'] as String?;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _cash = cash;
        _cashId = (last != null && cash.any((a) => a['id'] == last)) ? last : null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _loadError = friendlyError('Could not load', e); });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
        context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _post() async {
    if (_saving) return;
    if (_cashId == null) { setState(() => _msg = 'Select the cash / bank account first.'); return; }
    final amt = double.tryParse(_amtCtrl.text.trim()) ?? 0;
    if (amt <= 0) { setState(() => _msg = 'Enter the amount received.'); return; }
    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    if (orgId == null) return;
    final bid = ref.read(selectedBranchProvider)?['id'] as String? ?? '';
    final userId = user?.id;
    final userName = user?.name ?? '';
    setState(() => _msg = null);

    // Same safety checks as the Receipt Vouchers screen.
    if (!await confirmPreOpeningDate(context, orgId: orgId, date: _date, doc: 'receipt')) return;
    if (!mounted) return;
    final note = _noteCtrl.text.trim();
    final dupNote = await checkDuplicateRefs(context,
        orgId: orgId, narrations: [note], amounts: [amt], voucherType: 'CRV', date: _date, branchId: bid);
    if (dupNote == null || !mounted) return;

    setState(() => _saving = true);
    SavingOverlay.show(context, label: 'Posting…');
    String? vid;
    String? vNum;
    try {
      final client = Supabase.instance.client;
      final cashRow = _cash.firstWhere((a) => a['id'] == _cashId);
      final cashName = '${cashRow['code'] != null ? '${cashRow['code']} — ' : ''}${cashRow['name']}';
      final dateStr = DateFormat('yyyy-MM-dd').format(_date);
      final nowIso = DateTime.now().toUtc().toIso8601String();

      final yr = DateTime.now().year.toString();
      final ex = await client.from('crv_vouchers').select('voucher_number').eq('org_id', orgId).like('voucher_number', 'CRV-$yr-%');
      int mx = 0;
      for (final r in (ex as List)) {
        final n = int.tryParse((r['voucher_number'] as String? ?? '').split('-').last) ?? 0;
        if (n > mx) mx = n;
      }
      vNum = 'CRV-$yr-${(mx + 1).toString().padLeft(4, '0')}';
      vid = 'crv_${DateTime.now().millisecondsSinceEpoch}';

      await client.from('crv_vouchers').insert({
        'id': vid, 'org_id': orgId, 'branch_id': bid, 'voucher_number': vNum, 'voucher_date': dateStr,
        'cash_account_id': _cashId, 'cash_account_name': cashName, 'status': 'posted', 'total_amount': amt,
        'created_by': userId, 'posted_by': userId, 'posted_at': nowIso, 'posted_by_name': userName,
      });
      await client.from('crv_voucher_lines').insert({
        'id': uniqueId('crvl'), 'voucher_id': vid, 'account_type': 'customer',
        'account_id': widget.customer['id'], 'account_name': _custLabel,
        'description': note, 'amount': amt, 'line_order': 0,
      });
      try {
        await client.from('crv_audit_trail').insert({
          'id': uniqueId('aud'), 'voucher_id': vid, 'action': 'created',
          'performed_by': userId, 'performed_by_name': userName, 'performed_at': nowIso,
          'notes': 'Total: Rs. ${amt.toStringAsFixed(2)}  •  1 line  •  $cashName  •  recorded from Customer 360',
        });
        if (dupNote.isNotEmpty) {
          await client.from('crv_audit_trail').insert({
            'id': uniqueId('aud'), 'voucher_id': vid, 'action': 'duplicate_reference',
            'performed_by': userId, 'performed_by_name': userName, 'performed_at': nowIso, 'notes': dupNote,
          });
        }
      } catch (_) {/* history note is best-effort */}
      if (dupNote.isNotEmpty) { linkDuplicateRefEvent(vid, vNum); }

      // Post the GL through the same atomic, balance-guarded server function.
      // If it raises, put the voucher back to draft so it never shows "posted"
      // without having reached the ledger.
      try {
        await client.rpc('post_crv', params: {'p_voucher_id': vid});
      } catch (glErr) {
        await client.from('crv_vouchers').update({
          'status': 'draft', 'posted_by': null, 'posted_at': null, 'posted_by_name': null,
        }).eq('id', vid);
        rethrow;
      }
      SavingOverlay.hide();
      if (mounted) Navigator.of(context).pop(vNum);
      return;
    } catch (e) {
      final saved = vid != null
          ? 'The receipt $vNum was saved as a draft but could NOT be posted: ${friendlyError('Posting failed', e)}'
          : friendlyError('That did not save', e);
      if (mounted) setState(() => _msg = saved);
    }
    SavingOverlay.hide();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.customer;
    return AlertDialog(
      title: const Text('Record payment'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : _loadError != null
                ? Text(_loadError!, style: const TextStyle(color: AppTheme.danger))
                : SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${c['shop_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          if (c['code'] != null) Text('${c['code']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                          if (widget.outstanding > 0) ...[
                            const SizedBox(height: 6),
                            Text('Outstanding: Rs. ${money(widget.outstanding)}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.danger)),
                          ],
                        ]),
                      ),
                      const SizedBox(height: 14),
                      InkWell(
                        onTap: _saving ? null : _pickDate,
                        child: InputDecorator(
                          decoration: const InputDecoration(labelText: 'Date', isDense: true, border: OutlineInputBorder(), suffixIcon: Icon(Icons.calendar_today, size: 16)),
                          child: Text(DateFormat('dd MMM yyyy').format(_date)),
                        ),
                      ),
                      const SizedBox(height: 12),
                      AccountPickerField(
                        accounts: _cash,
                        selectedId: _cashId,
                        label: 'Received in (cash / bank account)',
                        title: 'Select cash / bank account',
                        fontSize: 14,
                        enabled: !_saving,
                        onPicked: (a) => setState(() => _cashId = a['id'] as String?),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _amtCtrl,
                        autofocus: true,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                        decoration: InputDecoration(
                          labelText: 'Amount received',
                          prefixText: 'Rs. ',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          suffixIcon: widget.outstanding > 0
                              ? TextButton(
                                  onPressed: _saving ? null : () => setState(() => _amtCtrl.text = widget.outstanding.toStringAsFixed(2)),
                                  child: const Text('Full amount'))
                              : null,
                        ),
                        onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _noteCtrl,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                            labelText: 'Narration / receipt no. (optional)', isDense: true, border: OutlineInputBorder()),
                        onSubmitted: (_) => _post(),
                      ),
                      if (_msg != null) ...[
                        const SizedBox(height: 10),
                        Text(_msg!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
                      ],
                    ]),
                  ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton.icon(
          onPressed: (_loading || _saving || _loadError != null) ? null : _post,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('Post receipt'),
        ),
      ],
    );
  }
}
