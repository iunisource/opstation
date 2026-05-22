import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../dispatch/models/delivery.dart';
import '../services/driver_report_context_builder.dart';

class DriverSummaryPdfBuilder {
  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _mutedLight = PdfColor.fromInt(0xFF9CA3AF);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);

  static final _dtFmt = DateFormat('hh:mm a - MMM d, y');
  static final _timeFmt = DateFormat('hh:mm a');
  static final _genFmt = DateFormat('MMM d, y HH:mm');
  static final _subFmt = DateFormat('EEE, MMM d, y');

  static Future<List<int>> build({
    required DriverReportContext ctx,
    required String orgName,
  }) async {
    final d = ctx.delivery;
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        header: (c) => _pageHeader(orgName),
        footer: (c) => _pageFooter(c, orgName, ctx.usedGoogle),
        build: (c) => [
          _subtitleLine(d),
          pw.SizedBox(height: 14),
          _journeyBlock(d, ctx),
          pw.SizedBox(height: 14),
          _summaryRow(d, ctx),
          pw.SizedBox(height: 14),
          _sectionTitle('Stop Sequence'),
          pw.SizedBox(height: 6),
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

  static pw.Widget _pageHeader(String orgName) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.7)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(orgName.toUpperCase(),
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, letterSpacing: 2, color: _brandBlue)),
          pw.Text('Driver Trip Summary',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
        ],
      ),
    );
  }

  static pw.Widget _pageFooter(pw.Context c, String orgName, bool usedGoogle) {
    final generated = _genFmt.format(DateTime.now());
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _ruleSoft, width: 0.5)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '$orgName - Driver Trip Summary - Generated $generated',
                style: pw.TextStyle(fontSize: 8, color: _muted),
              ),
              pw.Text('Page ${c.pageNumber} of ${c.pagesCount}',
                  style: pw.TextStyle(fontSize: 8, color: _muted)),
            ],
          ),
          pw.Text(
            usedGoogle
                ? 'Distances: Google Directions API (road distance)'
                : 'Distances: straight-line / Haversine — add GOOGLE_MAPS_API_KEY for road distances',
            style: pw.TextStyle(fontSize: 8, color: _mutedLight),
          ),
        ],
      ),
    );
  }

  static pw.Widget _subtitleLine(Delivery d) {
    final date = _subFmt.format(d.createdAt);
    final name = d.driverName ?? 'Driver';
    return pw.Text(
      '$name · $date',
      style: pw.TextStyle(fontSize: 9, color: _muted),
    );
  }

  static pw.Widget _journeyBlock(Delivery d, DriverReportContext ctx) {
    final started = d.startedAt == null ? 'Not started' : _dtFmt.format(d.startedAt!);
    final startAddr = ctx.startAddress ?? '';
    final ended = d.completedAt == null ? 'In progress' : _dtFmt.format(d.completedAt!);
    final endAddr = ctx.endAddress ?? '';
    final driverName = (d.driverName ?? 'Unassigned').toUpperCase();

    final left = [
      ['DRIVER', driverName],
      ['STATUS', d.status.wire.toUpperCase()],
      ['TOTAL STOPS', '${d.stops.length}'],
    ];
    final right = [
      ['JOURNEY STARTED', startAddr.isEmpty ? started : '$started\n$startAddr'],
      ['JOURNEY ENDED', endAddr.isEmpty ? ended : '$ended\n$endAddr'],
      ['DISPATCHED BY', d.createdByName],
    ];

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final c in left) ...[_labelValue(c[0], c[1]), pw.SizedBox(height: 10)],
            ],
          ),
        ),
        pw.SizedBox(width: 16),
        pw.Expanded(
          flex: 2,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final c in right) ...[_labelValue(c[0], c[1]), pw.SizedBox(height: 10)],
            ],
          ),
        ),
      ],
    );
  }

  static pw.Widget _summaryRow(Delivery d, DriverReportContext ctx) {
    return pw.Row(
      children: [
        _summaryCell('${d.stops.length}', 'STOPS'),
        _summaryCell('${d.deliveredCount}', 'DELIVERED'),
        _summaryCell('${d.failedCount}', 'FAILED'),
        _summaryCell('${ctx.totalDistanceKm.toStringAsFixed(2)} km', 'DISTANCE'),
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
            pw.Text(value, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
            pw.SizedBox(height: 2),
            pw.Text(label, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: _muted)),
          ],
        ),
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Text(text, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink));
  }

  static pw.Widget _sequencedTable(DriverReportContext ctx) {
    const headers = ['#', 'CUSTOMER', 'STATUS', 'DISTANCE (KM)', 'TIME'];
    final rows = <List<String>>[];

    int gpsIdx = 0;

    for (int i = 0; i < ctx.orderedStops.length; i++) {
      final s = ctx.orderedStops[i];

      String outcome;
      switch (s.status) {
        case DeliveryStopStatus.delivered:
          outcome = 'DELIVERED';
          break;
        case DeliveryStopStatus.failed:
          outcome = 'FAILED';
          break;
        case DeliveryStopStatus.pending:
          outcome = 'PENDING';
          break;
      }

      String distStr = '-';
      String timeStr = '-';

      if (s.status == DeliveryStopStatus.delivered && s.capturedLat != null) {
        if (gpsIdx > 0 && gpsIdx < ctx.distanceKm.length) {
          distStr = ctx.distanceKm[gpsIdx].toStringAsFixed(2);
        }
        if (s.deliveredAt != null) timeStr = _timeFmt.format(s.deliveredAt!);
        gpsIdx++;
      }

      final customerLine = '${s.customerName}\n${s.customerCode}';
      rows.add(['${i + 1}', customerLine, outcome, distStr, timeStr]);
    }

    if (ctx.returnDistanceKm > 0) {
      rows.add(['', 'Return to end', '', ctx.returnDistanceKm.toStringAsFixed(2), '']);
    }

    rows.add(['', 'Total Distance', '', '${ctx.totalDistanceKm.toStringAsFixed(2)} km', '']);

    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: rows,
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {
        0: pw.Alignment.center,
        3: pw.Alignment.centerRight,
        4: pw.Alignment.centerRight,
      },
      headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.3),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      columnWidths: const {
        0: pw.FixedColumnWidth(20),
        1: pw.FlexColumnWidth(4),
        2: pw.FixedColumnWidth(54),
        3: pw.FixedColumnWidth(64),
        4: pw.FixedColumnWidth(50),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _reimbursementBlock(DriverReportContext ctx) {
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
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
          pw.SizedBox(height: 8),
          _reimbRow('Total Distance', '${ctx.totalDistanceKm.toStringAsFixed(2)} km'),
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
        pw.SizedBox(width: 110, child: pw.Text(label, style: pw.TextStyle(fontSize: 10, color: _muted))),
        pw.Expanded(
          child: pw.Container(
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6)),
            ),
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _ink)),
          ),
        ),
      ],
    );
  }

  static pw.Widget _labelValue(String label, String value) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
        pw.SizedBox(height: 2),
        pw.Text(value, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink)),
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
            border: pw.Border(top: pw.BorderSide(color: _ink, width: 0.6)),
          ),
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('OPERATIONS MANAGER',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
        ),
      ],
    );
  }
}
