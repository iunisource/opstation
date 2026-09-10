import 'dart:math';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/format/money.dart';

/// Web port of mobile's TripReportContext.
/// Pre-computed data for a trip report. Distances via Haversine (no Google
/// Directions on web yet).
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
  });

  factory TripReportContext.build({
    required Map<String, dynamic> trip,
    required List<Map<String, dynamic>> visits,
    required Map<String, Map<String, dynamic>> customersById,
    String? startAddress,
    String? endAddress,
  }) {
    final ordered = visits
        .where((v) =>
            v['status'] == 'verified' &&
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

/// Web port of mobile's ReportPdfBuilder. Same layout, fonts, colors, spacing.
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
  }) async {
    final trip = ctx.trip;
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      header: (c) => _pageHeader(orgName, 'Trip Summary'),
      footer: (c) => _pageFooter(c, orgName, 'Trip Summary',
          distanceNote: ctx.usedGoogle
              ? 'Distances: Google Directions API (road distance)'
              : 'Distances: straight-line / Haversine'),
      build: (c) => [
        _subtitleLine(trip),
        pw.SizedBox(height: 14),
        _journeyBlock(trip, ctx.startAddress, ctx.endAddress,
            status: false,
            totalVisitsOverride: ctx.orderedVerifiedVisits.length),
        pw.SizedBox(height: 14),
        _sequencedTable(ctx),
        pw.SizedBox(height: 18),
        _reimbursementBlock(ctx),
        pw.SizedBox(height: 36),
        _signatureLine(),
      ],
    ));
    return doc.save();
  }

  // ========= Shared building blocks ======================================

  static pw.Widget _pageHeader(String orgName, String title) {
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
          pw.Text(title,
              style: pw.TextStyle(
                  fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
        ],
      ),
    );
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
                  '$orgName - $title - Generated ${DateFormat('MMM d, y HH:mm').format(DateTime.now())}',
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

    final startTime = DateFormat('hh:mm a - MMM d, y').format(startedAt);
    final endTime = endedAt == null
        ? 'In progress'
        : DateFormat('hh:mm a - MMM d, y').format(endedAt);
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
        'collected': byReceipt.values.fold<int>(0, (s, a) => s + a),
        'receipts':
            byReceipt.keys.where((k) => !k.startsWith('__nr')).toList(),
      });
    });
    return out;
  }

  static pw.Widget _summaryRow(Map<String, dynamic> trip, TripReportContext ctx) {
    final lines = _custLines(ctx.visits);
    final totalStops = lines.length;
    final verifiedCount = lines
        .where((l) => (l['latest'] as Map)['status'] == 'verified')
        .length;
    final totalCollected =
        lines.fold<int>(0, (s, l) => s + (l['collected'] as int));
    final completion =
        totalStops == 0 ? 0.0 : (verifiedCount / totalStops) * 100;

    return pw.Row(children: [
      _summaryCell('$totalStops', 'CUSTOMERS'),
      _summaryCell('$verifiedCount', 'VERIFIED'),
      _summaryCell('${completion.toStringAsFixed(1)}%', 'COMPLETION'),
      _summaryCell('Rs. ${_fmtNum(totalCollected)}', 'COLLECTED'),
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

  static pw.Widget _visitDetailsTable(TripReportContext ctx) {
    final lines = _custLines(ctx.visits);

    final headers = [
      '#', 'CODE', 'CUSTOMER', 'STATUS', 'COLLECTED', 'CR#', 'TIME', 'NOTES'
    ];
    final rows = <List<String>>[];
    for (var i = 0; i < lines.length; i++) {
      final cid = lines[i]['cid'] as String;
      final v = lines[i]['latest'] as Map<String, dynamic>;
      final cust = ctx.customersById[cid];
      final status = v['status'] as String? ?? 'pending';
      final collected = lines[i]['collected'] as int;
      final receipts = (lines[i]['receipts'] as List).cast<String>();
      rows.add([
        '${i + 1}',
        (cust?['code'] as String?) ?? '-',
        (cust?['shop_name'] as String?) ?? '-',
        _statusTagWithDistance(status, v),
        status == 'pending' ? '-' : '$collected',
        receipts.isEmpty ? '-' : receipts.join(', '),
        DateFormat('hh:mm a')
            .format(DateTime.parse(v['timestamp'] as String).toLocal()),
        _notesFor(status, v),
      ]);
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

  /// Expand a receipt field into every slip number it represents — combined
  /// entries ("31457 & 31458", "31451 to 31452") and shorthand ("32282 83 84"
  /// = 32282, 32283, 32284). Reading only the first number over-counted skips.
  static List<int> _receiptSlipNumbers(String raw) {
    final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
    final out = <int>[];
    int? prevFull;
    for (final t in toks) {
      final n = int.parse(t);
      final prevLen = prevFull?.toString().length ?? 0;
      if (prevFull == null || t.length >= prevLen) {
        out.add(n); prevFull = n;
      } else {
        var p10 = 1; for (var i = 0; i < t.length; i++) p10 *= 10;
        final e = (prevFull - (prevFull % p10)) + n;
        out.add(e); prevFull = e;
      }
    }
    return out;
  }

  /// Missing receipt numbers in the trip's sequence — a skip means a
  /// collection may have been made but never entered. Big jumps (> 20) are
  /// treated as a new receipt book and ignored. Admin control only.
  static List<int> _skippedReceipts(TripReportContext ctx) {
    final nums = <int>[];
    for (final v in ctx.visits) {
      nums.addAll(_receiptSlipNumbers(v['receipt_number'] as String? ?? ''));
    }
    nums.sort();
    final missing = <int>[];
    for (var i = 1; i < nums.length; i++) {
      final gap = nums[i] - nums[i - 1];
      if (gap > 1 && gap <= 20) {
        for (var n = nums[i - 1] + 1; n < nums[i]; n++) {
          missing.add(n);
        }
      }
    }
    return missing;
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
        DateFormat('hh:mm a')
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
            : DateFormat('hh:mm a').format(
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
          pw.Text('REIMBURSEMENT',
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.8,
                  color: _muted)),
          pw.SizedBox(height: 8),
          _reimbRow('Total Distance',
              '${ctx.totalDistanceKm.toStringAsFixed(2)} km'),
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

  static pw.Widget _signatureLine() {
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
        return 'NO LOCATION';
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
