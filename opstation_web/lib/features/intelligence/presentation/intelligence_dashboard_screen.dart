// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/widgets/responsive.dart';

/// Intelligence Dashboard — placement score by salesman and by market (route).
///
/// Placement score = SKUs present ÷ SKUs audited, using the LATEST audit per
/// shop-SKU pair (so the dashboard reflects the current state of the market),
/// summed across all customers in the group. An optional date range restricts
/// which audits are considered (latest within the range).
///
/// Attribution: a customer belongs to the route(s) that carry it
/// (route_stops); a route's score rolls up to the salesperson(s) assigned to
/// it (route_assignments). Customers on no route land in "Unassigned".
class IntelligenceDashboardScreen extends ConsumerStatefulWidget {
  const IntelligenceDashboardScreen({super.key});
  @override
  ConsumerState<IntelligenceDashboardScreen> createState() =>
      _IntelligenceDashboardScreenState();
}

class _GroupScore {
  final String name;
  final Set<String> customers = {};
  int present = 0;
  int total = 0;
  _GroupScore(this.name);
  double get score => total == 0 ? 0 : present / total;
}

/// One SKU's on-shelf rate across the shops where it was checked.
class _SkuStat {
  final String name;
  final int present;
  final int shops;
  _SkuStat(this.name, this.present, this.shops);
  double get rate => shops == 0 ? 0 : present / shops;
}

// ── Fuzzy brand-name clustering ──────────────────────────────────────────────
// Competitor spottings are typed by hand in the field, so the same brand shows
// up spelled several ways ("Excel", "Excal", "Philips", "Phillips"). Counting
// those as separate brands inflates the competitor list and splits a category
// leader's shops across near-duplicate rows. We merge names that differ by only
// a character or two (edit distance, length-aware) into one cluster.

/// Normalised comparison key: lowercase, alphanumerics only, single-spaced.
String _brandKey(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final prev = List<int>.generate(b.length + 1, (i) => i);
  final cur = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    cur[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      final del = prev[j + 1] + 1;
      final ins = cur[j] + 1;
      final sub = prev[j] + cost;
      cur[j + 1] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    for (var k = 0; k <= b.length; k++) {
      prev[k] = cur[k];
    }
  }
  return prev[b.length];
}

/// Two normalised names count as the same brand when they're within a
/// length-aware edit distance (1 for short names, 2 for longer ones). This
/// catches typos like Excel/Excal without merging genuinely different brands
/// like Osaka/Osram (distance 3).
bool _sameBrand(String ka, String kb) {
  if (ka == kb) return true;
  final shorter = ka.length < kb.length ? ka.length : kb.length;
  if (shorter <= 2) return false; // too short to fuzz safely
  final allowed = shorter <= 8 ? 1 : 2;
  if ((ka.length - kb.length).abs() > allowed) return false;
  return _levenshtein(ka, kb) <= allowed;
}

/// Collapse a brand→shops map into fuzzy clusters. Returns display-name→shops
/// where the display name is the cluster's most-common original spelling.
/// Shop sets are unioned so each shop is counted once per cluster.
List<MapEntry<String, Set<String>>> _clusterBrands(
    Map<String, Set<String>> raw) {
  // Seed clusters largest-first so the dominant spelling anchors each cluster.
  final entries = raw.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  final clusters = <_BrandCluster>[];
  for (final e in entries) {
    final key = _brandKey(e.key);
    if (key.isEmpty) continue;
    _BrandCluster? hit;
    for (final c in clusters) {
      if (_sameBrand(c.key, key)) {
        hit = c;
        break;
      }
    }
    if (hit == null) {
      clusters.add(_BrandCluster(key, e.key, Set<String>.from(e.value)));
    } else {
      hit.shops.addAll(e.value);
      hit.consider(e.key, e.value.length);
    }
  }
  return clusters
      .map((c) => MapEntry(c.display, c.shops))
      .toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
}

class _BrandCluster {
  final String key; // normalised anchor
  String display; // best original spelling seen
  int _bestCount;
  final Set<String> shops;
  _BrandCluster(this.key, this.display, this.shops) : _bestCount = shops.length;
  void consider(String original, int count) {
    if (count > _bestCount) {
      _bestCount = count;
      display = original;
    }
  }
}

