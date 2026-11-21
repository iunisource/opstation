/// The overall placement score of each SKU, worked out from the Placement Audit grid (the latest audit of
/// each shop for each SKU). Pure logic, so the scorecard report and its tests share one set of rules.

/// How a score reads: 80% and over is strong, 50-79% average, under 50% weak; [none] when the SKU has not
/// been audited in any of the shops. Bands follow the whole-number score that is printed, so a score shown
/// as 80% is never coloured as 79%.
enum ScoreBand { strong, average, weak, none }

ScoreBand scoreBand(double? pct) {
  if (pct == null) return ScoreBand.none;
  final r = pct.round();
  if (r >= 80) return ScoreBand.strong;
  if (r >= 50) return ScoreBand.average;
  return ScoreBand.weak;
}

/// One SKU: in how many shops it is displayed, not displayed, or was never audited.
class SkuScore {
  const SkuScore({
    required this.productId,
    required this.name,
    required this.code,
    required this.displayed,
    required this.notDisplayed,
    required this.totalShops,
  });

  final String productId;
  final String name;
  final String code;
  final int displayed;
  final int notDisplayed;

  /// The shops in the scope (audited for this SKU or not).
  final int totalShops;

  /// Shops where this SKU was audited.
  int get audited => displayed + notDisplayed;
  int get notAudited => totalShops - audited;

  /// Displayed in audited shops, as a percentage; null when the SKU was never audited.
  double? get score => audited == 0 ? null : displayed / audited * 100;
  ScoreBand get band => scoreBand(score);
}

class PlacementScorecard {
  const PlacementScorecard({required this.skus, required this.shops});

  /// Every SKU of the scope, best placed first; SKUs never audited last.
  final List<SkuScore> skus;

  /// Shops in the scope.
  final int shops;

  List<SkuScore> get withData => [for (final s in skus) if (s.audited > 0) s];
  List<SkuScore> get withoutData => [for (final s in skus) if (s.audited == 0) s];

  int get displayedChecks => skus.fold(0, (a, s) => a + s.displayed);
  int get auditedChecks => skus.fold(0, (a, s) => a + s.audited);

  /// All SKUs together: displayed checks over audited checks.
  double? get overall => auditedChecks == 0 ? null : displayedChecks / auditedChecks * 100;
  ScoreBand get overallBand => scoreBand(overall);

  int count(ScoreBand b) => skus.where((s) => s.band == b).length;

  /// The SKUs that most need attention: lowest scores first (only SKUs that have been audited).
  List<SkuScore> weakest([int n = 5]) {
    final l = [...withData]..sort(_worstFirst);
    return l.take(n).toList();
  }

  /// The best placed SKUs.
  List<SkuScore> strongest([int n = 3]) => withData.take(n).toList();

  static int _worstFirst(SkuScore a, SkuScore b) {
    final c = a.score!.compareTo(b.score!);
    if (c != 0) return c;
    final d = b.audited.compareTo(a.audited); // among equals, the better evidenced first
    return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
}

/// [customers] are the shops in the scope, [products] the SKUs listed, [latest] is customer id -> product id ->
/// the latest audit row (`is_present`); a missing row means "never audited".
///
/// [applies] says whether a SKU applies to a shop (the shop carries its product line). A shop that does not
/// carry a SKU's line is not counted for that SKU at all: not as displayed, not as missing, and not among
/// the shops it should have been audited in. Without it every SKU applies to every shop.
PlacementScorecard buildScorecard({
  required List<Map<String, dynamic>> customers,
  required List<Map<String, dynamic>> products,
  required Map<String, Map<String, Map<String, dynamic>>> latest,
  bool Function(Map<String, dynamic> customer, Map<String, dynamic> product)? applies,
}) {
  final skus = <SkuScore>[];
  final shopsInScope = <String>{};
  for (final p in products) {
    final pid = '${p['id']}';
    var yes = 0, no = 0, applicable = 0;
    for (final c in customers) {
      if (applies != null && !applies(c, p)) continue;
      final cid = '${c['id']}';
      applicable++;
      shopsInScope.add(cid);
      final row = latest[cid]?[pid];
      if (row == null) continue;
      if (row['is_present'] == true) {
        yes++;
      } else {
        no++;
      }
    }
    skus.add(SkuScore(
      productId: pid,
      name: '${p['name'] ?? ''}'.trim(),
      code: '${p['sku_code'] ?? ''}'.trim(),
      displayed: yes,
      notDisplayed: no,
      totalShops: applicable,
    ));
  }
  skus.sort((a, b) {
    final as = a.score, bs = b.score;
    if (as == null && bs == null) return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (as == null) return 1; // never audited: last
    if (bs == null) return -1;
    final c = bs.compareTo(as); // best first
    if (c != 0) return c;
    final d = b.audited.compareTo(a.audited);
    return d != 0 ? d : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return PlacementScorecard(skus: skus, shops: applies == null ? customers.length : shopsInScope.length);
}

/// One section of the "all lines" report: a line's name and its own scorecard.
class ScorecardSection {
  const ScorecardSection(this.name, this.card);

  final String name;
  final PlacementScorecard card;
}

/// The scorecard of each product line, in the lines' order: only lines that have a listed SKU. SKUs with no
/// line come last as "No line". [lines] are (id, name) in display order.
List<ScorecardSection> buildLineSections({
  required List<Map<String, dynamic>> customers,
  required List<Map<String, dynamic>> products,
  required Map<String, Map<String, Map<String, dynamic>>> latest,
  required List<({String id, String name})> lines,
  bool Function(Map<String, dynamic> customer, Map<String, dynamic> product)? applies,
}) {
  final out = <ScorecardSection>[];
  final known = {for (final l in lines) l.id};
  for (final l in lines) {
    final ps = [for (final p in products) if (p['line_id'] == l.id) p];
    if (ps.isEmpty) continue;
    out.add(ScorecardSection(l.name, buildScorecard(customers: customers, products: ps, latest: latest, applies: applies)));
  }
  final rest = [for (final p in products) if (p['line_id'] == null || !known.contains('${p['line_id']}')) p];
  if (rest.isNotEmpty) {
    out.add(ScorecardSection('No line', buildScorecard(customers: customers, products: rest, latest: latest, applies: applies)));
  }
  return out;
}
