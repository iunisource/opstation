import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/database/app_database.dart';

/// Product lines on the phone: which shops carry which line of SKUs (Lights, PVC, ...), so a surveyor is only
/// asked about the SKUs the shop in front of them carries. The same rule as the web:
///   1. a shop's own check / uncheck of a line wins, else
///   2. the line is "applies to all shops", or is ticked for the shop's group.
/// A switched-off line is carried by nobody. A SKU with no line (or no lines at all) applies to every shop.

/// Group names are typed text on each customer: matched ignoring case and spaces at the ends.
String groupKey(String? g) => (g ?? '').trim().toLowerCase();

class ProductLine {
  const ProductLine({required this.id, required this.name, this.position = 0, this.isActive = true, this.appliesToAll = false, this.groups = const {}});

  final String id;
  final String name;
  final int position;
  final bool isActive;
  final bool appliesToAll;
  final Set<String> groups;
}

class LineRules {
  const LineRules(this.lines, [this.overrides = const {}]);

  static const empty = LineRules([]);

  final List<ProductLine> lines;

  /// customer id -> line id -> carries
  final Map<String, Map<String, bool>> overrides;

  bool get isEmpty => lines.isEmpty;

  ProductLine? byId(String? id) {
    if (id == null) return null;
    for (final l in lines) {
      if (l.id == id) return l;
    }
    return null;
  }

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

  bool carries(String customerId, String? group, String lineId) {
    final line = byId(lineId);
    if (line == null) return true; // an unknown line never hides a SKU
    if (!line.isActive) return false;
    return overrides[customerId]?[lineId] ?? defaultCarries(line, group);
  }

  bool applies(String customerId, String? group, String? lineId) {
    if (isEmpty || lineId == null || lineId.isEmpty) return true;
    return carries(customerId, group, lineId);
  }

  List<ProductLine> linesOf(String customerId, String? group) => [
        for (final l in lines)
          if (carries(customerId, group, l.id)) l,
      ];
}

/// The rules plus the line of each SKU: what the phone keeps.
class SurveyLines {
  const SurveyLines(this.rules, this.skuLine);

  static const empty = SurveyLines(LineRules.empty, {});

  final LineRules rules;

  /// SKU id -> its line id (null = no line)
  final Map<String, String?> skuLine;

  bool get isEmpty => rules.isEmpty;

  /// Does this SKU apply to this shop?
  bool applies(String customerId, String? group, String productId) => rules.applies(customerId, group, skuLine[productId]);

  /// The items (SKUs) that apply to this shop, in their order.
  List<T> forShop<T>(List<T> items, String customerId, String? group, String Function(T) idOf) =>
      isEmpty ? items : [for (final i in items) if (applies(customerId, group, idOf(i))) i];

  /// "Lights - PVC": the lines this shop carries (empty when there are no lines).
  String describe(String customerId, String? group) =>
      isEmpty ? '' : rules.linesOf(customerId, group).map((l) => l.name).join('  \u00B7  ');

  Map<String, dynamic> toJson() => {
        'v': 1,
        'lines': [
          for (final l in rules.lines) {'id': l.id, 'name': l.name, 'pos': l.position, 'on': l.isActive, 'all': l.appliesToAll, 'groups': l.groups.toList()},
        ],
        'sku': {for (final e in skuLine.entries) if (e.value != null) e.key: e.value},
        'ov': {
          for (final c in rules.overrides.entries) c.key: {for (final l in c.value.entries) l.key: l.value ? 1 : 0},
        },
      };

  factory SurveyLines.fromJson(Map<String, dynamic> j) {
    final lines = <ProductLine>[
      for (final l in (j['lines'] as List? ?? const []))
        ProductLine(
          id: '${(l as Map)['id']}',
          name: '${l['name'] ?? ''}',
          position: (l['pos'] as num?)?.toInt() ?? 0,
          isActive: l['on'] != false,
          appliesToAll: l['all'] == true,
          groups: {for (final g in (l['groups'] as List? ?? const [])) '$g'},
        ),
    ];
    final ov = <String, Map<String, bool>>{};
    (j['ov'] as Map? ?? const {}).forEach((c, m) {
      ov['$c'] = {for (final e in (m as Map).entries) '${e.key}': e.value == 1 || e.value == true};
    });
    return SurveyLines(LineRules(lines, ov), {for (final e in (j['sku'] as Map? ?? const {}).entries) '${e.key}': e.value as String?});
  }

  /// Builds what the phone keeps from the server's rows.
  factory SurveyLines.fromRows({
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> groups,
    required List<Map<String, dynamic>> overrides,
    required List<Map<String, dynamic>> skus,
  }) {
    final byLine = <String, Set<String>>{};
    for (final g in groups) {
      final n = '${g['group_name'] ?? ''}'.trim();
      if (n.isNotEmpty) byLine.putIfAbsent('${g['line_id']}', () => {}).add(n);
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
    return SurveyLines(LineRules(ls, ov), {for (final s in skus) '${s['id']}': s['line_id'] as String?});
  }
}

/// Keeps the lines on the phone (in the phone's settings store) and refreshes them from the server.
class ProductLinesStore {
  ProductLinesStore._();

  static const _key = 'product_lines.v1';

  /// What this phone has: nothing (every SKU applies to every shop) until the first refresh finds lines.
  static Future<SurveyLines> load(AppDatabase db) async {
    try {
      final raw = await db.getConfig(_key);
      if (raw == null || raw.isEmpty) return SurveyLines.empty;
      return SurveyLines.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return SurveyLines.empty;
    }
  }

  static Future<void> save(AppDatabase db, SurveyLines data) => db.setConfig(_key, jsonEncode(data.toJson()));

  static Future<List<Map<String, dynamic>>> _all(Future<dynamic> Function(int from, int to) page) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; from < 500000; from += 1000) {
      final rows = List<Map<String, dynamic>>.from(await page(from, from + 999) as List);
      out.addAll(rows);
      if (rows.length < 1000) break;
    }
    return out;
  }

  /// Downloads the lines, their groups, the shops' own checks and each SKU's line. Best effort: offline, or
  /// before the lines exist on the server, the phone keeps what it had. Returns whether it is now up to date.
  static Future<bool> refresh(AppDatabase db, String orgId) async {
    try {
      final c = Supabase.instance.client;
      final lines = List<Map<String, dynamic>>.from(await c.from('product_lines').select().eq('org_id', orgId) as List);
      if (lines.isEmpty) {
        await save(db, SurveyLines.empty);
        return true;
      }
      final groups = await _all((f, t) => c.from('product_line_groups').select('line_id, group_name').eq('org_id', orgId).order('line_id').range(f, t));
      final overrides = await _all((f, t) => c.from('customer_product_lines').select('customer_id, line_id, carries').eq('org_id', orgId).order('customer_id').range(f, t));
      final skus = await _all((f, t) => c.from('intelligence_products').select('id, line_id').eq('org_id', orgId).order('id').range(f, t));
      await save(db, SurveyLines.fromRows(lines: lines, groups: groups, overrides: overrides, skus: skus));
      return true;
    } catch (_) {
      return false;
    }
  }
}
