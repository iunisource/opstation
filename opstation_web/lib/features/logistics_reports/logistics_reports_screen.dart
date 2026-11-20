import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/pdf/pdf_output.dart';
import '../../core/utils/place_name.dart';
import '../../core/utils/reimb.dart';
import '../../core/utils/report_trail.dart';
import '../auth/auth_controller.dart';
import '../reports/pdf/report_pdf_builder.dart';
import '../reports/visit_report_open.dart';
import 'driver_job_pdf.dart';
import 'driver_job_report.dart';
import 'logistics_report_rows.dart';
import 'logistics_reports_view.dart';

/// Logistics Reports: the summaries of the drivers' work, generated on the web —
///  - Driver jobs (deliveries and pickups): the Driver Trip Summary with the stops in
///    sequence and the distance of every leg, including the way from the start and back to
///    the return location (the same document the driver's phone makes);
///  - Free routes the drivers ran: the Trip Summary and the Visit Report, exactly as on the
///    Reports page.
class LogisticsReportsScreen extends ConsumerStatefulWidget {
  const LogisticsReportsScreen({super.key});

  @override
  ConsumerState<LogisticsReportsScreen> createState() => _LogisticsReportsScreenState();
}

class _LogisticsReportsScreenState extends ConsumerState<LogisticsReportsScreen> {
  LogisticsTab _tab = LogisticsTab.jobs;
  late DateTimeRange _range;
  String? _driverId;
  List<Map<String, dynamic>> _drivers = [];
  List<JobRow> _jobs = [];
  List<TripRow> _trips = [];
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
      if (_tab == LogisticsTab.jobs) {
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
      } else {
        final ids = _driverId != null ? [_driverId!] : [for (final d in _drivers) '${d['id']}'];
        var trips = <Map<String, dynamic>>[];
        if (ids.isNotEmpty) {
          trips = List<Map<String, dynamic>>.from(await _db
              .from('trips')
              .select()
              .eq('org_id', orgId)
              .inFilter('user_id', ids)
              .gte('started_at', from)
              .lt('started_at', to)
              .order('started_at', ascending: false));
        }
        final counts = <String, int>{};
        for (final chunk in _chunks([for (final t in trips) '${t['id']}'], 100)) {
          final rows = await _db.from('visits').select('trip_id').inFilter('trip_id', chunk);
          for (final r in rows) {
            counts['${r['trip_id']}'] = (counts['${r['trip_id']}'] ?? 0) + 1;
          }
        }
        if (!mounted || seq != _loadSeq) return;
        setState(() {
          _trips = buildTripRows(trips, counts);
          _loading = false;
        });
      }
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

  // ---- Driver job: the Driver Trip Summary ---------------------------------------------

  Future<void> _jobSummary(String id) => _generate(id, () async {
        final d = await _db.from('deliveries').select().eq('id', id).maybeSingle();
        if (d == null) {
          _say('This job was not found.');
          return;
        }
        final stops = List<Map<String, dynamic>>.from(await _db.from('delivery_stops').select().eq('delivery_id', id).order('sequence'));
        final user = ref.read(currentUserProvider);
        final delivery = Map<String, dynamic>.from(d);
        final ctx = await DriverJobReport.build(
          delivery: delivery,
          stops: stops,
          orgId: user?.orgId,
          placeLookup: (lat, lng, until) => placeName(lat, lng, until: until), // start / end area names
        );
        final bytes = await DriverJobPdf.build(ctx: ctx, orgName: user?.orgName ?? 'Opstation');
        await outputPdf(bytes, 'Driver Trip Summary', date: DateTime.tryParse('${delivery['created_at'] ?? ''}')?.toLocal());
      });

  // ---- Free route: Trip Summary and Visit Report, as on the Reports page --------------

  Future<bool> _registerReportIssue(String type, String key, String? orgId, String? by) async {
    if (orgId == null) return false;
    final role = ref.read(currentUserProvider)?.role;
    final isAdmin = role == WebUserRole.admin || role == WebUserRole.masterAdmin || role == WebUserRole.superAdmin;
    try {
      final res = await _db.rpc('register_report_issue',
          params: {'p_org': orgId, 'p_type': type, 'p_key': key, 'p_by': by, 'p_increment': !isAdmin});
      return res == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _tripSummary(String tripId) => _generate(tripId, () async {
        final t = await _db.from('trips').select().eq('id', tripId).maybeSingle();
        if (t == null) {
          _say('This route was not found.');
          return;
        }
        final trip = Map<String, dynamic>.from(t);
        final visits = List<Map<String, dynamic>>.from(await _db.from('visits').select().eq('trip_id', tripId).order('timestamp', ascending: true));
        final custIds = {for (final v in visits) if (v['customer_id'] != null) v['customer_id'] as String}.toList();
        final custs = <String, Map<String, dynamic>>{};
        for (final chunk in _chunks(custIds, 400)) {
          for (final c in await _db.from('customers').select('id, shop_name, code').inFilter('id', chunk)) {
            custs[c['id'] as String] = Map<String, dynamic>.from(c);
          }
        }
        final places = await tripPlaceNames(trip);
        final ctx = await (await TripReportContext.buildRoad(
          trip: trip,
          visits: visits,
          customersById: custs,
          startAddress: places.$1,
          endAddress: places.$2,
        )).withFreePhotos();
        final user = ref.read(currentUserProvider);
        final orgName = user?.orgName ?? 'Opstation';
        // The same sequence as the Reports page, so a summary made here is the same document
        // (same re-issue watermark and claim record) as one made there.
        final duplicate = await _registerReportIssue('trip_summary', tripId, user?.orgId, user?.id);
        final isAdmin = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.superAdmin;
        final trail = await logReportIssue(user?.orgId, 'trip_summary', tripId, counted: !isAdmin);
        final started = DateTime.tryParse('${trip['started_at'] ?? ''}')?.toLocal();
        final reimb = await reimbSubmit(
          orgId: user?.orgId,
          type: 'trip_summary',
          key: tripId,
          claimantId: trip['user_id'] as String?,
          lines: [
            {'trip': tripId, 'day': started ?? DateTime.now(), 'km': ctx.totalDistanceKm}
          ],
          record: true,
        );
        final bytes = await ReportPdfBuilder.buildTripSummary(ctx: ctx, orgName: orgName, duplicate: duplicate, trail: trail, reimb: reimb);
        await outputPdf(bytes, 'Trip Summary', date: started);
        if (reimbLastError != null) {
          _say('Paid / already-generated details could not be checked: $reimbLastError', seconds: 8);
        }
      });

  Future<void> _visitReport(String tripId) => _generate('$tripId#v', () async {
        await openVisitReportForTrip(context, tripId, orgName: ref.read(currentUserProvider)?.orgName ?? 'Opstation');
      });

  @override
  Widget build(BuildContext context) {
    return LogisticsReportsView(
      tab: _tab,
      onTab: (t) {
        if (t == _tab) return;
        setState(() => _tab = t);
        _load();
      },
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
      trips: _trips,
      busyId: _busyId,
      onJobSummary: _jobSummary,
      onTripSummary: _tripSummary,
      onVisitReport: _visitReport,
    );
  }
}
