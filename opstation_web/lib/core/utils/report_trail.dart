import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Records this generation of a reimbursement report (SQL 413) and returns
/// who generated it and when, oldest first — printed in a DUPLICATE copy's
/// footer. [counted] is false for admins (listed, never counted). Never throws.
Future<List<String>> logReportIssue(String? orgId, String type, String key, {bool counted = true}) async {
  if (orgId == null) return const [];
  try {
    final r = await Supabase.instance.client.rpc('report_issue_log', params: {
      'p_org': orgId, 'p_type': type, 'p_key': key, 'p_counted': counted,
    });
    final fmt = DateFormat('d MMM yyyy, h:mm a');
    return [
      for (final e in (r as List? ?? const []))
        () {
          final at = DateTime.tryParse('${e['at'] ?? ''}')?.toLocal();
          final role = '${e['role'] ?? ''}';
          final admin = role == 'admin' || role == 'masterAdmin' || role == 'superAdmin';
          return '${e['name'] ?? 'Unknown'}${admin ? ' (admin)' : ''} ${at == null ? '' : fmt.format(at)}'.trim();
        }(),
    ];
  } catch (_) {
    return const [];
  }
}
