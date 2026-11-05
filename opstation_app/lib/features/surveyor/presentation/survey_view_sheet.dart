import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import 'survey_audit_screen.dart' show fixStatusText, fixStatusColor;
import '../services/survey_audit_service.dart';
import '../services/survey_feedback.dart';

/// Read-only view of a shop's latest survey: Placement Audit (✓ / ✗ per
/// product) and Competitor Spotting (brand, price, specs per category), with
/// when and by whom. Opened from the survey lists and from "Surveyed shops".
class SurveyViewSheet {
  /// [showFeedback]: adds a "Feedback" button (auditors, from Surveyed shops).
  static Future<void> show(BuildContext context, CustomersData shop, {bool showFeedback = false}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => _SurveyView(shop: shop, scroll: scroll, showFeedback: showFeedback),
      ),
    );
  }
}

class _Data {
  final List<(String name, bool shown)> placement;
  final DateTime? placementAt;
  final String placementBy;
  final List<(String cat, String brand, int? price, String specs, DateTime at)> spotting;
  final String spottingBy;
  const _Data(this.placement, this.placementAt, this.placementBy, this.spotting, this.spottingBy);
}

class _SurveyView extends ConsumerStatefulWidget {
  final CustomersData shop;
  final ScrollController scroll;
  final bool showFeedback;
  const _SurveyView({required this.shop, required this.scroll, this.showFeedback = false});
  @override
  ConsumerState<_SurveyView> createState() => _SurveyViewState();
}

class _SurveyViewState extends ConsumerState<_SurveyView> {
  late final Future<_Data> _future = _load();
  late Future<List<Map<String, dynamic>>> _audits = _loadAudits();

  /// This shop's audits (server + any still waiting on this phone).
  Future<List<Map<String, dynamic>>> _loadAudits() async {
    final orgId = widget.shop.orgId;
    final svc = SurveyAuditService(ref.read(appDatabaseProvider));
    final server = orgId == null ? <Map<String, dynamic>>[] : await svc.fetchShop(orgId, widget.shop.id);
    final queued = [for (final q in await svc.queued()) if (q['customer_id'] == widget.shop.id) {...q, '_pending': true}];
    final all = <String, Map<String, dynamic>>{
      for (final a in server) '${a['id']}': a,
      for (final a in queued) '${a['id']}': a,
    };
    return all.values.toList()..sort((a, b) => '${b['audited_at']}'.compareTo('${a['audited_at']}'));
  }

