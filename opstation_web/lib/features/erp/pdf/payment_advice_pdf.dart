import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One party row on a Payment Advice slip.
class PaymentAdvicePdfLine {
  final String partyName;
  final String partyType; // customer | supplier
  final String bankDetails;
  final double amountDue;
  final double amountToPay;
  final DateTime? lastPayment;
  const PaymentAdvicePdfLine({
    required this.partyName,
    required this.partyType,
    required this.bankDetails,
    required this.amountDue,
    required this.amountToPay,
    this.lastPayment,
  });
}

/// Printable Payment Advice (A4). Non-financial slip: parties, bank details,
/// amount due, amount to be paid, grand total, created/approved footprints.
class PaymentAdvicePdf {
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _brand = PdfColor.fromInt(0xFF2F6FED);
  static const _band = PdfColor.fromInt(0xFFF3F4F6);

  static String _money(double v) {
    final f = v == v.roundToDouble()
        ? NumberFormat('#,##0')
        : NumberFormat('#,##0.00');
    return 'Rs ${f.format(v)}';
  }

  static Future<Uint8List> build({
    required String orgName,
    required String adviceNumber,
    required DateTime adviceDate,
    required String status, // pending | approved
    required String note,
    required List<PaymentAdvicePdfLine> lines,
    required double grandTotal,
    required String createdBy,
    required DateTime? createdAt,
    required String? approvedBy,
    required DateTime? approvedAt,
  }) async {
    // Use a Unicode TTF so em-dashes, bullets (•) in bank details, middots
    // and non-Latin text all render instead of the missing-glyph box that
    // the built-in Helvetica shows. Falls back to Helvetica if the font
    // can't be fetched (offline), which is still correct for plain ASCII.
    pw.ThemeData? theme;
    try {
      final base = await PdfGoogleFonts.notoSansRegular();
      final bold = await PdfGoogleFonts.notoSansBold();
      theme = pw.ThemeData.withFont(base: base, bold: bold);
    } catch (_) {
      theme = null;
    }

    final doc = pw.Document(title: 'Payment Advice $adviceNumber', theme: theme);
    final dFmt = DateFormat('d MMM yyyy');
    final dtFmt = DateFormat('d MMM yyyy, HH:mm');
    final dShort = DateFormat('d MMM yy');

    pw.Widget cell(String t,
            {bool bold = false,
            pw.TextAlign align = pw.TextAlign.left,
            double size = 9.5,
            PdfColor color = _ink}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.Text(t,
              textAlign: align,
              style: pw.TextStyle(
                  fontSize: size,
                  color: color,
                  fontWeight:
                      bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        );

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _band),
        children: [
          cell('#', bold: true),
          cell('Party', bold: true),
          cell('Bank details', bold: true),
          cell('Last paid', bold: true, align: pw.TextAlign.center),
          cell('Amount due', bold: true, align: pw.TextAlign.right),
          cell('Amount to pay', bold: true, align: pw.TextAlign.right),
        ],
      ),
      for (var i = 0; i < lines.length; i++)
        pw.TableRow(
          decoration: pw.BoxDecoration(
              border: const pw.Border(
                  bottom: pw.BorderSide(color: _rule, width: 0.4))),
          children: [
            cell('${i + 1}'),
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(lines[i].partyName,
                        style: pw.TextStyle(
                            fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                    pw.Text(lines[i].partyType,
                        style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
                  ]),
            ),
            cell(lines[i].bankDetails.isEmpty ? '-' : lines[i].bankDetails,
                size: 8.5),
            cell(
                lines[i].lastPayment == null
                    ? '-'
                    : dShort.format(lines[i].lastPayment!),
                align: pw.TextAlign.center,
                size: 8.5),
            cell(_money(lines[i].amountDue), align: pw.TextAlign.right),
            cell(_money(lines[i].amountToPay),
                align: pw.TextAlign.right, bold: true),
          ],
        ),
    ];

