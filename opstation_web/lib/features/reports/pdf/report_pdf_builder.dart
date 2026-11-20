import 'dart:math';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:opstation_web/core/utils/visit_outcome.dart';

import '../../../core/format/money.dart';
import '../../../core/utils/route_distances.dart';
import '../../../core/utils/receipt_book_rules.dart';
import '../../../core/utils/member_receipt_books.dart';
import '../../../core/format/time_format.dart';

/// How a trip report finds the place name of a visit's GPS point. Set once at
/// start-up (main.dart: the shared place-name lookup). Null = no names, the GPS
/// point is shown instead.
Future<String?> Function(double lat, double lng, DateTime until)? tripReportPlaceName;

/// Web port of mobile's TripReportContext.
/// Pre-computed data for a trip report. [build] uses straight lines;
/// [buildRoad] uses Google road distances via the server when available.
class TripReportContext {
  final Map<String, dynamic> trip;
  final List<Map<String, dynamic>> visits;
  final Map<String, Map<String, dynamic>> customersById;
  final String? startAddress;
  final String? endAddress;
  final List<Map<String, dynamic>> orderedVerifiedVisits;
  final List<double> distanceKm;
  final double returnDistanceKm;
  final double totalDistanceKm;
  final bool usedGoogle;

  /// Place name of each visit marked without a customer (visit id → name).
  final Map<String, String> freePlaceNames;

  /// Receipt-books flow ON/OFF and the salesperson's books, for the admin "Missing
  /// receipts" line. Null = not read: the old number-sequence check is used.
  final ReceiptCheckData? receiptCheck;

  /// The customers the route planned for this trip, in route order (the trip's stops).
  /// Empty for a free route or when they were not read: the report then lists only the
  /// customers that were actually marked.
  final List<String> plannedStops;

  const TripReportContext({
    required this.trip,
    required this.visits,
    required this.customersById,
    required this.startAddress,
    required this.endAddress,
    required this.orderedVerifiedVisits,
    required this.distanceKm,
    required this.returnDistanceKm,
    required this.totalDistanceKm,
    required this.usedGoogle,
    this.freePlaceNames = const {},
    this.receiptCheck,
    this.plannedStops = const [],
  });

  TripReportContext _withExtras({
    Map<String, String>? names,
    ReceiptCheckData? check,
    List<String>? planned,
    Map<String, Map<String, dynamic>>? customers,
  }) =>
      TripReportContext(
        trip: trip,
        visits: visits,
        customersById: customers ?? customersById,
        startAddress: startAddress,
        endAddress: endAddress,
        orderedVerifiedVisits: orderedVerifiedVisits,
        distanceKm: distanceKm,
        returnDistanceKm: returnDistanceKm,
        totalDistanceKm: totalDistanceKm,
        usedGoogle: usedGoogle,
        freePlaceNames: names ?? freePlaceNames,
        receiptCheck: check ?? receiptCheck,
        plannedStops: planned ?? plannedStops,
      );

  factory TripReportContext.build({
    required Map<String, dynamic> trip,
    required List<Map<String, dynamic>> visits,
    required Map<String, Map<String, dynamic>> customersById,
    String? startAddress,
    String? endAddress,
    List<String> plannedStops = const [],
  }) {
    final ordered = visits
        .where((v) =>
            (v['status'] == 'verified' || visitIsFree(v)) &&
            v['captured_lat'] != null &&
            v['captured_lng'] != null)
        .toList()
      ..sort((a, b) => DateTime.parse(a['timestamp'] as String)
          .compareTo(DateTime.parse(b['timestamp'] as String)));

    final startLat = (trip['start_lat'] as num?)?.toDouble();
    final startLng = (trip['start_lng'] as num?)?.toDouble();
    final endLat = (trip['end_lat'] as num?)?.toDouble();
    final endLng = (trip['end_lng'] as num?)?.toDouble();
    final hasStart = startLat != null && startLng != null;
    final hasEnd = endLat != null && endLng != null;

    final distances = <double>[];
    if (ordered.isNotEmpty) {
      double prevLat;
      double prevLng;
      if (hasStart) {
        prevLat = startLat;
        prevLng = startLng;
      } else {
        prevLat = (ordered.first['captured_lat'] as num).toDouble();
        prevLng = (ordered.first['captured_lng'] as num).toDouble();
      }
      for (var i = 0; i < ordered.length; i++) {
        final v = ordered[i];
        final lat = (v['captured_lat'] as num).toDouble();
        final lng = (v['captured_lng'] as num).toDouble();
        if (i == 0 && !hasStart) {
          distances.add(0);
        } else {
          distances.add(_haversineKm(prevLat, prevLng, lat, lng));
        }
        prevLat = lat;
        prevLng = lng;
      }
    }

    double returnKm = 0;
    if (hasEnd && ordered.isNotEmpty) {
      final last = ordered.last;
      final lat = (last['captured_lat'] as num).toDouble();
      final lng = (last['captured_lng'] as num).toDouble();
      returnKm = _haversineKm(lat, lng, endLat, endLng);
    }

    final total = distances.fold<double>(0, (s, d) => s + d) + returnKm;

    return TripReportContext(
      trip: trip,
      visits: visits,
      customersById: customersById,
      startAddress: startAddress,
      endAddress: endAddress,
      orderedVerifiedVisits: ordered,
      distanceKm: distances,
      returnDistanceKm: returnKm,
      totalDistanceKm: total,
      usedGoogle: false,
      plannedStops: plannedStops,
    );
  }

  /// Same as [build], but with road distances from Google (via the server,
  /// saved per trip) when available; straight lines otherwise.
  static Future<TripReportContext> buildRoad({
    required Map<String, dynamic> trip,
    required List<Map<String, dynamic>> visits,
    required Map<String, Map<String, dynamic>> customersById,
    String? startAddress,
    String? endAddress,
    bool withPlannedStops = false, // the Visit Report: list every stop of the route
  }) async {
    final ctx = await _buildRoadDistances(
      trip: trip,
      visits: visits,
      customersById: customersById,
      startAddress: startAddress,
      endAddress: endAddress,
    );
    final names = await _freePlaces(ctx);
    final check = await _tripReceiptCheck(ctx);
    final stops = withPlannedStops ? await _readPlannedStops(ctx) : null;
    if (names.isEmpty && check == null && stops == null) return ctx;
    return ctx._withExtras(
      names: names.isEmpty ? null : names,
      check: check,
      planned: stops?.$1,
      customers: stops?.$2,
    );
  }

