import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/pdf/pdf_output.dart';
import '../../core/utils/place_name.dart';
import 'pdf/report_pdf_builder.dart';
import 'package:opstation_web/core/widgets/generating_overlay.dart';

/// Market Visit Report for one trip, built the same way as on the Reports
/// screen and in Team 360 (so it is identical wherever it is opened).
Future<void> openVisitReportForTrip(BuildContext context, String tripId, {required String orgName}) =>
    withGenerating(context, () => _openVisitReportForTripRun(context, tripId, orgName: orgName));

Future<void> _openVisitReportForTripRun(BuildContext context, String tripId, {required String orgName}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final client = Supabase.instance.client;
    final t = await client.from('trips').select().eq('id', tripId).maybeSingle();
    if (t == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('No visit report for this day (no route found).')));
      return;
    }
    messenger?.showSnackBar(const SnackBar(content: Text('Preparing the visit report…'), duration: Duration(seconds: 2)));
    final visits = List<Map<String, dynamic>>.from(
        await client.from('visits').select().eq('trip_id', tripId).order('timestamp', ascending: true));
    final ids = {for (final v in visits) if (v['customer_id'] != null) v['customer_id'] as String}.toList();
    final custs = <String, Map<String, dynamic>>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      for (final c in await client.from('customers').select('id, shop_name, code').inFilter('id', chunk)) {
        custs[c['id'] as String] = Map<String, dynamic>.from(c);
      }
    }
    final ctx = await TripReportContext.buildComplete(
      trip: t,
      visits: visits,
      customersById: custs,
      placesOf: tripPlaceNames, // start / end area names, fetched together with the road distances
      withPlannedStops: true,
    );
    final bytes = await ReportPdfBuilder.buildVisitReport(ctx: ctx, orgName: orgName);
    await outputPdf(bytes, 'Visit Report', date: DateTime.tryParse('${t['started_at'] ?? ''}')?.toLocal());
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not open the visit report: $e')));
  }
}
