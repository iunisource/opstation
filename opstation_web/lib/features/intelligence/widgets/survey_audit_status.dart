import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

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

  SurveyAuditState stateFor(String customerId, DateTime? lastSurvey) {
    // Feedback is a note only — the status comes from the latest Matches / Issue.
    final list = byShop[customerId]?.where((x) => x['result'] != 'feedback').toList();
    if (list == null || list.isEmpty) return SurveyAuditState.notAudited;
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
  Widget badge(BuildContext context, String customerId, String shopName, DateTime? lastSurvey) {
    final s = stateFor(customerId, lastSurvey);
    final list = byShop[customerId] ?? const [];
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
        onTap: list.isEmpty ? null : () => showTrail(context, shopName, list),
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

  static String _locText(Map<String, dynamic> a) {
    final d = (a['distance_m'] as num?)?.round();
    return switch ('${a['location_status']}') {
      'inside' => 'At the shop${d == null ? '' : ' (${d}m)'}',
      'outside' => 'Outside the shop area${d == null ? '' : ' (${d}m away)'}',
      'no_shop_location' => 'Shop has no saved location',
      _ => 'No GPS',
    };
  }

  static Future<void> showTrail(BuildContext context, String shopName, List<Map<String, dynamic>> audits) {
    final df = DateFormat('d MMM yyyy, h:mm a');
    return showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Audit trail · $shopName'),
        content: SizedBox(
          width: 520,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: audits.length,
            separatorBuilder: (_, __) => const Divider(height: 20),
            itemBuilder: (_, i) {
              final a = audits[i];
              final issue = a['result'] == 'issue';
              final feedback = a['result'] == 'feedback';
              final at = _t(a['audited_at'])?.toLocal();
              final sAt = _t(a['survey_at'])?.toLocal();
              final corr = a['corrections'] is List ? a['corrections'] as List : const [];
              final outside = a['location_status'] != 'inside';
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(issue ? Icons.error_outline : (feedback ? Icons.chat_bubble_outline : Icons.verified_outlined),
                      size: 18, color: issue ? AppTheme.danger : (feedback ? AppTheme.primary : const Color(0xFF059669))),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('${issue ? 'Issue found' : (feedback ? 'Feedback' : 'Matches survey')} · ${a['auditor_name'] ?? ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    if (at != null) df.format(at),
                    _locText(a),
                    if (sAt != null) 'checked survey of ${DateFormat('d MMM yyyy').format(sAt)}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: outside ? const Color(0xFFD97706) : AppTheme.textSecondary),
                ),
                if ('${a['comment'] ?? ''}'.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('${a['comment']}', style: const TextStyle(fontSize: 13)),
                ],
                if (corr.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  const Text('Corrected', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                  for (final c in corr)
                    if (c is Map)
                      Text(
                        '• ${c['type'] == 'placement' ? c['product'] : c['category']}: ${c['from'] ?? '—'}  →  ${c['to'] ?? '—'}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                ],
                if ('${a['photo_path'] ?? ''}'.isNotEmpty)
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () async {
                      final path = '${a['photo_path']}';
                      String url;
                      try {
                        url = await Supabase.instance.client.storage.from('opstation-photos').createSignedUrl(path, 3600);
                      } catch (_) {
                        url = Supabase.instance.client.storage.from('opstation-photos').getPublicUrl(path);
                      }
                      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
                    },
                    icon: const Icon(Icons.photo_outlined, size: 16),
                    label: const Text('View photo'),
                  ),
              ]);
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}