  /// The trip's planned stops (trip_stops, in route order) and the customers among them that
  /// the caller did not load (a stop never visited has no visit to load its customer from).
  /// Null when there are none or they cannot be read: the report is then built as before.
  static Future<(List<String>, Map<String, Map<String, dynamic>>)?> _readPlannedStops(TripReportContext ctx) async {
    final tripId = ctx.trip['id'] as String?;
    if (tripId == null) return null;
    try {
      final db = Supabase.instance.client;
      final rows = await db.from('trip_stops').select('customer_id, position').eq('trip_id', tripId).order('position');
      final ids = <String>[];
      for (final r in rows as List) {
        final c = r['customer_id'];
        if (c != null && !ids.contains('$c')) ids.add('$c');
      }
      if (ids.isEmpty) return null;
      final merged = <String, Map<String, dynamic>>{...ctx.customersById};
      final missing = [for (final id in ids) if (!merged.containsKey(id)) id];
      for (var i = 0; i < missing.length; i += 100) {
        final chunk = missing.sublist(i, i + 100 > missing.length ? missing.length : i + 100);
        final cs = await db.from('customers').select('id, code, shop_name').inFilter('id', chunk);
        for (final c in cs as List) {
          merged['${c['id']}'] = Map<String, dynamic>.from(c as Map);
        }
      }
      return (ids, merged);
    } catch (_) {
      return null;
    }
  }

  /// The flow setting and the salesperson's books, for the "Missing receipts" line.
  /// Null when the trip has no user or organisation — the old check is then used.
  static Future<ReceiptCheckData?> _tripReceiptCheck(TripReportContext ctx) async {
    final uid = ctx.trip['user_id'] as String?;
    String? org = ctx.trip['org_id'] as String?;
    if (org == null) {
      for (final v in ctx.visits) {
        if (v['org_id'] != null) {
          org = v['org_id'] as String;
          break;
        }
      }
    }
    if (uid == null || org == null) return null;
    return loadReceiptCheck(orgId: org, userId: uid);
  }

  /// Place names of the visits marked without a customer: the name the phone
  /// saved with the visit, else the shared place-name lookup (within a time
  /// budget). A visit without a name is listed by its GPS point.
  static Future<Map<String, String>> _freePlaces(TripReportContext ctx) async {
    final out = <String, String>{};
    final until = DateTime.now().add(const Duration(seconds: 10));
    for (final v in ctx.orderedVerifiedVisits) {
      if (!visitIsFree(v)) continue;
      final id = '${v['id']}';
      final saved = (v['location_name'] as String?)?.trim();
      if (saved != null && saved.isNotEmpty) {
        out[id] = saved;
        continue;
      }
      final lookup = tripReportPlaceName;
      if (lookup == null) continue;
      try {
        final n = await lookup((v['captured_lat'] as num).toDouble(), (v['captured_lng'] as num).toDouble(), until);
        if (n != null && n.trim().isNotEmpty) out[id] = n.trim();
      } catch (_) {}
    }
    return out;
  }

  static Future<TripReportContext> _buildRoadDistances({
    required Map<String, dynamic> trip,
    required List<Map<String, dynamic>> visits,
    required Map<String, Map<String, dynamic>> customersById,
    String? startAddress,
    String? endAddress,
  }) async {
    final base = TripReportContext.build(
      trip: trip,
      visits: visits,
      customersById: customersById,
      startAddress: startAddress,
      endAddress: endAddress,
    );
    final ordered = base.orderedVerifiedVisits;
    if (ordered.isEmpty) return base;
    final sLat = (trip['start_lat'] as num?)?.toDouble();
    final sLng = (trip['start_lng'] as num?)?.toDouble();
    final eLat = (trip['end_lat'] as num?)?.toDouble();
    final eLng = (trip['end_lng'] as num?)?.toDouble();
    final hasStart = sLat != null && sLng != null;
    final hasEnd = eLat != null && eLng != null;
    final points = <List<double>>[
      if (hasStart) [sLat, sLng],
      for (final v in ordered) [(v['captured_lat'] as num).toDouble(), (v['captured_lng'] as num).toDouble()],
      if (hasEnd) [eLat, eLng],
    ];
    final legs = await roadLegsKm(trip['org_id'] as String?, points);
    if (legs == null) return base;
    final distances = <double>[];
    for (var i = 0; i < ordered.length; i++) {
      if (hasStart) {
        distances.add(legs[i]);
      } else {
        distances.add(i == 0 ? 0 : legs[i - 1]);
      }
    }
    final returnKm = hasEnd ? legs.last : 0.0;
    final total = distances.fold<double>(0, (s, d) => s + d) + returnKm;
    return TripReportContext(
      trip: trip,
      visits: visits,
      customersById: customersById,
      startAddress: startAddress,
      endAddress: endAddress,
      orderedVerifiedVisits: ordered,
      distanceKm: distances,
      returnDistanceKm: returnKm,
      totalDistanceKm: total,
      usedGoogle: true,
    );
  }

  static double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthKm = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = (sin(dLat / 2) * sin(dLat / 2)) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * (sin(dLng / 2) * sin(dLng / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthKm * c;
  }

  static double _rad(double deg) => deg * (pi / 180.0);
}

/// One aggregated line of a Combined Trip Summary: the total road distance a
/// salesperson covered on a single date, and the route(s) they ran that day.
/// The four numbers at the top of the Visit Report.
class VisitReportSummary {
  const VisitReportSummary({required this.customers, required this.visited, required this.completion, required this.collected});

  final int customers;
  final int visited;

  /// Null when the route had no planned stops.
  final double? completion;
  final int collected;
}

class CombinedSummaryRow {
  final DateTime date;
  final String salesperson;
  final String routes;
  final double km;
  /// Same salesperson, same weekday one week earlier. Null = no trip that day.
  final double? lastWeekKm;
  const CombinedSummaryRow({
    required this.date,
    required this.salesperson,
    required this.routes,
    required this.km,
    this.lastWeekKm,
  });
}

/// Web port of mobile's ReportPdfBuilder. Same layout, fonts, colors, spacing.
/// Reimbursement status printed on trip summaries (SQL 466).
class ReimbInfo {
  final double? rate; // Rs per km (null = left blank)
  final String? stamp; // why days are excluded (already approved), one line per claim
  final bool fullyPaid; // every day already approved → nothing to claim
  final String? approvedBy;
  /// When the claim was approved (for the APPROVED watermark).
  final DateTime? approvedAt;
  /// Public check link of the claim (SQL 485) → trust badge + QR under the
  /// signature line.
  final String? verifyUrl;
  final double paidKm; // km of trips already approved / paid (excluded)
  /// Dates (yyyy-MM-dd) with a trip already approved → marked † and excluded.
  final Set<String> excludedDays;
  /// Dates (yyyy-MM-dd) already generated for reimbursement on other sheets,
  /// and the printed explanation (replaces the DUPLICATE watermark).
  final Set<String> generatedDays;
  final String? generatedNote;
  /// Admin Settings → allowance per day (null = not set → line left blank).
  final double? allowancePerDay;
  /// Days on this sheet not already paid (null = all of the sheet's days).
  final int? unpaidDays;
  /// Allowance total set by the approver (days can differ); overrides per-day × days.
  final double? allowanceTotal;
  const ReimbInfo({this.rate, this.stamp, this.fullyPaid = false, this.approvedBy, this.approvedAt, this.verifyUrl, this.paidKm = 0,
      this.excludedDays = const <String>{}, this.generatedDays = const <String>{}, this.generatedNote, this.allowancePerDay, this.unpaidDays,
      this.allowanceTotal});
}

class ReportPdfBuilder {
  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _mutedLight = PdfColor.fromInt(0xFF9CA3AF);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);

