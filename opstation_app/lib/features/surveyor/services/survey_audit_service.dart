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
          await client.from('survey_audits').insert(row);
        } on PostgrestException catch (e) {
          // Already sent earlier (retry after a lost response) — treat as done.
          if (e.code != '23505') break;
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
