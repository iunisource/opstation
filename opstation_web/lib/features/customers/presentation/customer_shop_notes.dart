import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Customer 360 → Shop notes (SQL 459). Notes shown to salespeople in the
/// shop brief on their route ("i" on the stop). Anyone who can open Customer
/// 360 can add one; the writer or an admin can remove it.
class ShopNotesPanel extends StatefulWidget {
  final String orgId;
  final String customerId;
  const ShopNotesPanel({super.key, required this.orgId, required this.customerId});
  @override
  State<ShopNotesPanel> createState() => _ShopNotesPanelState();
}

class _ShopNotesPanelState extends State<ShopNotesPanel> {
  final _ctrl = TextEditingController();
  DateTime? _until;
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;
  bool _busy = false;
  bool _missing = false; // SQL 459 not run yet

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ShopNotesPanel old) {
    super.didUpdateWidget(old);
    if (old.customerId != widget.customerId) _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // Only while Admin Settings → Smart route guide is ON.
      final cfg = await _db.from('app_config').select('value')
          .eq('org_id', widget.orgId).eq('key', 'org.route_guide').isFilter('branch_id', null).limit(1);
      final on = (cfg as List).isNotEmpty && '${cfg.first['value']}'.trim() == 'true';
      if (!on) {
        if (mounted) setState(() { _loading = false; _missing = true; });
        return;
      }
      final rows = await _db.from('customer_shop_notes')
          .select('id, note, show_until, created_by_name, created_at, removed_at, removed_by_name')
          .eq('org_id', widget.orgId).eq('customer_id', widget.customerId)
          .order('created_at', ascending: false).limit(50);
      if (!mounted) return;
      setState(() { _notes = List<Map<String, dynamic>>.from(rows as List); _loading = false; _missing = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _missing = true; });
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _add() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) { _snack('Write the note first.'); return; }
    setState(() => _busy = true);
    try {
      await _db.rpc('shop_note_add', params: {
        'p_org': widget.orgId, 'p_customer': widget.customerId, 'p_note': text,
        'p_until': _until == null ? null : DateFormat('yyyy-MM-dd').format(_until!),
      });
      _ctrl.clear();
      _until = null;
      await _load();
    } catch (e) {
      _snack(friendlyError('Could not add the note', e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove(Map<String, dynamic> n) async {
    setState(() => _busy = true);
    try {
      await _db.rpc('shop_note_remove', params: {'p_id': n['id']});
      await _load();
    } catch (e) {
      _snack(friendlyError('Could not remove the note', e));
    }
    if (mounted) setState(() => _busy = false);
  }

  String _d(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : DateFormat('d MMM yyyy').format(d.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) return const SizedBox.shrink();
    final today = DateTime.now();
    bool showing(Map<String, dynamic> n) {
      if (n['removed_at'] != null) return false;
      final u = DateTime.tryParse('${n['show_until'] ?? ''}');
      return u == null || !DateTime(u.year, u.month, u.day).isBefore(DateTime(today.year, today.month, today.day));
    }

    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.sticky_note_2_outlined, size: 18, color: AppTheme.primary),
          SizedBox(width: 8),
          Text('Shop notes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          SizedBox(width: 8),
          Flexible(child: Text('— shown to salespeople in the shop brief',
              overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 260, maxWidth: 520),
            child: TextField(
              controller: _ctrl,
              minLines: 1, maxLines: 3,
              decoration: const InputDecoration(
                  isDense: true, border: OutlineInputBorder(),
                  hintText: 'Write a note for the salesperson… e.g. Collect the cheque promised last week'),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final p = await showDatePicker(
                  context: context, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)),
                  initialDate: _until ?? DateTime.now().add(const Duration(days: 7)));
              setState(() => _until = p);
            },
            icon: const Icon(Icons.event, size: 16),
            label: Text(_until == null ? 'Show until (optional)' : 'Until ${DateFormat('d MMM').format(_until!)}'),
          ),
          if (_until != null)
            IconButton(tooltip: 'No end date', icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _until = null)),
          ElevatedButton(onPressed: _busy ? null : _add, child: const Text('Add note')),
        ]),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
        else if (_notes.isEmpty)
          const Padding(padding: EdgeInsets.only(top: 6),
              child: Text('No notes yet.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)))
        else
          for (final n in _notes)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
              child: Opacity(
                opacity: showing(n) ? 1 : 0.55,
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${n['note'] ?? ''}', style: TextStyle(fontSize: 13, fontWeight: showing(n) ? FontWeight.w600 : FontWeight.w400)),
                    Text([
                      '${n['created_by_name'] ?? '—'} · ${_d(n['created_at'])}',
                      if (n['removed_at'] != null) 'removed by ${n['removed_by_name'] ?? '—'} on ${_d(n['removed_at'])}'
                      else if (n['show_until'] != null) 'shows until ${_d(n['show_until'])}'
                      else 'no end date',
                    ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                  ])),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: showing(n) ? const Color(0xFFECFDF5) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text(n['removed_at'] != null ? 'Removed' : (showing(n) ? 'Showing' : 'Ended'),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                            color: showing(n) ? const Color(0xFF047857) : const Color(0xFF475569))),
                  ),
                  if (n['removed_at'] == null)
                    TextButton(onPressed: _busy ? null : () => _remove(n), child: const Text('Remove', style: TextStyle(fontSize: 12))),
                ]),
              ),
            ),
      ]),
    );
  }
}