  // ========= Market Visit Report =========================================

  static Future<Uint8List> buildVisitReport({
    required TripReportContext ctx,
    required String orgName,
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      header: (c) => _pageHeader(orgName, 'Market Visit Report'),
      footer: (c) => _pageFooter(c, orgName, 'Market Visit Report'),
      build: (c) => [
        _subtitleLine(trip),
        pw.SizedBox(height: 14),
        _journeyBlock(trip, ctx.startAddress, ctx.endAddress, status: true),
        pw.SizedBox(height: 14),
        _summaryRow(trip, ctx),
        pw.SizedBox(height: 14),
        _sectionTitle('Visit Details'),
        pw.SizedBox(height: 6),
        _visitDetailsTable(ctx),
        pw.SizedBox(height: 10),
        _receiptsFooter(ctx),
        _receiptGapsNote(ctx),
        pw.SizedBox(height: 36),
        _signatureLine(),
      ],
    ));
    return doc.save();
  }

  // ========= Trip Summary ================================================

  static Future<Uint8List> buildTripSummary({
    required TripReportContext ctx,
    required String orgName,
    bool duplicate = false,
    List<String> trail = const [],
    ReimbInfo? reimb,
    String? adjustNote, // "Adjusted by approver" box (Reimbursement Approvals)
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageTheme: _pageTheme(duplicate, reimb),
      header: (c) => _pageHeader(orgName, 'Trip Summary', verifyUrl: reimb?.verifyUrl),
      footer: (c) => _withTrail(duplicate ? trail : const [], _pageFooter(c, orgName, 'Trip Summary',
          distanceNote: ctx.usedGoogle
              ? 'Distances: Google Directions API (road distance)'
              : 'Distances: straight-line / Haversine')),
      build: (c) => [
        _subtitleLine(trip),
        pw.SizedBox(height: 14),
        _journeyBlock(trip, ctx.startAddress, ctx.endAddress,
            status: false,
            totalVisitsOverride: ctx.orderedVerifiedVisits.length),
        pw.SizedBox(height: 14),
        _sequencedTable(ctx),
        pw.SizedBox(height: 18),
        if (adjustNote != null) ...[_adjustBox(adjustNote), pw.SizedBox(height: 10)],
        if (reimb?.generatedNote != null) ...[_generatedBox(reimb!.generatedNote!), pw.SizedBox(height: 10)],
        if (reimb?.stamp != null) ...[_paidStamp(reimb!), pw.SizedBox(height: 10)],
        _reimbursementBlock(ctx, reimb),
        pw.SizedBox(height: 36),
        _signatureLine(reimb),
      ],
    ));
    return doc.save();
  }

  // ========= Combined Trip Summary (multi-date, reimbursement) ============

  /// A multi-date reimbursement sheet: one row per day with that day's total
  /// road distance and the route(s) covered, a grand-total distance, and a
  /// claim block whose Rate/km and Total Amount are left blank on purpose for
  /// finance to fill in by hand. No per-stop detail (that's the Trip Summary).
  static Future<Uint8List> buildCombinedTripSummary({
    required String orgName,
    required String periodLabel,
    required String salespersonLabel,
    required bool showSalesperson,
    required List<CombinedSummaryRow> rows,
    required double grandTotalKm,
    double? lastWeekTotalKm,
    bool duplicate = false,
    List<String> trail = const [],
    ReimbInfo? reimb,
    String? adjustNote, // "Adjusted by approver" box (Reimbursement Approvals)
  }) async {
    final doc = pw.Document();
    final lastWeekTotal = lastWeekTotalKm ??
        rows.fold<double>(0, (s, r) => s + (r.lastWeekKm ?? 0));
    // No last-week figures (e.g. an approved claim printed from Reimbursement
    // Approvals) → leave the column out instead of a column of dashes.
    final showLast = lastWeekTotalKm != null || rows.any((r) => r.lastWeekKm != null);

    final headers = <String>[
      'DATE',
      if (showSalesperson) 'SALESPERSON',
      'ROUTE(S)',
      if (showLast) 'LAST WEEK (KM)',
      'DISTANCE (KM)',
    ];
    final data = <List<String>>[
      for (final r in rows)
        [
          DateFormat('EEE, MMM d, y').format(r.date) +
              ((reimb?.excludedDays.contains(DateFormat('yyyy-MM-dd').format(r.date)) ?? false)
                  ? '  (approved)'
                  : (reimb?.generatedDays.contains(DateFormat('yyyy-MM-dd').format(r.date)) ?? false) ? '  *' : ''),
          if (showSalesperson) r.salesperson,
          r.routes,
          if (showLast) r.lastWeekKm == null ? '-' : r.lastWeekKm!.toStringAsFixed(2),
          r.km.toStringAsFixed(2),
        ],
      [
        'TOTAL',
        if (showSalesperson) '',
        '',
        if (showLast) '${lastWeekTotal.toStringAsFixed(2)} km',
        '${grandTotalKm.toStringAsFixed(2)} km',
      ],
      if ((reimb?.paidKm ?? 0) > 0) ...[
        [
          'EXCLUDED (already approved)',
          if (showSalesperson) '',
          '',
          if (showLast) '',
          '- ${reimb!.paidKm.toStringAsFixed(2)} km',
        ],
        [
          'TOTAL TO CLAIM',
          if (showSalesperson) '',
          '',
          if (showLast) '',
          '${(grandTotalKm - reimb!.paidKm).clamp(0, double.infinity).toStringAsFixed(2)} km',
        ],
      ],
    ];
    final distIdx = (showSalesperson ? 4 : 3) - (showLast ? 0 : 1);

    doc.addPage(pw.MultiPage(
      pageTheme: _pageTheme(duplicate, reimb),
      header: (c) => _pageHeader(orgName, 'Combined Trip Summary', verifyUrl: reimb?.verifyUrl),
      footer: (c) => _withTrail(duplicate ? trail : const [], _pageFooter(c, orgName, 'Combined Trip Summary',
          distanceNote: 'Distances: road distance (Google Directions API); straight-line where unavailable')),
      build: (c) => [
        pw.Text(salespersonLabel,
            style: pw.TextStyle(
                fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 2),
        pw.Text(
          'Period: $periodLabel   -   ${rows.length} day${rows.length == 1 ? '' : 's'}',
          style: pw.TextStyle(fontSize: 9, color: _muted),
        ),
        pw.SizedBox(height: 14),
        if (rows.isEmpty)
          pw.Text('No trips in the selected period.',
              style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            cellAlignment: pw.Alignment.centerLeft,
            cellAlignments: {
              if (showLast) distIdx - 1: pw.Alignment.centerRight,
              distIdx: pw.Alignment.centerRight,
            },
            headerStyle: pw.TextStyle(
                fontSize: 7.5,
                fontWeight: pw.FontWeight.bold,
                color: _muted,
                letterSpacing: 0.3),
            headerDecoration: const pw.BoxDecoration(color: _bg),
            cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
            cellPadding:
                const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
          ),
        pw.SizedBox(height: 18),
        if (adjustNote != null) ...[_adjustBox(adjustNote), pw.SizedBox(height: 10)],
        if (reimb?.stamp != null) ...[_paidStamp(reimb!), pw.SizedBox(height: 10)],
        _reimbursementClaimBlock(grandTotalKm, reimb, rows.length),
        pw.SizedBox(height: 36),
        _signatureLine(reimb),
      ],
    ));
    return doc.save();
  }

  /// Claim block for the combined summary: the distance is filled from the
  /// trips; Rate per km and Total Amount are left blank for finance.
  static pw.Widget _reimbursementClaimBlock(double totalKm, [ReimbInfo? reimb, int days = 1]) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: _bg,
        border: pw.Border.all(color: _ruleSoft, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('REIMBURSEMENT',
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.8,
                  color: _muted)),
          pw.SizedBox(height: 8),
          ..._reimbRows(totalKm, reimb, days),
        ],
      ),
    );
  }

  // ========= Shared building blocks ======================================

  /// A4 page theme; when [duplicate] is true every page gets a faint diagonal
  /// "DUPLICATE" watermark behind the content (re-issued reimbursement docs).
  /// An approved claim (Reimbursement Approvals print) also gets a faint
  /// repeated "APPROVED BY …" mark over every page, like an approved PA.
  static pw.PageTheme _pageTheme(bool duplicate, [ReimbInfo? reimb]) {
    final by = reimb?.approvedBy?.trim() ?? '';
    return pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      buildBackground: (ctx) =>
          duplicate ? _duplicateWatermark() : pw.SizedBox(),
      buildForeground: by.isEmpty ? null : (ctx) => _approvedMarks(by, reimb?.approvedAt),
    );
  }

  static pw.Widget _approvedMarks(String by, DateTime? at) {
    final line = 'APPROVED BY ${by.toUpperCase()}';
    final when = at == null ? '' : DateFormat(orgTime('d MMM yyyy, h:mm a')).format(at.toLocal());
    return pw.FullPage(
      ignoreMargins: true,
      child: pw.Opacity(
        opacity: 0.09,
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
          children: [
            for (var r = 0; r < 8; r++)
              pw.Padding(
                padding: pw.EdgeInsets.only(left: r.isOdd ? 60 : 0, right: r.isOdd ? 0 : 60),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var c = 0; c < 3; c++)
                      pw.Transform.rotate(
                        angle: 0.35,
                        child: pw.Column(mainAxisSize: pw.MainAxisSize.min, children: [
                          pw.Text(line,
                              style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _brandBlue)),
                          if (when.isNotEmpty)
                            pw.Text(when, style: const pw.TextStyle(fontSize: 7, color: _brandBlue)),
                        ]),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _duplicateWatermark() => pw.FullPage(
        ignoreMargins: true,
        child: pw.Center(
          child: pw.Transform.rotate(
            angle: 0.6,
            child: pw.Opacity(
              opacity: 0.12,
              child: pw.Text(
                'DUPLICATE',
                style: pw.TextStyle(
                  fontSize: 130,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.red,
                ),
              ),
            ),
          ),
        ),
      );

  static pw.Widget _pageHeader(String orgName, String title, {String? verifyUrl}) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.7))),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(orgName.toUpperCase(),
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 2,
                  color: _brandBlue)),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text(title,
                style: pw.TextStyle(
                    fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
            if (verifyUrl != null && verifyUrl.isNotEmpty) ...[
              pw.SizedBox(width: 8),
              _trustMark(verifyUrl),
            ],
          ]),
        ],
      ),
    );
  }

  /// Small green tick + QR (no text) in the header of a claim print; the QR
  /// opens the claim's public check page (/#/rc/<token>).
  static pw.Widget _trustMark(String url) {
    const green = PdfColor.fromInt(0xFF059669);
    return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
      pw.Container(
        width: 12,
        height: 12,
        decoration: const pw.BoxDecoration(color: green, shape: pw.BoxShape.circle),
        child: pw.CustomPaint(
          size: const PdfPoint(12, 12),
          painter: (canvas, size) {
            canvas
              ..setStrokeColor(PdfColors.white)
              ..setLineWidth(1.3)
              ..setLineCap(PdfLineCap.round)
              ..setLineJoin(PdfLineJoin.round)
              ..moveTo(3.3, 6.3)
              ..lineTo(5.3, 4.3)
              ..lineTo(8.9, 8.1)
              ..strokePath();
          },
        ),
      ),
      pw.SizedBox(width: 4),
      pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: url, width: 26, height: 26, drawText: false),
    ]);
  }

  /// On a DUPLICATE copy: who generated this report and when, above the footer.
  static pw.Widget _withTrail(List<String> trail, pw.Widget footer) {
    if (trail.isEmpty) return footer;
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('Generated: ${trail.join(';  ')}',
          style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.red800)),
      pw.SizedBox(height: 3),
      footer,
    ]);
  }

  static pw.Widget _pageFooter(pw.Context c, String orgName, String title,
      {String? distanceNote}) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
          border: pw.Border(top: pw.BorderSide(color: _ruleSoft, width: 0.5))),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                  '$orgName - $title - Generated ${DateFormat(orgTime('MMM d, y HH:mm')).format(DateTime.now())}',
                  style: pw.TextStyle(fontSize: 8, color: _muted)),
              pw.Text('Page ${c.pageNumber} of ${c.pagesCount}',
                  style: pw.TextStyle(fontSize: 8, color: _muted)),
            ],
          ),
          if (distanceNote != null)
            pw.Text(distanceNote,
                style: pw.TextStyle(fontSize: 8, color: _mutedLight)),
        ],
      ),
    );
  }

  static pw.Widget _subtitleLine(Map<String, dynamic> trip) {
    final startedAt = DateTime.parse(trip['started_at'] as String).toLocal();
    final routeName = trip['route_name'] as String? ?? '';
    final date = DateFormat('EEE, MMM d, y').format(startedAt);
    return pw.Text('$routeName - $date',
        style: pw.TextStyle(fontSize: 9, color: _muted));
  }

  static pw.Widget _journeyBlock(
    Map<String, dynamic> trip,
    String? startAddr,
    String? endAddr, {
    required bool status,
    int? totalVisitsOverride,
  }) {
    final startedAt = DateTime.parse(trip['started_at'] as String).toLocal();
    final endedAt = trip['ended_at'] != null
        ? DateTime.parse(trip['ended_at'] as String).toLocal()
        : null;
    final userName = trip['user_name'] as String? ?? '';
    final routeName = trip['route_name'] as String? ?? '';
    final startLat = (trip['start_lat'] as num?)?.toDouble();
    final startLng = (trip['start_lng'] as num?)?.toDouble();
    final endLat = (trip['end_lat'] as num?)?.toDouble();
    final endLng = (trip['end_lng'] as num?)?.toDouble();

    final startTime = DateFormat(orgTime('hh:mm a - MMM d, y')).format(startedAt);
    final endTime = endedAt == null
        ? 'In progress'
        : DateFormat(orgTime('hh:mm a - MMM d, y')).format(endedAt);
    final startLoc = startAddr ?? _coordsOrDash(startLat, startLng);
    final endLoc = endAddr ?? _coordsOrDash(endLat, endLng);

    final leftCells = <List<String>>[
      ['SALESPERSON', userName.isEmpty ? '-' : userName.toUpperCase()],
      ['ROUTE', routeName],
      if (status)
        ['STATUS', _statusLabel(trip)]
      else
        ['TOTAL VISITS', (totalVisitsOverride ?? 0).toString()],
    ];

    final rightCells = <List<String>>[
      ['JOURNEY STARTED', '$startTime\n$startLoc'],
      ['JOURNEY ENDED', '$endTime\n$endLoc'],
    ];

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final c in leftCells) ...[
                _labelValue(c[0], c[1]),
                pw.SizedBox(height: 10),
              ],
            ],
          ),
        ),
        pw.SizedBox(width: 16),
        pw.Expanded(
          flex: 2,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final c in rightCells) ...[
                _labelValue(c[0], c[1]),
                pw.SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _labelValue(String label, String value) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label,
            style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.8,
                color: _muted)),
        pw.SizedBox(height: 2),
        pw.Text(value,
            style: pw.TextStyle(
                fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink)),
      ],
    );
  }

  // ── Per-customer collection, de-duplicated by receipt ─────────────────────
  // The field app can submit the SAME collection more than once (GPS re-fire or
  // repeated taps), producing several visit rows with an identical receipt and
  // amount. Money, verified stops and receipts must therefore be counted per
  // DISTINCT RECEIPT / per customer — never as the raw sum of visit rows —
  // otherwise one 30,000 receipt entered 3× reads as 90,000. This collapses a
  // trip's visits to one entry per customer: `collected` = sum of
  // distinct-receipt amounts, `receipts` = those distinct numbers, and `latest`
  // (the last visit) drives status / time / notes. Order preserves first
  // appearance, matching how the list read before.
  static List<Map<String, dynamic>> _custLines(
      List<Map<String, dynamic>> visits) {
    final byCustomer = <String, List<Map<String, dynamic>>>{};
    for (final v in visits) {
      final cid = v['customer_id'] as String?;
      if (cid == null) continue;
      byCustomer.putIfAbsent(cid, () => <Map<String, dynamic>>[]).add(v);
    }
    final out = <Map<String, dynamic>>[];
    byCustomer.forEach((cid, vs) {
      vs.sort((a, b) => DateTime.parse(a['timestamp'] as String)
          .compareTo(DateTime.parse(b['timestamp'] as String)));
      final latest = vs.last;
      // Once the shop was verified on this trip it counts as Visited.
      final verified = vs.where((v) => v['status'] == 'verified').toList();
      final byReceipt = <String, int>{};
      var noReceiptSeq = 0;
      for (final v in vs) {
        final amt = (v['amount'] as int?) ?? 0;
        if (amt <= 0) continue;
        final raw = (v['receipt_number'] as String?)?.trim() ?? '';
        // a real collection without a receipt keeps its own slot; identical
        // receipts collapse to one (max guards a 0-vs-real mismatch).
        final key = (raw.isEmpty || raw == '0') ? '__nr${noReceiptSeq++}' : raw;
        final prev = byReceipt[key] ?? 0;
        byReceipt[key] = amt > prev ? amt : prev;
      }
      out.add({
        'cid': cid,
        'latest': latest,
        'shown': verified.isNotEmpty ? verified.first : latest,
        'first_at': DateTime.parse(vs.first['timestamp'] as String),
        'collected': byReceipt.values.fold<int>(0, (s, a) => s + a),
        'receipts':
            byReceipt.keys.where((k) => !k.startsWith('__nr')).toList(),
      });
    });
    return out;
  }

  /// The four numbers at the top of the Visit Report, as on the phone: CUSTOMERS is the
  /// number of planned stops (for a route with none: the customers actually marked, and
  /// no completion %), VISITED counts the customers verified on the trip, COMPLETION is
  /// visited over planned.
  static VisitReportSummary visitSummary(TripReportContext ctx) {
    final lines = _custLines(ctx.visits);
    final visited = lines.where((l) => (l['shown'] as Map)['status'] == 'verified').length;
    final collected = lines.fold<int>(0, (s, l) => s + (l['collected'] as int));
    final planned = ctx.plannedStops.length;
    return VisitReportSummary(
      customers: planned > 0 ? planned : lines.length,
      visited: visited,
      completion: planned > 0 ? (visited / planned) * 100 : null,
      collected: collected,
    );
  }

  static pw.Widget _summaryRow(Map<String, dynamic> trip, TripReportContext ctx) {
    final sum = visitSummary(ctx);
    return pw.Row(children: [
      _summaryCell('${sum.customers}', 'CUSTOMERS'),
      _summaryCell('${sum.visited}', 'VISITED'),
      _summaryCell(sum.completion == null ? '-' : '${sum.completion!.toStringAsFixed(1)}%', 'COMPLETION'),
      _summaryCell('Rs. ${_fmtNum(sum.collected)}', 'COLLECTED'),
    ]);
  }

  static pw.Widget _summaryCell(String value, String label) {
    return pw.Expanded(
      child: pw.Container(
        margin: const pw.EdgeInsets.only(right: 6),
        padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: pw.BoxDecoration(
          color: _bg,
          border: pw.Border.all(color: _ruleSoft, width: 0.5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink)),
            pw.SizedBox(height: 2),
            pw.Text(label,
                style: pw.TextStyle(
                    fontSize: 7,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.6,
                    color: _muted)),
          ],
        ),
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Text(text,
        style: pw.TextStyle(
            fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink));
  }

  /// The rows of the Visit Details table: the customers marked, in the order they were
  /// first marked, then the planned stops never marked (NOT VISITED) in route order.
  static List<List<String>> visitDetailRows(TripReportContext ctx) {
    // In the order the shops were visited (time of the first mark at each).
    final lines = _custLines(ctx.visits)
      ..sort((a, b) => (a['first_at'] as DateTime).compareTo(b['first_at'] as DateTime));

    final rows = <List<String>>[];
    for (var i = 0; i < lines.length; i++) {
      final cid = lines[i]['cid'] as String;
      final v = lines[i]['shown'] as Map<String, dynamic>;
      final cust = ctx.customersById[cid];
      final status = v['status'] as String? ?? 'pending';
      final collected = lines[i]['collected'] as int;
      final receipts = (lines[i]['receipts'] as List).cast<String>();
      rows.add([
        '${i + 1}',
        (cust?['code'] as String?) ?? '-',
        // "Shop (Godown)" when visited at another of the customer's locations.
        '${(cust?['shop_name'] as String?) ?? '-'}'
            '${'${v['location_name'] ?? ''}'.trim().isEmpty ? '' : ' (${'${v['location_name']}'.trim()})'}',
        _outcomeTag(status, collected, v),
        status == 'pending' ? '-' : '$collected',
        receipts.isEmpty ? '-' : receipts.join(', '),
        DateFormat(orgTime('hh:mm a')).format((lines[i]['first_at'] as DateTime).toLocal()),
        _notesFor(status, v),
      ]);
    }
    final marked = {for (final l in lines) l['cid'] as String};
    for (final cid in ctx.plannedStops) {
      if (marked.contains(cid)) continue;
      final cust = ctx.customersById[cid];
      rows.add([
        '${rows.length + 1}',
        (cust?['code'] as String?) ?? '-',
        (cust?['shop_name'] as String?) ?? '(customer)',
        'NOT VISITED', '-', '-', '-', '-',
      ]);
    }
    return rows;
  }

  static pw.Widget _visitDetailsTable(TripReportContext ctx) {
    final headers = [
      '#', 'CODE', 'CUSTOMER', 'STATUS', 'COLLECTED', 'CR#', 'TIME', 'NOTES'
    ];
    final rows = visitDetailRows(ctx);

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {
        0: pw.Alignment.center,
        4: pw.Alignment.centerRight,
      },
      headerStyle: pw.TextStyle(
          fontSize: 7.5,
          fontWeight: pw.FontWeight.bold,
          color: _muted,
          letterSpacing: 0.3),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      columnWidths: const {
        0: pw.FixedColumnWidth(18),
        1: pw.FixedColumnWidth(46),
        2: pw.FlexColumnWidth(5),
        3: pw.FixedColumnWidth(54),
        4: pw.FixedColumnWidth(46),
        5: pw.FixedColumnWidth(36),
        6: pw.FixedColumnWidth(46),
        7: pw.FlexColumnWidth(3),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _receiptsFooter(TripReportContext ctx) {
    // De-duplicated: distinct receipts and their summed amount (see _custLines),
    // so a re-submitted collection is not double-counted here either.
    final lines = _custLines(ctx.visits);
    final receipts =
        lines.fold<int>(0, (s, l) => s + (l['receipts'] as List).length);
    final total = lines.fold<int>(0, (s, l) => s + (l['collected'] as int));
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: pw.BoxDecoration(
        color: _bg,
        border: pw.Border.all(color: _ruleSoft, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('$receipts Receipt${receipts == 1 ? "" : "s"}',
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: _ink)),
          pw.Text('Rs. ${_fmtNum(total)}',
              style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _ink)),
        ],
      ),
    );
  }

  /// Missing receipt numbers in the trip's sequence — a skip means a
  /// collection may have been made but never entered. Big jumps (> 20) are
  /// treated as a new receipt book and ignored. Admin control only.
  ///
  /// The flow is ON or OFF. ON: checked against the salesperson's receipt books (a
  /// slip is missing only when it is not used, cancelled or cleared there) — and
  /// nothing is claimed if the books can't be read. OFF: the old check, unchanged.
  static List<String> _skippedReceipts(TripReportContext ctx) {
    final rc = ctx.receiptCheck;
    if (rc != null && rc.unavailable) return const [];
    return missingSlipLabels([for (final v in ctx.visits) v['receipt_number'] as String? ?? ''],
        flowOn: rc?.usesBooks ?? false, books: rc?.books ?? const <BookSlips>[]);
  }

  /// Admin-only line listing skipped receipt numbers. Renders nothing when
  /// the sequence is clean (or on a salesperson's own copy, which never
  /// calls this).
  static pw.Widget _receiptGapsNote(TripReportContext ctx) {
    final missing = _skippedReceipts(ctx);
    if (missing.isEmpty) return pw.SizedBox();
    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 6),
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFFFF7ED),
        border: pw.Border.all(color: PdfColor.fromInt(0xFFFB923C), width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('Missing receipts:  ',
            style: pw.TextStyle(
                fontSize: 9.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColor.fromInt(0xFF9A3412))),
        pw.Expanded(
          child: pw.Text(missing.join(', '),
              style: pw.TextStyle(
                  fontSize: 9.5, color: PdfColor.fromInt(0xFF9A3412))),
        ),
      ]),
    );
  }

  static pw.Widget _sequencedTable(TripReportContext ctx) {
    // No visit without a customer on this trip: the table is exactly what it always was.
    if (!ctx.orderedVerifiedVisits.any(visitIsFree)) return _sequencedTablePlain(ctx);
    return _sequencedTableWithFree(ctx);
  }

  /// The same table; a visit marked without a customer is listed by its place
  /// name, with its GPS point under it as a link that opens Google Maps.
  static pw.Widget _sequencedTableWithFree(TripReportContext ctx) {
    const headers = ['#', 'CODE', 'CUSTOMER', 'DISTANCE (KM)', 'TIME'];
    final hdr = pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.3);
    const cellStyle = pw.TextStyle(fontSize: 8.5, color: _ink);
    pw.Widget cell(pw.Widget w, [pw.Alignment a = pw.Alignment.centerLeft]) =>
        pw.Container(alignment: a, padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4), child: w);
    pw.Widget txt(String t, {pw.Alignment a = pw.Alignment.centerLeft, pw.TextStyle? style}) =>
        cell(pw.Text(t, style: style ?? cellStyle), a);
    pw.Alignment alignOf(int i) => i == 0 ? pw.Alignment.center : (i == 3 || i == 4) ? pw.Alignment.centerRight : pw.Alignment.centerLeft;

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _bg),
        children: [for (var i = 0; i < headers.length; i++) txt(headers[i], a: alignOf(i), style: hdr)],
      ),
    ];

    for (var i = 0; i < ctx.orderedVerifiedVisits.length; i++) {
      final v = ctx.orderedVerifiedVisits[i];
      final free = visitIsFree(v);
      final cid = v['customer_id'] as String?;
      final c = cid != null ? ctx.customersById[cid] : null;
      final km = ctx.distanceKm.length > i ? ctx.distanceKm[i] : 0.0;
      final time = DateFormat(orgTime('hh:mm a')).format(DateTime.parse(v['timestamp'] as String).toLocal());

      pw.Widget custCell;
      if (free) {
        final lat = (v['captured_lat'] as num).toDouble();
        final lng = (v['captured_lng'] as num).toDouble();
        final name = ctx.freePlaceNames['${v['id']}'];
        final pt = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
        custCell = cell(pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (name != null && name.isNotEmpty) pw.Text(_pdfSafe(name), style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.UrlLink(
            destination: mapsLink(lat, lng),
            child: pw.Text(pt, style: pw.TextStyle(fontSize: name != null && name.isNotEmpty ? 7 : 8.5, color: PdfColors.blue, decoration: pw.TextDecoration.underline)),
          ),
        ]));
      } else {
        custCell = txt((c?['shop_name'] as String?) ?? '-');
      }
      rows.add(pw.TableRow(children: [
        txt('${i + 1}', a: pw.Alignment.center),
        txt(free ? '-' : ((c?['code'] as String?) ?? '-')),
        custCell,
        txt(km.toStringAsFixed(2), a: pw.Alignment.centerRight),
        txt(time, a: pw.Alignment.centerRight),
      ]));
    }

    if (ctx.returnDistanceKm > 0) {
      rows.add(pw.TableRow(children: [
        txt(''), txt(''), txt('Return to end location'),
        txt(ctx.returnDistanceKm.toStringAsFixed(2), a: pw.Alignment.centerRight),
        txt(ctx.trip['ended_at'] == null
            ? '-'
            : DateFormat(orgTime('hh:mm a')).format(DateTime.parse(ctx.trip['ended_at'] as String).toLocal()), a: pw.Alignment.centerRight),
      ]));
    }
    rows.add(pw.TableRow(children: [
      txt(''), txt(''), txt('Total Distance'),
      txt('${ctx.totalDistanceKm.toStringAsFixed(2)} km', a: pw.Alignment.centerRight),
      txt(''),
    ]));

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(20),
        1: pw.FixedColumnWidth(52),
        2: pw.FlexColumnWidth(5),
        3: pw.FixedColumnWidth(64),
        4: pw.FixedColumnWidth(54),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
      children: rows,
    );
  }

  static pw.Widget _sequencedTablePlain(TripReportContext ctx) {
    final headers = ['#', 'CODE', 'CUSTOMER', 'DISTANCE (KM)', 'TIME'];
    final rows = <List<String>>[];

    for (var i = 0; i < ctx.orderedVerifiedVisits.length; i++) {
      final v = ctx.orderedVerifiedVisits[i];
      final cid = v['customer_id'] as String?;
      final c = cid != null ? ctx.customersById[cid] : null;
      final km = ctx.distanceKm.length > i ? ctx.distanceKm[i] : 0.0;
      rows.add([
        '${i + 1}',
        (c?['code'] as String?) ?? '-',
        (c?['shop_name'] as String?) ?? '-',
        km.toStringAsFixed(2),
        DateFormat(orgTime('hh:mm a'))
            .format(DateTime.parse(v['timestamp'] as String).toLocal()),
      ]);
    }

    if (ctx.returnDistanceKm > 0) {
      rows.add([
        '',
        '',
        'Return to end location',
        ctx.returnDistanceKm.toStringAsFixed(2),
        ctx.trip['ended_at'] == null
            ? '-'
            : DateFormat(orgTime('hh:mm a')).format(
                DateTime.parse(ctx.trip['ended_at'] as String).toLocal()),
      ]);
    }

    rows.add([
      '',
      '',
      'Total Distance',
      '${ctx.totalDistanceKm.toStringAsFixed(2)} km',
      '',
    ]);

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {
        0: pw.Alignment.center,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
      },
      headerStyle: pw.TextStyle(
          fontSize: 7.5,
          fontWeight: pw.FontWeight.bold,
          color: _muted,
          letterSpacing: 0.3),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      columnWidths: const {
        0: pw.FixedColumnWidth(20),
        1: pw.FixedColumnWidth(52),
        2: pw.FlexColumnWidth(5),
        3: pw.FixedColumnWidth(64),
        4: pw.FixedColumnWidth(54),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _reimbursementBlock(TripReportContext ctx, [ReimbInfo? reimb]) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: _bg,
        border: pw.Border.all(color: _ruleSoft, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('REIMBURSEMENT',
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.8,
                  color: _muted)),
          pw.SizedBox(height: 8),
          ..._reimbRows(ctx.totalDistanceKm, reimb, 1),
        ],
      ),
    );
  }

  /// Distance · Rate per km (Admin Settings) · Distance amount · Other
  /// allowances (filled by hand) · Total amount · Approved by.
  static List<pw.Widget> _reimbRows(double km, ReimbInfo? r, int days) {
    final f = NumberFormat('#,##0');
    final f2 = NumberFormat('#,##0.##');
    final nothing = r?.fullyPaid ?? false;
    final locked = r?.paidKm ?? 0;
    final rate = r?.rate;
    final due = (km - locked) < 0 ? 0.0 : km - locked;
    final amt = rate == null || nothing ? null : (due * rate).round();
    // Allowance per day (Admin Settings): days not already approved × allowance.
    final perDay = r?.allowancePerDay;
    final allowDays = r?.unpaidDays ?? days;
    final allow = nothing
        ? null
        : r?.allowanceTotal != null
            ? r!.allowanceTotal!.round()
            : perDay == null ? null : (allowDays * perDay).round();
    final total = amt == null || allow == null ? null : amt + allow;
    final rows = <pw.Widget>[
      _reimbRow('Total Distance', '${km.toStringAsFixed(2)} km'),
      if (locked > 0) ...[
        _reimbRow('Already approved', '- ${locked.toStringAsFixed(2)} km  (see box above)'),
        _reimbRow('Distance to Claim', '${due.toStringAsFixed(2)} km'),
      ],
      _reimbRow('Rate per km', rate == null ? '' : 'Rs ${f2.format(rate)}'),
      _reimbRow('Distance Amount', nothing ? 'Nothing to claim' : (amt == null ? '' : 'Rs ${f.format(amt)}')),
      // Not set in settings → blank to fill in by hand.
      _reimbRow('Other Allowances', nothing
          ? 'Nothing to claim'
          : allow == null
              ? ''
              : allow == 0 || perDay == null || (allowDays * perDay).round() != allow
                  ? 'Rs ${f.format(allow)}'
                  : 'Rs ${f.format(allow)}  ($allowDays day${allowDays == 1 ? '' : 's'} × Rs ${f2.format(perDay)})'),
      _reimbRow('Total Amount', nothing ? 'Nothing to claim' : total == null ? '' : 'Rs ${f.format(total)}'),
      _reimbRow('Approved By', r?.approvedBy ?? ''),
    ];
    return [for (var i = 0; i < rows.length; i++) ...[if (i > 0) pw.SizedBox(height: 6), rows[i]]];
  }

  static String _reimbAmount(double km, ReimbInfo? r) {
    if (r == null) return '';
    if (r.fullyPaid) return 'Already paid — see above';
    if (r.rate == null) return '';
    final due = (km - r.paidKm) < 0 ? 0.0 : km - r.paidKm;
    return 'Rs ${NumberFormat('#,##0').format((due * r.rate!).round())}  (@ Rs ${NumberFormat('#,##0.##').format(r.rate)}/km'
        '${r.paidKm > 0 ? ' on ${due.toStringAsFixed(2)} unpaid km' : ''})';
  }

  /// Which dates of this sheet were already generated for reimbursement.
  static pw.Widget _generatedBox(String note) {
    const c = PdfColor.fromInt(0xFFB45309);
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFFFFFBEB),
        border: pw.Border.all(color: c, width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('* ALREADY GENERATED FOR REIMBURSEMENT',
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: c)),
        pw.SizedBox(height: 4),
        pw.Text(_pdfSafe(note), style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFF78350F))),
      ]),
    );
  }

  /// "† EXCLUDED — ALREADY APPROVED" box: which days, and the claim that
  /// approved them (shown above the reimbursement block).
  static pw.Widget _paidStamp(ReimbInfo r) {
    const c = PdfColor.fromInt(0xFF475569);
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFFF8FAFC),
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFCBD5E1), width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(
            r.fullyPaid
                ? 'NOTHING TO CLAIM - ALL DAYS ALREADY APPROVED FOR REIMBURSEMENT'
                : 'EXCLUDED - ALREADY APPROVED FOR REIMBURSEMENT',
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: c)),
        pw.SizedBox(height: 4),
        pw.Text(_pdfSafe(r.stamp ?? ''), style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFF334155))),
      ]),
    );
  }

  /// "ADJUSTED BY APPROVER" — what was left out of the trip and why.
  static pw.Widget _adjustBox(String note) {
    const c = PdfColor.fromInt(0xFFB91C1C);
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFFFEF2F2),
        border: pw.Border.all(color: const PdfColor.fromInt(0xFFFCA5A5), width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('ADJUSTED BY APPROVER',
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: c)),
        pw.SizedBox(height: 4),
        pw.Text(_pdfSafe(note), style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFF7F1D1D))),
      ]),
    );
  }

  static pw.Widget _reimbRow(String label, String value) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.SizedBox(
          width: 110,
          child: pw.Text(label,
              style: pw.TextStyle(fontSize: 10, color: _muted)),
        ),
        pw.Expanded(
          child: pw.Container(
            decoration: const pw.BoxDecoration(
                border: pw.Border(
                    bottom: pw.BorderSide(color: _rule, width: 0.6))),
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(value,
                style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                    color: _ink)),
          ),
        ),
      ],
    );
  }

  /// The PDF font has no long dashes or arrows (they print as boxes).
  static String _pdfSafe(String t) => t
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll('→', 'to')
      .replaceAll('…', '...')
      .replaceAll('‘', "'")
      .replaceAll('’', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"');

  static pw.Widget _signatureLine([ReimbInfo? reimb]) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 180,
          decoration: const pw.BoxDecoration(
              border: pw.Border(top: pw.BorderSide(color: _ink, width: 0.6))),
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('OPERATIONS MANAGER',
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.8,
                  color: _muted)),
        ),
      ],
    );
  }


  // ---- Helpers ---------------------------------------------------------

  static String _statusLabel(Map<String, dynamic> trip) {
    if (trip['ended_at'] == null) return 'IN PROGRESS';
    if (trip['close_reason'] == 'cutoff') return 'CUT-OFF';
    return 'COMPLETED';
  }

  static String _statusTagWithDistance(String s, Map<String, dynamic>? v) {
    final base = _statusTag(s, v);
    if (s == 'skipped' || s == 'noLocation' || s == 'pending') {
      final dist = (v?['distance_meters'] as num?)?.toDouble();
      if (dist != null && dist > 0) {
        final km = dist >= 1000
            ? '${(dist / 1000).toStringAsFixed(1)} km away'
            : '${dist.round()} m away';
        return '$base\n$km';
      }
    }
    return base;
  }

  /// Visit Report status under the rules without "Skip".
  static String _outcomeTag(String s, int collected, Map<String, dynamic>? v) {
    final lbl = visitOutcomeLabel(s, collected, hasGps: v == null ? null : visitHasGps(v));
    final extra = v == null ? '' : visitExtras(v, lbl).replaceFirst(' · ', '').replaceAll(' · ', '\n').toUpperCase();
    final base = lbl.toUpperCase() + (extra.isEmpty ? '' : '\n$extra');
    if (s == 'outside' || s == 'noLocation' || s == 'no_location') {
      final d = (v?['distance_meters'] as num?)?.toDouble();
      if (d != null && d > 0) {
        final away = d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km away' : '${d.round()} m away';
        return '$base\n$away';
      }
    }
    return base;
  }

  static String _statusTag(String s, Map<String, dynamic>? v) {
    final d = (v?['distance_meters'] as num?)?.toDouble();
    switch (s) {
      case 'verified':
        return 'VERIFIED';
      case 'outside':
        if (d != null) {
          final km = d / 1000.0;
          return 'OUTSIDE GF ${km.toStringAsFixed(1)}km';
        }
        return 'OUTSIDE GF';
      case 'noLocation':
        return v != null && visitHasGps(v) == false ? 'NO GPS' : 'NO LOCATION';
      case 'skipped':
        if (d != null) {
          final km = d / 1000.0;
          return 'SKIPPED ${km.toStringAsFixed(1)}km';
        }
        return 'SKIPPED';
      case 'pending':
        return 'NOT VISITED';
      default:
        return s.toUpperCase();
    }
  }

  static String _notesFor(String s, Map<String, dynamic>? v) {
    if (s == 'skipped') {
      final r = v?['skip_reason'] as String?;
      if (r != null && r.isNotEmpty) return r;
    }
    final n = v?['notes'] as String?;
    if (n != null && n.isNotEmpty) return n;
    return '-';
  }

  static String _fmtNum(int n) => money(n);

  static String _coordsOrDash(double? lat, double? lng) {
    if (lat == null || lng == null) return 'No GPS';
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }
}
