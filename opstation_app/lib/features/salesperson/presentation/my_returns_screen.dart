import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/storage/photo_url.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import 'field_order_edit_screen.dart' show fieldOrderErrorText;
import 'field_return_form_screen.dart';

/// Return requests this salesperson sent, with where each one is now:
/// Submitted → Approved (waiting for goods) → Goods received → Credited.
class MyReturnsScreen extends ConsumerStatefulWidget {
  const MyReturnsScreen({super.key});
  @override
  ConsumerState<MyReturnsScreen> createState() => _MyReturnsScreenState();
}

class _MyReturnsScreenState extends ConsumerState<MyReturnsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  RealtimeChannel? _channel;
  late DateTime _from;
  late DateTime _to;
  final _df = DateFormat('d MMM yyyy');

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month - 1, now.day);
    _to = DateTime(now.year, now.month, now.day);
    _load();
    _subscribe();
  }

  void _subscribe() {
    final userId = ref.read(authControllerProvider).valueOrNull?.id;
    if (userId == null) return;
    _channel = Supabase.instance.client
        .channel('field_returns_mine_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'field_returns',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'salesperson_id',
            value: userId,
          ),
          callback: (_) {
            if (mounted) _load();
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  String _ymd(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  Future<void> _load() async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('my_field_returns',
          params: {'p_org': orgId, 'p_from': _ymd(_from), 'p_to': _ymd(_to)});
      if (!mounted) return;
      setState(() {
        _rows = [
          if (res is List)
            for (final r in res) Map<String, dynamic>.from(r as Map)
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString().toLowerCase();
      setState(() {
        _loading = false;
        _error = (s.contains('socket') ||
                s.contains('network') ||
                s.contains('connection'))
            ? 'No connection — pull down to try again when online.'
            : (s.contains('could not find the function')
                ? 'Returns are not switched on yet. Please ask the office.'
                : 'Could not load your returns.');
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
    _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _newReturn() async {
    final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const FieldReturnFormScreen()));
    if (ok == true) {
      _snack('Return request sent to the office.');
      _load();
    }
  }

  // ── Stage ──────────────────────────────────────────────────────────────
  static String stageOf(Map<String, dynamic> r) {
    final st = (r['status'] ?? 'submitted').toString();
    if (st != 'approved') return st;
    final credits = r['credit_numbers'];
    if (credits is List && credits.isNotEmpty) return 'credited';
    if (r['srn_voided'] == true) return 'cancelled_by_office';
    final srn = (r['srn_status'] ?? 'draft').toString();
    if (srn != 'draft' && srn != 'cancelled') return 'received';
    return 'approved';
  }

  Widget _chip(String stage) {
    Color bg, fg;
    String label;
    switch (stage) {
      case 'approved':
        bg = Colors.teal.shade50;
        fg = Colors.teal.shade700;
        label = 'Approved';
        break;
      case 'received':
        bg = AppColors.primaryLight;
        fg = AppColors.primaryDark;
        label = 'Goods received';
        break;
      case 'credited':
        bg = AppColors.successLight;
        fg = AppColors.successDark;
        label = 'Credited';
        break;
      case 'rejected':
        bg = Colors.red.shade50;
        fg = Colors.red.shade700;
        label = 'Rejected';
        break;
      case 'cancelled':
      case 'cancelled_by_office':
        bg = AppColors.borderLight;
        fg = AppColors.textSecondaryLight;
        label = 'Cancelled';
        break;
      default:
        bg = AppColors.warningLight;
        fg = AppColors.warningDark;
        label = 'Submitted';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  String _stageHint(String stage) {
    switch (stage) {
      case 'approved':
        return 'Approved — waiting for the goods to come back';
      case 'received':
        return 'Goods are back at the warehouse';
      case 'credited':
        return 'The shop has been credited';
      case 'cancelled_by_office':
        return 'The office cancelled the return note';
      default:
        return '';
    }
  }

  String _refs(Map<String, dynamic> r) {
    final credits = r['credit_numbers'];
    return [
      if ((r['srn_number'] ?? '').toString().isNotEmpty) r['srn_number'],
      if (credits is List) ...credits,
    ].join(' · ');
  }

  String _qty(num? v) {
    final d = (v ?? 0).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  DateTime? _date(Map<String, dynamic> r) =>
      DateTime.tryParse((r['created_at'] ?? '').toString())?.toLocal();

  // ── Build ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('My Returns'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimaryLight,
        elevation: 0.5,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newReturn,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New return'),
      ),
      body: Column(children: [
        _dateBar(),
        Expanded(child: RefreshIndicator(onRefresh: _load, child: _body())),
      ]),
    );
  }

  Widget _dateBar() {
    Widget field(String label, DateTime value, bool isFrom) => Expanded(
          child: InkWell(
            onTap: () => _pickDate(isFrom: isFrom),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.borderLight),
              ),
              child: Row(children: [
                Icon(Icons.calendar_today_outlined,
                    size: 15, color: AppColors.textSecondaryLight),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textTertiaryLight,
                          letterSpacing: 0.5)),
                  Text(_df.format(value),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              ]),
            ),
          ),
        );
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(children: [
        field('FROM', _from, true),
        const SizedBox(width: 10),
        field('TO', _to, false),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _message(Icons.cloud_off_outlined, _error!);
    if (_rows.isEmpty) {
      return _message(Icons.assignment_return_outlined,
          'No return requests in these dates.\nTap "New return" to ask for one.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _tile(_rows[i]),
    );
  }

  Widget _message(IconData icon, String text) => ListView(
        padding: const EdgeInsets.only(top: 120, left: 32, right: 32),
        children: [
          Icon(icon, size: 40, color: AppColors.textTertiaryLight),
          const SizedBox(height: 10),
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondaryLight)),
        ],
      );

  Widget _tile(Map<String, dynamic> r) {
    final stage = stageOf(r);
    final items = (r['items'] as List?) ?? const [];
    final d = _date(r);
    final refs = _refs(r);
    return InkWell(
      onTap: () => _showDetail(r),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((r['shop_name'] ?? '—').toString(),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text(
                  '${d != null ? _df.format(d) : '—'}  ·  ${items.length} product${items.length == 1 ? '' : 's'}'
                  '${(r['reason'] ?? '').toString().isNotEmpty ? '  ·  ${r['reason']}' : ''}',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textSecondaryLight)),
              if (refs.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(refs,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ],
              if (stage == 'rejected') ...[
                const SizedBox(height: 6),
                _note(
                    (r['reject_reason'] ?? '').toString().isEmpty
                        ? 'Rejected · no reason given'
                        : 'Reason: ${r['reject_reason']}',
                    AppColors.danger),
              ],
            ]),
          ),
          const SizedBox(width: 10),
          _chip(stage),
        ]),
      ),
    );
  }

  Widget _note(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12.5, color: color, fontWeight: FontWeight.w600)),
      );

  void _showDetail(Map<String, dynamic> r) {
    final stage = stageOf(r);
    final items = [
      for (final it in (r['items'] as List? ?? const []))
        Map<String, dynamic>.from(it as Map)
    ];
    final photo = (r['photo_path'] ?? '').toString();
    final hint = _stageHint(stage);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scroll) => Column(children: [
          Expanded(
            child: ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(
                  child: Text((r['shop_name'] ?? '—').toString(),
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                _chip(stage),
              ]),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(hint,
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.textSecondaryLight)),
              ],
              const SizedBox(height: 10),
              _row('Sent on', _date(r) != null ? _df.format(_date(r)!) : '—'),
              if ((r['invoice_number'] ?? '').toString().isNotEmpty)
                _row('Invoice', r['invoice_number'].toString()),
              _row('Reason', (r['reason'] ?? '—').toString()),
              if ((r['note'] ?? '').toString().isNotEmpty)
                _row('Note', r['note'].toString()),
              if ((r['srn_number'] ?? '').toString().isNotEmpty)
                _row('Return note', r['srn_number'].toString()),
              if (r['credit_numbers'] is List &&
                  (r['credit_numbers'] as List).isNotEmpty)
                _row('Credit', (r['credit_numbers'] as List).join(', ')),
              if (stage == 'rejected')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _note(
                      (r['reject_reason'] ?? '').toString().isEmpty
                          ? 'Rejected · no reason given'
                          : 'Reason: ${r['reject_reason']}',
                      AppColors.danger),
                ),
              if (photo.isNotEmpty) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(PhotoUrl.build(photo),
                      height: 170,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                ),
              ],
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              for (final it in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Expanded(
                      child: Text((it['name'] ?? 'Product').toString(),
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    Text('Qty ${_qty(it['quantity'] as num?)}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ]),
                ),
            ]),
          ),
          if (stage == 'submitted')
            Container(
              padding: EdgeInsets.fromLTRB(
                  16, 10, 16, 12 + MediaQuery.of(ctx).padding.bottom),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.borderLight)),
              ),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _cancel(ctx, r),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel request'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _edit(ctx, r, items),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Change'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondaryLight)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  Future<void> _edit(BuildContext sheetCtx, Map<String, dynamic> r,
      List<Map<String, dynamic>> items) async {
    Navigator.pop(sheetCtx);
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => FieldReturnFormScreen(
        existing: ReturnDraft(
          id: r['id'].toString(),
          customerId: (r['customer_id'] ?? '').toString(),
          customerName: (r['shop_name'] ?? 'Shop').toString(),
          invoiceId: r['invoice_id']?.toString(),
          invoiceNumber: r['invoice_number']?.toString(),
          reason: r['reason']?.toString(),
          note: r['note']?.toString(),
          photoPath: (r['photo_path'] ?? '').toString().isEmpty
              ? null
              : r['photo_path'].toString(),
          lines: [
            for (final it in items)
              ReturnLine(
                productId: (it['product_id'] ?? '').toString(),
                name: (it['name'] ?? 'Product').toString(),
                sku: (it['sku'] ?? '').toString(),
                uomId: it['uom_id']?.toString(),
                qty: (it['quantity'] as num?)?.toDouble() ?? 0,
              ),
          ],
        ),
      ),
    ));
    if (ok == true) {
      _snack('Return request updated. The office has been told.');
      _load();
    }
  }

  Future<void> _cancel(BuildContext sheetCtx, Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: sheetCtx,
      builder: (d) => AlertDialog(
        title: const Text('Cancel this return request?'),
        content: const Text('The office will be told.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Cancel request'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .rpc('cancel_field_return', params: {'p_id': r['id']});
      if (sheetCtx.mounted) Navigator.pop(sheetCtx);
      _snack('Return request cancelled.');
      _load();
    } catch (e) {
      _snack(fieldOrderErrorText(e));
    }
  }
}