  Widget _auditTile(Map<String, dynamic> a) {
    final r = '${a['result']}';
    final color = r == 'issue' ? const Color(0xFFDC2626) : (r == 'feedback' ? const Color(0xFF2563EB) : const Color(0xFF059669));
    final at = DateTime.tryParse('${a['audited_at'] ?? ''}')?.toLocal();
    final outside = a['location_status'] != null && a['location_status'] != 'inside';
    final corr = a['corrections'] is List ? a['corrections'] as List : const [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(r == 'issue' ? Icons.error_outline : (r == 'feedback' ? Icons.chat_bubble_outline : Icons.verified_outlined),
              size: 18, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${r == 'issue' ? 'Issue found' : (r == 'feedback' ? 'Feedback' : 'Matches survey')} · ${a['auditor_name'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ]),
        Text(
          [
            if (at != null) _df.format(at),
            if (outside && (ref.watch(auditLocationOnProvider).valueOrNull ?? true)) 'away from the shop',
            if (a['_pending'] == true) 'not sent yet',
          ].join(' · '),
          style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
        ),
        if ('${a['comment'] ?? ''}'.trim().isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('${a['comment']}')),
        for (final c in corr)
          if (c is Map)
            Text('• ${c['type'] == 'placement' ? c['product'] : c['category']}: ${c['from'] ?? '—'} → ${c['to'] ?? '—'}',
                style: const TextStyle(fontSize: 12.5)),
        if (fixStatusText(a).isNotEmpty)
          Text(fixStatusText(a), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fixStatusColor(a))),
        if ((a['photo_path'] ?? a['local_photo']) != null)
          TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => showFeedbackPhoto(context, a),
            icon: const Icon(Icons.photo_outlined, size: 16),
            label: const Text('View photo'),
          ),
      ]),
    );
  }
  final _df = DateFormat('d MMM yyyy, h:mm a');

  Future<_Data> _load() async {
    final db = ref.read(appDatabaseProvider);
    final cid = widget.shop.id;
    final users = {for (final u in await db.select(db.users).get()) u.id: u.name};

    // Placement: latest row per product; only active products, in their order.
    final products = await (db.select(db.products)
          ..where((p) => p.isActive.equals(true))
          ..orderBy([(p) => OrderingTerm.asc(p.position), (p) => OrderingTerm.asc(p.name)]))
        .get();
    final audits = await (db.select(db.placementAudits)
          ..where((a) => a.customerId.equals(cid))
          ..orderBy([(a) => OrderingTerm.desc(a.surveyedAt)]))
        .get();
    final latest = <String, PlacementAuditRow>{};
    for (final a in audits) {
      latest.putIfAbsent(a.productId, () => a);
    }
    final placement = <(String, bool)>[];
    DateTime? pAt;
    String? pBy;
    for (final p in products.where((p) => p.orgId == widget.shop.orgId || widget.shop.orgId == null)) {
      final a = latest[p.id];
      if (a == null) continue;
      placement.add((p.name, a.isPresent));
      if (pAt == null || a.surveyedAt.isAfter(pAt)) {
        pAt = a.surveyedAt;
        pBy = users[a.surveyedByUserId];
      }
    }

    // Competitor spotting: latest per category.
    final cats = await (db.select(db.competitorCategories)
          ..orderBy([(c) => OrderingTerm.asc(c.position), (c) => OrderingTerm.asc(c.name)]))
        .get();
    final spots = await (db.select(db.competitorSpottings)
          ..where((s) => s.customerId.equals(cid))
          ..orderBy([(s) => OrderingTerm.desc(s.surveyedAt)]))
        .get();
    final byCat = <String, CompetitorSpottingRow>{};
    for (final s in spots) {
      byCat.putIfAbsent(s.categoryId, () => s);
    }
    final spotting = <(String, String, int?, String, DateTime)>[];
    DateTime? sAt;
    String? sBy;
    for (final c in cats.where((c) => c.orgId == widget.shop.orgId || widget.shop.orgId == null)) {
      final s = byCat[c.id];
      if (s == null) continue;
      spotting.add((c.name, s.brandName, s.price, s.specs ?? '', s.surveyedAt));
      if (sAt == null || s.surveyedAt.isAfter(sAt)) {
        sAt = s.surveyedAt;
        sBy = users[s.surveyedByUserId];
      }
    }
    return _Data(placement, pAt, pBy ?? '', spotting, sBy ?? '');
  }

  Widget _section(String title, String sub) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          if (sub.isNotEmpty)
            Text(sub, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Data>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        return ListView(controller: widget.scroll, children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(children: [
              const Icon(Icons.store_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.shop.shopName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  Text(widget.shop.code, style: TextStyle(color: Theme.of(context).hintColor)),
                ]),
              ),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
          ),
          if (d == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else ...[
            _section(
              'Placement Audit',
              d.placement.isEmpty
                  ? ''
                  : '${d.placement.where((p) => p.$2).length} of ${d.placement.length} displayed · '
                      '${d.placementAt == null ? '' : _df.format(d.placementAt!)}'
                      '${d.placementBy.isEmpty ? '' : ' · ${d.placementBy}'}',
            ),
            if (d.placement.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Not surveyed yet.'))
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in d.placement)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: (p.$2 ? const Color(0xFF059669) : const Color(0xFFDC2626)).withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: (p.$2 ? const Color(0xFF059669) : const Color(0xFFDC2626)).withOpacity(0.30)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(p.$2 ? Icons.check : Icons.close,
                            size: 15, color: p.$2 ? const Color(0xFF059669) : const Color(0xFFDC2626)),
                        const SizedBox(width: 4),
                        Text(p.$1, style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                ]),
              ),
            const Divider(height: 24),
            _section(
              'Competitor Spotting',
              d.spotting.isEmpty
                  ? ''
                  : [
                      _df.format(d.spotting.map((s) => s.$5).reduce((a, b) => a.isAfter(b) ? a : b)),
                      if (d.spottingBy.isNotEmpty) d.spottingBy,
                    ].join(' · '),
            ),
            if (d.spotting.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('No competitor spotted yet.'))
            else
              for (final s in d.spotting)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      flex: 4,
                      child: Text(s.$1, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                    ),
                    Expanded(
                      flex: 6,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(
                            child: Text(s.$2, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                          ),
                          if (s.$3 != null) ...[
                            const SizedBox(width: 8),
                            Text('Rs ${NumberFormat.decimalPattern().format(s.$3)}',
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ],
                        ]),
                        if (s.$4.trim().isNotEmpty)
                          Text(s.$4.trim(), style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                      ]),
                    ),
                  ]),
                ),
            const Divider(height: 24),
            _section('Feedback', ''),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _audits,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                }
                final list = snap.data!;
                if (list.isEmpty) {
                  return const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('No feedback yet.'));
                }
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final a in list) _auditTile(a)]);
              },
            ),
            if (widget.showFeedback)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Feedback'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: () async {
                      final ok = await giveFeedback(context, ref, widget.shop);
                      if (ok && mounted) setState(() => _audits = _loadAudits());
                    },
                  ),
                ),
              ),
            const SizedBox(height: 24),
          ],
        ]);
      },
    );
  }
}