    pw.Widget foot(String label, String who, String when) => pw.Expanded(
          child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(label,
                    style: pw.TextStyle(
                        fontSize: 7.5,
                        letterSpacing: 1,
                        color: _muted,
                        fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 3),
                pw.Text(who,
                    style: pw.TextStyle(
                        fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.Text(when,
                    style: const pw.TextStyle(fontSize: 8, color: _muted)),
                pw.SizedBox(height: 22),
                pw.Container(
                    width: 150,
                    decoration: const pw.BoxDecoration(
                        border: pw.Border(
                            top: pw.BorderSide(color: _ink, width: 0.6)))),
                pw.SizedBox(height: 2),
                pw.Text('Signature',
                    style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
              ]),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 30),
      header: (c) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 6),
        margin: const pw.EdgeInsets.only(bottom: 12),
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
                    color: _brand)),
            pw.Text('Payment Advice',
                style: pw.TextStyle(
                    fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
          ],
        ),
      ),
      footer: (c) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 6),
        decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _rule, width: 0.5))),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                  'Non-financial processing slip - does not post to accounts.',
                  style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
              pw.Text('Page ${c.pageNumber} of ${c.pagesCount}',
                  style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
            ]),
      ),
      build: (c) => [
        // Meta block
        pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(adviceNumber,
                        style: pw.TextStyle(
                            fontSize: 14, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 2),
                    pw.Text('Date: ${dFmt.format(adviceDate)}',
                        style: const pw.TextStyle(fontSize: 9.5)),
                    if (note.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 2),
                      pw.Text('Note: ${note.trim()}',
                          style:
                              const pw.TextStyle(fontSize: 9, color: _muted)),
                    ],
                  ]),
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: pw.BoxDecoration(
                    color: status == 'approved'
                        ? const PdfColor.fromInt(0xFFDCFCE7)
                        : const PdfColor.fromInt(0xFFFEF3C7),
                    borderRadius: pw.BorderRadius.circular(4)),
                child: pw.Text(status.toUpperCase(),
                    style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        letterSpacing: 1,
                        color: status == 'approved'
                            ? const PdfColor.fromInt(0xFF166534)
                            : const PdfColor.fromInt(0xFF92400E))),
              ),
            ]),
        pw.SizedBox(height: 14),
        pw.Table(
          border: const pw.TableBorder(
              top: pw.BorderSide(color: _rule, width: 0.6),
              bottom: pw.BorderSide(color: _rule, width: 0.6)),
          columnWidths: {
            0: const pw.FixedColumnWidth(22),
            1: const pw.FlexColumnWidth(2.1),
            2: const pw.FlexColumnWidth(2.9),
            3: const pw.FlexColumnWidth(1.1),
            4: const pw.FlexColumnWidth(1.3),
            5: const pw.FlexColumnWidth(1.3),
          },
          children: rows,
        ),
        pw.SizedBox(height: 10),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: pw.BoxDecoration(
                color: _band, borderRadius: pw.BorderRadius.circular(4)),
            child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
              pw.Text('GRAND TOTAL',
                  style: pw.TextStyle(
                      fontSize: 9,
                      letterSpacing: 1,
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(width: 24),
              pw.Text(_money(grandTotal),
                  style: pw.TextStyle(
                      fontSize: 13,
                      fontWeight: pw.FontWeight.bold,
                      color: _brand)),
            ]),
          ),
        ]),
        pw.SizedBox(height: 28),
        pw.Row(children: [
          foot('CREATED BY', createdBy,
              createdAt == null ? '-' : dtFmt.format(createdAt.toLocal())),
          foot(
              'APPROVED BY',
              approvedBy ?? '-',
              approvedAt == null
                  ? (status == 'pending' ? 'Awaiting approval' : '-')
                  : dtFmt.format(approvedAt.toLocal())),
          foot('RECEIVED BY', '', ''),
        ]),
      ],
    ));
    return doc.save();
  }
}
