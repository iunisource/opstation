import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/pdf/pdf_output.dart';
import '../../core/utils/place_name.dart';
import '../auth/auth_controller.dart';
import '../deliveries/delivery_report_pdf.dart';
import 'driver_job_report.dart';
import 'logistics_report_rows.dart';
import 'logistics_reports_view.dart';

/// Logistics Reports: the report of every driver job, generated on the web — deliveries, pickups and
/// the free routes the drivers ran. It is the same Delivery Report the driver's phone makes, with the
/// distances merged in: where the job started and ended, the distance against each stop, the way back
/// to the return location, the total.
class LogisticsReportsScreen extends ConsumerStatefulWidget {
  const LogisticsReportsScreen({super.key});

  @override
  ConsumerState<LogisticsReportsScreen> createState() => _LogisticsReportsScreenState();
}

class _LogisticsReportsScreenState extends ConsumerState<LogisticsReportsScreen> {
  late DateTimeRange _range;
  String? _driverId;
  List<Map<String, dynamic>> _drivers = [];
  List<JobRow> _jobs = [];
  bool _loading = true;
  String? _error;
  String? _busyId;
  int _loadSeq = 0; // a late answer of an older filter never replaces a newer one

  SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _range = DateTimeRange(start: DateTime.now().subtract(const Duration(days: 7)), end: DateTime.now());
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reloadDrivers: true));
  }

  static List<List<T>> _chunks<T>(List<T> l, int n) => [for (var i = 0; i < l.length; i += n) l.sublist(i, i + n > l.length ? l.length : i + n)];

  Future<void> _load({bool reloadDrivers = false}) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (reloadDrivers || _drivers.isEmpty) {
        final d = await _db.from('users').select('id, name').eq('org_id', orgId).eq('role', 'driver');
        _drivers = List<Map<String, dynamic>>.from(d);
      }
      final from = DateTime(_range.start.year, _range.start.month, _range.start.day).toUtc().toIso8601String();
      final to = DateTime(_range.end.year, _range.end.month, _range.end.day).add(const Duration(days: 1)).toUtc().toIso8601String();
      var q = _db.from('deliveries').select().eq('org_id', orgId).neq('status', 'draft').not('driver_id', 'is', null).gte('created_at', from).lt('created_at', to);
      if (_driverId != null) q = q.eq('driver_id', _driverId!);
      final deliveries = List<Map<String, dynamic>>.from(await q.order('created_at', ascending: false));
      final stopsBy = <String, List<Map<String, dynamic>>>{};
      for (final chunk in _chunks([for (final d in deliveries) '${d['id']}'], 100)) {
        final rows = await _db.from('delivery_stops').select('delivery_id, stop_type, status').inFilter('delivery_id', chunk);
        for (final r in rows) {
          stopsBy.putIfAbsent('${r['delivery_id']}', () => []).add(Map<String, dynamic>.from(r));
        }
      }
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _jobs = buildJobRows(deliveries, stopsBy);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
        context: context, firstDate: DateTime(2024), lastDate: DateTime.now(), initialDateRange: _range);
    if (r != null) {
      setState(() => _range = r);
      _load();
    }
  }

  void _say(String m, {int seconds = 4}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: Duration(seconds: seconds)));
  }

  /// Runs one PDF at a time; the button of [id] shows a spinner meanwhile.
  Future<void> _generate(String id, Future<void> Function() job) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      await job();
    } catch (e) {
      _say('Failed to generate PDF: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  // ---- A job: the job sheet with the distances ----------------------------------------

  Future<void> _jobReport(String id) => _generate(id, () async {
        final d = await _db.from('deliveries').select().eq('id', id).maybeSingle();
        if (d == null) {
          _say('This job was not found.');
          return;
        }
        final stops = List<Map<String, dynamic>>.from(await _db.from('delivery_stops').select().eq('delivery_id', id).order('sequence'));
        final user = ref.read(currentUserProvider);
        final delivery = Map<String, dynamic>.from(d);
        // The distances; if they cannot be worked out now the sheet is still made, without them.
        DriverJobReportContext? route;
        try {
          route = await DriverJobReport.build(
            delivery: delivery,
            stops: stops,
            orgId: user?.orgId,
            placeLookup: (lat, lng, until) => placeName(lat, lng, until: until), // start / end area names
          );
        } catch (_) {}
        final bytes = await DeliveryReportPdf.build(
          delivery: delivery,
          stops: stops,
          orgName: user?.orgName ?? 'Opstation',
          route: route,
        );
        await outputPdf(bytes, 'Delivery Report - ${delivery['driver_name'] ?? 'Delivery'}',
            date: DateTime.tryParse('${delivery['created_at'] ?? ''}')?.toLocal());
      });

  @override
  Widget build(BuildContext context) {
    return LogisticsReportsView(
      range: _range,
      onPickRange: _pickRange,
      drivers: _drivers,
      driverId: _driverId,
      onDriver: (v) {
        setState(() => _driverId = v);
        _load();
      },
      loading: _loading,
      error: _error,
      onRetry: _load,
      jobs: _jobs,
      busyId: _busyId,
      onJobReport: _jobReport,
    );
  }
}
