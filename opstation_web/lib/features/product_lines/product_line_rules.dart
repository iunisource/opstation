/// Product lines: which shops carry which line of SKUs (Lights, PVC, ...). Pure logic, shared by every screen
/// and report so they all agree.
///
/// A shop carries a line when:
///   1. the shop has its own check / uncheck for that line, else
///   2. the line is "applies to all shops", or is ticked for the shop's group.
/// A line that is switched off is carried by nobody. A SKU with no line (or when no lines exist yet) applies
/// to every shop, as before.

/// Group names are typed text on each customer, so they are matched ignoring case and spaces at the ends.
String groupKey(String? g) => (g ?? '').trim().toLowerCase();

class ProductLine {
  const ProductLine({
    required this.id,
    required this.name,
    this.position = 0,
    this.isActive = true,
    this.appliesToAll = false,
    this.groups = const {},
  });

  final String id;
  final String name;
  final int position;
  final bool isActive;

  /// Carried by every shop (including shops with no group), unless a shop says otherwise.
  final bool appliesToAll;

  /// The customer groups this line is ticked for (names as stored).
  final Set<String> groups;

  ProductLine copyWith({Set<String>? groups}) => ProductLine(
        id: id,
        name: name,
        position: position,
        isActive: isActive,
        appliesToAll: appliesToAll,
        groups: groups ?? this.groups,
      );
}

class LineRules {
  const LineRules(this.lines, [this.overrides = const {}]);

  /// Everything applies to everyone: no lines exist yet (or they could not be loaded).
  static const empty = LineRules([]);

  /// Builds the rules from the database rows of the three tables.
  factory LineRules.fromRows({
    required List<Map<String, dynamic>> lines,
    List<Map<String, dynamic>> groups = const [],
    List<Map<String, dynamic>> overrides = const [],
  }) {
    final byLine = <String, Set<String>>{};
    for (final g in groups) {
      final name = '${g['group_name'] ?? ''}'.trim();
      if (name.isNotEmpty) byLine.putIfAbsent('${g['line_id']}', () => {}).add(name);
    }
    final ls = [
      for (final r in lines)
        ProductLine(
          id: '${r['id']}',
          name: '${r['name'] ?? ''}'.trim(),
          position: (r['position'] as num?)?.toInt() ?? 0,
          isActive: r['is_active'] != false,
          appliesToAll: r['applies_to_all'] == true,
          groups: byLine['${r['id']}'] ?? const {},
        ),
    ]..sort((a, b) {
        final c = a.position.compareTo(b.position);
        return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final ov = <String, Map<String, bool>>{};
    for (final o in overrides) {
      ov.putIfAbsent('${o['customer_id']}', () => {})['${o['line_id']}'] = o['carries'] == true;
    }
    return LineRules(ls, ov);
  }

  final List<ProductLine> lines;

  /// customer id -> line id -> carries
  final Map<String, Map<String, bool>> overrides;

  bool get isEmpty => lines.isEmpty;

  List<ProductLine> get activeLines => [for (final l in lines) if (l.isActive) l];

  ProductLine? byId(String? id) {
    if (id == null) return null;
    for (final l in lines) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// What a shop in [group] carries with no check / uncheck of its own.
  bool defaultCarries(ProductLine line, String? group) {
    if (!line.isActive) return false;
    if (line.appliesToAll) return true;
    final k = groupKey(group);
    if (k.isEmpty) return false;
    for (final g in line.groups) {
      if (groupKey(g) == k) return true;
    }
    return false;
  }

  bool hasOverride(String customerId, String lineId) => overrides[customerId]?.containsKey(lineId) ?? false;

  /// Does this shop carry this line?
  bool carries(String customerId, String? group, String lineId) {
    final line = byId(lineId);
    if (line == null) return true; // an unknown line never hides a SKU
    if (!line.isActive) return false;
    final own = overrides[customerId]?[lineId];
    return own ?? defaultCarries(line, group);
  }

  /// Does a SKU of [lineId] apply to this shop? A SKU with no line applies everywhere.
  bool applies(String customerId, String? group, String? lineId) {
    if (isEmpty || lineId == null || lineId.isEmpty) return true;
    return carries(customerId, group, lineId);
  }

  /// The lines this shop carries, in order.
  List<ProductLine> linesOf(String customerId, String? group) => [
        for (final l in lines)
          if (carries(customerId, group, l.id)) l,
      ];

  /// What to store for a shop whose checks on the screen are [checked] (line id -> ticked): only the lines
  /// that differ from what its group gives it.
  Map<String, bool> overridesFor(String? group, Map<String, bool> checked) => {
        for (final e in checked.entries)
          if (byId(e.key) != null && byId(e.key)!.isActive && e.value != defaultCarries(byId(e.key)!, group)) e.key: e.value,
      };
}

/// A shop that bought SKUs of a line it does not carry (Auto Pilot saw the sales).
class SalesOutsideLine {
  const SalesOutsideLine(this.line, this.customerIds);

  final ProductLine line;
  final List<String> customerIds;
}

/// From Auto Pilot's invoice rows: the shops that bought a line's SKUs but do not carry that line, per line.
/// [lineOfProduct] is SKU id -> line id; [groupOf] is customer id -> group.
List<SalesOutsideLine> salesOutsideLines({
  required List<Map<String, dynamic>> autoRows,
  required LineRules rules,
  required Map<String, String?> lineOfProduct,
  required Map<String, String?> groupOf,
}) {
  final hits = <String, Set<String>>{};
  for (final r in autoRows) {
    if (r['is_present'] != true) continue;
    final cid = '${r['customer_id']}';
    final lineId = lineOfProduct['${r['product_id']}'];
    if (lineId == null) continue;
    final line = rules.byId(lineId);
    if (line == null || !line.isActive) continue;
    if (!groupOf.containsKey(cid)) continue; // a shop that is not in the customer list (inactive, removed)
    if (!rules.carries(cid, groupOf[cid], lineId)) hits.putIfAbsent(lineId, () => {}).add(cid);
  }
  return [
    for (final l in rules.lines)
      if (hits[l.id] != null) SalesOutsideLine(l, hits[l.id]!.toList()..sort()),
  ];
}
