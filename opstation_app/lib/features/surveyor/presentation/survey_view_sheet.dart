import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:intl/intl.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';

/// Read-only view of a shop's latest survey: Placement Audit (✓ / ✗ per
/// product) and Competitor Spotting (brand, price, specs per category), with
/// when and by whom. Opened from the survey lists and from "Surveyed shops".
class SurveyViewSheet {
  static Future<void> show(BuildContext context, CustomersData shop) {
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
        builder: (ctx, scroll) => _SurveyView(shop: shop, scroll: scroll),
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
  const _SurveyView({required this.shop, required this.scroll});
  @override
  ConsumerState<_SurveyView> createState() => _SurveyViewState();
}

class _SurveyViewState extends ConsumerState<_SurveyView> {
  late final Future<_Data> _future = _load();
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
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Not audited yet.'))
            else
              for (final p in d.placement)
                ListTile(
                  dense: true,
                  leading: Icon(p.$2 ? Icons.check_circle : Icons.cancel,
                      color: p.$2 ? const Color(0xFF10B981) : const Color(0xFFEF4444)),
                  title: Text(p.$1),
                  trailing: Text(p.$2 ? 'Displayed' : 'Not displayed',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                ),
            const Divider(height: 24),
            _section(
              'Competitor Spotting',
              d.spotting.isEmpty ? '' : (d.spottingBy.isEmpty ? '' : 'Last by ${d.spottingBy}'),
            ),
            if (d.spotting.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('No competitor spotted yet.'))
            else
              for (final s in d.spotting)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.flag_outlined),
                  title: Text('${s.$1}: ${s.$2}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    if (s.$3 != null) 'Rs ${NumberFormat.decimalPattern().format(s.$3)}',
                    if (s.$4.trim().isNotEmpty) s.$4.trim(),
                    DateFormat('d MMM yyyy').format(s.$5),
                  ].join(' · ')),
                ),
            const SizedBox(height: 24),
          ],
        ]);
      },
    );
  }
}
