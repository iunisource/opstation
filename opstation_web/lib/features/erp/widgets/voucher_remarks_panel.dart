import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';

/// Internal remarks trail for a voucher (screen-only — never printed).
/// Any user can add a remark; the full trail is kept and shown here. Rows are
/// stored in `voucher_remarks`. Collapsible.
class VoucherRemarksPanel extends StatefulWidget {
  final String voucherType;
  final String voucherId;
  final String orgId;
  final String? userId;
  final String? userName;
  final bool canWrite;

  const VoucherRemarksPanel({
    super.key,
    required this.voucherType,
    required this.voucherId,
    required this.orgId,
    required this.userId,
    required this.userName,
    this.canWrite = true,
  });

  @override
  State<VoucherRemarksPanel> createState() => _VoucherRemarksPanelState();
}

class _VoucherRemarksPanelState extends State<VoucherRemarksPanel> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _expanded = false;
  bool _saving = false;
  final _ctrl = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(covariant VoucherRemarksPanel old) {
    super.didUpdateWidget(old);
    if (old.voucherId != widget.voucherId) { _ctrl.clear(); _load(); }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('voucher_remarks')
          .select()
          .eq('voucher_type', widget.voucherType)
          .eq('voucher_id', widget.voucherId)
          .order('created_at', ascending: false);
      if (mounted) setState(() { _rows = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _rows = []; _loading = false; });
    }
  }

  Future<void> _add() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _saving = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      await Supabase.instance.client.from('voucher_remarks').insert({
        'id': 'vrmk_$ts',
        'org_id': widget.orgId,
        'voucher_type': widget.voucherType,
        'voucher_id': widget.voucherId,
        'user_id': widget.userId,
        'user_name': widget.userName,
        'remark': text,
      });
      _ctrl.clear();
      await _load();
    } catch (e) { _snack('Failed: $e'); }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: const Radius.circular(8), bottom: Radius.circular(_expanded ? 0 : 8))),
            child: Row(children: [
              const Icon(Icons.forum_outlined, size: 16, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Text('Internal Remarks', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              const Text('(not printed)', style: TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
              const Spacer(),
              if (_rows.isNotEmpty)
                Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                  child: Text('${_rows.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary))),
              const SizedBox(width: 6),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: AppTheme.textSecondary),
            ]),
          ),
        ),
        if (_expanded) ...[
          if (widget.canWrite)
            Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 6), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: TextField(
                controller: _ctrl, minLines: 1, maxLines: 4,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(hintText: 'Add a remark…', isDense: true, border: OutlineInputBorder(), enabledBorder: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
              )),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
                onPressed: _saving ? null : _add,
                child: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Add')),
            ])),
          if (_loading)
            const Padding(padding: EdgeInsets.all(14), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))))
          else if (_rows.isEmpty)
            const Padding(padding: EdgeInsets.fromLTRB(14, 4, 14, 14), child: Text('No remarks yet.', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)))
          else
            Column(children: [
              for (final r in _rows)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border.withOpacity(0.5)))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(r['user_name'] as String? ?? '—', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text(r['created_at'] != null ? DateFormat('d MMM yyyy HH:mm').format(DateTime.parse(r['created_at'] as String).toLocal()) : '',
                          style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                    ]),
                    const SizedBox(height: 2),
                    Text(r['remark'] as String? ?? '', style: const TextStyle(fontSize: 12.5)),
                  ]),
                ),
            ]),
          const SizedBox(height: 6),
        ],
      ]),
    );
  }
}
