import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'product_line_rules.dart';

/// What a bulk change does to one line for the chosen shops.
enum LineChoice { keep, carries, notCarries, groupDefault }

/// Reads and writes product lines. Reading is forgiving: before the database file has been run (or when the
/// tables cannot be read) there are simply no lines, and every screen behaves as it did before.
class ProductLinesRepo {
  ProductLinesRepo._();

  static SupabaseClient get _db => Supabase.instance.client;

  static Future<List<Map<String, dynamic>>> _pageAll(Future<dynamic> Function(int from, int to) page) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; from < 500000; from += 1000) {
      final rows = List<Map<String, dynamic>>.from(await page(from, from + 999));
      out.addAll(rows);
      if (rows.length < 1000) break;
    }
    return out;
  }

  static List<List<T>> _chunks<T>(List<T> l, int n) => [for (var i = 0; i < l.length; i += n) l.sublist(i, i + n > l.length ? l.length : i + n)];

  /// The lines, their groups and every shop's own check / uncheck. Empty rules when there are none.
  static Future<LineRules> loadRules(String orgId) async {
    try {
      final lines = List<Map<String, dynamic>>.from(await _db.from('product_lines').select().eq('org_id', orgId));
      if (lines.isEmpty) return LineRules.empty;
      final groups = await _pageAll((f, t) => _db.from('product_line_groups').select('line_id, group_name').eq('org_id', orgId).range(f, t));
      final overrides = await _pageAll((f, t) => _db.from('customer_product_lines').select('customer_id, line_id, carries').eq('org_id', orgId).range(f, t));
      return LineRules.fromRows(lines: lines, groups: groups, overrides: overrides);
    } catch (_) {
      return LineRules.empty;
    }
  }

  /// The lines and groups, and only this shop's own checks (for the customer screen).
  static Future<LineRules> loadForCustomer(String orgId, String? customerId) async {
    try {
      final lines = List<Map<String, dynamic>>.from(await _db.from('product_lines').select().eq('org_id', orgId));
      if (lines.isEmpty) return LineRules.empty;
      final groups = await _pageAll((f, t) => _db.from('product_line_groups').select('line_id, group_name').eq('org_id', orgId).range(f, t));
      final overrides = customerId == null
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await _db.from('customer_product_lines').select('customer_id, line_id, carries').eq('customer_id', customerId));
      return LineRules.fromRows(lines: lines, groups: groups, overrides: overrides);
    } catch (_) {
      return LineRules.empty;
    }
  }

  /// Rules for the lines page: errors are not hidden there, so a missing database file is explained.
  static Future<LineRules> loadForPage(String orgId) async {
    final lines = List<Map<String, dynamic>>.from(await _db.from('product_lines').select().eq('org_id', orgId));
    final groups = await _pageAll((f, t) => _db.from('product_line_groups').select('line_id, group_name').eq('org_id', orgId).range(f, t));
    return LineRules.fromRows(lines: lines, groups: groups);
  }

  /// SKUs per line (line id -> count); the key '' counts SKUs with no line.
  static Future<Map<String, int>> skuCounts(String orgId) async {
    final rows = await _pageAll((f, t) => _db.from('intelligence_products').select('line_id').eq('org_id', orgId).range(f, t));
    final out = <String, int>{};
    for (final r in rows) {
      final k = '${r['line_id'] ?? ''}';
      out[k] = (out[k] ?? 0) + 1;
    }
    return out;
  }

  /// The customer groups, live: the list kept in Settings plus any group name found on a shop (the way the
  /// Customers screen builds its own list), sorted, each spelled once.
  static Future<List<String>> orgGroups(String orgId) async {
    final seen = <String, String>{};
    void add(String? g) {
      final t = (g ?? '').trim();
      if (t.isNotEmpty) seen.putIfAbsent(groupKey(t), () => t);
    }

    try {
      final row = await _db.from('app_config').select('value').eq('key', 'org.groups').eq('org_id', orgId).maybeSingle();
      final v = row?['value'];
      if (v is String) {
        final d = jsonDecode(v);
        if (d is List) {
          for (final g in d) {
            add('$g');
          }
        }
      }
    } catch (_) {}
    try {
      final rows = await _pageAll((f, t) => _db.from('customers').select('group_name').eq('org_id', orgId).range(f, t));
      for (final r in rows) {
        add(r['group_name'] as String?);
      }
    } catch (_) {}
    final out = seen.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  /// Creates (id null) or updates a line, with the groups it is ticked for. Returns its id.
  static Future<String> saveLine({
    String? id,
    required String orgId,
    required String name,
    required int position,
    required bool appliesToAll,
    required bool isActive,
    required Set<String> groups,
  }) async {
    final data = {
      'org_id': orgId,
      'name': name.trim(),
      'position': position,
      'applies_to_all': appliesToAll,
      'is_active': isActive,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    String lineId;
    if (id == null) {
      final row = await _db.from('product_lines').insert(data).select('id').single();
      lineId = '${row['id']}';
    } else {
      await _db.from('product_lines').update(data).eq('id', id);
      lineId = id;
    }
    await _db.from('product_line_groups').delete().eq('line_id', lineId);
    if (groups.isNotEmpty) {
      await _db.from('product_line_groups').insert([for (final g in groups) {'line_id': lineId, 'org_id': orgId, 'group_name': g}]);
    }
    return lineId;
  }

  static Future<void> setActive(String lineId, bool active) async {
    await _db.from('product_lines').update({'is_active': active, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', lineId);
  }

  /// A line can only be deleted when no SKU belongs to it (its SKUs would otherwise silently apply to every shop).
  static Future<void> deleteLine(String lineId) async {
    final used = await _db.from('intelligence_products').select('id').eq('line_id', lineId).limit(1);
    if ((used as List).isNotEmpty) {
      throw StateError('Move this line\'s SKUs to another line first, or switch the line off instead.');
    }
    await _db.from('product_lines').delete().eq('id', lineId);
  }

  /// Replaces a shop's own checks with [overrides] (line id -> carries). Empty = the shop follows its group.
  static Future<void> saveCustomerOverrides(String customerId, String orgId, Map<String, bool> overrides) async {
    await _db.from('customer_product_lines').delete().eq('customer_id', customerId);
    if (overrides.isEmpty) return;
    await _db.from('customer_product_lines').insert([
      for (final e in overrides.entries) {'customer_id': customerId, 'line_id': e.key, 'org_id': orgId, 'carries': e.value},
    ]);
  }

  /// Applies [choices] (line id -> what to do) to many shops at once.
  static Future<void> bulkSet({required String orgId, required List<String> customerIds, required Map<String, LineChoice> choices}) async {
    for (final e in choices.entries) {
      if (e.value == LineChoice.keep) continue;
      for (final chunk in _chunks(customerIds, 200)) {
        if (e.value == LineChoice.groupDefault) {
          await _db.from('customer_product_lines').delete().eq('line_id', e.key).inFilter('customer_id', chunk);
        } else {
          await _db.from('customer_product_lines').upsert([
            for (final cid in chunk)
              {
                'customer_id': cid,
                'line_id': e.key,
                'org_id': orgId,
                'carries': e.value == LineChoice.carries,
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              },
          ], onConflict: 'customer_id,line_id');
        }
      }
    }
  }
}
