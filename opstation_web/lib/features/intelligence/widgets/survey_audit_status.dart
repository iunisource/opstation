import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// Audit status of a surveyed shop (SQL 441), shown on the Placement Audit and
/// Competitor Spotting screens: the auditor's latest audit compared with the
/// shop's latest survey.
enum SurveyAuditState { notAudited, ok, issue, resurveyed }

const surveyAuditFilterLabels = <String, String>{
  'all': 'All audit statuses',
  'not': 'Not audited',
  'ok': 'Audited ✓',
  'issue': 'Audit issue',
  'resurveyed': 'Re-surveyed since audit',
};

/// Feedback photos (SQL 447) are in the private bucket "survey-feedback" and
/// stored as "survey-feedback/<org>/<id>.jpg"; older ones in opstation-photos.
String photoBucket(String path) => path.startsWith('survey-feedback/') ? 'survey-feedback' : 'opstation-photos';
String photoName(String path) =>
    path.startsWith('survey-feedback/') ? path.substring('survey-feedback/'.length) : path;

/// Status of an auditor's correction (SQL 444) in plain words; '' when the
/// audit has no correction waiting / decided.
String fixStatusText(Map<String, dynamic> a) {
  final by = '${a['fix_decided_by_name'] ?? ''}'.trim();
  final reason = '${a['fix_reject_reason'] ?? ''}'.trim();
  return switch ('${a['fix_status'] ?? ''}') {
    'pending' => 'Correction waiting for approval',
    'approved' => 'Correction approved${by.isEmpty ? '' : ' by $by'}',
    'rejected' => 'Correction rejected${by.isEmpty ? '' : ' by $by'}${reason.isEmpty ? '' : ': $reason'}',
    _ => '',
  };
}

class SurveyAuditIndex {
  /// customer_id → audits, newest first.
  final Map<String, List<Map<String, dynamic>>> byShop;
  const SurveyAuditIndex(this.byShop);
  static const empty = SurveyAuditIndex({});

  static Future<SurveyAuditIndex> load(String orgId) async {
    try {
      final out = <Map<String, dynamic>>[];
      for (var from = 0;; from += 1000) {
        final page = await Supabase.instance.client
            .from('survey_audits')
            .select()
            .eq('org_id', orgId)
            .order('audited_at', ascending: false)
            .range(from, from + 999);
        out.addAll(List<Map<String, dynamic>>.from(page));
        if ((page as List).length < 1000) break;
      }
      final m = <String, List<Map<String, dynamic>>>{};
      for (final a in out) {
        m.putIfAbsent('${a['customer_id']}', () => []).add(a);
      }
      return SurveyAuditIndex(m);
    } catch (_) {
      return empty; // table not set up yet / offline: no badges
    }
  }

  static DateTime? _t(dynamic v) => v == null ? null : DateTime.tryParse('$v');

  /// Entries that count (hidden ones are seen only by admins, in the trail).
  List<Map<String, dynamic>> visible(String customerId) =>
      [for (final a in byShop[customerId] ?? const <Map<String, dynamic>>[]) if (a['hidden_at'] == null) a];

  SurveyAuditState stateFor(String customerId, DateTime? lastSurvey) {
    // Any audit counts — feedback (the auditors' only action now), and the
    // older Matches / Issue. Where the auditor stood is shown separately.
    final list = visible(customerId);
    if (list.isEmpty) return SurveyAuditState.notAudited;
    final a = list.first;
    final at = _t(a['audited_at']);
    // A correction saved by the audit carries the audit's own time — it is
    // not a newer survey.
    if (at != null && lastSurvey != null && lastSurvey.isAfter(at.add(const Duration(seconds: 2)))) {
      return SurveyAuditState.resurveyed;
    }
    return a['result'] == 'issue' ? SurveyAuditState.issue : SurveyAuditState.ok;
  }

  bool matchesFilter(String filter, String customerId, DateTime? lastSurvey) {
    if (filter == 'all') return true;
    final s = stateFor(customerId, lastSurvey);
    return switch (filter) {
      'not' => s == SurveyAuditState.notAudited,
      'ok' => s == SurveyAuditState.ok,
      'issue' => s == SurveyAuditState.issue,
      'resurveyed' => s == SurveyAuditState.resurveyed,
      _ => true,
    };
  }

