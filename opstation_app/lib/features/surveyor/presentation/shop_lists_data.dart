import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/survey_audit_service.dart';

/// What Surveyed shops and Non-surveyed shops show: the org's active shops
/// (an auditor only those in their customer groups), each shop's latest
/// survey summary, and the audits / feedback (server + waiting on phone).
class ShopListData {
  final Map<String, CustomersData> shops; // all shops in scope
  final Map<String, DateTime> lastSurvey; // surveyed shops only
  final Map<String, String> lastBy; // surveyor name of the latest survey
  final Map<String, (int shown, int total)> placement;
  final Map<String, int> competitor; // categories spotted
  final List<Map<String, dynamic>> audits; // newest first
  final Map<String, int> feedbackCount;
  // Shops whose placement score includes sales invoices (Auto Pilot).
  final Set<String> autoPilot;
  const ShopListData(this.shops, this.lastSurvey, this.lastBy, this.placement, this.competitor, this.audits,
      this.feedbackCount, {this.autoPilot = const {}});

  Set<String> get surveyed => lastSurvey.keys.toSet();
}

/// Pull the latest surveys from the server (ignored when offline).
Future<void> refreshSurveys(WidgetRef ref) async {
  final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
  if (orgId == null) return;
  try {
    await ref.read(supabasePullServiceProvider).refreshSurveyReference(orgId);
    await ref.read(supabasePullServiceProvider).refreshSurveyHistory(orgId);
  } catch (_) {}
}

Future<ShopListData> loadShopLists(WidgetRef ref, {bool withAudits = true}) async {
  final db = ref.read(appDatabaseProvider);
  final user = ref.read(authControllerProvider).valueOrNull;
  final orgId = user?.organizationId;
  final svc = SurveyAuditService(db);
  final isAuditor = user?.role == UserRole.auditor;
  // Auditor limited to customer groups (Admin Settings): only those shops.
  final groups = (orgId == null || !isAuditor) ? null : await svc.shopGroups(orgId);
  final users = {for (final u in await db.select(db.users).get()) u.id: u.name};
  final shops = {
    for (final c in await (db.select(db.customers)..where((c) => c.isActive.equals(true))).get())
      if ((orgId == null || c.orgId == null || c.orgId == orgId) && SurveyAuditService.inGroups(groups, c)) c.id: c,
  };

  final last = <String, DateTime>{};
  final by = <String, String>{};
  void note(String cid, DateTime at, String? uid) {
    final cur = last[cid];
    if (cur == null || at.isAfter(cur)) {
      last[cid] = at;
      by[cid] = users[uid] ?? '';
    }
  }

  // Placement: latest row per shop + product.
  final latestP = <String, Map<String, PlacementAuditRow>>{};
  for (final a in await db.select(db.placementAudits).get()) {
    if (!shops.containsKey(a.customerId)) continue;
    note(a.customerId, a.surveyedAt, a.surveyedByUserId);
    final m = latestP.putIfAbsent(a.customerId, () => {});
    final cur = m[a.productId];
    if (cur == null || a.surveyedAt.isAfter(cur.surveyedAt)) m[a.productId] = a;
  }
  // Auto Pilot (Admin Settings): placements picked up from sales invoices.
  // Worked out on the server each time; ignored when offline.
  final latest = <String, Map<String, (bool, DateTime)>>{
    for (final e in latestP.entries)
      e.key: {for (final a in e.value.entries) a.key: (a.value.isPresent, a.value.surveyedAt)},
  };
  final autoShops = <String>{};
  if (orgId != null) {
    try {
      for (var from = 0; from < 500000; from += 1000) {
        final page = await Supabase.instance.client
            .rpc('placement_invoice_rows', params: {'p_org': orgId})
            .range(from, from + 999);
        final rows = page as List;
        for (final r in rows) {
          final cid = '${r['customer_id']}';
          if (!shops.containsKey(cid)) continue;
          final at = DateTime.tryParse('${r['surveyed_at']}');
          if (at == null) continue;
          final m = latest.putIfAbsent(cid, () => {});
          final pid = '${r['product_id']}';
          final cur = m[pid];
          if (cur == null || at.isAfter(cur.$2)) {
            m[pid] = (r['is_present'] == true, at);
            autoShops.add(cid);
          }
        }
        if (rows.length < 1000) break;
      }
    } catch (_) {}
  }
  final placement = {
    for (final e in latest.entries) e.key: (e.value.values.where((a) => a.$1).length, e.value.length),
  };
  final cats = <String, Set<String>>{};
  for (final s in await db.select(db.competitorSpottings).get()) {
    if (!shops.containsKey(s.customerId)) continue;
    note(s.customerId, s.surveyedAt, s.surveyedByUserId);
    cats.putIfAbsent(s.customerId, () => {}).add(s.categoryId);
  }

  var audits = <Map<String, dynamic>>[];
  if (withAudits && orgId != null) {
    final server = await svc.fetchOrg(orgId);
    final queued = await svc.queued();
    final all = <String, Map<String, dynamic>>{
      for (final a in server) '${a['id']}': a,
      for (final a in queued) '${a['id']}': {...a, '_pending': true},
    };
    audits = all.values.where((a) => shops.containsKey('${a['customer_id']}')).toList()
      ..sort((a, b) => '${b['audited_at']}'.compareTo('${a['audited_at']}'));
  }
  final fb = <String, int>{};
  for (final a in audits) {
    fb['${a['customer_id']}'] = (fb['${a['customer_id']}'] ?? 0) + 1;
  }
  return ShopListData(shops, last, by, placement, {for (final e in cats.entries) e.key: e.value.length}, audits, fb,
      autoPilot: autoShops);
}
