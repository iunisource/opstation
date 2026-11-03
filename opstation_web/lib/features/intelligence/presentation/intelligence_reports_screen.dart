import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/pdf/pdf_output.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import '../services/survey_reports_pdf.dart';
import '../widgets/searchable_dropdown.dart';

/// Intelligence → Reports: the survey team's reports in one place, for a
/// chosen period and, optionally, one salesperson's or one route's shops.
class IntelligenceReportsScreen extends ConsumerStatefulWidget {
  const IntelligenceReportsScreen({super.key});
  @override
  ConsumerState<IntelligenceReportsScreen> createState() => _State();
}

class _Report {
  final String key;
  final String title;
  final String about;
  final IconData icon;
  const _Report(this.key, this.title, this.about, this.icon);
}

const _reports = [
  _Report(
    'audit',
    'Audit Report',
    'Every audit in the period: Matches, Issues and Feedback, with the auditor, '
        'comments, corrections and whether the auditor was at the shop.',
    Icons.fact_check_outlined,
  ),
  _Report(
    'surveyor',
    'Surveyor Report',
    'What each surveyor surveyed in the period — days active, shops visited, '
        'placement and competitor entries — and how their surveys held up in audits.',
    Icons.badge_outlined,
  ),
];

class _State extends ConsumerState<IntelligenceReportsScreen> {
  late DateTimeRange _range;
  String? _salespersonId;
  String? _routeId;
  final Map<String, String> _userName = {};
  final Map<String, String> _routeName = {};
  final Map<String, Set<String>> _routeUsers = {}; // route -> owners
  final Map<String, Set<String>> _routeShops = {}; // route -> shops
  bool _filtersReady = false;
  String? _busy; // report being created

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, 1), end: now);
    _loadFilters();
  }

  Future<void> _loadFilters() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    try {
      final users = await client.from('users').select('id, name').eq('org_id', orgId);
      final routes = List<Map<String, dynamic>>.from(await client
          .from('sales_routes')
          .select('id, name, is_unassigned')
          .eq('org_id', orgId)
          .order('name'));
      routes.removeWhere((r) => r['is_unassigned'] == true);
      final ids = [for (final r in routes) '${r['id']}'];
      final routeUsers = <String, Set<String>>{};
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        final rows = await client.from('route_assignments').select('user_id, route_id').inFilter('route_id', chunk);
        for (final a in rows) {
          if (a['user_id'] == null || a['route_id'] == null) continue;
          routeUsers.putIfAbsent('${a['route_id']}', () => <String>{}).add('${a['user_id']}');
        }
      }
      final routeShops = <String, Set<String>>{};
      final idSet = ids.toSet();
      for (var from = 0;; from += 1000) {
        final page = await client
            .from('route_stops')
            .select('customer_id, route_id')
            .eq('org_id', orgId)
            .order('route_id')
            .order('customer_id')
            .range(from, from + 999);
        for (final s in page) {
          final rid = '${s['route_id']}';
          if (s['customer_id'] == null || !idSet.contains(rid)) continue;
          routeShops.putIfAbsent(rid, () => <String>{}).add('${s['customer_id']}');
        }
        if ((page as List).length < 1000) break;
      }
      if (!mounted) return;
      setState(() {
        _userName
          ..clear()
          ..addAll({for (final u in users) '${u['id']}': '${u['name'] ?? 'Unknown'}'});
        _routeName
          ..clear()
          ..addAll({for (final r in routes) '${r['id']}': '${r['name'] ?? ''}'});
        _routeUsers
          ..clear()
          ..addAll(routeUsers);
        _routeShops
          ..clear()
          ..addAll(routeShops);
        _filtersReady = true;
      });
    } catch (_) {
      // Filters are optional: reports still work for the whole organisation.
      if (mounted) setState(() => _filtersReady = false);
    }
  }

  /// Routes shown in the Route list (only the salesperson's when one is picked).
  List<String> get _routeOptions {
    final ids = _routeName.keys
        .where((r) => _salespersonId == null || (_routeUsers[r]?.contains(_salespersonId) ?? false))
        .toList()
      ..sort((a, b) => _routeName[a]!.toLowerCase().compareTo(_routeName[b]!.toLowerCase()));
    return ids;
  }

  /// Shops the reports are limited to; null = whole organisation.
  Set<String>? get _shops {
    if (_routeId != null) return _routeShops[_routeId] ?? <String>{};
    if (_salespersonId != null) {
      return {
        for (final e in _routeUsers.entries)
          if (e.value.contains(_salespersonId)) ...?_routeShops[e.key],
      };
    }
    return null;
  }

  String? get _scope {
    if (_routeId != null) return 'Route: ${_routeName[_routeId] ?? ''}';
    if (_salespersonId != null) return 'Salesperson: ${_userName[_salespersonId] ?? ''}';
    return null;
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: _range,
      helpText: 'Report period',
    );
    if (picked != null && mounted) setState(() => _range = picked);
  }

  void _quick(String k) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      _range = switch (k) {
        'today' => DateTimeRange(start: today, end: today),
        '7' => DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
        'last_month' => DateTimeRange(
            start: DateTime(now.year, now.month - 1, 1),
            end: DateTime(now.year, now.month, 0),
          ),
        _ => DateTimeRange(start: DateTime(now.year, now.month, 1), end: today),
      };
    });
  }

  Future<void> _run(_Report r) async {
    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    if (orgId == null) return;
    setState(() => _busy = r.key);
    try {
      final orgName = user?.orgName ?? '';
      final bytes = r.key == 'audit'
          ? await SurveyReportsPdf.auditReport(
              orgId: orgId, orgName: orgName, from: _range.start, to: _range.end, shopIds: _shops, scope: _scope)
          : await SurveyReportsPdf.surveyorReport(
              orgId: orgId, orgName: orgName, from: _range.start, to: _range.end, shopIds: _shops, scope: _scope);
      await outputPdf(bytes, r.key == 'audit' ? 'Survey Audit Report' : 'Surveyor Report');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not create the report', e))));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = context.isMobile;
    final df = DateFormat('d MMM yyyy');
    final owners = <String>{for (final s in _routeUsers.values) ...s}.toList()
      ..sort((a, b) => (_userName[a] ?? '').toLowerCase().compareTo((_userName[b] ?? '').toLowerCase()));

    final period = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
        onPressed: _pickRange,
        icon: const Icon(Icons.date_range_outlined, size: 18),
        label: Text('${df.format(_range.start)}  –  ${df.format(_range.end)}'),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final q in const [('today', 'Today'), ('7', 'Last 7 days'), ('month', 'This month'), ('last_month', 'Last month')])
          ActionChip(label: Text(q.$2), onPressed: () => _quick(q.$1)),
      ]),
    ]);
    final spDropdown = SearchableDropdown(
      label: 'Salesperson',
      value: _salespersonId,
      allLabel: 'All salespeople',
      options: [for (final u in owners) MapEntry<String?, String>(u, _userName[u] ?? 'Unknown')],
      onChanged: (v) => setState(() {
        _salespersonId = v;
        if (_routeId != null && !_routeOptions.contains(_routeId)) _routeId = null;
      }),
    );
    final routeDropdown = SearchableDropdown(
      label: 'Route',
      value: _routeId,
      allLabel: 'All routes',
      options: [for (final r in _routeOptions) MapEntry<String?, String>(r, _routeName[r] ?? '')],
      onChanged: (v) => setState(() => _routeId = v),
    );

    return Container(
      color: AppTheme.background,
      child: ListView(padding: EdgeInsets.all(isMobile ? 12 : 32), children: [
        Text('Reports', style: TextStyle(fontSize: isMobile ? 22 : 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text(
          'Survey and audit reports. Pick the period, and a salesperson or route to see only their shops.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Period', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              period,
              if (_filtersReady) ...[
                const SizedBox(height: 16),
                if (isMobile) ...[
                  spDropdown,
                  const SizedBox(height: 10),
                  routeDropdown,
                ] else
                  Row(children: [
                    Expanded(child: spDropdown),
                    const SizedBox(width: 12),
                    Expanded(child: routeDropdown),
                  ]),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 16),
        for (final r in _reports)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(r.icon, color: AppTheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(r.about, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy != null ? null : () => _run(r),
                      icon: _busy == r.key
                          ? const SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                      label: Text(_busy == r.key ? 'Creating…' : 'Create PDF'),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}
