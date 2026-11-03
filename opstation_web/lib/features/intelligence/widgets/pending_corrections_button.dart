import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// "Pending corrections (n)" on the Placement Audit and Competitor Spotting
/// screens (SQL 444). Shown only to users who may approve auditor corrections,
/// and only while something is waiting. Approve applies the correction to the
/// survey; Reject keeps the survey as it was.
class PendingCorrectionsButton extends ConsumerStatefulWidget {
  /// Called after something was approved, so the screen can reload.
  final VoidCallback? onChanged;
  final bool compact;
  const PendingCorrectionsButton({super.key, this.onChanged, this.compact = false});
  @override
  ConsumerState<PendingCorrectionsButton> createState() => _PendingCorrectionsButtonState();
}

class _PendingCorrectionsButtonState extends ConsumerState<PendingCorrectionsButton> {
  bool _canApprove = false;
  List<Map<String, dynamic>> _pending = [];
  Map<String, String> _shopNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    try {
      final perm = await client.rpc('my_audit_permissions', params: {'p_org': orgId});
      final can = perm is Map && perm['can_approve'] == true;
      if (!can) {
        if (mounted) setState(() => _canApprove = false);
        return;
      }
      final rows = List<Map<String, dynamic>>.from(await client
          .from('survey_audits')
          .select()
          .eq('org_id', orgId)
          .eq('fix_status', 'pending')
          .order('audited_at', ascending: true)
          .limit(500));
      final ids = rows.map((r) => '${r['customer_id']}').toSet().toList();
      final names = <String, String>{};
      if (ids.isNotEmpty) {
        final cs = await client.from('customers').select('id, shop_name').eq('org_id', orgId).inFilter('id', ids);
        for (final c in List<Map<String, dynamic>>.from(cs)) {
          names['${c['id']}'] = '${c['shop_name'] ?? ''}';
        }
      }
      if (!mounted) return;
      setState(() {
        _canApprove = true;
        _pending = rows;
        _shopNames = names;
      });
    } catch (_) {
      // Not set up yet / offline: show nothing.
      if (mounted) setState(() => _canApprove = false);
    }
  }

  Future<void> _open() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _PendingDialog(pending: _pending, shopNames: _shopNames),
    );
    await _load();
    if (changed == true) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canApprove || _pending.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFFEF3C7),
          foregroundColor: const Color(0xFF92400E),
        ),
        onPressed: _open,
        icon: const Icon(Icons.rule_outlined, size: 18),
        label: Text(widget.compact ? 'Pending (${_pending.length})' : 'Pending corrections (${_pending.length})'),
      ),
    );
  }
}

class _PendingDialog extends StatefulWidget {
  final List<Map<String, dynamic>> pending;
  final Map<String, String> shopNames;
  const _PendingDialog({required this.pending, required this.shopNames});
  @override
  State<_PendingDialog> createState() => _PendingDialogState();
}

class _PendingDialogState extends State<_PendingDialog> {
  late final List<Map<String, dynamic>> _rows = List.of(widget.pending);
  final Set<String> _busy = {};
  bool _changed = false;

  Future<void> _decide(Map<String, dynamic> a, bool approve) async {
    String? reason;
    if (!approve) {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reject correction'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder()),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reject'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      reason = ctrl.text.trim();
    }
    final id = '${a['id']}';
    setState(() => _busy.add(id));
    try {
      await Supabase.instance.client.rpc('decide_survey_fix', params: {
        'p_audit': id,
        'p_approve': approve,
        'p_reason': reason,
      });
      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => '${r['id']}' == id);
        _changed = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(approve ? 'Correction approved and applied' : 'Correction rejected')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not save', e))));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _photo(String path) async {
    String url;
    try {
      url = await Supabase.instance.client.storage.from('opstation-photos').createSignedUrl(path, 3600);
    } catch (_) {
      url = Supabase.instance.client.storage.from('opstation-photos').getPublicUrl(path);
    }
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM yyyy, h:mm a');
    return AlertDialog(
      title: Text('Pending corrections (${_rows.length})'),
      content: SizedBox(
        width: 620,
        child: _rows.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Nothing waiting for approval.', textAlign: TextAlign.center),
              )
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 24),
                itemBuilder: (_, i) {
                  final a = _rows[i];
                  final id = '${a['id']}';
                  final at = DateTime.tryParse('${a['audited_at']}')?.toLocal();
                  final corr = a['corrections'] is List ? a['corrections'] as List : const [];
                  final busy = _busy.contains(id);
                  final outside = a['location_status'] != 'inside';
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.shopNames['${a['customer_id']}'] ?? 'Shop',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${a['auditor_name'] ?? 'Auditor'}',
                        if (at != null) df.format(at),
                        if (outside) 'location flagged',
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: outside ? const Color(0xFFD97706) : AppTheme.textSecondary),
                    ),
                    if ('${a['comment'] ?? ''}'.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('${a['comment']}', style: const TextStyle(fontSize: 13)),
                    ],
                    const SizedBox(height: 6),
                    for (final c in corr)
                      if (c is Map)
                        Text(
                          '• ${c['type'] == 'placement' ? c['product'] : c['category']}: ${c['from'] ?? '—'}  →  ${c['to'] ?? '—'}',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                    const SizedBox(height: 8),
                    Row(children: [
                      if ('${a['photo_path'] ?? ''}'.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => _photo('${a['photo_path']}'),
                          icon: const Icon(Icons.photo_outlined, size: 16),
                          label: const Text('View photo'),
                        ),
                      const Spacer(),
                      if (busy)
                        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      else ...[
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                          onPressed: () => _decide(a, false),
                          child: const Text('Reject'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: () => _decide(a, true), child: const Text('Approve')),
                      ],
                    ]),
                  ]);
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Close'))],
    );
  }
}
