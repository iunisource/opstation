import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../pdf/report_pdf_builder.dart';
import 'package:printing/printing.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  List<Map<String, dynamic>> _trips = [];
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  DateTimeRange? _range;
  String? _selectedUserId;
  Map<String, List<Map<String, dynamic>>> _visitsByTrip = {};
  Map<String, Map<String, dynamic>> _customersById = {};

  @override
  void initState() {
    super.initState();
    _range = DateTimeRange(start: DateTime.now().subtract(const Duration(days: 7)), end: DateTime.now());
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final users = await client.from('users').select('id, name').eq('org_id', orgId).eq('role', 'salesperson');
      List<Map<String, dynamic>> trips;
      if (_selectedUserId != null) {
        trips = await client.from('trips').select().eq('org_id', orgId)
            .eq('user_id', _selectedUserId!)
            .gte('started_at', _range!.start.toIso8601String())
            .lte('started_at', _range!.end.add(const Duration(days: 1)).toIso8601String())
            .order('started_at', ascending: false);
      } else {
        trips = await client.from('trips').select().eq('org_id', orgId)
            .gte('started_at', _range!.start.toIso8601String())
            .lte('started_at', _range!.end.add(const Duration(days: 1)).toIso8601String())
            .order('started_at', ascending: false);
      }
      // Pre-fetch visits + customers for displayed trips so we can
      // show stop counts inline + power the per-row PDF buttons.
      final tripList = List<Map<String, dynamic>>.from(trips);
      final tripIds = tripList.map((t) => t['id'] as String).toList();
      Map<String, List<Map<String, dynamic>>> visitsByTrip = {};
      Map<String, Map<String, dynamic>> customersById = {};
      if (tripIds.isNotEmpty) {
        final v = await client
            .from('visits')
            .select()
            .inFilter('trip_id', tripIds);
        for (final row in v) {
          final m = Map<String, dynamic>.from(row);
          (visitsByTrip[m['trip_id'] as String] ??= []).add(m);
        }
        final custIds = (v as List)
            .map((r) => r['customer_id'] as String?)
            .whereType<String>()
            .toSet()
            .toList();
        if (custIds.isNotEmpty) {
          final c = await client
              .from('customers')
              .select('id, shop_name, code')
              .inFilter('id', custIds);
          for (final row in c) {
            final m = Map<String, dynamic>.from(row);
            customersById[m['id'] as String] = m;
          }
        }
      }

      setState(() {
        _users = List<Map<String, dynamic>>.from(users);
        _trips = tripList;
        _visitsByTrip = visitsByTrip;
        _customersById = customersById;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }


  Future<void> _generateTripSummary(Map<String, dynamic> trip) async {
    try {
      final visits = _visitsByTrip[trip['id']] ?? const <Map<String, dynamic>>[];
      final ctx = TripReportContext.build(
        trip: trip,
        visits: visits,
        customersById: _customersById,
      );
      final orgName =
          ref.read(currentUserProvider)?.orgName ?? 'Opstation';
      final bytes = await ReportPdfBuilder.buildTripSummary(
        ctx: ctx,
        orgName: orgName,
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to generate PDF: $e')),
      );
    }
  }

  Future<void> _generateVisitReport(Map<String, dynamic> trip) async {
    try {
      final visits = _visitsByTrip[trip['id']] ?? const <Map<String, dynamic>>[];
      final ctx = TripReportContext.build(
        trip: trip,
        visits: visits,
        customersById: _customersById,
      );
      final orgName =
          ref.read(currentUserProvider)?.orgName ?? 'Opstation';
      final bytes = await ReportPdfBuilder.buildVisitReport(
        ctx: ctx,
        orgName: orgName,
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
    final totalCollection = _trips.fold<int>(0, (s, t) => s + (t['total_collected'] as int? ?? 0));
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Reports', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 24),
        // Filters
        Row(children: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppTheme.textPrimary),
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(_range == null ? 'Select date range' : '${DateFormat('d MMM').format(_range!.start)} – ${DateFormat('d MMM').format(_range!.end)}'),
            onPressed: () async {
              final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now());
              if (r != null) { setState(() => _range = r); _load(); }
            },
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            hint: const Text('All salespersons'),
            value: _selectedUserId,
            items: [
              const DropdownMenuItem(value: null, child: Text('All salespersons')),
              ..._users.map((u) => DropdownMenuItem(value: u['id'] as String, child: Text(u['name'] as String))),
            ],
            onChanged: (v) { setState(() => _selectedUserId = v); _load(); },
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Text('Total: Rs $totalCollection', style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ),
        ]),
        const SizedBox(height: 16),
        if (_loading) const Center(child: CircularProgressIndicator())
        else Expanded(
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
                child: const Row(children: [
                  Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Salesperson', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Route', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text('Stops', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text('Visited', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Text('Collected', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  Expanded(flex: 1, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                  SizedBox(width: 110, child: Text('Reports', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: _trips.isEmpty
                  ? const Center(child: Text('No trips found for selected filters', style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                    itemCount: _trips.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final t = _trips[i];
                      final date = t['started_at'] != null ? DateFormat('d MMM yyyy').format(DateTime.parse(t['started_at'] as String).toLocal()) : '-';
                      final isCompleted = t['ended_at'] != null;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Row(children: [
                          Expanded(flex: 2, child: Text(date, style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 2, child: Text(t['user_name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600))),
                          Expanded(flex: 2, child: Text(t['route_name'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 1, child: Text('${(_visitsByTrip[t['id']] ?? const []).length}', style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 1, child: Text('${(_visitsByTrip[t['id']] ?? const []).where((v) => v['status'] == 'verified').length}', style: const TextStyle(fontSize: 13))),
                          Expanded(flex: 2, child: Text('Rs ${(_visitsByTrip[t['id']] ?? const []).fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0))}', style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.success))),
                          Expanded(flex: 1, child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: isCompleted ? AppTheme.success.withOpacity(0.1) : AppTheme.warning.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                            child: Text(isCompleted ? 'Done' : 'Active', style: TextStyle(color: isCompleted ? AppTheme.success : AppTheme.warning, fontSize: 11, fontWeight: FontWeight.w600)),
                          )),
                          SizedBox(
                            width: 110,
                            child: Row(children: [
                              IconButton(
                                icon: const Icon(Icons.summarize_outlined, size: 20, color: AppTheme.primary),
                                onPressed: () => _generateTripSummary(t),
                                tooltip: 'Trip Summary',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                              ),
                              IconButton(
                                icon: const Icon(Icons.assignment_outlined, size: 20, color: AppTheme.success),
                                onPressed: () => _generateVisitReport(t),
                                tooltip: 'Visit Report',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                              ),
                            ]),
                          ),
                        ]),
                      );
                    },
                  ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
