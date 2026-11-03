import 'dart:convert';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/device_gps_service.dart';

/// Where the surveyor was when saving a survey (SQL 445). Read in the
/// background after the survey is saved, compared with the shop's saved
/// location, kept on the phone (queue in app_config) and sent when online.
///   inside → Visited · outside → Not visited · no_gps / no_shop_location → No location
class SurveyLocationService {
  final AppDatabase db;
  SurveyLocationService(this.db);

  static const _queueKey = 'survey_location_queue';
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

  static double _distance(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Reads GPS, records the result and tries to send it. Never throws, and
  /// uses no screen state — safe to run after the screen has closed.
  static Future<void> capture({
    required AppDatabase db,
    required DeviceGpsService gps,
    required Future<int> radius,
    required String id,
    required String orgId,
    required CustomersData shop,
    required String kind, // 'placement' | 'competitor'
    required DateTime surveyedAt,
  }) async {
    try {
      final rec = <String, dynamic>{
        'id': id,
        'org_id': orgId,
        'customer_id': shop.id,
        'kind': kind,
        'surveyed_at': surveyedAt.toUtc().toIso8601String(),
      };
      GpsFixResult? res;
      try {
        res = await gps.getFixResult(timeout: const Duration(seconds: 20));
      } catch (_) {}
      if (res == null || !res.ok) {
        rec['location_status'] = 'no_gps';
      } else {
        final fix = res.fix!;
        rec['lat'] = fix.lat;
        rec['lng'] = fix.lng;
        rec['accuracy_m'] = fix.accuracy;
        final sLat = shop.latitude, sLng = shop.longitude;
        if (sLat == null || sLng == null) {
          rec['location_status'] = 'no_shop_location';
        } else {
          int r = 100;
          try {
            r = await radius;
          } catch (_) {}
          final d = _distance(fix.lat, fix.lng, sLat, sLng);
          rec['distance_m'] = double.parse(d.toStringAsFixed(1));
          rec['location_status'] = d <= r ? 'inside' : 'outside';
        }
      }
      final svc = SurveyLocationService(db);
      final q = await svc.queued();
      q.removeWhere((x) => x['id'] == id);
      q.add(rec);
      await svc._save(q);
      await svc.flush();
    } catch (_) {}
  }

  /// Sends queued locations. Returns how many are still waiting.
  Future<int> flush() async {
    if (_flushing) return (await queued()).length;
    _flushing = true;
    try {
      final client = Supabase.instance.client;
      for (final rec in await queued()) {
        try {
          await client.rpc('record_survey_location', params: {'p': rec});
        } on PostgrestException catch (e) {
          // Refused (e.g. shop removed): it will never go through — drop it.
          // Anything else (offline, server not updated yet): try later.
          if (e.code != 'P0001') break;
        } catch (_) {
          break;
        }
        final q = await queued();
        q.removeWhere((x) => x['id'] == rec['id']);
        await _save(q);
      }
      return (await queued()).length;
    } finally {
      _flushing = false;
    }
  }
}
