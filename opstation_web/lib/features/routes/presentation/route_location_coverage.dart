// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../customers/presentation/erp_customer_360_screen.dart';

/// Routes → "Location coverage": for every active route, how many of its
/// active shops have a saved location, and exactly which ones are missing.
/// A shop counts as located when it has its main location or at least one
/// other location (SQL 409) — visits there can be verified.
Future<void> showRouteLocationCoverage(BuildContext context, {required String orgId}) async {
  final client = Supabase.instance.client;
  Future<List<Map<String, dynamic>>> paged(dynamic Function(int f, int t) q) async {
    final out = <Map<String, dynamic>>[];
    for (int f = 0;; f += 1000) {
      final page = List<Map<String, dynamic>>.from(await q(f, f + 999) as List);
      out.addAll(page);
      if (page.length < 1000 || f > 200000) break;
    }
    return out;
  }

  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  List<_RouteLoc> rows;
  try {
    showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));
    final routes = await paged((f, t) => client.from('sales_routes')
        .select('id, name, is_active').eq('org_id', orgId).order('name').range(f, t));
    final live = routes.where((r) => r['is_active'] != false).toList();
    final ids = [for (final r in live) r['id'] as String];
    final stops = <Map<String, dynamic>>[];
    final assigns = <Map<String, dynamic>>[];
    for (var k = 0; k < ids.length; k += 150) {
      final chunk = ids.sublist(k, (k + 150).clamp(0, ids.length));
      stops.addAll(await paged((f, t) => client.from('route_stops')
          .select('route_id, customer_id, position').inFilter('route_id', chunk).range(f, t)));
      assigns.addAll(await paged((f, t) => client.from('route_assignments')
          .select('route_id, user_id').inFilter('route_id', chunk).range(f, t)));
    }
    final custs = await paged((f, t) => client.from('customers')
        .select('id, code, shop_name, address, phone, latitude, longitude')
        .eq('org_id', orgId).eq('is_active', true).range(f, t));
    final users = await paged((f, t) => client.from('users')
        .select('id, name').eq('org_id', orgId).range(f, t));
    // Customers that have another location (Godown …). Optional: older
    // databases without it just count the main location.
    final extra = <String>{};
    try {
      for (final l in await paged((f, t) => client.from('customer_locations')
          .select('customer_id').eq('org_id', orgId).range(f, t))) {
        extra.add('${l['customer_id']}');
      }
    } catch (_) {}

    final custById = {for (final c in custs) c['id'] as String: c};
    final userName = {for (final u in users) u['id'] as String: '${u['name'] ?? ''}'.trim()};
    final shopsBy = <String, List<String>>{};
    final posBy = <String, int>{};
    for (final st in stops) {
      final cid = st['customer_id'] as String?;
      final rid = st['route_id'] as String?;
      if (cid == null || rid == null || !custById.containsKey(cid)) continue; // active shops only
      final l = shopsBy[rid] ??= [];
      if (l.contains(cid)) continue;
      l.add(cid);
      posBy['$rid|$cid'] = (st['position'] as num?)?.toInt() ?? 0;
    }
    final peopleBy = <String, Set<String>>{};
    for (final a in assigns) {
      final n = userName[a['user_id']];
      if (n == null || n.isEmpty) continue;
      (peopleBy[a['route_id'] as String] ??= {}).add(n);
    }
    bool located(String cid) {
      final c = custById[cid]!;
      return (c['latitude'] != null && c['longitude'] != null) || extra.contains(cid);
    }

    rows = [
      for (final r in live)
        if ((shopsBy[r['id']] ?? const []).isNotEmpty)
          () {
            final rid = r['id'] as String;
            final shops = shopsBy[rid]!
              ..sort((a, b) => (posBy['$rid|$a'] ?? 0).compareTo(posBy['$rid|$b'] ?? 0));
            return _RouteLoc(
              id: rid,
              name: '${r['name'] ?? '(route)'}',
              salespeople: (peopleBy[rid] ?? const <String>{}).toList()..sort(),
              total: shops.length,
              missing: [for (final c in shops) if (!located(c)) custById[c]!],
            );
          }(),
    ];
    nav.pop(); // spinner
  } catch (_) {
    nav.pop();
    messenger.showSnackBar(const SnackBar(
        content: Text('Could not load location coverage. Please try again.'),
        behavior: SnackBarBehavior.floating));
    return;
  }
  if (!context.mounted) return;

  final none = rows.where((r) => r.located == 0).toList()..sort((a, b) => b.total.compareTo(a.total));
  final partly = rows.where((r) => r.located > 0 && r.missing.isNotEmpty).toList()
    ..sort((a, b) => a.ratio.compareTo(b.ratio));
  final full = rows.where((r) => r.missing.isEmpty).toList()..sort((a, b) => a.name.compareTo(b.name));
  final allShops = rows.fold<int>(0, (s, r) => s + r.total);
  final allLocated = rows.fold<int>(0, (s, r) => s + r.located);
  final overall = allShops == 0 ? 0.0 : allLocated / allShops;
  String tab = partly.isNotEmpty ? 'partly' : (none.isNotEmpty ? 'none' : 'full');
  String query = '';

  void download() {
    String q(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    final sb = StringBuffer()
      ..writeln(['Route', 'Salesperson', 'Shops', 'With location', '%', 'Code', 'Missing shop', 'Address', 'Phone']
          .map(q).join(','));
    final sorted = [...rows]..sort((a, b) => a.ratio != b.ratio ? a.ratio.compareTo(b.ratio) : a.name.compareTo(b.name));
    for (final r in sorted) {
      final head = [r.name, r.salespeople.join(' / '), r.total, r.located, (r.ratio * 100).toStringAsFixed(1)];
      if (r.missing.isEmpty) {
        sb.writeln([...head, '', '', '', ''].map(q).join(','));
      } else {
        for (final c in r.missing) {
          sb.writeln([...head, c['code'], c['shop_name'], c['address'], c['phone']].map(q).join(','));
        }
      }
    }
    final blob = html.Blob(['﻿', sb.toString()], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', 'location_coverage_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> openCustomer(BuildContext ctx, String id) async {
    try {
      final row = await client.from('customers').select().eq('id', id).maybeSingle();
      if (row == null || !ctx.mounted) return;
      await Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => Customer360Screen(customer: row)));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open the customer. Please try again.')));
    }
  }

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final mobile = MediaQuery.of(ctx).size.width < 700;
      final base = tab == 'none' ? none : tab == 'partly' ? partly : full;
      final qq = query.trim().toLowerCase();
      final list = qq.isEmpty
          ? base
          : base.where((r) => matchesQuery(
              '${r.name} ${r.salespeople.join(' ')} ${r.missing.map((c) => '${c['code'] ?? ''} ${c['shop_name'] ?? ''}').join(' ')}',
              qq)).toList();
      Widget tabChip(String key, String label, int n, Color c) => ChoiceChip(
            selected: tab == key,
            visualDensity: VisualDensity.compact,
            selectedColor: c.withOpacity(0.14),
            label: Text('$label ($n)',
                style: TextStyle(fontSize: 12, fontWeight: tab == key ? FontWeight.w700 : FontWeight.w500,
                    color: tab == key ? c : AppTheme.textSecondary)),
            onSelected: (_) => setLocal(() => tab = key),
          );
      final overallColor = overall >= 1 ? AppTheme.success : overall >= 0.8 ? Colors.amber.shade800 : Colors.deepOrange;
      return Dialog(
        insetPadding: EdgeInsets.all(mobile ? 10 : 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 760),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Location coverage by route',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                TextButton.icon(
                  onPressed: rows.isEmpty ? null : download,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(mobile ? 'CSV' : 'Download CSV'),
                ),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
              ]),
              const Text('Active routes and active shops. A shop counts once it has a saved location.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 10),
              // Overall
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                      value: overall, minHeight: 8,
                      backgroundColor: overallColor.withOpacity(0.12),
                      valueColor: AlwaysStoppedAnimation(overallColor)),
                )),
                const SizedBox(width: 10),
                Text('${(overall * 100).toStringAsFixed(1)}% · $allLocated of $allShops shops',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: overallColor)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                tabChip('partly', 'Partly marked', partly.length, Colors.amber.shade800),
                tabChip('none', 'None marked', none.length, Colors.deepOrange),
                tabChip('full', 'Complete', full.length, AppTheme.success),
              ]),
              const SizedBox(height: 10),
              TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search route, salesperson or shop…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onChanged: (v) => setLocal(() => query = v),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: list.isEmpty
                    ? Center(child: Text(
                        tab == 'full' ? 'No route has every shop marked yet.' : 'No routes here.',
                        style: const TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final r = list[i];
                          final color = r.located == 0 ? Colors.deepOrange
                              : r.missing.isNotEmpty ? Colors.amber.shade800 : AppTheme.success;
                          return Theme(
                            data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
                            child: ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                              childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                              title: Text(r.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const SizedBox(height: 3),
                                Text(r.salespeople.isEmpty ? 'No salesperson' : r.salespeople.join(', '),
                                    style: TextStyle(fontSize: 12,
                                        color: r.salespeople.isEmpty ? AppTheme.danger : AppTheme.textSecondary)),
                                const SizedBox(height: 5),
                                Row(children: [
                                  Expanded(child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                        value: r.ratio, minHeight: 6,
                                        backgroundColor: color.withOpacity(0.12),
                                        valueColor: AlwaysStoppedAnimation(color)),
                                  )),
                                  const SizedBox(width: 10),
                                  Text('${(r.ratio * 100).round()}% · ${r.located} of ${r.total}',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                                ]),
                              ]),
                              children: [
                                if (r.missing.isEmpty)
                                  const Align(alignment: Alignment.centerLeft,
                                      child: Text('Every shop on this route has a location.',
                                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)))
                                else ...[
                                  Align(alignment: Alignment.centerLeft,
                                      child: Text('No location (${r.missing.length}) — in route order',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                                  const SizedBox(height: 4),
                                  for (final c in r.missing)
                                    InkWell(
                                      onTap: () => openCustomer(ctx, c['id'] as String),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 4),
                                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                          const Icon(Icons.location_off_outlined, size: 14, color: Colors.deepOrange),
                                          const SizedBox(width: 6),
                                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                            Text('${'${c['code'] ?? ''}'.isEmpty ? '' : '${c['code']} · '}${c['shop_name'] ?? 'Unnamed shop'}',
                                                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                                            if ('${c['address'] ?? ''}'.trim().isNotEmpty)
                                              Text('${c['address']}',
                                                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                                          ])),
                                          const Icon(Icons.chevron_right, size: 16, color: AppTheme.textSecondary),
                                        ]),
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class _RouteLoc {
  final String id;
  final String name;
  final List<String> salespeople;
  final int total;
  final List<Map<String, dynamic>> missing;
  const _RouteLoc({required this.id, required this.name, required this.salespeople,
      required this.total, required this.missing});
  int get located => total - missing.length;
  double get ratio => total == 0 ? 0 : located / total;
}
