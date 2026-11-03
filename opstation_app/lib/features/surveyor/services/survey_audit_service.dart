import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';

/// Survey audits (SQL 441). An audit is saved on the phone first (queue in
/// app_config) and sent when online, so an auditor can work without signal.
/// Each queued record may carry a `local_photo` file path; the photo is
/// uploaded to `opstation-photos` before the row is inserted.
class SurveyAuditService {
  final AppDatabase db;
  SurveyAuditService(this.db);

  static const _queueKey = 'survey_audit_queue';
  static const _rejectedKey = 'survey_audit_rejected';

  /// Audits the server refused (kept on the phone for reference).
  Future<List<Map<String, dynamic>>> rejected() async {
    final raw = await db.getConfig(_rejectedKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      return list is List ? [for (final x in list) if (x is Map) Map<String, dynamic>.from(x)] : [];
    } catch (_) {
      return [];
    }
  }
  static bool _flushing = false;

  Future<List<Map<String, dynamic>>> queued() async {
    final raw = await db.getConfig(_queueKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [for (final x in list) if (x is Map) Map<String, dynamic>.from(x)];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Map<String, dynamic>> q) => db.setConfig(_queueKey, jsonEncode(q));

  Future<void> enqueue(Map<String, dynamic> rec) async {
    final q = await queued();
    q.removeWhere((x) => x['id'] == rec['id']);
    q.add(rec);
    await _save(q);
  }

  /// Sends queued audits. Returns how many are still waiting.
  Future<int> flush() async {
    if (_flushing) return (await queued()).length;
    _flushing = true;
    try {
      final client = Supabase.instance.client;
      var q = await queued();
      for (final rec in List<Map<String, dynamic>>.from(q)) {
        final row = Map<String, dynamic>.from(rec);
        final local = row.remove('local_photo') as String?;
        if (local != null && local.isNotEmpty && (row['photo_path'] == null || '${row['photo_path']}'.isEmpty)) {
          final f = File(local);
          if (await f.exists()) {
            final path = 'survey-audits/${row['org_id']}/${row['id']}.jpg';
            try {
              await client.storage.from('opstation-photos').uploadBinary(
                    path,
                    await f.readAsBytes(),
                    fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
                  );
              row['photo_path'] = path;
            } catch (_) {
              break; // offline / storage error: keep it queued, try later
            }
          }
        }
        try {
          // Saved by the server in one step: the audit and its fixes together,
          // with the auditor taken from the login (SQL 443 / 444).
          dynamic res;
          try {
            res = await client.rpc('submit_survey_audit', params: {'p': row});
          } on PostgrestException catch (e) {
            final hasFixes = row['fixes'] is List && (row['fixes'] as List).isNotEmpty;
            if (e.code != 'P0001' || !hasFixes || !('${e.message}').contains('not allowed to correct')) rethrow;
            // Correcting was switched off for this auditor: keep the audit
            // (issue + comment) and drop the correction.
            await _dropLocalFixes(row['fixes'] as List);
            row['fixes'] = <dynamic>[];
            row['corrections'] = <dynamic>[];
            res = await client.rpc('submit_survey_audit', params: {'p': row});
          }
          // Correction waiting for approval: it is not part of the survey yet,
          // so the phone must not show it either. It arrives with the normal
          // survey refresh once approved.
          if (res is Map && res['pending'] == true && row['fixes'] is List) {
            await _dropLocalFixes(row['fixes'] as List);
          }
        } on PostgrestException catch (e) {
          if (e.code == 'P0001') {
            if (row['fixes'] is List) await _dropLocalFixes(row['fixes'] as List);
            // Refused by the server (e.g. not an Auditor) — it will never go
            // through, so take it out of the queue and keep a note of it.
            final rej = await rejected();
            rej.add({...rec, 'error': e.message});
            await db.setConfig(_rejectedKey, jsonEncode(rej));
          } else {
            break; // keep it queued, try later
          }
        } catch (_) {
          break; // offline: stop, keep the rest queued
        }
        q = await queued();
        q.removeWhere((x) => x['id'] == rec['id']);
        await _save(q);
        if (local != null && local.isNotEmpty) {
          try {
            await File(local).delete();
          } catch (_) {}
        }
      }
      return (await queued()).length;
    } finally {
      _flushing = false;
    }
  }

  /// Removes corrected survey rows the phone saved for an audit whose
  /// correction did not go into the survey (refused, or waiting for approval).
  Future<void> _dropLocalFixes(List fixes) async {
    final pa = <String>[], cs = <String>[];
    for (final f in fixes) {
      if (f is! Map || f['id'] == null) continue;
      (f['type'] == 'placement' ? pa : cs).add('${f['id']}');
    }
    try {
      if (pa.isNotEmpty) await (db.delete(db.placementAudits)..where((t) => t.id.isIn(pa))).go();
      if (cs.isNotEmpty) await (db.delete(db.competitorSpottings)..where((t) => t.id.isIn(cs))).go();
    } catch (_) {}
  }

  static const _permKey = 'survey_audit_perms';

  /// What this auditor may do (SQL 444): {can_fix, needs_approval}. Read from
  /// the server and kept on the phone for offline use. Without either, the
  /// survey is view-only.
  Future<Map<String, dynamic>> permissions(String orgId) async {
    try {
      final res = await Supabase.instance.client.rpc('my_audit_permissions', params: {'p_org': orgId});
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        await db.setConfig('${_permKey}_$orgId', jsonEncode(m));
        return m;
      }
    } catch (_) {}
    try {
      final raw = await db.getConfig('${_permKey}_$orgId');
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) return Map<String, dynamic>.from(m);
      }
    } catch (_) {}
    return const {'can_fix': false, 'needs_approval': false};
  }

  /// Customer groups this auditor is limited to (SQL 446), lower-case;
  /// null = all shops.
  Future<Set<String>?> shopGroups(String orgId) async {
    final g = (await permissions(orgId))['groups'];
    if (g is! List) return null;
    return {for (final x in g) '$x'.trim().toLowerCase()};
  }

  static bool inGroups(Set<String>? groups, CustomersData c) =>
      groups == null || groups.contains((c.groupName ?? '').trim().toLowerCase());

  /// One shop's audits from the server, newest first; [] when offline.
  Future<List<Map<String, dynamic>>> fetchShop(String orgId, String customerId) async {
    try {
      final rows = await Supabase.instance.client
          .from('survey_audits')
          .select()
          .eq('org_id', orgId)
          .eq('customer_id', customerId)
          .order('audited_at', ascending: false);
      return List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return [];
    }
  }

  /// All audits of the org from the server, newest first; [] when offline.
  Future<List<Map<String, dynamic>>> fetchOrg(String orgId) async {
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
      return out;
    } catch (_) {
      return [];
    }
  }
}
