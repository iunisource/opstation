import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format/time_format.dart';
import 'driver_job_report.dart';

/// The Driver Trip Summary of a job (deliveries and pickups) — the same document the driver's
/// phone makes, so it can be generated on the web too: journey start and end, the stops in
/// sequence with the distance of each leg, the way back to the return location, the total.
class DriverJobPdf {
  DriverJobPdf._();

  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _mutedLight = PdfColor.fromInt(0xFF9CA3AF);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);

  /// The PDF font has no long dashes, arrows or curly quotes (they print as boxes).
  static String _safe(String t) => t
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('\u2192', 'to')
      .replaceAll('\u2026', '...')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"');

  static DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
  static String _time(DateTime d) => DateFormat(orgTime('hh:mm a')).format(d);
  static String _dateTime(DateTime d) => '${_time(d)} - ${DateFormat('MMM d, y').format(d)}';

  static Future<Uint8List> build({required DriverJobReportContext ctx, required String orgName}) async {
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      header: (c) => _pageHeader(orgName),
      footer: (c) => _pageFooter(c, orgName, ctx.usedGoogle),
      build: (c) => [
        _subtitleLine(ctx.delivery),
        pw.SizedBox(height: 14),
        _journeyBlock(ctx),
        pw.SizedBox(height: 14),
        _summaryRow(ctx),
        pw.SizedBox(height: 14),
        _sectionTitle('Stop Sequence'),
        pw.SizedBox(height: 6),
        _sequencedTable(ctx),
        pw.SizedBox(height: 18),
        _reimbursementBlock(ctx),
        pw.SizedBox(height: 36),
        _signatureLine(),
      ],
    ));
    return doc.save();
  }

  static pw.Widget _pageHeader(String orgName) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 6),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.7))),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(_safe(orgName).toUpperCase(),
                style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, letterSpacing: 2, color: _brandBlue)),
            pw.Text('Driver Trip Summary', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
          ],
        ),
      );

  static pw.Widget _pageFooter(pw.Context c, String orgName, bool usedGoogle) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 6),
        decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _ruleSoft, width: 0.5))),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('${_safe(orgName)} - Driver Trip Summary - Generated ${DateFormat('MMM d, y HH:mm').format(DateTime.now())}',
                style: pw.TextStyle(fontSize: 8, color: _muted)),
            pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: pw.TextStyle(fontSize: 8, color: _muted)),
          ]),
          pw.Text(
            usedGoogle ? 'Distances: Google Directions API (road distance)' : 'Distances: straight-line / Haversine',
            style: pw.TextStyle(fontSize: 8, color: _mutedLight),
          ),
        ]),
      );

  static pw.Widget _subtitleLine(Map<String, dynamic> d) {
    final created = _dt(d['created_at']);
    final date = created == null ? '' : DateFormat('EEE, MMM d, y').format(created);
    return pw.Text('${_safe('${d['driver_name'] ?? 'Driver'}')} - $date', style: pw.TextStyle(fontSize: 9, color: _muted));
  }

  static pw.Widget _journeyBlock(DriverJobReportContext ctx) {
    final d = ctx.delivery;
    final started = _dt(d['started_at']);
    final ended = _dt(d['completed_at']);
    final startText = started == null ? 'Not started' : _dateTime(started);
    final endText = ended == null ? 'In progress' : _dateTime(ended);
    final startAddr = ctx.startAddress ?? '';
    final endAddr = ctx.endAddress ?? '';
    final status = '${d['status'] ?? ''}'.replaceAll('_', ' ').toUpperCase();

    final left = [
      ['DRIVER', _safe('${d['driver_name'] ?? 'Unassigned'}').toUpperCase()],
      ['STATUS', status],
      ['TOTAL STOPS', '${ctx.stops.length}'],
    ];
    final right = [
      ['JOURNEY STARTED', startAddr.isEmpty ? startText : '$startText\n${_safe(startAddr)}'],
      ['JOURNEY ENDED', endAddr.isEmpty ? endText : '$endText\n${_safe(endAddr)}'],
      ['DISPATCHED BY', _safe('${d['created_by_name'] ?? ''}')],
    ];
    return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          for (final c in left) ...[_labelValue(c[0], c[1]), pw.SizedBox(height: 10)],
        ]),
      ),
      pw.SizedBox(width: 16),
      pw.Expanded(
        flex: 2,
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          for (final c in right) ...[_labelValue(c[0], c[1]), pw.SizedBox(height: 10)],
        ]),
      ),
    ]);
  }

  static pw.Widget _summaryRow(DriverJobReportContext ctx) {
    final delivered = ctx.stops.where((s) => s['status'] == 'delivered').length;
    final failed = ctx.stops.where((s) => s['status'] == 'failed').length;
    return pw.Row(children: [
      _summaryCell('${ctx.stops.length}', 'STOPS'),
      _summaryCell('$delivered', 'DELIVERED'),
      _summaryCell('$failed', 'FAILED'),
      _summaryCell('${ctx.totalDistanceKm.toStringAsFixed(2)} km', 'DISTANCE'),
    ]);
  }

  static pw.Widget _summaryCell(String value, String label) => pw.Expanded(
        child: pw.Container(
          margin: const pw.EdgeInsets.only(right: 6),
          padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: pw.BoxDecoration(
            color: _bg,
            border: pw.Border.all(color: _ruleSoft, width: 0.5),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
          ),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(value, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _ink)),
            pw.SizedBox(height: 2),
            pw.Text(label, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: _muted)),
          ]),
        ),
      );

  static pw.Widget _sectionTitle(String text) => pw.Text(text, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink));

  /// The rows of the Stop Sequence table (also used by the tests).
  static List<List<String>> stopRows(DriverJobReportContext ctx) {
    final rows = <List<String>>[];
    var gpsIdx = 0;
    for (var i = 0; i < ctx.stops.length; i++) {
      final s = ctx.stops[i];
      final pickup = s['stop_type'] == 'pickup';
      final status = '${s['status']}';
      final outcome = status == 'delivered' ? (pickup ? 'PICKED UP' : 'DELIVERED') : (status == 'failed' ? 'FAILED' : 'PENDING');
      var dist = '-';
      var time = '-';
      if (DriverJobReport.hasGps(s)) {
        // The first stop's distance is from the start, when the job's start was recorded.
        if (gpsIdx < ctx.distanceKm.length && (gpsIdx > 0 || ctx.distanceKm[gpsIdx] > 0)) {
          dist = ctx.distanceKm[gpsIdx].toStringAsFixed(2);
        }
        gpsIdx++;
      }
      final at = _dt(s['delivered_at']);
      if (status != 'pending' && at != null) time = _time(at);
      final name = _safe('${s['customer_name'] ?? ''}');
      final code = '${s['customer_code'] ?? ''}';
      rows.add(['${i + 1}', '$name\n$code${pickup ? '\nPICKUP' : ''}', outcome, dist, time]);
    }
    if (ctx.returnDistanceKm > 0) rows.add(['', 'Return to end', '', ctx.returnDistanceKm.toStringAsFixed(2), '']);
    rows.add(['', 'Total Distance', '', '${ctx.totalDistanceKm.toStringAsFixed(2)} km', '']);
    return rows;
  }

  static pw.Widget _sequencedTable(DriverJobReportContext ctx) {
    const headers = ['#', 'CUSTOMER', 'STATUS', 'DISTANCE (KM)', 'TIME'];
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: stopRows(ctx),
      cellAlignment: pw.Alignment.centerLeft,
      cellAlignments: const {0: pw.Alignment.center, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight},
      headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.3),
      headerDecoration: const pw.BoxDecoration(color: _bg),
      cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      columnWidths: const {
        0: pw.FixedColumnWidth(20),
        1: pw.FlexColumnWidth(4),
        2: pw.FixedColumnWidth(66), // wide enough for DELIVERED on one line
        3: pw.FixedColumnWidth(64),
        4: pw.FixedColumnWidth(50),
      },
      border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
    );
  }

  static pw.Widget _reimbursementBlock(DriverJobReportContext ctx) => pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: _bg,
          border: pw.Border.all(color: _ruleSoft, width: 0.5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('REIMBURSEMENT', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
          pw.SizedBox(height: 8),
          _reimbRow('Total Distance', '${ctx.totalDistanceKm.toStringAsFixed(2)} km'),
          pw.SizedBox(height: 6),
          _reimbRow('Amount', ''),
          pw.SizedBox(height: 6),
          _reimbRow('Approved By', ''),
        ]),
      );

  static pw.Widget _reimbRow(String label, String value) => pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
        pw.SizedBox(width: 110, child: pw.Text(label, style: pw.TextStyle(fontSize: 10, color: _muted))),
        pw.Expanded(
          child: pw.Container(
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6))),
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _ink)),
          ),
        ),
      ]);

  static pw.Widget _labelValue(String label, String value) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(label, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
        pw.SizedBox(height: 2),
        pw.Text(value, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _ink)),
      ]);

  static pw.Widget _signatureLine() => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Container(
          width: 180,
          decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _ink, width: 0.6))),
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text('OPERATIONS MANAGER', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8, color: _muted)),
        ),
      ]);
}