  /// Small status chip; tap opens the shop's audit trail.
  /// [role] decides Hide / Delete in the trail; [onChanged] reloads the screen.
  Widget badge(BuildContext context, String customerId, String shopName, DateTime? lastSurvey,
      {WebUserRole? role, VoidCallback? onChanged}) {
    final s = stateFor(customerId, lastSurvey);
    final all = byShop[customerId] ?? const <Map<String, dynamic>>[];
    final list = visible(customerId);
    final (label, color) = switch (s) {
      SurveyAuditState.notAudited => ('Not audited', AppTheme.textSecondary),
      SurveyAuditState.ok => ('Audited ✓', const Color(0xFF059669)),
      SurveyAuditState.issue => ('Audit issue', AppTheme.danger),
      SurveyAuditState.resurveyed => ('Re-surveyed', const Color(0xFFD97706)),
    };
    final latest = list.isEmpty ? null : list.first;
    final when = latest == null ? null : _t(latest['audited_at'])?.toLocal();
    final flagged = latest != null && latest['location_status'] != null && latest['location_status'] != 'inside';
    return Tooltip(
      message: latest == null
          ? 'No audit yet'
          : '${latest['auditor_name'] ?? 'Auditor'} · ${when == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(when)}'
              '${flagged ? ' · location flagged' : ''}${list.length > 1 ? ' · ${list.length} audits' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: all.isEmpty ? null : () => showTrail(context, shopName, all, role: role, onChanged: onChanged),
        child: Container(
          margin: const EdgeInsets.only(top: 3),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(5)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
            if (flagged) ...[
              const SizedBox(width: 3),
              const Icon(Icons.wrong_location_outlined, size: 11, color: Color(0xFFD97706)),
            ],
          ]),
        ),
      ),
    );
  }

  static Future<void> showTrail(BuildContext context, String shopName, List<Map<String, dynamic>> audits,
      {WebUserRole? role, VoidCallback? onChanged}) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _TrailDialog(shopName: shopName, audits: audits, role: role),
    );
    if (changed == true) onChanged?.call();
  }
}

class _TrailDialog extends StatefulWidget {
  final String shopName;
  final List<Map<String, dynamic>> audits;
  final WebUserRole? role;
  const _TrailDialog({required this.shopName, required this.audits, required this.role});
  @override
  State<_TrailDialog> createState() => _TrailDialogState();
}

class _TrailDialogState extends State<_TrailDialog> {
  late final List<Map<String, dynamic>> _list = [for (final a in widget.audits) Map<String, dynamic>.from(a)];
  final Set<String> _busy = {};
  bool _changed = false;

  bool get _canHide =>
      widget.role == WebUserRole.admin || widget.role == WebUserRole.masterAdmin || widget.role == WebUserRole.superAdmin;
  bool get _canDelete => widget.role == WebUserRole.superAdmin;

  DateTime? _t(dynamic v) => v == null ? null : DateTime.tryParse('$v');

