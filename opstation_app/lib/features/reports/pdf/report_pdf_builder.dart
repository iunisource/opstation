import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../salesperson/models/customer.dart';
import '../../salesperson/models/trip.dart';
import '../services/coverage_context_builder.dart';
import '../services/report_context_builder.dart';

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
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
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
    final completion = trip.totalStops == 0
        ? 0.0
        : (trip.verifiedCount / trip.totalStops) * 100;

    return pw.Row(
      children: [
        _summaryCell('${trip.totalStops}', 'CUSTOMERS'),
        _summaryCell('${trip.verifiedCount}', 'VERIFIED'),
        _summaryCell('${completion.toStringAsFixed(1)}%', 'COMPLETION'),
        _summaryCell('Rs. ${_fmtNum(trip.totalCollected)}', 'COLLECTED'),
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
    final rows = <List<String>>[];
    for (int i = 0; i < trip.stopSnapshot.length; i++) {
      final c = trip.stopSnapshot[i];

      // Every visit for this stop, oldest → newest. A customer collected from
      // more than once in a day (e.g. a morning payment and an evening one)
      // gets a line PER collection — each with its own amount, receipt and
      // time — instead of collapsing to just the latest. The stop number and
      // shop repeat on each line so the grouping survives a page break.
      final stopVisits = [
        for (final v in trip.visits)
          if (v.customerId == c.id) v,
      ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      if (stopVisits.isEmpty) {
        final status = byCustomer[c.id] ?? VisitStatus.pending;
        rows.add([
          '${i + 1}',
          c.code,
          c.shopName,
          _statusTagWithDistance(status, null),
          status == VisitStatus.pending ? '-' : '0',
          '-',
          '-',
          _notesFor(status, null),
        ]);
        continue;
      }

      for (final v in stopVisits) {
        rows.add([
          '${i + 1}',
          c.code,
          c.shopName,
          _statusTagWithDistance(v.status, v),
          '${v.amount}',
          (v.receiptNumber ?? '').isEmpty ? '-' : v.receiptNumber!,
          DateFormat('hh:mm a').format(v.timestamp),
          _notesFor(v.status, v),
        ]);
      }
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

  static pw.Widget _receiptsFooter(Trip trip) {
    int receipts = 0;
    int total = 0;
    for (final v in trip.visits) {
      if ((v.receiptNumber ?? '').isNotEmpty && v.amount > 0) receipts++;
      total += v.amount;
    }
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
