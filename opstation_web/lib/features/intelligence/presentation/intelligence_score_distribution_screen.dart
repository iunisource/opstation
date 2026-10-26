import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:excel/excel.dart' as xls;
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import '../widgets/searchable_dropdown.dart';
import 'package:opstation_web/core/pdf/pdf_output.dart';

/// Placement Score Distribution — for each salesperson (or market), how many
/// shops sit at each placement score 0 … N (N = active survey products), and
/// what % of that salesperson's / market's shops that is.
///
/// Shop score = products displayed in the shop, from each product's latest
/// survey (a product never surveyed there counts as not displayed).
/// Salesperson = owner of the shop's route; a shop on two people's routes
/// counts for both. Shops on no route are grouped as "Not on any route".
class IntelligenceScoreDistributionScreen extends ConsumerStatefulWidget {
  const IntelligenceScoreDistributionScreen({super.key});
  @override
  ConsumerState<IntelligenceScoreDistributionScreen> createState() => _State();
}

class _Group {
  final String key;
  final String name;
  final String sub; // market mode: the route's salesperson(s)
  final List<String> shops = [];
  _Group(this.key, this.name, [this.sub = '']);
}

class _State extends ConsumerState<IntelligenceScoreDistributionScreen> {
  bool _loading = true;
  String? _error;
  bool _byMarket = false;
  String? _routeId;
  String? _salespersonId;

