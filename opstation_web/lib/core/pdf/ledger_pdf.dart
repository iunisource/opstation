import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One posted ledger line, pre-formatted by the caller (so this builder stays
/// decoupled from the app's money/date formatting).
class LedgerLine {
  final String date, voucher, description, type, debit, credit, balance;
  const LedgerLine(this.date, this.voucher, this.description, this.type,
      this.debit, this.credit, this.balance);
}

/// A pending-cheque (PDC) memo line, customer ledger only.
class LedgerPdc {
  final String voucher, chequeDate, details, amount;
  const LedgerPdc(this.voucher, this.chequeDate, this.details, this.amount);
}

/// Build the ledger PDF and hand it to the device's native share sheet
/// (WhatsApp, email, files, …). On mobile web this uses navigator.share with the
/// actual PDF file; where that's unavailable it falls back to a download.
Future<void> shareLedgerPdf({
  required String docTitle, // 'Customer Ledger' / 'Supplier Ledger'
  required String orgName,
  required String partyName,
  required String partyCode,
  required String branchName,
  required String period,
  required String genTime,
  required List<LedgerLine> lines,
  required String totalDebit,
  required String totalCredit,
  required String netBalanceLabel, // e.g. 'Receivable: Rs. 12,000'
  required bool netIsDanger, // red when they owe (receivable) / we owe (payable)
  required String fileBase,
  List<LedgerPdc> pdc = const [],
  String? pdcTotal,
}) async {
  final doc = pw.Document();
  final hStyle = pw.TextStyle(
      fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700);
  pw.Widget hc(String t, {pw.TextAlign a = pw.TextAlign.left}) =>
      pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(t, style: hStyle, textAlign: a));
  pw.Widget c(String t,
          {pw.TextAlign a = pw.TextAlign.left, bool bold = false, PdfColor? color}) =>
      pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Text(t,
              textAlign: a,
              style: pw.TextStyle(
                  fontSize: 8.5,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                  color: color)));

  final netColor = netIsDanger ? PdfColors.red800 : PdfColors.green800;

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (ctx) => [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(orgName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text(docTitle, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(partyName + (partyCode.isNotEmpty ? '  ($partyCode)' : ''),
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text(branchName, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          if (period.isNotEmpty) pw.Text(period, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          pw.Text('Generated: ' + genTime, style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey)),
        ]),
      ]),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        columnWidths: const {
          0: pw.FixedColumnWidth(46),
          1: pw.FixedColumnWidth(66),
          2: pw.FlexColumnWidth(3),
          3: pw.FixedColumnWidth(52),
          4: pw.FixedColumnWidth(58),
          5: pw.FixedColumnWidth(58),
          6: pw.FixedColumnWidth(64),
        },
        children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
            hc('Date'), hc('Voucher'), hc('Description'), hc('Type'),
            hc('Debit', a: pw.TextAlign.right), hc('Credit', a: pw.TextAlign.right), hc('Balance', a: pw.TextAlign.right),
          ]),
          for (final l in lines)
            pw.TableRow(children: [
              c(l.date), c(l.voucher), c(l.description), c(l.type),
              c(l.debit, a: pw.TextAlign.right), c(l.credit, a: pw.TextAlign.right),
              c(l.balance, a: pw.TextAlign.right, bold: true),
            ]),
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey100), children: [
            c(''), c(''), c(''), c('Total', bold: true),
            c(totalDebit, a: pw.TextAlign.right, bold: true),
            c(totalCredit, a: pw.TextAlign.right, bold: true), c(''),
          ]),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: pw.BoxDecoration(color: PdfColors.grey100, borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Text(netBalanceLabel,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: netColor)),
        ),
      ]),
      if (pdc.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        pw.Text('Pending Cheques (PDC) — memo only, not included in the balance',
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.orange800)),
        pw.SizedBox(height: 4),
        pw.Table(border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5), children: [
          pw.TableRow(decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
            hc('Voucher'), hc('Cheque Date'), hc('Details'), hc('Amount', a: pw.TextAlign.right),
          ]),
          for (final p in pdc)
            pw.TableRow(children: [
              c(p.voucher), c(p.chequeDate), c(p.details), c(p.amount, a: pw.TextAlign.right),
            ]),
        ]),
        if (pdcTotal != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
              pw.Text('PDC Total: ' + pdcTotal, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ]),
          ),
      ],
    ],
  ));

  final bytes = await doc.save();
  await Printing.sharePdf(bytes: bytes, filename: fileBase + '.pdf');
}
