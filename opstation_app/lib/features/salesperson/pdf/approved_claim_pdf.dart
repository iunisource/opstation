import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One day of an approved reimbursement: the day, the route(s) run and the km.
class ApprovedDayRow {
  final DateTime date;
  final String routes;
  final double km;
  const ApprovedDayRow({required this.date, required this.routes, required this.km});
}

/// Reimbursement figures printed on the approved copy (same as the portal's ReimbInfo).
class ApprovedReimbInfo {
  final double? rate;
  final String? stamp;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? verifyUrl;
  final double paidKm;
  final double? allowanceTotal;
  const ApprovedReimbInfo({this.rate, this.stamp, this.approvedBy, this.approvedAt, this.verifyUrl, this.paidKm = 0, this.allowanceTotal});
}

/// The approved copy of a reimbursement, laid out like the one the portal prints
/// (Combined Trip Summary with the APPROVED BY marks, claim block and verify QR).
class ApprovedClaimPdf {
  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _mutedLight = PdfColor.fromInt(0xFF9CA3AF);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);

  static Future<Uint8List> build({
    required String orgName,
    required String periodLabel,
    required String salespersonLabel,
    required List<ApprovedDayRow> rows,
    required double grandTotalKm,
    required ApprovedReimbInfo reimb,
    String? adjustNote,
  }) async {
    final doc = pw.Document();
    final headers = <String>['DATE', 'ROUTE(S)', 'DISTANCE (KM)'];
    final data = <List<String>>[
      for (final r in rows) [DateFormat('EEE, MMM d, y').format(r.date), r.routes, r.km.toStringAsFixed(2)],
      ['TOTAL', '', '${grandTotalKm.toStringAsFixed(2)} km'],
      if (reimb.paidKm > 0) ...[
        ['EXCLUDED (already approved)', '', '- ${reimb.paidKm.toStringAsFixed(2)} km'],
        ['TOTAL TO CLAIM', '', '${(grandTotalKm - reimb.paidKm).clamp(0, double.infinity).toStringAsFixed(2)} km'],
      ],
    ];
    final by = reimb.approvedBy?.trim() ?? '';
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        buildBackground: (ctx) => pw.SizedBox(),
        buildForeground: by.isEmpty ? null : (ctx) => _approvedMarks(by, reimb.approvedAt),
      ),
      header: (c) => _pageHeader(orgName, 'Combined Trip Summary', verifyUrl: reimb.verifyUrl),
      footer: (c) => _pageFooter(c, orgName, 'Combined Trip Summary',
          distanceNote: 'Distances: road distance (Google Directions API); straight-line where unavailable'),
      build: (c) => [
        pw.Text(salespersonLabel, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(height: 2),
        pw.Text('Period: $periodLabel   -   ${rows.length} day${rows.length == 1 ? '' : 's'}',
            style: pw.TextStyle(fontSize: 9, color: _muted)),
        pw.SizedBox(height: 14),
        if (rows.isEmpty)
          pw.Text('No trips in the selected period.', style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          pw.TableHelper.fromTextArray(
            headers: headers,
            data: data,
            cellAlignment: pw.Alignment.centerLeft,
            cellAlignments: {2: pw.Alignment.centerRight},
            headerStyle: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.3),
            headerDecoration: const pw.BoxDecoration(color: _bg),
            cellStyle: const pw.TextStyle(fontSize: 8.5, color: _ink),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            border: pw.TableBorder.all(color: _ruleSoft, width: 0.3),
          ),
        pw.SizedBox(height: 18),
        if (adjustNote != null && adjustNote.trim().isNotEmpty) ...[_adjustBox(adjustNote), pw.SizedBox(height: 10)],
        if (reimb.stamp != null) ...[_paidStamp(reimb), pw.SizedBox(height: 10)],
        _claimBlock(grandTotalKm, reimb, rows.length),
        pw.SizedBox(height: 36),
        _signatureLine(),
      ],
    ));
    return doc.save();
  }

  static pw.Widget _claimBlock(double totalKm, ApprovedReimbInfo reimb, int days) {
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
          ..._reimbRows(totalKm, reimb, days),
        ],
      ),
    );
  }

  static pw.Widget _approvedMarks(String by, DateTime? at) {
    final line = 'APPROVED BY ${by.toUpperCase()}';
    final when = at == null ? '' : DateFormat('d MMM yyyy, h:mm a').format(at.toLocal());
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

  static List<pw.Widget> _reimbRows(double km, ApprovedReimbInfo? r, int days) {
    final f = NumberFormat('#,##0');
    final f2 = NumberFormat('#,##0.##');
    final nothing = false;
    final locked = r?.paidKm ?? 0;
    final rate = r?.rate;
    final due = (km - locked) < 0 ? 0.0 : km - locked;
    final amt = rate == null || nothing ? null : (due * rate).round();
    // Allowance per day (Admin Settings): days not already approved × allowance.
    final double? perDay = null;
    final allowDays = days;
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


  static pw.Widget _paidStamp(ApprovedReimbInfo r) {
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
            'EXCLUDED - ALREADY APPROVED FOR REIMBURSEMENT',
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6, color: c)),
        pw.SizedBox(height: 4),
        pw.Text(_pdfSafe(r.stamp ?? ''), style: const pw.TextStyle(fontSize: 9, color: PdfColor.fromInt(0xFF334155))),
      ]),
    );
  }


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

  static pw.Widget _signatureLine([ApprovedReimbInfo? reimb]) {
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
}
