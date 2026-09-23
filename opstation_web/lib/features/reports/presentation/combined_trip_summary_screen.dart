import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';
import '../pdf/report_pdf_builder.dart';

/// Combined Trip Summary — a multi-date, distance-only reimbursement sheet.
/// Pick a salesperson (or all) and a date range; each day's total road
/// distance is aggregated with a grand total. The generated PDF leaves the
/// per-km rate and total amount blank for finance to fill in.
class CombinedTripSummaryScreen extends ConsumerStatefulWidget {
  const CombinedTripSummaryScreen({super.key});

  @override
  ConsumerState<CombinedTripSummaryScreen> createState() =>
      _CombinedTripSummaryScreenState();
}

class _DayRow {
  final DateTime date;
  final String salesperson;
  final Set<String> routes = {};
  double km = 0;
  int trips = 0;
  _DayRow({required this.date, required this.salesperson});
}

class _CombinedTripSummaryScreenState
    extends ConsumerState<CombinedTripSummaryScreen> {
  bool _loading = true;
  String? _error;
  DateTimeRange? _range;
  String? _selectedUserId;

  List<Map<String, dynamic>> _users = [];
  List<_DayRow> _rows = [];
  double _grandKm = 0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, 1), end: now);
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() {
        _error = 'No organization on the current user session.';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final users = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('role', 'salesperson');

      final start = _range!.start;
      final end = _range!.end.add(const Duration(days: 1));
      final List<Map<String, dynamic>> trips;
      if (_selectedUserId != null) {
        trips = await client
            .from('trips')
            .select()
            .eq('org_id', orgId)
            .eq('user_id', _selectedUserId!)
            .gte('started_at', start.toIso8601String())
            .lte('started_at', end.toIso8601String())
            .order('started_at', ascending: true);
      } else {
        trips = await client
            .from('trips')
            .select()
            .eq('org_id', orgId)
            .gte('started_at', start.toIso8601String())
            .lte('started_at', end.toIso8601String())
            .order('started_at', ascending: true);
      }

      final tripList = List<Map<String, dynamic>>.from(trips);
      final tripIds = tripList.map((t) => t['id'] as String).toList();

      final visitsByTrip = <String, List<Map<String, dynamic>>>{};
      final customersById = <String, Map<String, dynamic>>{};
      if (tripIds.isNotEmpty) {
        final v = <Map<String, dynamic>>[];
        for (var i = 0; i < tripIds.length; i += 40) {
          final batch = tripIds.sublist(
              i, i + 40 > tripIds.length ? tripIds.length : i + 40);
          final rows =
              await client.from('visits').select().inFilter('trip_id', batch);
          v.addAll(List<Map<String, dynamic>>.from(rows));
        }
        for (final row in v) {
          final m = Map<String, dynamic>.from(row);
          (visitsByTrip[m['trip_id'] as String] ??= []).add(m);
        }
        final custIds = v
            .map((r) => r['customer_id'] as String?)
            .whereType<String>()
            .toSet()
            .toList();
        for (var i = 0; i < custIds.length; i += 40) {
          final batch = custIds.sublist(
              i, i + 40 > custIds.length ? custIds.length : i + 40);
          final c = await client
              .from('customers')
              .select('id, shop_name, code')
              .inFilter('id', batch);
          for (final row in c) {
            final m = Map<String, dynamic>.from(row);
            customersById[m['id'] as String] = m;
          }
        }
      }

      // Aggregate distance per (salesperson, calendar day).
      final acc = <String, _DayRow>{};
      for (final t in tripList) {
        final startedAt = t['started_at'] as String?;
        if (startedAt == null) continue;
        final dt = DateTime.parse(startedAt).toLocal();
        final d = DateTime(dt.year, dt.month, dt.day);
        final uid = t['user_id'] as String? ?? '';
        final key = '$uid|${d.toIso8601String()}';
        final row = acc.putIfAbsent(
          key,
          () => _DayRow(date: d, salesperson: t['user_name'] as String? ?? '-'),
        );
        final ctx = TripReportContext.build(
          trip: t,
          visits: visitsByTrip[t['id']] ?? const <Map<String, dynamic>>[],
          customersById: customersById,
        );
        row.km += ctx.totalDistanceKm;
        row.trips += 1;
        final rn = (t['route_name'] as String?)?.trim() ?? '';
        if (rn.isNotEmpty) row.routes.add(rn);
      }

      final rows = acc.values.toList()
        ..sort((a, b) {
          final s = a.salesperson.compareTo(b.salesperson);
          return s != 0 ? s : a.date.compareTo(b.date);
        });
      final grand = rows.fold<double>(0, (s, r) => s + r.km);

      setState(() {
        _users = List<Map<String, dynamic>>.from(users);
        _rows = rows;
        _grandKm = grand;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _generatePdf() async {
    try {
      final showSalesperson = _selectedUserId == null;
      final salespersonLabel = _selectedUserId == null
          ? 'All salespersons'
          : (_users.firstWhere((u) => u['id'] == _selectedUserId,
                  orElse: () => {'name': 'Salesperson'})['name'] as String);
      final periodLabel =
          '${DateFormat('d MMM y').format(_range!.start)} - ${DateFormat('d MMM y').format(_range!.end)}';
      final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';

      final pdfRows = _rows
          .map((r) => CombinedSummaryRow(
                date: r.date,
                salesperson: r.salesperson,
                routes: r.routes.join(', '),
                km: r.km,
              ))
          .toList();

      final bytes = await ReportPdfBuilder.buildCombinedTripSummary(
        orgName: orgName,
        periodLabel: periodLabel,
        salespersonLabel: salespersonLabel,
        showSalesperson: showSalesperson,
        rows: pdfRows,
        grandTotalKm: _grandKm,
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to generate PDF: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSalesperson = _selectedUserId == null;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Combined Trip Summary',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text(
          'Multi-date distance sheet for expense reimbursement. Rate per km and total amount are left blank for finance.',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 20),
        Row(children: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppTheme.textPrimary),
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(_range == null
                ? 'Select date range'
                : '${DateFormat('d MMM').format(_range!.start)} – ${DateFormat('d MMM').format(_range!.end)}'),
            onPressed: () async {
              final r = await showDateRangePicker(
                  context: context,
                  firstDate: DateTime(2024),
                  lastDate: DateTime.now(),
                  initialDateRange: _range);
              if (r != null) {
                setState(() => _range = r);
                _load();
              }
            },
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            hint: const Text('All salespersons'),
            value: _selectedUserId,
            items: [
              const DropdownMenuItem(
                  value: null, child: Text('All salespersons')),
              ..._users.map((u) => DropdownMenuItem(
                  value: u['id'] as String, child: Text(u['name'] as String))),
            ],
            onChanged: (v) {
              setState(() => _selectedUserId = v);
              _load();
            },
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Text('Total: ${_grandKm.toStringAsFixed(2)} km',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('Generate PDF'),
            onPressed: (_loading || _rows.isEmpty) ? null : _generatePdf,
          ),
        ]),
        const SizedBox(height: 16),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Color(0xFFDC2626), size: 32),
                    const SizedBox(height: 12),
                    const Text('Could not load trips',
                        style:
                            TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 6),
                    SelectableText(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Color(0xFFDC2626), fontSize: 12)),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(
            child: HScrollOnNarrow(
              minWidth: 820,
              child: Container(
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border)),
                child: Column(children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(12))),
                    child: Row(children: [
                      const Expanded(
                          flex: 2,
                          child: Text('Date',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppTheme.textSecondary))),
                      if (showSalesperson)
                        const Expanded(
                            flex: 2,
                            child: Text('Salesperson',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: AppTheme.textSecondary))),
                      const Expanded(
                          flex: 3,
                          child: Text('Route(s)',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppTheme.textSecondary))),
                      const Expanded(
                          flex: 2,
                          child: Text('Distance (km)',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppTheme.textSecondary))),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _rows.isEmpty
                        ? const Center(
                            child: Text('No trips found for selected filters',
                                style:
                                    TextStyle(color: AppTheme.textSecondary)))
                        : ListView.separated(
                            itemCount: _rows.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final r = _rows[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                      flex: 2,
                                      child: Text(
                                          DateFormat('EEE, d MMM y')
                                              .format(r.date),
                                          style: const TextStyle(fontSize: 13))),
                                  if (showSalesperson)
                                    Expanded(
                                        flex: 2,
                                        child: Text(r.salesperson,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 13))),
                                  Expanded(
                                      flex: 3,
                                      child: Text(r.routes.join(', '),
                                          style: const TextStyle(fontSize: 13))),
                                  Expanded(
                                      flex: 2,
                                      child: Text(r.km.toStringAsFixed(2),
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700))),
                                ]),
                              );
                            },
                          ),
                  ),
                  const Divider(height: 1),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius:
                            BorderRadius.vertical(bottom: Radius.circular(12))),
                    child: Row(children: [
                      const Expanded(
                          flex: 2,
                          child: Text('GRAND TOTAL',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 13))),
                      if (showSalesperson) const Expanded(flex: 2, child: Text('')),
                      const Expanded(flex: 3, child: Text('')),
                      Expanded(
                          flex: 2,
                          child: Text('${_grandKm.toStringAsFixed(2)} km',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primary))),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}