  int _outOf = 0;
  final Map<String, int> _score = {}; // shop -> score
  final Map<String, Map<String, dynamic>> _shop = {}; // shop -> {shop_name, code}
  final Map<String, String> _routeName = {};
  final Map<String, Set<String>> _shopRoutes = {};
  final Map<String, Set<String>> _routeUsers = {};
  final Map<String, String> _userName = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<Map<String, dynamic>>> _paged(
      PostgrestFilterBuilder<List<Map<String, dynamic>>> Function() q, String orderCol) async {
    final out = <Map<String, dynamic>>[];
    for (var from = 0; ; from += 1000) {
      final page = await q().order(orderCol).range(from, from + 999);
      out.addAll(page);
      if (page.length < 1000) break;
    }
    return out;
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = Supabase.instance.client;
      final res = await Future.wait<List<Map<String, dynamic>>>([
        c.from('intelligence_products').select('id').eq('org_id', orgId).eq('is_active', true),
        _paged(() => c.from('placement_audit')
            .select('id, customer_id, product_id, is_present, surveyed_at').eq('org_id', orgId), 'id'),
        _paged(() => c.from('customers').select('id, shop_name, code')
            .eq('org_id', orgId).eq('is_active', true), 'id'),
        c.from('sales_routes').select('id, name, is_unassigned').eq('org_id', orgId),
        _paged(() => c.from('route_stops').select('route_id, customer_id').eq('org_id', orgId), 'customer_id'),
        c.from('users').select('id, name').eq('org_id', orgId),
      ]);
      final prodIds = {for (final p in res[0]) p['id'] as String};
      final active = {for (final s in res[2]) s['id'] as String: s};

      // Latest survey per (shop, product).
      final latest = <String, Map<String, dynamic>>{};
      for (final a in res[1]) {
        final pid = a['product_id'] as String?;
        final cid = a['customer_id'] as String?;
        if (pid == null || cid == null || !prodIds.contains(pid) || !active.containsKey(cid)) continue;
        final k = '$cid|$pid';
        final prev = latest[k];
        if (prev == null || '${a['surveyed_at']}'.compareTo('${prev['surveyed_at']}') > 0) latest[k] = a;
      }
      final score = <String, int>{};
      for (final a in latest.values) {
        final cid = a['customer_id'] as String;
        score[cid] = (score[cid] ?? 0) + (a['is_present'] == true ? 1 : 0);
      }

      final routeName = <String, String>{
        for (final r in res[3])
          if (r['is_unassigned'] != true) r['id'] as String: '${r['name'] ?? ''}'.trim(),
      };
      final shopRoutes = <String, Set<String>>{};
      for (final s in res[4]) {
        final rid = s['route_id'] as String?;
        final cid = s['customer_id'] as String?;
        if (rid == null || cid == null || !routeName.containsKey(rid)) continue;
        (shopRoutes[cid] ??= {}).add(rid);
      }
      final routeUsers = <String, Set<String>>{};
      final rids = routeName.keys.toList();
      for (var i = 0; i < rids.length; i += 150) {
        final chunk = rids.sublist(i, i + 150 > rids.length ? rids.length : i + 150);
        final rows = await c.from('route_assignments').select('route_id, user_id').inFilter('route_id', chunk);
        for (final a in rows) {
          final rid = a['route_id'] as String?;
          final uid = a['user_id'] as String?;
          if (rid == null || uid == null) continue;
          (routeUsers[rid] ??= {}).add(uid);
        }
      }

      if (!mounted) return;
      setState(() {
        _outOf = prodIds.length;
        _score..clear()..addAll(score);
        _shop..clear()..addAll({for (final id in score.keys) id: active[id]!});
        _routeName..clear()..addAll(routeName);
        _shopRoutes..clear()..addAll(shopRoutes);
        _routeUsers..clear()..addAll(routeUsers);
        _userName..clear()..addAll({for (final u in res[5]) u['id'] as String: '${u['name'] ?? ''}'.trim()});
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the survey data. Please try again.';
      });
    }
  }

  // ── grouping ──────────────────────────────────────────────────────────────

  bool _inScope(String cid) {
    final rs = _shopRoutes[cid] ?? const <String>{};
    if (_routeId != null && !rs.contains(_routeId)) return false;
    if (_salespersonId != null && !rs.any((r) => _routeUsers[r]?.contains(_salespersonId) ?? false)) return false;
    return true;
  }

  String _ownersOf(String rid) {
    final names = [for (final u in _routeUsers[rid] ?? const <String>{}) _userName[u] ?? '']
        .where((n) => n.isNotEmpty)
        .toList()
      ..sort();
    return names.isEmpty ? 'Not assigned' : names.join(', ');
  }

  List<_Group> _groups() {
    final g = <String, _Group>{};
    for (final cid in _score.keys) {
      if (!_inScope(cid)) continue;
      var rs = _shopRoutes[cid] ?? const <String>{};
      if (_routeId != null) rs = {_routeId!};
      if (rs.isEmpty) {
        g.putIfAbsent('_none', () => _Group('_none', 'Not on any route')).shops.add(cid);
        continue;
      }
      if (_byMarket) {
        for (final r in rs) {
          g.putIfAbsent(r, () => _Group(r, _routeName[r] ?? 'Route', _ownersOf(r))).shops.add(cid);
        }
      } else {
        final owners = <String>{};
        for (final r in rs) {
          owners.addAll(_routeUsers[r] ?? const <String>{});
        }
        if (_salespersonId != null) owners.retainAll({_salespersonId!});
        if (owners.isEmpty) {
          g.putIfAbsent('_noowner', () => _Group('_noowner', 'Not assigned')).shops.add(cid);
        }
        for (final u in owners) {
          g.putIfAbsent(u, () => _Group(u, _userName[u] ?? 'Unknown')).shops.add(cid);
        }
      }
    }
    final list = g.values.toList()
      ..sort((a, b) {
        int rank(_Group x) => x.key.startsWith('_') ? 1 : 0;
        final r = rank(a) - rank(b);
        return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  int _count(List<String> shops, int s) => shops.where((c) => _score[c] == s).length;
  double _avg(List<String> shops) =>
      shops.isEmpty ? 0 : shops.fold<int>(0, (a, c) => a + (_score[c] ?? 0)) / shops.length;
  String _pct(int n, int of) => of == 0 ? '0%' : '${(100 * n / of).round()}%';

  // ── exports ───────────────────────────────────────────────────────────────

  String get _scopeLabel {
    final parts = <String>[_byMarket ? 'By market' : 'By salesperson'];
    if (_routeId != null) parts.add('Route: ${_routeName[_routeId] ?? ''}');
    if (_salespersonId != null) parts.add('Salesperson: ${_userName[_salespersonId] ?? ''}');
    return parts.join('   ·   ');
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  void _exportExcel(List<_Group> groups, List<String> all) {
    try {
      final excel = xls.Excel.createExcel();
      const name = 'Score Distribution';
      final sheet = excel[name];
      final def = excel.getDefaultSheet();
      if (def != null && def != name) excel.delete(def);
      xls.TextCellValue t(Object? v) => xls.TextCellValue('${v ?? ''}');
      sheet.appendRow([t(ref.read(currentUserProvider)?.orgName ?? '')]);
      sheet.appendRow([t('Placement Score Distribution'), t(_today())]);
      sheet.appendRow([t('$_scopeLabel   ·   Score = products displayed, out of $_outOf')]);
      sheet.appendRow([t('')]);
      sheet.appendRow([
        t(_byMarket ? 'Market' : 'Salesperson'),
        if (_byMarket) t('Salesperson'),
        t('Shops'),
        t('Avg score'),
        for (var s = 0; s <= _outOf; s++) ...[t('$s shops'), t('$s %')],
      ]);
      void row(String label, String sub, List<String> shops) {
        sheet.appendRow([
          t(label),
          if (_byMarket) t(sub),
          xls.IntCellValue(shops.length),
          xls.DoubleCellValue(double.parse(_avg(shops).toStringAsFixed(1))),
          for (var s = 0; s <= _outOf; s++) ...[
            xls.IntCellValue(_count(shops, s)),
            xls.DoubleCellValue(shops.isEmpty ? 0 : double.parse((100 * _count(shops, s) / shops.length).toStringAsFixed(1))),
          ],
        ]);
      }
      for (final g in groups) {
        row(g.name, g.sub, g.shops);
      }
      row('All shops', '', all);
      excel.save(fileName: 'placement-score-distribution-${_today()}.xlsx');
    } catch (_) {
      _snack('Could not create the Excel file. Please try again.');
    }
  }

  Future<void> _exportPdf(List<_Group> groups, List<String> all) async {
    try {
      final org = ref.read(currentUserProvider)?.orgName ?? '';
      final doc = pw.Document();
      final font = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      final n = _outOf;
      pw.Widget cell(String s, {bool b = false, PdfColor? bg, pw.Alignment al = pw.Alignment.center}) => pw.Container(
            color: bg,
            alignment: al,
            padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
            child: pw.Text(s, style: pw.TextStyle(fontSize: 7.5, font: b ? bold : font)),
          );
      PdfColor heat(double p) {
        if (p <= 0) return PdfColors.white;
        final a = 0.12 + 0.55 * p;
        return PdfColor(1 - a * (1 - 0x2F / 255), 1 - a * (1 - 0x6F / 255), 1 - a * (1 - 0xED / 255));
      }
      pw.TableRow rowFor(String label, String sub, List<String> shops, {bool total = false}) => pw.TableRow(
            decoration: total ? const pw.BoxDecoration(color: PdfColors.grey200) : null,
            children: [
              cell(sub.isEmpty ? label : '$label\n$sub', b: total, al: pw.Alignment.centerLeft),
              cell('${shops.length}', b: total),
              cell(_avg(shops).toStringAsFixed(1), b: true),
              for (var s = 0; s <= n; s++)
                cell(
                  _count(shops, s) == 0 ? '-' : '${_count(shops, s)}\n${_pct(_count(shops, s), shops.length)}',
                  bg: shops.isEmpty ? null : heat(_count(shops, s) / shops.length),
                ),
            ],
          );
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(22),
        theme: pw.ThemeData.withFont(base: font, bold: bold),
        header: (ctx) => ctx.pageNumber == 1
            ? pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 10),
                child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                    pw.Text(org, style: pw.TextStyle(fontSize: 11, font: bold)),
                    pw.Text('Placement Score Distribution', style: const pw.TextStyle(fontSize: 16)),
                    pw.Text('$_scopeLabel   ·   Score = products displayed, out of $n',
                        style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
                  ]),
                  pw.Text(_today(), style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                ]))
            : pw.SizedBox(),
        footer: (ctx) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600))),
        build: (ctx) => [
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            columnWidths: {
              0: const pw.FlexColumnWidth(3.2),
              1: const pw.FlexColumnWidth(0.8),
              2: const pw.FlexColumnWidth(0.8),
              for (var s = 0; s <= n; s++) 3 + s: const pw.FlexColumnWidth(0.9),
            },
            children: [
              pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey100), children: [
                cell(_byMarket ? 'Market' : 'Salesperson', b: true, al: pw.Alignment.centerLeft),
                cell('Shops', b: true),
                cell('Avg', b: true),
                for (var s = 0; s <= n; s++) cell('$s', b: true),
              ]),
              for (final g in groups) rowFor(g.name, g.sub, g.shops),
              rowFor('All shops', '', all, total: true),
            ],
          ),
        ],
      ));
      await outputPdf(await doc.save(), 'Placement Score Distribution');
    } catch (_) {
      _snack('Could not create the PDF. Please try again.');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _showShops(String title, List<String> shops) {
    final list = [...shops]
      ..sort((a, b) => '${_shop[a]?['shop_name'] ?? ''}'.compareTo('${_shop[b]?['shop_name'] ?? ''}'));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 460,
          height: 420,
          child: ListView(children: [
            for (final c in list)
              ListTile(
                dense: true,
                title: Text('${_shop[c]?['shop_name'] ?? ''}'),
                subtitle: Text([
                  '${_shop[c]?['code'] ?? ''}',
                  ...[for (final r in _shopRoutes[c] ?? const <String>{}) _routeName[r] ?? ''],
                ].where((x) => x.isNotEmpty).join(' · ')),
                trailing: Text('${_score[c] ?? 0} / $_outOf', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isMobile = context.isMobile;
    final groups = _loading ? <_Group>[] : _groups();
    final all = _loading ? <String>[] : _score.keys.where(_inScope).toList();

    final routeOptions = _routeName.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final owners = <String>{for (final s in _routeUsers.values) ...s}.toList()
      ..sort((a, b) => (_userName[a] ?? '').toLowerCase().compareTo((_userName[b] ?? '').toLowerCase()));

    final spDropdown = SearchableDropdown(
      label: 'Salesperson',
      value: _salespersonId,
      allLabel: 'All salespeople',
      options: [for (final u in owners) MapEntry<String?, String>(u, _userName[u] ?? 'Unknown')],
      onChanged: (v) => setState(() => _salespersonId = v),
    );
    final routeDropdown = SearchableDropdown(
      label: 'Route',
      value: _routeId,
      allLabel: 'All routes',
      options: [for (final r in routeOptions) MapEntry<String?, String>(r.key, r.value)],
      onChanged: (v) => setState(() => _routeId = v),
    );
    final modeSwitch = SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: false, label: Text('By salesperson'), icon: Icon(Icons.person_outline, size: 16)),
        ButtonSegment(value: true, label: Text('By market'), icon: Icon(Icons.storefront_outlined, size: 16)),
      ],
      selected: {_byMarket},
      showSelectedIcon: false,
      onSelectionChanged: (s) => setState(() => _byMarket = s.first),
    );
    final excelBtn = OutlinedButton.icon(
      onPressed: _loading || all.isEmpty ? null : () => _exportExcel(groups, all),
      icon: const Icon(Icons.grid_on_outlined, size: 18),
      label: Text(isMobile ? 'Excel' : 'Export Excel'),
    );
    final pdfBtn = OutlinedButton.icon(
      onPressed: _loading || all.isEmpty ? null : () => _exportPdf(groups, all),
      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
      label: Text(isMobile ? 'PDF' : 'Export PDF'),
    );

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(isMobile ? 12 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Score Distribution', style: TextStyle(fontSize: isMobile ? 22 : 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          'How many shops sit at each placement score. Score = products displayed out of $_outOf, '
          'from each product\'s latest survey. A shop counts for the salesperson who owns its route. '
          'Click a number to see the shops.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        if (isMobile) ...[
          modeSwitch,
          const SizedBox(height: 10),
          spDropdown,
          const SizedBox(height: 10),
          routeDropdown,
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [excelBtn, pdfBtn]),
        ] else ...[
          Row(children: [
            Expanded(child: spDropdown),
            const SizedBox(width: 12),
            Expanded(child: routeDropdown),
          ]),
          const SizedBox(height: 12),
          Row(children: [modeSwitch, const Spacer(), excelBtn, const SizedBox(width: 8), pdfBtn]),
        ],
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Expanded(child: Center(child: Text(_error!)))
        else if (all.isEmpty)
          const Expanded(child: Center(child: Text('No surveyed shops for this selection.')))
        else
          Expanded(child: _table(groups, all, isMobile)),
      ]),
    );
  }

  Widget _table(List<_Group> groups, List<String> all, bool isMobile) {
    final nameW = isMobile ? 150.0 : 260.0;
    const numW = 62.0;
    const scoreW = 66.0;
    final n = _outOf;

    Widget head(String s, double w, {Alignment al = Alignment.center}) => Container(
          width: w,
          alignment: al,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Text(s, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
        );

    Widget row(String label, String sub, List<String> shops, {bool total = false}) {
      final avg = _avg(shops);
      return Container(
        decoration: BoxDecoration(
          color: total ? AppTheme.background : Colors.white,
          border: const Border(top: BorderSide(color: AppTheme.border)),
        ),
        child: Row(children: [
          Container(
            width: nameW,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontWeight: total ? FontWeight.w800 : FontWeight.w600, fontSize: 13)),
              if (sub.isNotEmpty)
                Text(sub, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11.5)),
            ]),
          ),
          InkWell(
            onTap: () => _showShops('$label · all shops', shops),
            child: SizedBox(width: numW, child: Center(child: Text('${shops.length}', style: const TextStyle(fontWeight: FontWeight.w600)))),
          ),
          SizedBox(
            width: numW,
            child: Center(
              child: Text(avg.toStringAsFixed(1),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: avg >= n * 0.7 ? AppTheme.success : (avg < n * 0.5 ? AppTheme.danger : AppTheme.textPrimary),
                  )),
            ),
          ),
          for (var s = 0; s <= n; s++)
            Builder(builder: (_) {
              final k = _count(shops, s);
              final p = shops.isEmpty ? 0.0 : k / shops.length;
              return InkWell(
                onTap: k == 0 ? null : () => _showShops('$label · score $s of $n', shops.where((c) => _score[c] == s).toList()),
                child: Container(
                  width: scoreW,
                  height: 46,
                  margin: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    color: k == 0 ? Colors.transparent : AppTheme.primary.withOpacity(0.08 + 0.5 * p),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: k == 0
                      ? const Text('–', style: TextStyle(color: AppTheme.textSecondary))
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('$k', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: p > 0.45 ? Colors.white : AppTheme.textPrimary)),
                          Text(_pct(k, shops.length),
                              style: TextStyle(fontSize: 11, color: p > 0.45 ? Colors.white : AppTheme.textSecondary)),
                        ]),
                ),
              );
            }),
        ]),
      );
    }

    final width = nameW + numW * 2 + (scoreW + 3) * (n + 1) + 8;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(children: [
            Row(children: [
              head(_byMarket ? 'Market' : 'Salesperson', nameW, al: Alignment.centerLeft),
              head('Shops', numW),
              head('Avg', numW),
              for (var s = 0; s <= n; s++) head('$s', scoreW + 3),
            ]),
            Expanded(
              child: ListView(children: [
                for (final g in groups) row(g.name, g.sub, g.shops),
                row('All shops', '', all, total: true),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