class _IntelligenceDashboardScreenState
    extends ConsumerState<IntelligenceDashboardScreen> {
  bool _loading = true;
  String? _error;
  DateTime? _from;
  DateTime? _to;
  String _range = 'all'; // all | today | 7d | 30d | custom

  // Aggregates
  int _shopsAudited = 0;
  int _skusTracked = 0; // distinct SKUs seen in audits
  int _skuPresent = 0; // shop-SKU checks found on shelf
  int _skuTotal = 0; // shop-SKU checks performed
  List<_GroupScore> _bySalesman = [];
  List<_GroupScore> _byRoute = [];

  // Trend state: full audit history + scoping maps kept for the trend chart.
  List<Map<String, dynamic>> _allAudits = [];
  Map<String, String> _routeNames = {};
  Map<String, Set<String>> _custRoutes = {};
  String _trendScope = 'org'; // org | route | customer
  String? _trendRouteId;
  String? _trendCustomerId;
  String _trendCustomerLabel = '';
  List<Map<String, dynamic>> _trendCustomers = []; // lazy: id, shop_name, code
  final _trendCustSearchCtrl = TextEditingController();
  bool _trendCustPicking = false;

  // Shop names for expanding the "Unassigned" rows, and which rows are open.
  Map<String, String> _custName = {};
  final Set<String> _expandedGroups = {};

  // Shop code, and per-shop missing SKUs (latest check not on shelf) + how many
  // SKUs were checked there — feeds the task sheet's per-shop targets page.
  Map<String, String> _custCode = {};
  Map<String, List<String>> _custMissing = {};
  Map<String, int> _custChecks = {};

  // Section-wide market/route filter. null = All routes.
  String? _filterRouteId;

  // Auto-insights (narrative), computed each load from the same period's data.
  List<_SkuStat> _skuStats = [];          // sorted best-placed first
  String? _leadBrand;                     // most-spotted competitor overall
  int _leadBrandShops = 0;
  List<MapEntry<String, String>> _catLeaders = []; // category name -> top brand

  // Routes that actually carry audited shops in this period (id -> name), for
  // the searchable market picker. Filter-independent (whole audited set).
  Map<String, String> _routesWithData = {};

  // Company-wide placement average, computed ignoring the route filter, so a
  // route report can compare its salesperson against the whole company.
  double _orgAvgScore = 0;

  // Total audited shops per route in this period (route id -> shop count),
  // filter-independent — drives the task sheet's coverage lines.
  Map<String, int> _routeShopCount = {};

  final _pct = NumberFormat('#,##0.0');
  final _int = NumberFormat('#,##0');

  @override
  void dispose() {
    _trendCustSearchCtrl.dispose();
    super.dispose();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;

      // ── 1. Fetch everything for this period concurrently ────────────────
      // These queries are independent, so awaiting them one-by-one was the main
      // reason the dashboard felt slow. Fire them together; the helper paginates
      // past the 1000-row PostgREST cap.
      Future<List<Map<String, dynamic>>> pageAll(
          dynamic Function(int from, int to) build) async {
        final out = <Map<String, dynamic>>[];
        for (int from = 0;; from += 1000) {
          final page = await build(from, from + 999);
          final list = List<Map<String, dynamic>>.from(page as List);
          out.addAll(list);
          if (list.length < 1000 || from > 500000) break;
        }
        return out;
      }

      final res = await Future.wait<dynamic>([
        pageAll((f, t) => client
            .from('placement_audit')
            .select('customer_id, product_id, is_present, surveyed_at')
            .eq('org_id', orgId)
            .range(f, t)),
        client.from('sales_routes').select('id, name').eq('org_id', orgId),
        pageAll((f, t) => client.from('route_stops').select('route_id, customer_id').range(f, t)),
        pageAll((f, t) => client.from('route_assignments').select('user_id, route_id').range(f, t)),
        client.from('users').select('id, name').eq('org_id', orgId),
        pageAll((f, t) => client.from('customers').select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true).range(f, t)),
        pageAll((f, t) => client.from('intelligence_products').select('id, name').eq('org_id', orgId).range(f, t)),
        pageAll((f, t) => client
            .from('competitor_spotting')
            .select('customer_id, category_id, brand_name, surveyed_at')
            .eq('org_id', orgId)
            .range(f, t)),
        client.from('competitor_categories').select('id, name').eq('org_id', orgId),
        client.from('competitor_brand_aliases').select('alias, canonical').eq('org_id', orgId),
      ]);
      final audits = List<Map<String, dynamic>>.from(res[0] as List);
      final routesRaw = res[1] as List;
      final stopsRaw = res[2] as List;
      final assignsRaw = res[3] as List;
      final usersRaw = res[4] as List;
      final custRaw = res[5] as List;
      final prodRaw = res[6] as List; // intelligence_products (the audited SKUs)
      final compRaw = List<Map<String, dynamic>>.from(res[7] as List);
      final catRaw = res[8] as List;
      // Brand alias map (lowercased/trimmed variant -> correct brand). Applied
      // to every spotting's brand before it is tallied, so typos roll up under
      // the correct name (and with the correct label, not just merged).
      final brandAlias = <String, String>{
        for (final a in (res[9] as List))
          (a['alias'] as String? ?? '').toLowerCase().trim():
              (a['canonical'] as String? ?? '')
      };
      String canonBrand(String b) {
        final c = brandAlias[b.toLowerCase().trim()];
        return (c == null || c.isEmpty) ? b : c;
      }

      // Optional date-range restriction (then latest-per-pair within it).
      Iterable<Map<String, dynamic>> rows = audits;
      if (_from != null || _to != null) {
        final fromD = _from;
        final toD = _to?.add(const Duration(days: 1));
        rows = audits.where((a) {
          final d = DateTime.tryParse('${a['surveyed_at']}');
          if (d == null) return false;
          if (fromD != null && d.isBefore(fromD)) return false;
          if (toD != null && !d.isBefore(toD)) return false;
          return true;
        });
      }

      // ── 2. Latest audit per (customer, product) ─────────────────────────
      final latest = <String, Map<String, dynamic>>{}; // key -> row
      for (final a in rows) {
        final key = '${a['customer_id']}|${a['product_id']}';
        final prev = latest[key];
        if (prev == null ||
            '${a['surveyed_at']}'.compareTo('${prev['surveyed_at']}') > 0) {
          latest[key] = a;
        }
      }

      // Per-customer tallies.
      final custPresent = <String, int>{};
      final custTotal = <String, int>{};
      for (final a in latest.values) {
        final cid = a['customer_id'] as String;
        custTotal[cid] = (custTotal[cid] ?? 0) + 1;
        if (a['is_present'] == true) {
          custPresent[cid] = (custPresent[cid] ?? 0) + 1;
        }
      }
      final auditedCustomers = custTotal.keys.toSet();

      // ── 3. Route / salesman attribution (from the parallel fetch) ───────
      final routeName = {
        for (final r in routesRaw)
          r['id'] as String: (r['name'] as String? ?? '(route)')
      };
      // customer -> routes (only routes belonging to this org)
      final custRoutes = <String, Set<String>>{};
      for (final s in stopsRaw) {
        final rid = s['route_id'] as String?;
        final cid = s['customer_id'] as String?;
        if (rid == null || cid == null) continue;
        if (!routeName.containsKey(rid)) continue;
        (custRoutes[cid] ??= {}).add(rid);
      }
      final routeUsers = <String, Set<String>>{};
      for (final a in assignsRaw) {
        final rid = a['route_id'] as String?;
        final uid = a['user_id'] as String?;
        if (rid == null || uid == null) continue;
        if (!routeName.containsKey(rid)) continue;
        (routeUsers[rid] ??= {}).add(uid);
      }

      // ── Filter-independent rollups (ignore the current route filter) ─────
      // Company placement average across every audited shop, and the set of
      // routes that actually carry audited shops (for the market picker), with
      // each route's audited-shop count (for the task sheet).
      int orgPresent = 0, orgTotal = 0;
      final routesWithData = <String, String>{};
      final routeShopCount = <String, int>{};
      for (final cid in auditedCustomers) {
        orgPresent += custPresent[cid] ?? 0;
        orgTotal += custTotal[cid] ?? 0;
        for (final rid in (custRoutes[cid] ?? const <String>{})) {
          routesWithData[rid] = routeName[rid] ?? '(route)';
          routeShopCount[rid] = (routeShopCount[rid] ?? 0) + 1;
        }
      }
      final orgAvgScore = orgTotal == 0 ? 0.0 : orgPresent / orgTotal;
      final userName = {
        for (final u in usersRaw)
          u['id'] as String: (u['name'] as String? ?? 'Unknown')
      };
      // Shop names, for expanding the "Unassigned" rows.
      final custName = <String, String>{
        for (final c in custRaw)
          c['id'] as String: (c['shop_name'] as String? ?? 'Unnamed shop')
      };
      // SKU names for insight sentences come from intelligence_products — the
      // survey SKU list that placement_audit.product_id references (NOT the main
      // products table, which was the bug that showed every SKU as "SKU").
      final prodName = <String, String>{
        for (final p in prodRaw)
          p['id'] as String: (p['name'] as String? ?? 'Unnamed SKU')
      };
      final catName = {
        for (final c in catRaw)
          c['id'] as String: (c['name'] as String? ?? 'Category')
      };
      // Shop code (surveyor-facing identifier) for the task sheet targets page.
      final custCode = <String, String>{
        for (final c in custRaw)
          c['id'] as String: (c['code'] as String? ?? '')
      };
      // Per-shop missing SKUs = latest check per (shop, SKU) that was NOT on
      // shelf. Names resolved from the survey SKU list; sorted for a clean sheet.
      final custMissing = <String, List<String>>{};
      for (final a in latest.values) {
        if (a['is_present'] == true) continue;
        final cid = a['customer_id'] as String;
        final pid = a['product_id'] as String?;
        (custMissing[cid] ??= []).add(prodName[pid] ?? 'Unnamed SKU');
      }
      for (final l in custMissing.values) {
        l.sort();
      }

      // ── 4. Aggregate ───────────────────────────────────────────────────
      final byRoute = <String, _GroupScore>{};
      final bySalesman = <String, _GroupScore>{};
      _GroupScore routeBucket(String key, String name) =>
          byRoute.putIfAbsent(key, () => _GroupScore(name));
      _GroupScore salesmanBucket(String key, String name) =>
          bySalesman.putIfAbsent(key, () => _GroupScore(name));

      // Section-wide market/route filter: when a route is picked, every stat
      // (KPIs, score cards, SKU insights, competitor read) counts only shops on
      // that route. null = All routes.
      final filterRoute = _filterRouteId;
      bool passesRoute(String? cid) =>
          filterRoute == null ||
          (cid != null && (custRoutes[cid]?.contains(filterRoute) ?? false));

      final shopsInScope = auditedCustomers.where(passesRoute).length;

      int totPresent = 0, totAll = 0;
      for (final cid in auditedCustomers) {
        if (!passesRoute(cid)) continue;
        final p = custPresent[cid] ?? 0;
        final t = custTotal[cid] ?? 0;
        totPresent += p;
        totAll += t;

        final rids = custRoutes[cid];
        if (rids == null || rids.isEmpty) {
          final g = routeBucket('_none', 'No route / Unassigned');
          g.customers.add(cid);
          g.present += p;
          g.total += t;
          final s = salesmanBucket('_none', 'Unassigned');
          s.customers.add(cid);
          s.present += p;
          s.total += t;
          continue;
        }
        final salesmen = <String>{};
        for (final rid in rids) {
          final g = routeBucket(rid, routeName[rid] ?? '(route)');
          g.customers.add(cid);
          g.present += p;
          g.total += t;
          salesmen.addAll(routeUsers[rid] ?? const {});
        }
        if (salesmen.isEmpty) {
          final s = salesmanBucket('_none', 'Unassigned');
          s.customers.add(cid);
          s.present += p;
          s.total += t;
        } else {
          for (final uid in salesmen) {
            final s = salesmanBucket(uid, userName[uid] ?? 'Unknown');
            s.customers.add(cid);
            s.present += p;
            s.total += t;
          }
        }
      }

      List<_GroupScore> sorted(Map<String, _GroupScore> m) {
        final l = m.values.where((g) => g.total > 0).toList()
          ..sort((a, b) => b.score.compareTo(a.score));
        return l;
      }

      final skusTracked = latest.values
          .where((a) => passesRoute(a['customer_id'] as String?))
          .map((a) => a['product_id'] as String?)
          .whereType<String>()
          .toSet()
          .length;

      // ── SKU on-shelf rates (from the same latest-per-pair set) ──────────
      final skuPresent = <String, int>{};
      final skuShops = <String, int>{};
      for (final a in latest.values) {
        final pid = a['product_id'] as String?;
        if (pid == null) continue;
        if (!passesRoute(a['customer_id'] as String?)) continue;
        skuShops[pid] = (skuShops[pid] ?? 0) + 1;
        if (a['is_present'] == true) skuPresent[pid] = (skuPresent[pid] ?? 0) + 1;
      }
      // Only rank SKUs checked in enough shops to be meaningful.
      const kMinShops = 3;
      final skuStats = <_SkuStat>[];
      skuShops.forEach((pid, shops) {
        if (shops < kMinShops) return;
        skuStats.add(_SkuStat(prodName[pid] ?? 'SKU', skuPresent[pid] ?? 0, shops));
      });
      skuStats.sort((a, b) => b.rate.compareTo(a.rate));

      // ── Competitor leaders (same date window) ───────────────────────────
      String? leadBrand;
      int leadBrandShops = 0;
      final catLeaders = <MapEntry<String, String>>[];
      try {
        // Date-filter to match the placement window (compRaw fetched above).
        final fromD = _from;
        final toD = _to?.add(const Duration(days: 1));
        bool inWindow(dynamic ts) {
          if (fromD == null && toD == null) return true;
          final d = DateTime.tryParse('$ts');
          if (d == null) return false;
          if (fromD != null && d.isBefore(fromD)) return false;
          if (toD != null && !d.isBefore(toD)) return false;
          return true;
        }
        final brandShops = <String, Set<String>>{};
        final catBrandShops = <String, Map<String, Set<String>>>{};
        for (final s in compRaw as List) {
          if (!inWindow(s['surveyed_at'])) continue;
          final raw = (s['brand_name'] as String?)?.trim();
          final brand = (raw == null || raw.isEmpty) ? raw : canonBrand(raw);
          final cid = s['customer_id'] as String?;
          final cat = s['category_id'] as String?;
          if (brand == null || brand.isEmpty || cid == null) continue;
          if (!passesRoute(cid)) continue;
          (brandShops[brand] ??= {}).add(cid);
          if (cat != null) {
            ((catBrandShops[cat] ??= {})[brand] ??= {}).add(cid);
          }
        }
        // Fuzzy-merge near-duplicate spellings before ranking, so a typo can't
        // split one brand's shops or pad the list (Excel/Excal count as one).
        for (final entry in _clusterBrands(brandShops)) {
          if (entry.value.length > leadBrandShops) {
            leadBrandShops = entry.value.length;
            leadBrand = entry.key;
          }
        }
        if (catBrandShops.isNotEmpty) {
          catBrandShops.forEach((cat, brands) {
            final merged = _clusterBrands(brands); // sorted, most-shops first
            if (merged.isNotEmpty) {
              catLeaders.add(MapEntry(catName[cat] ?? 'Category', merged.first.key));
            }
          });
          catLeaders.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
        }
      } catch (_) {/* competitor module may be off; insights just skip it */}

      if (!mounted) return;
      setState(() {
        _shopsAudited = shopsInScope;
        _skusTracked = skusTracked;
        _skuPresent = totPresent;
        _skuTotal = totAll;
        _bySalesman = sorted(bySalesman);
        _byRoute = sorted(byRoute);
        _allAudits = audits; // FULL history for the trend (range-independent)
        _routeNames = routeName;
        _custRoutes = custRoutes;
        _custName = custName;
        _custCode = custCode;
        _custMissing = custMissing;
        _custChecks = custTotal;
        _skuStats = skuStats;
        _leadBrand = leadBrand;
        _leadBrandShops = leadBrandShops;
        _catLeaders = catLeaders;
        _routesWithData = routesWithData;
        _orgAvgScore = orgAvgScore;
        _routeShopCount = routeShopCount;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _setRange(String r) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _range = r;
      switch (r) {
        case 'today':
          _from = today;
          _to = today;
          break;
        case '7d':
          _from = today.subtract(const Duration(days: 6));
          _to = today;
          break;
        case '30d':
          _from = today.subtract(const Duration(days: 29));
          _to = today;
          break;
        default: // all
          _from = null;
          _to = null;
      }
    });
    _load();
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: (_from != null && _to != null)
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
    );
    if (picked != null && mounted) {
      setState(() {
        _range = 'custom';
        _from = picked.start;
        _to = picked.end;
      });
      _load();
    }
  }

  double get _overall => _skuTotal == 0 ? 0 : _skuPresent / _skuTotal;

  Color _scoreColor(double s) {
    if (s >= 0.75) return AppTheme.success;
    if (s >= 0.5) return AppTheme.warning;
    return AppTheme.danger;
  }

  void _print() {
    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final period = (_from == null && _to == null)
        ? 'All time (latest audit per shop-SKU)'
        : '${_from != null ? DateFormat('d MMM yy').format(_from!) : '…'} – ${_to != null ? DateFormat('d MMM yy').format(_to!) : '…'}';
    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    String table(String title, List<_GroupScore> rows) {
      final b = StringBuffer();
      b.write('<h2>$title</h2><table><thead><tr><th>#</th><th>Name</th>'
          '<th class="num">Shops</th><th class="num">Found on Shelf</th>'
          '<th class="num">Shelf Checks</th><th class="num">Score</th></tr></thead><tbody>');
      for (var i = 0; i < rows.length; i++) {
        final g = rows[i];
        b.write('<tr><td>${i + 1}</td><td>${esc(g.name)}</td>'
            '<td class="num">${g.customers.length}</td>'
            '<td class="num">${g.present}</td>'
            '<td class="num">${g.total}</td>'
            '<td class="num bold">${_pct.format(g.score * 100)}%</td></tr>');
      }
      b.write('</tbody></table>');
      return b.toString();
    }

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8">'
        '<title>Intelligence Dashboard</title><style>'
        '@page { margin: 0.6cm; } '
        'body { font-family: Arial, sans-serif; padding: 16px; font-size: 11px; color: #000; } '
        'h1 { font-size: 18px; margin: 0 0 4px 0; } '
        'h2 { font-size: 13px; margin: 16px 0 6px 0; } '
        '.info { font-size: 10px; color: #555; margin: 2px 0; } '
        '.kpi { display: inline-block; padding: 6px 12px; border: 1px solid #ddd; border-radius: 6px; margin: 6px 8px 6px 0; } '
        '.kpi b { font-size: 15px; } '
        'table { width: 100%; border-collapse: collapse; } '
        'th, td { padding: 4px 7px; border-bottom: 1px solid #ddd; text-align: left; font-size: 10px; } '
        'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
        '.num { text-align: right; } .bold { font-weight: 800; } '
        '</style></head><body>'
        '<h1>Intelligence Dashboard — Placement Score</h1>'
        '<div class="info"><strong>Period:</strong> ${esc(period)}</div>'
        '<div class="info">Generated: $gen</div>'
        '<div><span class="kpi">Overall Score <b>${_pct.format(_overall * 100)}%</b></span>'
        '<span class="kpi">Shops Audited <b>${_int.format(_shopsAudited)}</b></span>'
        '<span class="kpi">SKUs Tracked <b>${_int.format(_skusTracked)}</b></span>'
        '<span class="kpi">Found on Shelf <b>${_int.format(_skuPresent)}</b></span>'
        '<span class="kpi">Shelf Checks <b>${_int.format(_skuTotal)}</b></span></div>' +
        table('Placement Score — by Salesman', _bySalesman) +
        table('Placement Score — by Market (Route)', _byRoute) +
        '</body></html>';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  // ────────────────────────────────────────────────────────────── build

  @override
  Widget build(BuildContext context) {
    final mobile = context.isMobile;
    return Container(
      color: AppTheme.background,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(mobile ? 16 : 24),
              children: [
                _header(mobile),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.red.shade200)),
                    child: Text(_error!,
                        style:
                            TextStyle(fontSize: 11, color: Colors.red.shade900)),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_skuTotal == 0)
                  Container(
                    margin: const EdgeInsets.only(top: 24),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 48),
                    decoration: _cardDeco,
                    child: Column(children: [
                      Icon(Icons.storefront_outlined,
                          size: 44,
                          color: AppTheme.textSecondary.withOpacity(0.35)),
                      const SizedBox(height: 14),
                      const Text('No placement audits in this period',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      const Text(
                          'Audits appear here as surveyors sync from the field. '
                          'Try a wider date range — or check the organization '
                          'selected in the top bar: this dashboard shows the '
                          'current organization only.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: AppTheme.textSecondary,
                              height: 1.5)),
                      const SizedBox(height: 16),
                      if (_range != 'all')
                        OutlinedButton(
                            onPressed: () => _setRange('all'),
                            child: const Text('Show all time',
                                style: TextStyle(fontSize: 12))),
                    ]),
                  )
                else ...[
                  _heroRow(mobile),
                  const SizedBox(height: 16),
                  _trendCard(mobile),
                  const SizedBox(height: 16),
                  if (mobile) ...[
                    _scoreCard('By Salesman', 'salesmen',
                        Icons.person_outline, _bySalesman, mobile),
                    const SizedBox(height: 16),
                    _scoreCard('By Market (Route)', 'markets',
                        Icons.route_outlined, _byRoute, mobile),
                  ] else
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                          child: _scoreCard('By Salesman', 'salesmen',
                              Icons.person_outline, _bySalesman, mobile)),
                      const SizedBox(width: 16),
                      Expanded(
                          child: _scoreCard('By Market (Route)', 'markets',
                              Icons.route_outlined, _byRoute, mobile)),
                    ]),
                  const SizedBox(height: 16),
                  _insightsCard(),
                  const SizedBox(height: 24),
                ],
              ],
            ),
    );
  }

  // ── Header: title + actions, quick-range chips beneath ────────────
  Widget _header(bool mobile) {
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Intelligence Dashboard',
          style: TextStyle(
              fontSize: mobile ? 20 : 24, fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      const Text('Shelf checks found ÷ checked · latest audit per shop-SKU',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12.5)),
    ]);
    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.print_outlined, size: 16),
        label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
        onPressed: _print,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
      ),
      const SizedBox(width: 4),
      IconButton(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh'),
    ]);

    String customLabel() => (_from == null && _to == null)
        ? 'Custom…'
        : '${_from != null ? DateFormat('d MMM').format(_from!) : '…'} – ${_to != null ? DateFormat('d MMM').format(_to!) : '…'}';

    Widget chip(String value, String label, {VoidCallback? onTap}) {
      final selected = _range == value;
      return ChoiceChip(
        label: Text(value == 'custom' && selected ? customLabel() : label,
            style: const TextStyle(fontSize: 12)),
        selected: selected,
        visualDensity: VisualDensity.compact,
        selectedColor: AppTheme.primary.withOpacity(0.14),
        labelStyle: TextStyle(
            color: selected ? AppTheme.primary : AppTheme.textSecondary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
        onSelected: (_) => onTap != null ? onTap() : _setRange(value),
      );
    }

    final chips = Wrap(spacing: 8, runSpacing: 8, children: [
      chip('all', 'All time'),
      chip('today', 'Today'),
      chip('7d', 'Last 7 days'),
      chip('30d', 'Last 30 days'),
      chip('custom', 'Custom…', onTap: _pickRange),
    ]);

    // Market / route filter — scopes every stat below. Default "All routes".
    // Only routes that actually carry audited shops this period are offered, and
    // the picker has a search box (built in _openMarketPicker).
    final selectedLabel = _filterRouteId != null
        ? (_routesWithData[_filterRouteId] ?? 'All routes')
        : 'All routes';
    final routeFilter = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _openMarketPicker,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(8),
          color: Colors.white,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.route_outlined, size: 15, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(selectedLabel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary)),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 16, color: AppTheme.textSecondary),
        ]),
      ),
    );

    // Task sheet: a printable, auto-derived action list. Scoped to the selected
    // market, or org-wide (grouped by market) when "All routes" is showing.
    final taskSheetBtn = OutlinedButton.icon(
      onPressed: _loading ? null : _openTaskSheet,
      icon: const Icon(Icons.assignment_outlined, size: 16),
      label: Text(_filterRouteId != null ? 'Market task sheet' : 'Task sheet',
          style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primary,
        side: const BorderSide(color: AppTheme.border),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (mobile) ...[
        title,
        const SizedBox(height: 10),
        buttons,
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: title),
          buttons,
        ]),
      const SizedBox(height: 12),
      if (mobile) ...[
        chips,
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [routeFilter, taskSheetBtn]),
      ] else
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: chips),
          const SizedBox(width: 12),
          routeFilter,
          const SizedBox(width: 8),
          taskSheetBtn,
        ]),
    ]);
  }

  // ── Hero: ring gauge (the one hero figure) + three stat tiles ──────
  Widget _heroRow(bool mobile) {
    final gauge = _gaugeCard(mobile);
    final tiles = [
      _statTile('Shops audited', _int.format(_shopsAudited)),
      _statTile('SKUs tracked', _int.format(_skusTracked)),
      _statTile('Found on shelf', _int.format(_skuPresent)),
      _statTile('Shelf checks', _int.format(_skuTotal)),
    ];
    if (mobile) {
      return Column(children: [
        gauge,
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: tiles[0]),
          const SizedBox(width: 10),
          Expanded(child: tiles[1]),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: tiles[2]),
          const SizedBox(width: 10),
          Expanded(child: tiles[3]),
        ]),
      ]);
    }
    return SizedBox(
      height: 172,
      child: Row(children: [
        SizedBox(width: 360, child: gauge),
        const SizedBox(width: 16),
        Expanded(child: Column(children: [
          Expanded(child: Row(children: [
            Expanded(child: tiles[0]),
            const SizedBox(width: 16),
            Expanded(child: tiles[1]),
            const SizedBox(width: 16),
            Expanded(child: tiles[2]),
            const SizedBox(width: 16),
            Expanded(child: tiles[3]),
          ])),
        ])),
      ]),
    );
  }

  Widget _gaugeCard(bool mobile) {
    final c = _scoreColor(_overall);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDeco,
      child: Row(children: [
        // Ring gauge: severity fill on a lighter track of the same hue.
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: _overall),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (_, v, __) => SizedBox(
            width: mobile ? 108 : 132,
            height: mobile ? 108 : 132,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: v,
                  strokeWidth: 11,
                  strokeCap: StrokeCap.round,
                  backgroundColor: c.withOpacity(0.14),
                  valueColor: AlwaysStoppedAnimation<Color>(c),
                ),
              ),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${_pct.format(v * 100)}%',
                    style: TextStyle(
                        fontSize: mobile ? 24 : 30,
                        height: 1.05,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary)),
                const Text('placed',
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary)),
              ]),
            ]),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Overall placement score',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const SizedBox(height: 4),
                Text(
                    '${_int.format(_skuPresent)} of ${_int.format(_skuTotal)} shelf checks found the SKU — ${_int.format(_skusTracked)} SKUs across ${_int.format(_shopsAudited)} shops',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                        height: 1.4)),
              ]),
        ),
      ]),
    );
  }

  // ── Trend: placement score over time (snapshot per bin) ─────────────────
  //
  // For each bin end date E: take the LATEST audit per (shop, SKU) up to E
  // (within the scope's shops) and score = found / checks. That is "what the
  // shelf coverage looked like on date E" — a true trend, using the full
  // audit history (audits accumulate; nothing is overwritten).
  //
  // Bins adapt to history depth: daily while young (<3 weeks of data),
  // weekly afterwards, capped at 14 points.

  Set<String>? _trendCustomerFilter() {
    if (_trendScope == 'route' && _trendRouteId != null) {
      final set = <String>{};
      _custRoutes.forEach((cid, rids) {
        if (rids.contains(_trendRouteId)) set.add(cid);
      });
      return set;
    }
    if (_trendScope == 'customer' && _trendCustomerId != null) {
      return {_trendCustomerId!};
    }
    return null; // org-wide
  }

  List<MapEntry<DateTime, double>> _trendSeries() {
    if (_allAudits.isEmpty) return const [];
    final filter = _trendCustomerFilter();
    // Relevant audits, sorted ascending by time.
    final rel = _allAudits.where((a) {
      if (filter != null && !filter.contains(a['customer_id'])) return false;
      return a['surveyed_at'] != null;
    }).toList()
      ..sort((a, b) => '${a['surveyed_at']}'.compareTo('${b['surveyed_at']}'));
    if (rel.isEmpty) return const [];

    final firstD = DateTime.tryParse('${rel.first['surveyed_at']}')?.toLocal();
    if (firstD == null) return const [];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDay = DateTime(firstD.year, firstD.month, firstD.day);
    final spanDays = today.difference(firstDay).inDays + 1;
    final weekly = spanDays > 21;
    final step = weekly ? 7 : 1;
    var bins = ((spanDays + step - 1) / step).ceil();
    if (bins > 14) bins = 14;
    if (bins < 2) bins = 2;

    final binEnds = <DateTime>[
      for (var i = bins - 1; i >= 0; i--)
        today.subtract(Duration(days: i * step)),
    ];

    // Single ascending sweep; snapshot at each bin end.
    final latest = <String, bool>{}; // pair -> is_present
    final out = <MapEntry<DateTime, double>>[];
    var idx = 0;
    for (final end in binEnds) {
      final cutoff = DateTime(end.year, end.month, end.day, 23, 59, 59);
      while (idx < rel.length) {
        final t = DateTime.tryParse('${rel[idx]['surveyed_at']}')?.toLocal();
        if (t == null) { idx++; continue; }
        if (t.isAfter(cutoff)) break;
        latest['${rel[idx]['customer_id']}|${rel[idx]['product_id']}'] =
            rel[idx]['is_present'] == true;
        idx++;
      }
      if (latest.isEmpty) continue; // no data yet at this date
      final present = latest.values.where((v) => v).length;
      out.add(MapEntry(end, present / latest.length * 100));
    }
    return out;
  }

  Future<void> _loadTrendCustomers() async {
    if (_trendCustomers.isNotEmpty) return;
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final rows = await Supabase.instance.client
          .from('customers')
          .select('id, shop_name, code')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('shop_name')
          .limit(10000);
      if (mounted) {
        setState(() =>
            _trendCustomers = List<Map<String, dynamic>>.from(rows));
      }
    } catch (_) {}
  }

  Widget _trendScopeChip(String label, String value) {
    final sel = _trendScope == value;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: sel,
      visualDensity: VisualDensity.compact,
      selectedColor: AppTheme.primary.withOpacity(0.15),
      labelStyle: TextStyle(
          color: sel ? AppTheme.primary : AppTheme.textSecondary,
          fontWeight: sel ? FontWeight.w700 : FontWeight.w500),
      onSelected: (_) => setState(() {
        _trendScope = value;
        if (value == 'customer') _loadTrendCustomers();
      }),
    );
  }

  Widget _trendCard(bool mobile) {
    final series = _trendSeries();
    final scopeLabel = _trendScope == 'org'
        ? 'Organization-wide'
        : _trendScope == 'route'
            ? (_trendRouteId != null
                ? (_routeNames[_trendRouteId] ?? 'Route')
                : 'Pick a route')
            : (_trendCustomerLabel.isNotEmpty
                ? _trendCustomerLabel
                : 'Pick a shop');
    final routeIds = _routeNames.keys.toList()
      ..sort((a, b) =>
          (_routeNames[a] ?? '').compareTo(_routeNames[b] ?? ''));

    final q = _trendCustSearchCtrl.text.trim().toLowerCase();
    final custMatches = q.isEmpty
        ? const <Map<String, dynamic>>[]
        : _trendCustomers
            .where((c) =>
                matchesQuery('${c['shop_name'] ?? ''} ${c['code'] ?? ''}', q))
            .take(8)
            .toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(Icons.trending_up, size: 18, color: AppTheme.primary),
              const Text('Placement Trend',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(width: 4),
              _trendScopeChip('Org-wide', 'org'),
              _trendScopeChip('By Route', 'route'),
              _trendScopeChip('By Shop', 'customer'),
            ]),
        const SizedBox(height: 10),
        if (_trendScope == 'route')
          SizedBox(
            width: mobile ? double.infinity : 340,
            child: DropdownButtonFormField<String>(
              value: _trendRouteId,
              isExpanded: true,
              isDense: true,
              decoration: const InputDecoration(
                  labelText: 'Route', isDense: true, border: OutlineInputBorder()),
              items: [
                for (final rid in routeIds)
                  DropdownMenuItem(
                      value: rid,
                      child: Text(_routeNames[rid] ?? '',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _trendRouteId = v),
            ),
          ),
        if (_trendScope == 'customer') ...[
          SizedBox(
            width: mobile ? double.infinity : 340,
            child: TextField(
              controller: _trendCustSearchCtrl,
              decoration: InputDecoration(
                labelText: 'Shop',
                hintText: _trendCustomerLabel.isEmpty
                    ? 'Search shop name or code...'
                    : _trendCustomerLabel,
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                border: const OutlineInputBorder(),
              ),
              onTap: () => setState(() => _trendCustPicking = true),
              onChanged: (_) => setState(() => _trendCustPicking = true),
            ),
          ),
          if (_trendCustPicking && custMatches.isNotEmpty)
            Container(
              width: mobile ? double.infinity : 340,
              margin: const EdgeInsets.only(top: 2),
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppTheme.border),
                  borderRadius: BorderRadius.circular(6)),
              child: ListView(shrinkWrap: true, children: [
                for (final c in custMatches)
                  InkWell(
                    onTap: () => setState(() {
                      _trendCustomerId = c['id'] as String;
                      _trendCustomerLabel =
                          '${c['shop_name']}${c['code'] != null ? ' (${c['code']})' : ''}';
                      _trendCustSearchCtrl.clear();
                      _trendCustPicking = false;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      child: Text(
                          '${c['shop_name']}  ${c['code'] ?? ''}',
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
              ]),
            ),
        ],
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(scopeLabel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11.5, color: AppTheme.textSecondary)),
          ),
          if (series.isNotEmpty) ...[
            Text('Latest: ${_pct.format(series.last.value)}%',
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary)),
            if (series.length >= 2) ...[
              const SizedBox(width: 8),
              Builder(builder: (_) {
                final delta = series.last.value - series.first.value;
                final up = delta >= 0;
                return Text(
                  '${up ? '▲' : '▼'} ${_pct.format(delta.abs())} pts since ${series.first.key.day}/${series.first.key.month}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: up
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFDC2626)),
                );
              }),
            ],
          ],
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: mobile ? 180 : 220,
          child: series.length < 2
              ? const Center(
                  child: Text(
                      'Not enough history yet — the trend builds as audits repeat over time.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)))
              : LineChart(LineChartData(
                  minY: 0,
                  maxY: 100,
                  minX: 0,
                  maxX: (series.length - 1).toDouble(),
                  gridData:
                      const FlGridData(show: true, drawVerticalLine: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: 25,
                      getTitlesWidget: (v, _) => Text('${v.toInt()}%',
                          maxLines: 1,
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.textSecondary)),
                    )),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 24,
                        interval:
                            (series.length / 6).ceilToDouble().clamp(1, 99),
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= series.length) {
                            return const SizedBox.shrink();
                          }
                          final d = series[i].key;
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('${d.day}/${d.month}',
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary)),
                          );
                        },
                      ),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) => [
                        for (final s in spots)
                          LineTooltipItem(
                              '${_pct.format(s.y)}%',
                              const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                      ],
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        for (var i = 0; i < series.length; i++)
                          FlSpot(i.toDouble(), series[i].value),
                      ],
                      color: AppTheme.primary,
                      barWidth: 2.5,
                      isCurved: false,
                      dotData: const FlDotData(show: true),
                      belowBarData: BarAreaData(
                          show: true,
                          color: AppTheme.primary.withOpacity(0.08)),
                    ),
                  ],
                )),
        ),
        const SizedBox(height: 6),
        const Text(
            'How to read: each dot = the placement score as it stood on that date — of all shop-SKU shelf checks done up to then, the % where the SKU was on the shelf (latest check per shop-SKU counts). The line rises when surveyors find more SKUs placed on re-audit, falls when previously-placed SKUs go missing. Daily dots while history is young, weekly after 3 weeks.',
            style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      ]),
    );
  }

  Widget _statTile(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: _cardDeco,
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppTheme.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary)),
            ]),
      );

  // ── Bar-list card: rank · name · meter · % ─────────────────────────
  Widget _scoreCard(String title, String unit, IconData icon,
      List<_GroupScore> rows, bool mobile) {
    return Container(
      decoration: _cardDeco,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
          child: Row(children: [
            Icon(icon, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w800)),
            ),
            Text('${rows.length} $unit',
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text('No data',
                    style: TextStyle(color: AppTheme.textSecondary))),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 16),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const SizedBox(height: 14),
            itemBuilder: (_, i) => _meterRow(i + 1, rows[i], unit),
          ),
      ]),
    );
  }

  Widget _meterRow(int rank, _GroupScore g, String panelKey) {
    final c = _scoreColor(g.score);
    // The catch-all buckets are the only expandable rows: tapping the shop count
    // reveals exactly which shops fell into "Unassigned" / "No route".
    final isUnassigned = g.name == 'Unassigned' || g.name == 'No route / Unassigned';
    final rowKey = '$panelKey:${g.name}';
    final expanded = isUnassigned && _expandedGroups.contains(rowKey);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        SizedBox(
            width: 22,
            child: Text('$rank',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary))),
        Expanded(
          child: Text(g.name,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ),
        Text('${g.present}/${g.total}',
            style: const TextStyle(
                fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(width: 10),
        SizedBox(
          width: 52,
          child: Text('${_pct.format(g.score * 100)}%',
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary)),
        ),
      ]),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(left: 22),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: g.score),
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOutCubic,
          builder: (_, v, __) => ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 8,
              backgroundColor: c.withOpacity(0.13),
              valueColor: AlwaysStoppedAnimation<Color>(c),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 22, top: 4),
        child: isUnassigned
            ? InkWell(
                onTap: () => setState(() {
                  if (expanded) {
                    _expandedGroups.remove(rowKey);
                  } else {
                    _expandedGroups.add(rowKey);
                  }
                }),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15, color: AppTheme.primary),
                  const SizedBox(width: 2),
                  Text(
                      '${g.customers.length} shop${g.customers.length == 1 ? '' : 's'} — ${expanded ? 'hide' : 'show'}',
                      style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w600)),
                ]),
              )
            : Text(
                '${g.customers.length} shop${g.customers.length == 1 ? '' : 's'}',
                style: const TextStyle(
                    fontSize: 10.5, color: AppTheme.textSecondary)),
      ),
      if (expanded) _unassignedShops(g),
    ]);
  }

  // The list of shops inside an expanded "Unassigned" bucket, sorted by name.
  Widget _unassignedShops(_GroupScore g) {
    final names = g.customers
        .map((cid) => _custName[cid] ?? 'Unnamed shop')
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return Container(
      margin: const EdgeInsets.only(left: 22, top: 6),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Scrollbar(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: names.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: AppTheme.border),
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              const Icon(Icons.storefront_outlined,
                  size: 13, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(names[i],
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Salesperson read (my own judgment, context-aware) ───────────────────
  List<Widget> _salespersonInsight() {
    const icon = Icons.person_outline;
    final avg = _orgAvgScore;
    String pts(double d) {
      final n = (d.abs() * 100).round();
      return '$n pt${n == 1 ? '' : 's'}';
    }

    if (_filterRouteId != null) {
      // A market is selected: this route's placement = the in-scope overall,
      // and we judge whoever owns the route against the whole company.
      final routeScore = _skuTotal == 0 ? 0.0 : _skuPresent / _skuTotal;
      final named = _bySalesman
          .where((g) => g.name != 'Unassigned' && g.total > 0)
          .toList();
      if (named.isEmpty) {
        return [
          _insightLine(icon, AppTheme.warning, [
            _t('This market has no salesperson assigned. Placement here is '),
            _b('${(routeScore * 100).round()}%'),
            _t(' — assign an owner so someone is accountable for the shelf.'),
          ])
        ];
      }
      final who = named.map((g) => g.name).join(' & ');
      final delta = routeScore - avg;
      final spans = <InlineSpan>[
        _t('On this market, '),
        _b(who),
        _t(' is holding placement at '),
        _b('${(routeScore * 100).round()}%'),
      ];
      if (delta >= 0.05) {
        spans.add(_t(
            ' — ${pts(delta)} above the company average of ${(avg * 100).round()}%. Strong coverage; protect it.'));
      } else if (delta <= -0.05) {
        spans.add(_t(
            ' — ${pts(delta)} below the company average of ${(avg * 100).round()}%. This market needs a push.'));
      } else {
        spans.add(_t(
            ' — roughly in line with the company average of ${(avg * 100).round()}%.'));
      }
      final weakest = _skuStats.where((s) => s.rate < 0.5).toList()
        ..sort((a, b) => a.rate.compareTo(b.rate));
      if (weakest.isNotEmpty) {
        spans.add(_t(' Start with '));
        spans.add(_b(weakest.first.name));
        spans.add(_t(' (${(weakest.first.rate * 100).round()}% on shelf).'));
      } else if (_catLeaders.isNotEmpty) {
        spans.add(_t(' Biggest competitive gap: '));
        spans.add(_b(_catLeaders.first.value));
        spans.add(_t(' leads '));
        spans.add(_b(_catLeaders.first.key));
        spans.add(_t('.'));
      }
      return [_insightLine(icon, _scoreColor(routeScore), spans)];
    }

    // All routes: judge the whole team.
    final team = _bySalesman
        .where((g) =>
            g.name != 'Unassigned' && g.total > 0 && g.customers.length >= 2)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    if (team.isEmpty) return const [];
    final best = team.first;
    final worst = team.last;
    if (team.length == 1) {
      return [
        _insightLine(icon, _scoreColor(best.score), [
          _b(best.name),
          _t(' is carrying every assigned route at '),
          _b('${(best.score * 100).round()}%'),
          _t(' placement across ${best.customers.length} shops.'),
        ])
      ];
    }
    final spread = best.score - worst.score;
    final teamSpans = <InlineSpan>[
      _t('Across the team, '),
      _b(best.name),
      _t(' leads at '),
      _b('${(best.score * 100).round()}%'),
      _t(' while '),
      _b(worst.name),
      _t(' trails at '),
      _b('${(worst.score * 100).round()}%'),
    ];
    if (spread >= 0.25) {
      teamSpans.add(_t(
          ' — a wide ${pts(spread)} gap. The lower half is what is pulling company placement down to ${(avg * 100).round()}%.'));
    } else {
      teamSpans.add(_t(
          ' — fairly consistent, with the company averaging ${(avg * 100).round()}%.'));
    }
    final out = <Widget>[_insightLine(icon, _scoreColor(worst.score), teamSpans)];
    final belowAvg = team.where((g) => g.score < avg).length;
    if (belowAvg > 0 && team.length > 2) {
      out.add(_insightLine(Icons.trending_down, AppTheme.textSecondary, [
        _b('$belowAvg of ${team.length}'),
        _t(' salespeople are below the company average — focus coaching there first.'),
      ]));
    }
    return out;
  }

  // ── Searchable, data-only market picker ─────────────────────────────────
  static const String _kAllMarkets = '__all_markets__';

  Future<void> _openMarketPicker() async {
    final all = _routesWithData.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    String query = '';
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final q = query.trim().toLowerCase();
        final filtered =
            q.isEmpty ? all : all.where((e) => matchesQuery(e.value, q)).toList();
        return AlertDialog(
          contentPadding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
          title: const Text('Filter by market', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 440,
            height: 480,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: 'Search markets…',
                    border:
                        OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) => setLocal(() => query = v),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView(children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.public, size: 18),
                    title: const Text('All routes'),
                    trailing: _filterRouteId == null
                        ? const Icon(Icons.check, size: 18, color: AppTheme.primary)
                        : null,
                    onTap: () => Navigator.pop(ctx, _kAllMarkets),
                  ),
                  const Divider(height: 1),
                  if (filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(28),
                      child: Text('No markets match your search.',
                          style: TextStyle(color: AppTheme.textSecondary)),
                    ),
                  for (final e in filtered)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.route_outlined, size: 18),
                      title: Text(e.value,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${_routeShopCount[e.key] ?? 0} shop'
                          '${(_routeShopCount[e.key] ?? 0) == 1 ? '' : 's'} audited'),
                      trailing: _filterRouteId == e.key
                          ? const Icon(Icons.check, size: 18, color: AppTheme.primary)
                          : null,
                      onTap: () => Navigator.pop(ctx, e.key),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
          ],
        );
      }),
    );
    if (picked == null) return; // cancelled
    final newId = picked == _kAllMarkets ? null : picked;
    if (newId == _filterRouteId) return;
    setState(() => _filterRouteId = newId);
    _load();
  }

  // ── Printable, auto-derived market task sheet ───────────────────────────
  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  void _openTaskSheet() {
    final marketMode = _filterRouteId != null;
    final scopeName = marketMode
        ? (_routesWithData[_filterRouteId] ?? 'Market')
        : 'All markets (company-wide)';
    final orgName = ref.read(currentUserProvider)?.orgName ?? '';
    final generated = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final periodLabel = _range == 'all'
        ? 'All time'
        : (_from != null && _to != null
            ? '${DateFormat('d MMM').format(_from!)} – ${DateFormat('d MMM yyyy').format(_to!)}'
            : 'Selected period');
    final overall = _skuTotal == 0 ? 0.0 : _skuPresent / _skuTotal;

    // Auto-derived action items.
    final weakSkus = _skuStats.where((s) => s.rate < 0.5).toList()
      ..sort((a, b) => a.rate.compareTo(b.rate));

    String checkRow(String txt) =>
        '<tr><td class="cbx">☐</td><td>$txt</td></tr>';

    final actions = StringBuffer();
    if (!marketMode) {
      // Org-wide: prioritise the weakest markets first.
      final weakMarkets = _byRoute
          .where((g) => g.name != 'No route / Unassigned' && g.total > 0)
          .toList()
        ..sort((a, b) => a.score.compareTo(b.score));
      for (final m in weakMarkets.take(3)) {
        actions.write(checkRow(
            'Prioritise <b>${_esc(m.name)}</b> — placement is only '
            '<b>${(m.score * 100).round()}%</b> (${m.customers.length} shops). '
            'Ride along or re-brief the route owner.'));
      }
    }
    for (final s in weakSkus.take(marketMode ? 8 : 6)) {
      actions.write(checkRow(
          'Push <b>${_esc(s.name)}</b> — on shelf in only '
          '<b>${(s.rate * 100).round()}%</b> of ${s.shops} shops. '
          'Secure facings / arrange restock.'));
    }
    for (final c in _catLeaders.take(6)) {
      actions.write(checkRow(
          'Win back <b>${_esc(c.key)}</b> — <b>${_esc(c.value)}</b> is the '
          'most-visible brand in this category. Pitch our range against it.'));
    }
    if (_leadBrand != null) {
      actions.write(checkRow(
          'Watch <b>${_esc(_leadBrand!)}</b> — the most-spotted competitor '
          'overall ($_leadBrandShops shops). Note pricing / display where seen.'));
    }
    if (actions.isEmpty) {
      actions.write(checkRow(
          'No weak points flagged in this period — keep coverage up and '
          'log any new competitor displays.'));
    }

    // Who this is for.
    final assignedNames = marketMode
        ? (_bySalesman
            .where((g) => g.name != 'Unassigned')
            .map((g) => g.name)
            .toList())
        : <String>[];
    final assignedLine = marketMode
        ? (assignedNames.isEmpty
            ? 'Assigned to: <i>no salesperson linked to this route</i>'
            : 'Assigned to: <b>${_esc(assignedNames.join(', '))}</b>')
        : '';

    // Optional org-wide reference tables.
    String marketTable() {
      final rows = _byRoute
          .where((g) => g.total > 0)
          .toList()
        ..sort((a, b) => a.score.compareTo(b.score));
      if (rows.isEmpty) return '';
      final b = StringBuffer(
          '<h3>Markets by placement (weakest first)</h3><table class="ref">'
          '<tr><th>Market</th><th class="num">Shops</th><th class="num">Placement</th></tr>');
      for (final g in rows) {
        b.write('<tr><td>${_esc(g.name)}</td><td class="num">'
            '${g.customers.length}</td><td class="num">'
            '${(g.score * 100).round()}%</td></tr>');
      }
      b.write('</table>');
      return b.toString();
    }

    String salesTable() {
      final rows = _bySalesman.where((g) => g.total > 0).toList()
        ..sort((a, b) => a.score.compareTo(b.score));
      if (rows.isEmpty) return '';
      final b = StringBuffer(
          '<h3>Salespeople by placement (weakest first)</h3><table class="ref">'
          '<tr><th>Salesperson</th><th class="num">Shops</th><th class="num">Placement</th></tr>');
      for (final g in rows) {
        b.write('<tr><td>${_esc(g.name)}</td><td class="num">'
            '${g.customers.length}</td><td class="num">'
            '${(g.score * 100).round()}%</td></tr>');
      }
      b.write('</table>');
      return b.toString();
    }

    // ── Page 2: per-shop missing-SKU targets ────────────────────────────────
    // Every shop in scope that had at least one tracked SKU off-shelf on its
    // last check, biggest gaps first, with the exact SKUs to place.
    String shopTargets() {
      bool inScope(String cid) =>
          !marketMode || (_custRoutes[cid]?.contains(_filterRouteId) ?? false);
      final rows = _custMissing.entries
          .where((e) => e.value.isNotEmpty && inScope(e.key))
          .toList()
        ..sort((a, b) {
          final byCount = b.value.length.compareTo(a.value.length);
          if (byCount != 0) return byCount;
          return (_custName[a.key] ?? '').toLowerCase()
              .compareTo((_custName[b.key] ?? '').toLowerCase());
        });

      final b = StringBuffer()
        ..write('<div style="page-break-before:always"></div>')
        ..write('<h1>Shop Targets — Missing SKUs</h1>')
        ..write('<div class="info"><b>Scope:</b> ${_esc(scopeName)}</div>')
        ..write('<div class="info"><b>Period:</b> $periodLabel</div>');

      if (rows.isEmpty) {
        b.write('<div class="kpi">No off-shelf SKUs in scope this period — '
            'every audited shop had its tracked SKUs on shelf. Keep it up.</div>');
        return b.toString();
      }

      final totalGaps = rows.fold<int>(0, (s, e) => s + e.value.length);
      b
        ..write('<div class="kpi"><b>${rows.length}</b> shop'
            '${rows.length == 1 ? '' : 's'} with gaps · '
            '<b>$totalGaps</b> SKU placement${totalGaps == 1 ? '' : 's'} to win. '
            'Biggest gaps first.</div>')
        ..write('<table class="ref"><tr>'
            '<th class="cbx">✓</th><th>Shop</th><th>Code</th>'
            '<th class="num">Missing</th><th>SKUs to place on shelf</th></tr>');
      for (final e in rows) {
        final cid = e.key;
        final miss = e.value;
        final checked = _custChecks[cid] ?? miss.length;
        final skuList = miss.map(_esc).join(', ');
        b.write('<tr>'
            '<td class="cbx">☐</td>'
            '<td><b>${_esc(_custName[cid] ?? 'Unnamed shop')}</b></td>'
            '<td>${_esc(_custCode[cid] ?? '')}</td>'
            '<td class="num">${miss.length} of $checked</td>'
            '<td>$skuList</td>'
            '</tr>');
      }
      b.write('</table>');
      return b.toString();
    }

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8">'
        '<title>Task Sheet — ${_esc(scopeName)}</title><style>'
        'body{font-family:Arial,sans-serif;padding:22px;color:#111;font-size:12px}'
        'h1{font-size:20px;margin:0 0 2px}h3{font-size:13px;margin:20px 0 6px}'
        '.info{font-size:11px;margin:1px 0;color:#444}'
        '.kpi{margin:12px 0 4px;font-size:12px}'
        '.kpi b{font-size:15px}'
        'table{width:100%;border-collapse:collapse;margin-top:6px}'
        'td,th{padding:6px 8px;border-bottom:1px solid #e6e6e6;text-align:left;vertical-align:top}'
        'th{background:#f0f4ff;font-size:11px}'
        '.num{text-align:right;white-space:nowrap}'
        '.cbx{width:22px;font-size:16px;color:#333}'
        'table.ref td,table.ref th{font-size:11px}'
        '.assign{margin:6px 0 2px;font-size:12px}'
        '.foot{margin-top:22px;font-size:10px;color:#888;border-top:1px solid #ccc;padding-top:8px}'
        '@media print{.no-print{display:none}}'
        '@page{margin:0.7cm}</style></head><body>'
        '<div class="no-print" style="margin-bottom:12px">'
        '<button onclick="window.print()">Print / Save PDF</button></div>'
        '<h1>Field Task Sheet</h1>'
        '<div class="info"><b>Scope:</b> ${_esc(scopeName)}</div>'
        '${orgName.isEmpty ? '' : '<div class="info"><b>Company:</b> ${_esc(orgName)}</div>'}'
        '<div class="info"><b>Period:</b> $periodLabel</div>'
        '<div class="info"><b>Generated:</b> $generated</div>'
        '${assignedLine.isEmpty ? '' : '<div class="assign">$assignedLine</div>'}'
        '<div class="kpi">Placement this period: <b>${(overall * 100).round()}%</b> '
        'across $_shopsAudited shops ($_skuPresent of $_skuTotal shelf checks on shelf).</div>'
        '<h3>Action items</h3>'
        '<table>${actions.toString()}</table>'
        '${marketMode ? '' : marketTable()}'
        '${marketMode ? '' : salesTable()}'
        '${shopTargets()}'
        '<div class="foot">Auto-generated by Opstation Intelligence from this '
        'period’s shelf checks and competitor spottings. Tick items as completed.</div>'
        '</body></html>';

    _printHtmlDoc(doc, 'Task Sheet');
  }

  /// Render an HTML string and bring up the print dialog. Uses a hidden,
  /// same-origin iframe that prints itself on load — Safari renders documents
  /// opened from a blob: URL as BLANK when printed, so we must not rely on a
  /// blob tab. Falls back to a blob tab if the iframe can't be created.
  void _printHtmlDoc(String doc, String title) {
    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..title = title
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      // Print the frame's OWN document once it has loaded.
      final printable = doc.replaceFirst(
          '</body>',
          '<script>window.onload=function(){setTimeout(function(){'
              'try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      frame.srcdoc = printable;
      html.document.body!.append(frame);
    } catch (_) {
      // Last-resort fallback (non-Safari): open the doc in a new tab.
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }

  // ── Auto-insights: a plain-language read of this period's data ───────────
  TextSpan _t(String s) => TextSpan(text: s);
  TextSpan _b(String s) =>
      TextSpan(text: s, style: const TextStyle(fontWeight: FontWeight.w800));
  String _judge(double r) => r >= .75 ? 'strong' : (r >= .5 ? 'fair' : 'poor');

  Widget _insightLine(IconData icon, Color color, List<InlineSpan> spans) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(TextSpan(children: spans),
              style: const TextStyle(fontSize: 13, height: 1.5, color: AppTheme.textPrimary)),
        ),
      ]),
    );
  }

  Widget _insightsCard() {
    final lines = <Widget>[];

    // Overall availability opener.
    final overall = _skuTotal == 0 ? 0.0 : _skuPresent / _skuTotal;
    if (_skuTotal > 0) {
      lines.add(_insightLine(Icons.insights_outlined, _scoreColor(overall), [
        _t('Across all shelf checks this period, your tracked SKUs are on shelf '),
        _b('${(overall * 100).round()}% of the time'),
        _t(' — ${_judge(overall)} overall availability.'),
      ]));
    }

    // Best-placed SKU.
    if (_skuStats.isNotEmpty) {
      final top = _skuStats.first;
      lines.add(_insightLine(Icons.check_circle_outline, AppTheme.success, [
        _b(top.name),
        _t(' is your best-placed SKU — on shelf in '),
        _b('${(top.rate * 100).round()}%'),
        _t(' of ${top.shops} shops checked.'),
      ]));
    }

    // SKUs that need attention (below half the shops).
    final need = _skuStats.where((s) => s.rate < 0.5).toList()
      ..sort((a, b) => a.rate.compareTo(b.rate));
    if (need.isNotEmpty) {
      final pick = need.take(3).toList();
      final spans = <InlineSpan>[_t('Needs attention: ')];
      for (var i = 0; i < pick.length; i++) {
        if (i > 0) spans.add(_t(i == pick.length - 1 ? ' and ' : ', '));
        spans.add(_b(pick[i].name));
        spans.add(_t(' (${(pick[i].rate * 100).round()}%)'));
      }
      spans.add(_t(' — each on shelf in under half the shops surveyed.'));
      lines.add(_insightLine(Icons.error_outline, AppTheme.danger, spans));
    } else if (_skuStats.isNotEmpty) {
      lines.add(_insightLine(Icons.thumb_up_outlined, AppTheme.success, [
        _t('No tracked SKU is below 50% availability — placement is broadly healthy.'),
      ]));
    }

    // Competitor: most-visible brand overall.
    if (_leadBrand != null) {
      lines.add(_insightLine(Icons.emoji_events_outlined, AppTheme.warning, [
        _b(_leadBrand!),
        _t(' is the most-visible competitor, spotted in '),
        _b('$_leadBrandShops shop${_leadBrandShops == 1 ? '' : 's'}'),
        _t(' this period.'),
      ]));
    }
    // Competitor: category leaders.
    if (_catLeaders.isNotEmpty) {
      final spans = <InlineSpan>[_t('By category, ')];
      final n = _catLeaders.length > 5 ? 5 : _catLeaders.length;
      for (var i = 0; i < n; i++) {
        if (i > 0) spans.add(_t(i == n - 1 ? ' and ' : ', '));
        spans.add(_b(_catLeaders[i].value));
        spans.add(_t(' leads in '));
        spans.add(_b(_catLeaders[i].key));
      }
      spans.add(_t('.'));
      lines.add(_insightLine(Icons.category_outlined, AppTheme.textSecondary, spans));
    }

    // Salesperson read — context-aware:
    //  • a market is selected  -> judge that route's assigned salesperson
    //  • all routes            -> judge the whole team
    for (final l in _salespersonInsight()) {
      lines.add(l);
    }

    if (lines.isEmpty) {
      lines.add(_insightLine(Icons.info_outline, AppTheme.textSecondary, [
        _t('Not enough data in this period yet to generate insights. Try a wider date range.'),
      ]));
    }

    return Container(
      width: double.infinity,
      decoration: _cardDeco,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.auto_awesome_outlined, size: 16, color: AppTheme.primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('What the data says',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
          ),
          Text('auto-generated', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 6),
        const Text('A plain-language read of this period’s shelf checks and competitor spottings.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 10),
        const Divider(height: 1, color: AppTheme.border),
        const SizedBox(height: 4),
        ...lines,
      ]),
    );
  }

  BoxDecoration get _cardDeco => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      );
}
