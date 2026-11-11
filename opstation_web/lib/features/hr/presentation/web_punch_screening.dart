import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';

/// Attendance Review → "Punches to screen" (SQL 461). Web check-ins that look
/// like someone punched for a colleague. They already count; Approve keeps the
/// punch, Reject removes it. Hidden when there is nothing to screen.
class WebPunchScreening extends StatefulWidget {
  final String orgId;
  final VoidCallback? onChanged;
  const WebPunchScreening({super.key, required this.orgId, this.onChanged});
  @override
  State<WebPunchScreening> createState() => _WebPunchScreeningState();
}

class _WebPunchScreeningState extends State<WebPunchScreening> {
  List<Map<String, dynamic>> _rows = [];
  bool _open = true;
  final Set<String> _busy = {};

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.orgId.isEmpty) return;
    try {
      final r = await _db.rpc('web_punch_flags_list', params: {'p_org': widget.orgId});
      if (!mounted) return;
      setState(() => _rows = [for (final x in (r as List? ?? const [])) Map<String, dynamic>.from(x as Map)]);
    } catch (_) {
      // SQL 461 not run yet — nothing to show.
    }
  }

  static const _why = {
    'shared_computer': 'Same computer punched another employee today',
    'new_computer': 'First punch from this computer',
    'login_swap': 'Someone else used this browser just before this login',
    'off_network': 'Not on an office network',
  };

  static String _t(String? hhmm) {
    if (hhmm == null || !hhmm.contains(':')) return hhmm ?? '';
    final p = hhmm.split(':');
    final h = int.tryParse(p[0]) ?? 0, m = int.tryParse(p[1]) ?? 0;
    return DateFormat('h:mm a').format(DateTime(2000, 1, 1, h, m));
  }

  /// Name the connection this punch came from and add it as an office network.
  Future<void> _addNetwork(Map<String, dynamic> r) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add as office network'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("Future punches from the connection ${r['employee']} used will count as on the office network.",
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Warehouse Wi-Fi', isDense: true, border: OutlineInputBorder()),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await _db.rpc('office_network_add_from_flag', params: {'p_flag': r['id'], 'p_name': name});
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Office network added')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not add the network', e))));
    }
  }

  Future<void> _decide(Map<String, dynamic> r, String decision) async {
    String? note;
    if (decision == 'reject') {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject this punch?'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                r['direction'] == 'in'
                    ? "${r['employee']}'s check-in at ${_t(r['time'] as String?)} will be removed."
                    : "${r['employee']}'s check-out at ${_t(r['time'] as String?)} will be removed.",
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Reason (optional)', isDense: true, border: OutlineInputBorder())),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('Reject'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      note = ctrl.text.trim();
    }
    setState(() => _busy.add(r['id'] as String));
    try {
      await _db.rpc('web_punch_flag_decide', params: {'p_id': r['id'], 'p_decision': decision, 'p_note': note});
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not save', e))));
      }
    }
    if (mounted) setState(() => _busy.remove(r['id']));
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(children: [
              const Icon(Icons.policy_outlined, size: 18, color: Color(0xFFB45309)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Punches to screen (${_rows.length})',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF92400E))),
              ),
              const Flexible(
                child: Text('Web check-ins that may have been done for someone else',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: Color(0xFFB45309))),
              ),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: const Color(0xFFB45309)),
            ]),
          ),
        ),
        if (_open)
          for (final r in _rows) _row(r),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final reasons = [for (final x in (r['reasons'] as List? ?? const [])) '$x'];
    final others = [for (final x in (r['others'] as List? ?? const [])) '$x'];
    final busy = _busy.contains(r['id']);
    final d = DateTime.tryParse('${r['att_date'] ?? ''}');
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFFDE68A)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['employee'] ?? ''}${(r['code'] ?? '') != '' ? '  ·  ${r['code']}' : ''}',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              '${r['direction'] == 'in' ? 'Check-in' : 'Check-out'} ${_t(r['time'] as String?)}'
              '${d != null ? '  ·  ${DateFormat('d MMM').format(d)}' : ''}'
              '  ·  ${(r['network'] ?? '') != '' ? r['network'] : 'Not an office network'}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final w in reasons)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFFDE68A))),
                  child: Text(
                    w == 'shared_computer' && others.isNotEmpty
                        ? 'Same computer also punched ${others.join(', ')} today'
                        : w == 'login_swap' && (r['prev_user'] ?? '') != ''
                            ? '${r['prev_user']} was using this browser just before'
                            : (_why[w] ?? w),
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF92400E)),
                  ),
                ),
            ]),
            if (reasons.contains('off_network') && r['can_add_network'] == true && r['ip_listed'] != true && (r['ip'] ?? '') != '')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  onPressed: () => _addNetwork(r),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                  icon: const Icon(Icons.wifi_rounded, size: 15),
                  label: const Text('This is an office — add as office network', style: TextStyle(fontSize: 12)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        if (busy)
          const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
        else ...[
          OutlinedButton(
            onPressed: () => _decide(r, 'approve'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.green.shade700, visualDensity: VisualDensity.compact),
            child: const Text('Approve', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: () => _decide(r, 'reject'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red, visualDensity: VisualDensity.compact),
            child: const Text('Reject', style: TextStyle(fontSize: 12)),
          ),
        ],
      ]),
    );
  }
}
