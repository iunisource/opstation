import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';
import '../../auth/models/user_role.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../services/survey_audit_service.dart';
import 'survey_view_sheet.dart';

/// Shops that already have a Placement Audit or Competitor Spotting, newest
/// first. Tap one to see its survey (read-only).
class SurveyedShopsScreen extends ConsumerStatefulWidget {
  const SurveyedShopsScreen({super.key});
  @override
  ConsumerState<SurveyedShopsScreen> createState() => _SurveyedShopsScreenState();
}

class _Row {
  final CustomersData shop;
  final DateTime last;
  final bool placement;
  final bool spotting;
  _Row(this.shop, this.last, this.placement, this.spotting);
}

class _SurveyedShopsScreenState extends ConsumerState<SurveyedShopsScreen> {
  List<_Row> _rows = [];
  bool _loading = true;
  bool _fetching = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    // Show what the phone has straight away, then fetch the latest surveys
    // from the server — a fresh install may not have pulled them yet.
    _load().then((_) => _fetch());
  }

  Future<void> _fetch() async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (orgId == null || _fetching) return;
    if (mounted) setState(() => _fetching = true);
    try {
      await ref.read(supabasePullServiceProvider).refreshSurveyReference(orgId);
      await ref.read(supabasePullServiceProvider).refreshSurveyHistory(orgId);
    } catch (_) {}
    if (!mounted) return;
    await _load();
    if (mounted) setState(() => _fetching = false);
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    final shops = await (db.select(db.customers)
          ..where((c) => c.isActive.equals(true))
          ..orderBy([(c) => OrderingTerm.asc(c.shopName)]))
        .get();
    // Auditor limited to customer groups (Admin Settings): only those shops.
    final isAuditor = ref.read(authControllerProvider).valueOrNull?.role == UserRole.auditor;
    final groups = (orgId == null || !isAuditor) ? null : await SurveyAuditService(db).shopGroups(orgId);
    final byId = {
      for (final c in shops)
        if ((orgId == null || c.orgId == null || c.orgId == orgId) && SurveyAuditService.inGroups(groups, c)) c.id: c,
    };
    final last = <String, DateTime>{};
    final hasP = <String>{};
    final hasS = <String>{};
    for (final a in await db.select(db.placementAudits).get()) {
      if (!byId.containsKey(a.customerId)) continue;
      hasP.add(a.customerId);
      final cur = last[a.customerId];
      if (cur == null || a.surveyedAt.isAfter(cur)) last[a.customerId] = a.surveyedAt;
    }
    for (final s in await db.select(db.competitorSpottings).get()) {
      if (!byId.containsKey(s.customerId)) continue;
      hasS.add(s.customerId);
      final cur = last[s.customerId];
      if (cur == null || s.surveyedAt.isAfter(cur)) last[s.customerId] = s.surveyedAt;
    }
    final rows = [
      for (final e in last.entries)
        _Row(byId[e.key]!, e.value, hasP.contains(e.key), hasS.contains(e.key)),
    ]..sort((a, b) => b.last.compareTo(a.last));
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty
        ? _rows
        : _rows.where((r) => r.shop.shopName.toLowerCase().contains(q) || r.shop.code.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Surveyed shops'), actions: [
        _fetching
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _fetch),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: const InputDecoration(
                    hintText: 'Search shop by name or code',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('${shown.length} shop${shown.length == 1 ? '' : 's'}',
                      style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5)),
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text(_fetching ? 'Fetching surveys…' : 'No surveyed shops yet.'))
                    : RefreshIndicator(
                        onRefresh: _fetch,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: shown.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = shown[i];
                            return ListTile(
                              title: Text(r.shop.shopName),
                              subtitle: Text([
                                r.shop.code,
                                if (r.placement) 'Placement',
                                if (r.spotting) 'Competitor',
                                'Last ${DateFormat('d MMM yyyy').format(r.last)}',
                              ].join(' · ')),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => SurveyViewSheet.show(context, r.shop,
                                  showAudit: ref.read(authControllerProvider).valueOrNull?.role == UserRole.auditor),
                            );
                          },
                        ),
                      ),
              ),
            ]),
    );
  }
}