  String _locText(Map<String, dynamic> a) {
    final d = (a['distance_m'] as num?)?.round();
    return switch ('${a['location_status']}') {
      'inside' => 'At the shop${d == null ? '' : ' (${d}m)'}',
      'outside' => 'Outside the shop area${d == null ? '' : ' (${d}m away)'}',
      'no_shop_location' => 'Shop has no saved location',
      _ => 'No GPS',
    };
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _hide(Map<String, dynamic> a, bool hide) async {
    String? reason;
    if (hide) {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Hide feedback'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('It will no longer show for auditors, on badges or in reports. Admins can unhide it.',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Reason (optional)', border: OutlineInputBorder()),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hide')),
          ],
        ),
      );
      if (ok != true) return;
      reason = ctrl.text.trim();
    }
    final id = '${a['id']}';
    setState(() => _busy.add(id));
    try {
      await Supabase.instance.client.rpc('set_survey_audit_hidden', params: {'p_id': id, 'p_hide': hide, 'p_reason': reason});
      final me = ProviderScope.containerOf(context, listen: false).read(currentUserProvider);
      setState(() {
        a['hidden_at'] = hide ? DateTime.now().toUtc().toIso8601String() : null;
        a['hidden_by_name'] = hide ? (me?.name ?? '') : null;
        a['hide_reason'] = hide && (reason ?? '').isNotEmpty ? reason : null;
        _changed = true;
      });
    } catch (e) {
      _snack(friendlyError(hide ? 'Could not hide' : 'Could not unhide', e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: const Text('This feedback and its photo will be removed for good. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final id = '${a['id']}';
    setState(() => _busy.add(id));
    try {
      final res = await Supabase.instance.client.rpc('delete_survey_audit', params: {'p_id': id});
      final path = res is Map ? '${res['photo_path'] ?? ''}' : '';
      if (path.isNotEmpty) {
        try {
          await Supabase.instance.client.storage.from(photoBucket(path)).remove([photoName(path)]);
        } catch (_) {} // the entry is gone either way
      }
      setState(() {
        _list.removeWhere((x) => '${x['id']}' == id);
        _changed = true;
      });
    } catch (e) {
      _snack(friendlyError('Could not delete', e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM yyyy, h:mm a');
    return AlertDialog(
      title: Text('Audit trail · ${widget.shopName}'),
      content: SizedBox(
        width: 560,
        child: _list.isEmpty
            ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Text('Nothing left in the trail.'))
            : ListView.separated(
                shrinkWrap: true,
                itemCount: _list.length,
                separatorBuilder: (_, __) => const Divider(height: 20),
                itemBuilder: (_, i) {
                  final a = _list[i];
                  final id = '${a['id']}';
                  final hidden = a['hidden_at'] != null;
                  final issue = a['result'] == 'issue';
                  final feedback = a['result'] == 'feedback';
                  final at = _t(a['audited_at'])?.toLocal();
                  final sAt = _t(a['survey_at'])?.toLocal();
                  final corr = a['corrections'] is List ? a['corrections'] as List : const [];
                  final outside = a['location_status'] != 'inside';
                  final hiddenBy = '${a['hidden_by_name'] ?? ''}'.trim();
                  final hideReason = '${a['hide_reason'] ?? ''}'.trim();
                  return Opacity(
                    opacity: hidden ? 0.55 : 1,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(issue ? Icons.error_outline : (feedback ? Icons.chat_bubble_outline : Icons.verified_outlined),
                            size: 18,
                            color: issue ? AppTheme.danger : (feedback ? AppTheme.primary : const Color(0xFF059669))),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                              '${issue ? 'Issue found' : (feedback ? 'Feedback' : 'Matches survey')} · ${a['auditor_name'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        if (_busy.contains(id))
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        else ...[
                          if (_canHide)
                            TextButton(
                              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                              onPressed: () => _hide(a, !hidden),
                              child: Text(hidden ? 'Unhide' : 'Hide'),
                            ),
                          if (_canDelete)
                            IconButton(
                              tooltip: 'Delete permanently',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
                              onPressed: () => _delete(a),
                            ),
                        ],
                      ]),
                      if (hidden)
                        Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: AppTheme.textSecondary.withOpacity(0.12), borderRadius: BorderRadius.circular(5)),
                          child: Text(
                            'Hidden${hiddenBy.isEmpty ? '' : ' by $hiddenBy'}${hideReason.isEmpty ? '' : ': $hideReason'}',
                            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
                          ),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (at != null) df.format(at),
                          _locText(a),
                          if (sAt != null) 'checked survey of ${DateFormat('d MMM yyyy').format(sAt)}',
                          if (_t(a['received_at']) != null &&
                              at != null &&
                              _t(a['received_at'])!.toLocal().difference(at).inMinutes.abs() > 30)
                            'sent ${df.format(_t(a['received_at'])!.toLocal())}',
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: outside ? const Color(0xFFD97706) : AppTheme.textSecondary),
                      ),
                      if ('${a['comment'] ?? ''}'.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('${a['comment']}', style: const TextStyle(fontSize: 13)),
                      ],
                      if (corr.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          switch ('${a['fix_status'] ?? ''}') {
                            'pending' => 'Proposed correction',
                            'rejected' => 'Proposed correction (not applied)',
                            _ => 'Corrected',
                          },
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary),
                        ),
                        for (final c in corr)
                          if (c is Map)
                            Text(
                              '• ${c['type'] == 'placement' ? c['product'] : c['category']}: ${c['from'] ?? '—'}  →  ${c['to'] ?? '—'}',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                      ],
                      if (fixStatusText(a).isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          fixStatusText(a),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: switch ('${a['fix_status']}') {
                              'pending' => const Color(0xFFD97706),
                              'rejected' => AppTheme.danger,
                              _ => const Color(0xFF059669),
                            },
                          ),
                        ),
                      ],
                      if ('${a['photo_path'] ?? ''}'.isNotEmpty)
                        TextButton.icon(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero),
                          onPressed: () async {
                            final path = '${a['photo_path']}';
                            String url;
                            try {
                              url = await Supabase.instance.client.storage
                                  .from(photoBucket(path))
                                  .createSignedUrl(photoName(path), 3600);
                            } catch (_) {
                              url = Supabase.instance.client.storage.from(photoBucket(path)).getPublicUrl(photoName(path));
                            }
                            await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
                          },
                          icon: const Icon(Icons.photo_outlined, size: 16),
                          label: const Text('View photo'),
                        ),
                    ]),
                  );
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Close'))],
    );
  }
}
