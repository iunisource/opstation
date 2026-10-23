import '../../../core/utils/customer_locations.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../salesperson/models/customer.dart';
import '../../salesperson/models/trip.dart';
import '../services/coverage_context_builder.dart';
import '../services/report_context_builder.dart';

/// One aggregated line of a Combined Trip Summary: the total road distance a
/// salesperson covered on a single date, and the route(s) they ran that day.
class CombinedSummaryRow {
  final DateTime date;
  final String salesperson;
  final String routes;
  final double km;
  /// Same salesperson, same weekday one week earlier (same route filter).
  /// Null when there was no trip that day.
  final double? lastWeekKm;
  const CombinedSummaryRow({
    required this.date,
    required this.salesperson,
    required this.routes,
    required this.km,
    this.lastWeekKm,
  });
}

/// Builder for PDF reports. Shapes match the reference PDFs the user
/// supplied (OPSTATION branded, OPERATIONS MANAGER signature, etc.).
class ReportPdfBuilder {
  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _mutedLight = PdfColor.fromInt(0xFF9CA3AF);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);

  // ========= Market Visit Report ==========================================

  static Future<List<int>> buildVisitReport({
    required TripReportContext ctx,
    required String orgName,
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        header: (c) => _pageHeader(orgName, 'Market Visit Report'),
        footer: (c) =>
            _pageFooter(c, orgName, 'Market Visit Report'),
        build: (c) => [
          _subtitleLine(trip),
          pw.SizedBox(height: 14),
          _journeyBlock(trip, ctx.startAddress, ctx.endAddress, status: true),
          pw.SizedBox(height: 14),
          _summaryRow(trip),
          pw.SizedBox(height: 14),
          _sectionTitle('Visit Details'),
          pw.SizedBox(height: 6),
          _visitDetailsTable(trip, ctx),
          ..._collectionsAfterVerified(trip, ctx),
          pw.SizedBox(height: 10),
          _receiptsFooter(trip),
          pw.SizedBox(height: 36),
          _signatureLine(),
        ],
      ),
    );
    return doc.save();
  }

  // ========= Trip Summary =================================================

  static Future<List<int>> buildTripSummary({
    required TripReportContext ctx,
    required String orgName,
    bool duplicate = false,
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageTheme: _pageTheme(duplicate),
        header: (c) => _pageHeader(orgName, 'Trip Summary'),
        footer: (c) =>
            _pageFooter(c, orgName, 'Trip Summary',
                distanceNote: ctx.usedGoogle
                    ? 'Distances: Google Directions API (road distance)'
                    : 'Distances: straight-line / Haversine — add GOOGLE_MAPS_API_KEY for road distances'),
        build: (c) => [
          _subtitleLine(trip),
          pw.SizedBox(height: 14),
          _journeyBlock(
            trip,
            ctx.startAddress,
            ctx.endAddress,
            status: false,
            totalVisitsOverride: ctx.orderedVerifiedVisits.length,
          ),
          pw.SizedBox(height: 14),
          _sequencedTable(ctx),
          pw.SizedBox(height: 18),
          _reimbursementBlock(ctx),
          pw.SizedBox(height: 36),
          _signatureLine(),
        ],
      ),
    );
    return doc.save();
  }

  // ========= Combined Trip Summary (multi-date, reimbursement) ============

  /// A multi-date reimbursement sheet: one row per day with that day's total
  /// road distance and the route(s) covered, a grand-total distance, and a
  /// claim block whose Rate/km and Total Amount are left blank on purpose for
  /// finance to fill in by hand. No per-stop detail (that's the Trip Summary).
  static Future<List<int>> buildCombinedTripSummary({
    required String orgName,
    required String periodLabel,
    required String salespersonLabel,
    required bool showSalesperson,
    required List<CombinedSummaryRow> rows,
    required double grandTotalKm,
    required bool usedGoogle,
    bool duplicate = false,
  }) async {
    final doc = pw.Document();

    final headers = <String>[
      'DATE',
      if (showSalesperson) 'SALESPERSON',
      'ROUTE(S)',
      'LAST WEEK (KM)',
      'DISTANCE (KM)',
    ];
    final lastWeekTotal = rows.fold<double>(0, (s, r) => s + (r.lastWeekKm ?? 0));
    final data = <List<String>>[
      for (final r in rows)
        [
          DateFormat('EEE, MMM d, y').format(r.date),
          if (showSalesperson) r.salesperson,
          r.routes,
          r.lastWeekKm == null ? '-' : r.lastWeekKm!.toStringAsFixed(2),
          r.km.toStringAsFixed(2),
        ],
      [
        'TOTAL',
        if (showSalesperson) '',
        '',
        '${lastWeekTotal.toStringAsFixed(2)} km',
        '${grandTotalKm.toStringAsFixed(2)} km',
      ],
    ];
    final distIdx = showSalesperson ? 4 : 3;

    doc.addPage(
      pw.MultiPage(
        pageTheme: _pageTheme(duplicate),
        header: (c) => _pageHeader(orgName, 'Combined Trip Summary'),
        footer: (c) => _pageFooter(
          c,
          orgName,
          'Combined Trip Summary',
          distanceNote: usedGoogle
              ? 'Distances: Google Directions API (road distance)'
              : 'Distances: straight-line / Haversine — add GOOGLE_MAPS_API_KEY for road distances',
        ),
        build: (c) => [
          pw.Text(
            salespersonLabel,
            style: pw.TextStyle(
                fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink),
          ),
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
              cellAlignments: {distIdx - 1: pw.Alignment.centerRight, distIdx: pw.Alignment.centerRight},
              headerStyle: pw.TextStyle(
                fontSize: 7.5,
                fontWeight: pw.FontWeight.bold,
                color: _muted,
                letterSpacing: 0.3,
              ),
              headerDecoration: const pw.BoxDecoration(color: _bg),
              cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
              cellPadding:
                  const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
            ),
          pw.SizedBox(height: 18),
          _reimbursementClaimBlock(grandTotalKm),
          pw.SizedBox(height: 36),
          _signatureLine(),
        ],
      ),
    );
    return doc.save();
  }

  /// Claim block for the combined summary: the distance is filled from the
  /// trips; Rate per km and Total Amount are left blank for finance.
  static pw.Widget _reimbursementClaimBlock(double totalKm) {
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
          pw.Text(
            'REIMBURSEMENT',
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.8,
              color: _muted,
            ),
          ),
          pw.SizedBox(height: 8),
          _reimbRow('Total Distance', '${totalKm.toStringAsFixed(2)} km'),
          pw.SizedBox(height: 6),
          _reimbRow('Rate per km', ''),
          pw.SizedBox(height: 6),
          _reimbRow('Total Amount', ''),
          pw.SizedBox(height: 6),
          _reimbRow('Approved By', ''),
        ],
      ),
    );
  }

  // ========= Coverage Report ==============================================

  static Future<List<int>> buildCoverageReport({
    required CoverageReportContext ctx,
    required String orgName,
  }) async {
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        header: (c) => _pageHeader(orgName, 'Coverage Report'),
        footer: (c) => _pageFooter(c, orgName, 'Coverage Report'),
        build: (c) => [
          _coverageSubtitle(ctx),
          pw.SizedBox(height: 14),
          _coverageOverall(ctx),
          pw.SizedBox(height: 18),
          _sectionTitle('By Route'),
          pw.SizedBox(height: 6),
          _coverageRoutesTable(ctx),
          pw.SizedBox(height: 18),
          _sectionTitle('By Salesperson'),
          pw.SizedBox(height: 6),
          _coverageSalespersonsTable(ctx),
          if (ctx.routeCoverages.any((r) => r.unvisitedCustomers.isNotEmpty)) ...[
            pw.SizedBox(height: 18),
            _sectionTitle('Coverage Gaps'),
            pw.SizedBox(height: 6),
            _coverageGapsTable(ctx),
          ],
          pw.SizedBox(height: 36),
          _signatureLine(),
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _coverageSubtitle(CoverageReportContext ctx) {
    final fmt = DateFormat('d MMM y');
    final range = '${fmt.format(ctx.from)} - ${fmt.format(ctx.to)}';
    return pw.Text(
      'Period: $range',
      style: pw.TextStyle(fontSize: 9, color: _muted),
    );
  }

  static pw.Widget _coverageOverall(CoverageReportContext ctx) {
    return pw.Row(
      children: [
        _summaryCell('${ctx.totalTrips}', 'TRIPS'),
        _summaryCell('${ctx.totalUniqueCustomersVisited}', 'UNIQUE VISITS'),
        _summaryCell('${ctx.totalRoutesAssessed}', 'ROUTES'),
        _summaryCell('Rs. ${_fmtNum(ctx.totalCollected)}', 'COLLECTED'),
      ],
    );
  }

  static pw.Widget _coverageRoutesTable(CoverageReportContext ctx) {
    final headers = [
      'ROUTE',
      'STOPS',
      'VERIFIED',
      'OUTSIDE',
      'UNVISITED',
      'COVERAGE',
      'TRIPS',
      'COLLECTED',
    ];
    final rows = <List<String>>[];
    for (final rc in ctx.routeCoverages) {
      rows.add([
        rc.route.name,
        '${rc.totalStops}',
        '${rc.verifiedCustomerIds.length}',
        '${rc.outsideCustomerIds.length}',
        '${rc.unvisitedCustomers.length}',
        '${rc.coveragePercent.toStringAsFixed(1)}%',
        '${rc.tripsRun}',
        'Rs. ${_fmtNum(rc.totalCollected)}',
      ]);
    }
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
        6: pw.Alignment.centerRight,
        7: pw.Alignment.centerRight,
      },
      headerStyle: pw.TextStyle(
        fontSize: 7.5,
        fontWeight: pw.FontWeight.bold,
        color: _muted,
        letterSpacing: 0.3,
      ),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _coverageSalespersonsTable(CoverageReportContext ctx) {
    final headers = [
      'SALESPERSON',
      'TRIPS',
      'VERIFIED',
      'OUTSIDE',
      'SKIPPED',
      'UNIQUE',
      'COLLECTED',
    ];
    final rows = <List<String>>[];
    for (final sc in ctx.salespersonCoverages) {
      rows.add([
        sc.user.name,
        '${sc.tripsRun}',
        '${sc.verifiedVisits}',
        '${sc.outsideVisits}',
        '${sc.skippedVisits}',
        '${sc.uniqueCustomersVisited}',
        'Rs. ${_fmtNum(sc.totalCollected)}',
      ]);
    }
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {
        1: pw.Alignment.centerRight,
        2: pw.Alignment.centerRight,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
        5: pw.Alignment.centerRight,
        6: pw.Alignment.centerRight,
      },
      headerStyle: pw.TextStyle(
        fontSize: 7.5,
        fontWeight: pw.FontWeight.bold,
        color: _muted,
        letterSpacing: 0.3,
      ),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _coverageGapsTable(CoverageReportContext ctx) {
    final rows = <List<String>>[];
    for (final rc in ctx.routeCoverages) {
      if (rc.unvisitedCustomers.isEmpty) continue;
      for (final c in rc.unvisitedCustomers) {
        rows.add([rc.route.name, c.code, c.shopName]);
      }
    }
    if (rows.isEmpty) {
      return pw.Text(
        'No coverage gaps - every assigned customer was touched at least once in the period.',
        style: pw.TextStyle(fontSize: 9, color: _muted),
      );
    }
    return pw.TableHelper.fromTextArray(
      headers: const ['ROUTE', 'CODE', 'CUSTOMER (NEVER TOUCHED)'],
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      headerStyle: pw.TextStyle(
        fontSize: 7.5,
        fontWeight: pw.FontWeight.bold,
        color: _muted,
        letterSpacing: 0.3,
      ),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FixedColumnWidth(60),
        2: pw.FlexColumnWidth(5),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  // ========= Shared building blocks =======================================

  /// A4 page theme; when [duplicate] is true every page gets a faint diagonal
  /// "DUPLICATE" watermark behind the content (re-issued reimbursement docs).
  static pw.PageTheme _pageTheme(bool duplicate) => pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        buildBackground: (ctx) =>
            duplicate ? _duplicateWatermark() : pw.SizedBox(),
      );

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

  static pw.Widget _pageHeader(String orgName, String title) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: _rule, width: 0.7),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            orgName.toUpperCase(),
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 2,
              color: _brandBlue,
            ),
          ),
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _pageFooter(pw.Context c, String orgName, String title,
      {String? distanceNote}) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: _ruleSoft, width: 0.5),
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '$orgName - $title - Generated ${DateFormat('MMM d, y HH:mm').format(DateTime.now())}',
                style: pw.TextStyle(fontSize: 8, color: _muted),
              ),
              pw.Text('Page ${c.pageNumber} of ${c.pagesCount}',
                  style: pw.TextStyle(fontSize: 8, color: _muted)),
            ],
          ),
          if (distanceNote != null)
            pw.Text(
              distanceNote,
              style: pw.TextStyle(fontSize: 8, color: _mutedLight),
            ),
        ],
      ),
    );
  }

  static pw.Widget _subtitleLine(Trip trip) {
    final date = DateFormat('EEE, MMM d, y').format(trip.startedAt);
    return pw.Text(
      '${trip.routeName} - $date',
      style: pw.TextStyle(fontSize: 9, color: _muted),
    );
  }

  static pw.Widget _journeyBlock(
    Trip trip,
    String? startAddr,
    String? endAddr, {
    required bool status,
    int? totalVisitsOverride,
  }) {
    final startTime =
        DateFormat('hh:mm a - MMM d, y').format(trip.startedAt);
    final endTime = trip.endedAt == null
        ? 'In progress'
        : DateFormat('hh:mm a - MMM d, y').format(trip.endedAt!);

    String startLoc = startAddr ?? _coordsOrDash(trip.startLat, trip.startLng);
    String endLoc = endAddr ?? _coordsOrDash(trip.endLat, trip.endLng);

    final leftCells = <List<String>>[
      ['SALESPERSON', trip.userName.isEmpty ? '-' : trip.userName.toUpperCase()],
      ['ROUTE', trip.routeName],
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
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 0.8,
            color: _muted,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
      ],
    );
  }

  static pw.Widget _summaryRow(Trip trip) {
    // Verified and collected must exclude the field app's duplicate submissions
    // (the same collection re-sent on a GPS re-fire). VERIFIED counts distinct
    // customers by their latest visit; COLLECTED sums each DISTINCT receipt once
    // (see _receiptAmounts). CUSTOMERS stays the planned-stop count.
    final latestByCust = <String, Visit>{};
    for (final v in trip.visits) {
      final prev = latestByCust[v.customerId];
      if (prev == null || v.timestamp.isAfter(prev.timestamp)) {
        latestByCust[v.customerId] = v;
      }
    }
    // Once verified stays verified: a shop counts if ANY of its visits was.
    final verifiedCount = {
      for (final v in trip.visits)
        if (v.status == VisitStatus.verified) v.customerId,
    }.length;
    final totalCollected =
        _receiptAmounts(trip.visits).values.fold<int>(0, (s, a) => s + a);
    final completion = trip.totalStops == 0
        ? 0.0
        : (verifiedCount / trip.totalStops) * 100;

    // An off-route collections summary has no planned stops, so "customers" is
    // the distinct set actually collected from and a completion % is meaningless.
    final offRoute = trip.stopSnapshot.isEmpty;
    final distinctCustomers = latestByCust.length;

    return pw.Row(
      children: [
        _summaryCell(
            offRoute ? '$distinctCustomers' : '${trip.totalStops}', 'CUSTOMERS'),
        _summaryCell('$verifiedCount', 'VERIFIED'),
        _summaryCell(
            offRoute ? '—' : '${completion.toStringAsFixed(1)}%', 'COMPLETION'),
        _summaryCell('Rs. ${_fmtNum(totalCollected)}', 'COLLECTED'),
      ],
    );
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
            pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 7,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.6,
                color: _muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Text(
      text,
      style: pw.TextStyle(
        fontSize: 12,
        fontWeight: pw.FontWeight.bold,
        color: _ink,
      ),
    );
  }

  static pw.Widget _visitDetailsTable(Trip trip, TripReportContext ctx) {
    final byCustomer = trip.statusByCustomer;

    final headers = [
      '#', 'CODE', 'CUSTOMER', 'STATUS', 'COLLECTED', 'CR#', 'TIME', 'NOTES',
    ];
    // Rows in the order the shops were actually visited (time of each mark,
    // planned and off-route shops together); stops never marked follow at the
    // end in route order. Status uses the rules without "Skip": Visited /
    // Outside geofence / Not verified (old records may still say Skipped).
    final timed = <_TimedRow>[];
    final untouched = <List<String>>[];
    void addShop(String code, String shopName, List<Visit> vs, {Customer? cust}) {
      vs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      // A customer with more than one location: name the extra one the
      // verified visit was at, e.g. "Ali Traders (Godown)".
      var name = shopName;
      if (cust != null && cust.hasLocation) {
        for (final v in vs) {
          if (v.status != VisitStatus.verified) continue;
          final at = CustomerLocations.visitLocationName(
              cust.id, cust.latitude, cust.longitude, v.capturedLat, v.capturedLng);
          if (at.isNotEmpty) name = '$shopName ($at)';
          break;
        }
      }
      if (vs.isEmpty) {
        untouched.add(['', code, name, 'NOT VISITED', '-', '-', '-', '-']);
        return;
      }
      final verifiedVisit = vs.where((v) => v.status == VisitStatus.verified).toList();
      final collections = _dedupCollections(vs);
      if (collections.isEmpty) {
        final rep = verifiedVisit.isNotEmpty ? verifiedVisit.first : vs.last;
        timed.add(_TimedRow(rep.timestamp, [
          '', code, name,
          _outcomeTag(rep.status, 0, rep),
          '0', '-',
          DateFormat('hh:mm a').format(rep.timestamp),
          _notesFor(rep.status, rep),
        ]));
        return;
      }
      for (final v in collections) {
        // Once the shop was verified on this trip it counts as Visited.
        final st = verifiedVisit.isNotEmpty ? VisitStatus.verified : v.status;
        timed.add(_TimedRow(v.timestamp, [
          '', code, name,
          _outcomeTag(st, v.amount, v),
          '${v.amount}',
          (v.receiptNumber ?? '').isEmpty ? '-' : v.receiptNumber!,
          DateFormat('hh:mm a').format(v.timestamp),
          _notesFor(v.status, v),
        ]));
      }
    }

    for (final c in trip.stopSnapshot) {
      addShop(c.code, c.shopName, [for (final v in trip.visits) if (v.customerId == c.id) v], cust: c);
    }
    // Off-route / ad-hoc collections (customer not a planned stop, e.g. a "New
    // CR" payment) — resolved from ctx.extraCustomers.
    final snapshotIds = trip.stopSnapshot.map((c) => c.id).toSet();
    final offRouteIds = <String>[];
    for (final v in trip.visits) {
      if (!snapshotIds.contains(v.customerId) && !offRouteIds.contains(v.customerId)) {
        offRouteIds.add(v.customerId);
      }
    }
    for (final cid in offRouteIds) {
      final ref = ctx.extraCustomers[cid];
      addShop(ref?.code ?? '-', ref?.name ?? '(off-route customer)',
          [for (final v in trip.visits) if (v.customerId == cid) v]);
    }

    timed.sort((a, b) => a.at.compareTo(b.at));
    final rows = <List<String>>[];
    for (final t in timed) {
      rows.add([...t.cells]..[0] = '${rows.length + 1}');
    }
    for (final u in untouched) {
      rows.add([...u]..[0] = '${rows.length + 1}');
    }

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
        letterSpacing: 0.3,
      ),
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

  /// Shops that were verified first and had money recorded on a LATER mark
  /// (often away from the shop). The shop stays verified; these collections
  /// are listed here for the manager to review.
  static List<pw.Widget> _collectionsAfterVerified(Trip trip, TripReportContext ctx) {
    final byCust = <String, List<Visit>>{};
    for (final v in trip.visits) {
      byCust.putIfAbsent(v.customerId, () => <Visit>[]).add(v);
    }
    final rows = <List<String>>[];
    var total = 0;
    byCust.forEach((cid, vs) {
      vs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      Visit? firstVerified;
      for (final v in vs) {
        if (v.status == VisitStatus.verified) { firstVerified = v; break; }
      }
      if (firstVerified == null) return;
      final fv = firstVerified;
      final later = _dedupCollections([
        for (final v in vs)
          if (v.id != fv.id && v.timestamp.isAfter(fv.timestamp)) v,
      ]);
      if (later.isEmpty) return;
      String code = '-', name = '(customer)';
      for (final c in trip.stopSnapshot) {
        if (c.id == cid) { code = c.code; name = c.shopName; break; }
      }
      if (name == '(customer)') {
        final ref = ctx.extraCustomers[cid];
        if (ref != null) { code = ref.code; name = ref.name; }
      }
      for (final v in later) {
        total += v.amount;
        rows.add([
          code,
          name,
          DateFormat('hh:mm a').format(fv.timestamp),
          DateFormat('hh:mm a').format(v.timestamp),
          _fmtNum(v.amount),
          (v.receiptNumber ?? '').isEmpty ? '-' : v.receiptNumber!,
          _statusTagWithDistance(v.status, v),
        ]);
      }
    });
    if (rows.isEmpty) return const [];
    return [
      pw.SizedBox(height: 18),
      _sectionTitle('Collections after a verified visit'),
      pw.SizedBox(height: 2),
      pw.Text(
        'These shops were verified earlier on this trip, then money was recorded on a later mark. '
        'The shop stays verified — check where each collection was recorded.',
        style: pw.TextStyle(fontSize: 8, color: _muted),
      ),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: const ['CODE', 'CUSTOMER', 'VERIFIED AT', 'COLLECTED AT', 'AMOUNT', 'CR#', 'RECORDED'],
        data: [
          ...rows,
          ['', 'TOTAL', '', '', _fmtNum(total), '', ''],
        ],
        cellAlignment: pw.Alignment.centerLeft,
        cellAlignments: const {4: pw.Alignment.centerRight},
        headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.3),
        headerDecoration: const pw.BoxDecoration(color: _bg),
        cellStyle: const pw.TextStyle(fontSize: 8, color: _ink),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        columnWidths: const {
          0: pw.FixedColumnWidth(46),
          1: pw.FlexColumnWidth(5),
          2: pw.FixedColumnWidth(50),
          3: pw.FixedColumnWidth(54),
          4: pw.FixedColumnWidth(46),
          5: pw.FixedColumnWidth(36),
          6: pw.FixedColumnWidth(70),
        },
        border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
      ),
    ];
  }

  static pw.Widget _receiptsFooter(Trip trip) {
    // Distinct receipts only — a re-submitted collection must not be counted
    // twice here either (see _receiptAmounts).
    final amounts = _receiptAmounts(trip.visits);
    final receipts = amounts.length;
    final total = amounts.values.fold<int>(0, (s, a) => s + a);
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
          pw.Text(
            '$receipts Receipt${receipts == 1 ? '' : 's'}',
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
          pw.Text(
            'Rs. ${_fmtNum(total)}',
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _sequencedTable(TripReportContext ctx) {
    final headers = ['#', 'CODE', 'CUSTOMER', 'DISTANCE (KM)', 'TIME'];
    final rows = <List<String>>[];
    Customer? customerById(String id) {
      for (final c in ctx.trip.stopSnapshot) {
        if (c.id == id) return c;
      }
      return null;
    }

    for (int i = 0; i < ctx.orderedVerifiedVisits.length; i++) {
      final v = ctx.orderedVerifiedVisits[i];
      final c = customerById(v.customerId);
      // The route snapshot only holds stops planned at trip start, so an
      // ad-hoc visit — or an incompletely-synced snapshot on an admin's
      // device — isn't found there. Fall back to the customers looked up
      // from the local table before giving up on the name.
      final extra = ctx.extraCustomers[v.customerId];
      final code = c?.code ?? extra?.code ?? '-';
      final name = c?.shopName ?? extra?.name ?? '(customer not on this device)';
      final km = ctx.distanceKm.length > i ? ctx.distanceKm[i] : 0.0;
      rows.add([
        '${i + 1}',
        code,
        name,
        km.toStringAsFixed(2),
        DateFormat('hh:mm a').format(v.timestamp),
      ]);
    }

    if (ctx.returnDistanceKm > 0) {
      rows.add([
        '',
        '',
        'Return to end location',
        ctx.returnDistanceKm.toStringAsFixed(2),
        ctx.trip.endedAt == null
            ? '-'
            : DateFormat('hh:mm a').format(ctx.trip.endedAt!),
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
        letterSpacing: 0.3,
      ),
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

  static pw.Widget _reimbursementBlock(TripReportContext ctx) {
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
          pw.Text(
            'REIMBURSEMENT',
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.8,
              color: _muted,
            ),
          ),
          pw.SizedBox(height: 8),
          _reimbRow(
              'Total Distance', '${ctx.totalDistanceKm.toStringAsFixed(2)} km'),
          pw.SizedBox(height: 6),
          _reimbRow('Amount', ''),
          pw.SizedBox(height: 6),
          _reimbRow('Approved By', ''),
        ],
      ),
    );
  }

  static pw.Widget _reimbRow(String label, String value) {
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.SizedBox(
          width: 110,
          child: pw.Text(
            label,
            style: pw.TextStyle(fontSize: 10, color: _muted),
          ),
        ),
        pw.Expanded(
          child: pw.Container(
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: _rule, width: 0.6),
              ),
            ),
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: _ink,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static pw.Widget _signatureLine() {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 180,
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              top: pw.BorderSide(color: _ink, width: 0.6),
            ),
          ),
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(
            'OPERATIONS MANAGER',
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.8,
              color: _muted,
            ),
          ),
        ),
      ],
    );
  }

  // ---- Helpers ---------------------------------------------------------

  // De-duplicate the field app's repeat submissions. A collection is identified
  // by its receipt number; the same receipt sent again (GPS re-fire) is the
  // same money. Genuinely different receipts — e.g. a morning and an evening
  // payment from one shop — are kept separate.

  // receipt-number -> amount, one entry per DISTINCT receipt (amount > 0 only).
  // A collection with no receipt keeps its own slot (it cannot be de-duplicated).
  static Map<String, int> _receiptAmounts(List<Visit> visits) {
    final m = <String, int>{};
    var noReceiptSeq = 0;
    for (final v in visits) {
      if (v.amount <= 0) continue;
      final r = (v.receiptNumber ?? '').trim();
      // Scope the de-dup to the CUSTOMER: a GPS re-fire re-sends the SAME
      // shop's SAME receipt (must collapse), but two DIFFERENT shops that
      // happen to carry the same (mis-typed) receipt number are separate
      // collections and must both be counted — otherwise the smaller one is
      // silently dropped and COLLECTED under-reports (matches web _custLines).
      final key = (r.isEmpty || r == '0')
          ? '__nr${noReceiptSeq++}'
          : '${v.customerId}|$r';
      final prev = m[key] ?? 0;
      m[key] = v.amount > prev ? v.amount : prev;
    }
    return m;
  }

  // One representative visit per distinct collection (distinct receipt), kept in
  // time order — used to render one table line per real collection.
  static List<Visit> _dedupCollections(List<Visit> visits) {
    final seen = <String>{};
    final out = <Visit>[];
    for (final v in visits) {
      if (v.amount <= 0) continue;
      final r = (v.receiptNumber ?? '').trim();
      if (r.isEmpty || r == '0') {
        out.add(v); // no receipt to de-dup on — keep as a distinct collection
      } else if (seen.add(r)) {
        out.add(v);
      }
    }
    return out;
  }

  static String _statusLabel(Trip trip) {
    if (trip.endedAt == null) return 'IN PROGRESS';
    if (trip.closeReason == TripCloseReason.cutoff) return 'CUT-OFF';
    return 'COMPLETED';
  }

  static String _statusTagWithDistance(VisitStatus s, Visit? v) {
    final base = _statusTag(s, v);
    if (s == VisitStatus.skipped || s == VisitStatus.noLocation || s == VisitStatus.pending) {
      final dist = v?.distanceMeters;
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
  static String _outcomeTag(VisitStatus s, int collected, Visit? v) {
    final o = visitOutcomeOf(s, collected);
    final base = o.label.toUpperCase();
    if (o == VisitOutcome.outsideGeofence || o == VisitOutcome.notVerified) {
      final d = v?.distanceMeters;
      if (d != null && d > 0) {
        final away = d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km away' : '${d.round()} m away';
        return '$base\n$away';
      }
    }
    return base;
  }

  static String _statusTag(VisitStatus s, Visit? v) {
    switch (s) {
      case VisitStatus.verified:
        return 'VERIFIED';
      case VisitStatus.outside:
        final d = v?.distanceMeters;
        if (d != null) {
          final km = d / 1000.0;
          return 'OUTSIDE GF ${km.toStringAsFixed(1)}km';
        }
        return 'OUTSIDE GF';
      case VisitStatus.noLocation:
        return 'NO LOCATION';
      case VisitStatus.skipped:
        final d = v?.distanceMeters;
        if (d != null) {
          final km = d / 1000.0;
          return 'SKIPPED ${km.toStringAsFixed(1)}km';
        }
        return 'SKIPPED';
      case VisitStatus.pending:
        return 'NOT VISITED';
    }
  }

  static String _notesFor(VisitStatus s, Visit? v) {
    if (s == VisitStatus.skipped && (v?.skipReason ?? '').isNotEmpty) {
      return v!.skipReason!;
    }
    if ((v?.notes ?? '').isNotEmpty) return v!.notes!;
    return '-';
  }

  static String _fmtNum(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    int count = 0;
    for (int i = s.length - 1; i >= 0; i--) {
      buf.write(s[i]);
      count++;
      if (count % 3 == 0 && i != 0) buf.write(',');
    }
    return buf.toString().split('').reversed.join();
  }

  static String _coordsOrDash(double? lat, double? lng) {
    if (lat == null || lng == null) return 'No GPS';
    return '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
  }
}


/// A Visit Report row with the time it happened, for ordering by visit sequence.
class _TimedRow {
  final DateTime at;
  final List<String> cells;
  _TimedRow(this.at, this.cells);
}
