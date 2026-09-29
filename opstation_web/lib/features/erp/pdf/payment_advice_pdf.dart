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
    // Accounts copy: same slip WITHOUT the party's current balance / payable
    // ("Amount due") column.
    bool accountsCopy = false,
    // Pictorial signatures (and the company stamp next to the approver's).
    pw.ImageProvider? createdSignature,
    pw.ImageProvider? approvedSignature,
    pw.ImageProvider? approvedStamp,
    // Faint grid of "approved by" marks (name, time, signature) across the
    // page, so a copy can be matched against the approval at a glance.
    bool approvalWatermark = false,
    pw.ImageProvider? approvalMarkSignature,
    String? voidedBy,
    DateTime? voidedAt,
    String? voidReason,
  }) async {
    final isVoid = status == 'void';
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
          if (!accountsCopy)
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
                    // Free-text parties print by name only (no type label).
                    if (lines[i].partyType != 'other')
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
            if (!accountsCopy)
              cell(_money(lines[i].amountDue), align: pw.TextAlign.right),
            cell(_money(lines[i].amountToPay),
                align: pw.TextAlign.right, bold: true),
          ],
        ),
    ];

    pw.Widget foot(String label, String who, String when,
            {pw.ImageProvider? sig, pw.ImageProvider? stamp}) => pw.Expanded(
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
                if (sig != null || stamp != null)
                  pw.SizedBox(
                    height: 46,
                    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                      if (sig != null)
                        pw.Image(sig, height: 40, width: 110, fit: pw.BoxFit.contain),
                      if (stamp != null) ...[
                        pw.SizedBox(width: 6),
                        pw.Image(stamp, height: 46, width: 46, fit: pw.BoxFit.contain),
                      ],
                    ]),
                  )
                else
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

    // Voided slips carry a grid of small "VOIDED" stamps over every page, so
    // at least some stay readable whatever is printed underneath.
    pw.Widget voidStamps() => pw.FullPage(
          ignoreMargins: true,
          child: pw.Opacity(
            opacity: 0.2,
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
              children: [
                for (var r = 0; r < 7; r++)
                  pw.Padding(
                    padding: pw.EdgeInsets.only(left: r.isOdd ? 70 : 0, right: r.isOdd ? 0 : 70),
                    child: pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var c = 0; c < 3; c++)
                          pw.Transform.rotate(
                            angle: 0.45,
                            child: pw.Container(
                              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: pw.BoxDecoration(
                                border: pw.Border.all(color: PdfColors.red800, width: 2),
                                borderRadius: pw.BorderRadius.circular(4),
                              ),
                              child: pw.Text('VOIDED',
                                  style: pw.TextStyle(
                                      fontSize: 24,
                                      fontWeight: pw.FontWeight.bold,
                                      color: PdfColors.red800,
                                      letterSpacing: 2)),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );

    final showApproval = approvalWatermark && status == 'approved' && approvedBy != null;
    final approvalLine = showApproval
        ? 'APPROVED BY ${approvedBy!.toUpperCase()}'
        : '';
    final approvalWhen =
        showApproval && approvedAt != null ? dtFmt.format(approvedAt.toLocal()) : '';
    pw.Widget approvalMarks() => pw.FullPage(
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
                              if ((approvalMarkSignature ?? approvedSignature) != null)
                                pw.Image((approvalMarkSignature ?? approvedSignature)!,
                                    height: 22, width: 70, fit: pw.BoxFit.contain),
                              pw.Text(approvalLine,
                                  style: pw.TextStyle(
                                      fontSize: 8, fontWeight: pw.FontWeight.bold, color: _brand)),
                              if (approvalWhen.isNotEmpty)
                                pw.Text(approvalWhen,
                                    style: const pw.TextStyle(fontSize: 7, color: _brand)),
                            ]),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 30),
        theme: theme,
        buildForeground: isVoid
            ? (_) => voidStamps()
            : showApproval
                ? (_) => approvalMarks()
                : null,
      ),
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
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('Payment Advice',
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold, color: _ink)),
              if (accountsCopy)
                pw.Text('ACCOUNTS COPY',
                    style: pw.TextStyle(
                        fontSize: 8.5,
                        letterSpacing: 1.5,
                        fontWeight: pw.FontWeight.bold,
                        color: _muted)),
            ]),
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
                    color: isVoid
                        ? const PdfColor.fromInt(0xFFFEE2E2)
                        : status == 'approved'
                            ? const PdfColor.fromInt(0xFFDCFCE7)
                            : const PdfColor.fromInt(0xFFFEF3C7),
                    borderRadius: pw.BorderRadius.circular(4)),
                child: pw.Text(isVoid ? 'VOIDED' : status.toUpperCase(),
                    style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        letterSpacing: 1,
                        color: isVoid
                            ? const PdfColor.fromInt(0xFF991B1B)
                            : status == 'approved'
                                ? const PdfColor.fromInt(0xFF166534)
                                : const PdfColor.fromInt(0xFF92400E))),
              ),
            ]),
        pw.SizedBox(height: 14),
        pw.Table(
          border: const pw.TableBorder(
              top: pw.BorderSide(color: _rule, width: 0.6),
              bottom: pw.BorderSide(color: _rule, width: 0.6)),
          columnWidths: accountsCopy
              ? {
                  0: const pw.FixedColumnWidth(22),
                  1: const pw.FlexColumnWidth(2.3),
                  2: const pw.FlexColumnWidth(3.4),
                  3: const pw.FlexColumnWidth(1.1),
                  4: const pw.FlexColumnWidth(1.4),
                }
              : {
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
        if (isVoid) ...[
          pw.SizedBox(height: 12),
          pw.Text(
              'VOIDED${voidedBy != null && voidedBy.isNotEmpty ? ' by $voidedBy' : ''}'
              '${voidedAt != null ? ' on ${dtFmt.format(voidedAt.toLocal())}' : ''}'
              '${voidReason != null && voidReason.trim().isNotEmpty ? ' - Reason: ${voidReason.trim()}' : ''}',
              style: pw.TextStyle(
                  fontSize: 9.5,
                  fontWeight: pw.FontWeight.bold,
                  color: const PdfColor.fromInt(0xFF991B1B))),
        ],
        pw.SizedBox(height: 28),
        pw.Row(children: [
          foot('CREATED BY', createdBy,
              createdAt == null ? '-' : dtFmt.format(createdAt.toLocal()),
              sig: createdSignature),
          foot(
              'APPROVED BY',
              approvedBy ?? '-',
              approvedAt == null
                  ? (status == 'pending' ? 'Awaiting approval' : '-')
                  : dtFmt.format(approvedAt.toLocal()),
              sig: status == 'pending' ? null : approvedSignature,
              stamp: status == 'pending' ? null : approvedStamp),
          foot('RECEIVED BY', '', ''),
        ]),
        pw.SizedBox(height: 22),
        // Authenticity note with a verified (tick-in-circle) mark.
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.SvgImage(
            width: 18,
            height: 18,
            svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
                '<circle cx="12" cy="12" r="10.5" fill="#16A34A"/>'
                '<path d="M7 12.5l3.2 3.2L17.2 8.8" fill="none" stroke="#FFFFFF" '
                'stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
          ),
          pw.SizedBox(width: 8),
          pw.Expanded(
            child: pw.Text(
              'System-generated document; no physical signature required. '
              'Authenticity is confirmed when the approval signatures match the watermarks, '
              'including date and time.',
              style: const pw.TextStyle(fontSize: 8.5, color: _muted),
            ),
          ),
        ]),
      ],
    ));
    return doc.save();
  }
}
