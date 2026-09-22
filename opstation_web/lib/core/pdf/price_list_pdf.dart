// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../share/share_file.dart';

/// One row of a party price list, pre-formatted by the caller.
class PriceListRow {
  final String product, sku, note, price;
  const PriceListRow(this.product, this.sku, this.note, this.price);
}

/// Everything needed to render a party (customer/supplier) price list. Both the
/// Share button and the Print / Save-as-PDF button build one of these and hand
/// it to the SAME generator, so the two outputs are byte-for-byte identical.
class PriceListDoc {
  final String docTitle;   // 'Customer Price List' / 'Supplier Price List'
  final String orgName;
  final String partyLabel; // 'Customer' / 'Supplier'
  final String partyName;
  final String priceLabel; // 'Suggested Price' / 'Purchase Price'
  final String genTime;
  final List<PriceListRow> rows;
  final String fileBase;

  const PriceListDoc({
    required this.docTitle,
    required this.orgName,
    required this.partyLabel,
    required this.partyName,
    required this.priceLabel,
    required this.genTime,
    required this.rows,
    required this.fileBase,
  });
}

Future<pw.ThemeData?> _loadTheme() async {
  try {
    final base = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    final fallback = <pw.Font>[];
    try {
      fallback.add(await PdfGoogleFonts.notoNaskhArabicRegular());
      fallback.add(await PdfGoogleFonts.notoNaskhArabicBold());
    } catch (_) {/* Arabic script fallback unavailable — Latin still works */}
    return pw.ThemeData.withFont(
        base: base, bold: bold, fontFallback: fallback.isEmpty ? null : fallback);
  } catch (_) {
    return null;
  }
}

/// Single source of truth for the price-list PDF's appearance.
Future<Uint8List> buildPriceListPdfBytes(PriceListDoc d) async {
  final theme = await _loadTheme();
  final doc = pw.Document(
      title: d.fileBase, creator: 'Opstation ERP', theme: theme);

  final hStyle = pw.TextStyle(
      fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700);
  pw.Widget hc(String t, {pw.TextAlign a = pw.TextAlign.left}) => pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(t, style: hStyle, textAlign: a));
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

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    build: (ctx) => [
      // ── Header ─────────────────────────────────────────────────────────
      pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              if (d.orgName.trim().isNotEmpty)
                pw.Text(d.orgName,
                    style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text(d.docTitle,
                  style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.grey700)),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text('${d.partyLabel}: ${d.partyName}',
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text('Generated: ${d.genTime}',
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
              pw.Text('${d.rows.length} product${d.rows.length == 1 ? '' : 's'}',
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
            ]),
          ]),
      pw.SizedBox(height: 10),
      pw.Divider(height: 1, color: PdfColors.grey400),
      pw.SizedBox(height: 6),

      // ── Table ──────────────────────────────────────────────────────────
      if (d.rows.isEmpty)
        pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 24),
            child: pw.Center(
                child: pw.Text('No prices recorded.',
                    style: const pw.TextStyle(color: PdfColors.grey600))))
      else
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(4),
            1: pw.FlexColumnWidth(2),
            2: pw.FlexColumnWidth(4),
            3: pw.FlexColumnWidth(2.2),
          },
          children: [
            pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                children: [
                  hc('Product'),
                  hc('SKU'),
                  hc('Note'),
                  hc(d.priceLabel, a: pw.TextAlign.right),
                ]),
            for (final r in d.rows)
              pw.TableRow(children: [
                c(r.product, bold: true),
                c(r.sku),
                c(r.note),
                c(r.price, a: pw.TextAlign.right, bold: true),
              ]),
          ],
        ),
    ],
    footer: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 8),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Opstation ERP',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500)),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500)),
      ]),
    ),
  ));

  return doc.save();
}

Future<void> sharePriceListPdf(PriceListDoc d) async {
  final bytes = await buildPriceListPdfBytes(d);
  await shareFileOnly(bytes, d.fileBase + '.pdf');
}

/// Print / Save-as-PDF. Uses the SAME bytes as [sharePriceListPdf].
Future<void> printPriceListPdf(PriceListDoc d) async {
  final bytes = await buildPriceListPdfBytes(d);
  final fileName = d.fileBase + '.pdf';
  final ua = html.window.navigator.userAgent.toLowerCase();
  final isMobile = ua.contains('android') ||
      ua.contains('iphone') ||
      ua.contains('ipad') ||
      ua.contains('mobile');
  if (isMobile) {
    await shareFileOnly(bytes, fileName);
  } else if (ua.contains('firefox')) {
    final blob = html.Blob([bytes], 'application/pdf');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none';
    html.document.body!.append(a);
    a.click();
    Future.delayed(const Duration(seconds: 5), () {
      a.remove();
      html.Url.revokeObjectUrl(url);
    });
  } else {
    await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => bytes, name: fileName);
  }
}
