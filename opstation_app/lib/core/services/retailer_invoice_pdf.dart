import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// One invoice line for the retailer-side PDF.
class RetailerPdfLine {
  final String product;
  final String? sku;
  final String? uom;
  final double qty;
  final double? unitPrice;
  final double? discountPct;
  final double? lineTotal;

  RetailerPdfLine({
    required this.product,
    this.sku,
    this.uom,
    required this.qty,
    this.unitPrice,
    this.discountPct,
    this.lineTotal,
  });
}

/// Native (on-device) invoice PDF for the retailer app.
///
/// Deliberately self-contained and mobile-safe — NO dart:html, no network image
/// fetch, no app_config reads. It mirrors the look of the staff/web voucher PDF
/// closely enough that a shopkeeper recognises it, but only needs the plain
/// invoice data the retailer_invoice_detail RPC already returns. Opening goes
/// through Printing.layoutPdf, which renders a full-screen preview the user can
/// view, save as PDF, or print/share.
class RetailerInvoicePdf {
  static const _accent = PdfColor.fromInt(0xFF2563EB);
  static const _muted = PdfColor.fromInt(0xFF64748B);
  static const _border = PdfColor.fromInt(0xFFE2E8F0);
  static const _bg = PdfColor.fromInt(0xFFF8FAFC);

  static final NumberFormat _num4 = NumberFormat('#,##0.####');
  static String _n(num? v) => _num4.format((v ?? 0).toDouble());

  static Future<void> open({
    required String voucherNumber,
    required String orgName,
    String? date,
    String? customerName,
    required List<RetailerPdfLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String typeLabel = 'Sales Invoice',
  }) async {
    final bytes = await _build(
      voucherNumber: voucherNumber,
      orgName: orgName,
      date: date,
      customerName: customerName,
      lines: lines,
      subtotal: subtotal,
      discountTotal: discountTotal,
      grandTotal: grandTotal,
      typeLabel: typeLabel,
    );
    final safeParty = (customerName ?? '').replaceAll(RegExp(r'[^A-Za-z0-9 _\-]'), '').trim();
    final base = [
      if (safeParty.isNotEmpty) safeParty,
      voucherNumber,
    ].join('_');
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => bytes,
      name: '${base.isEmpty ? voucherNumber : base}.pdf',
    );
  }

  static Future<Uint8List> _build({
    required String voucherNumber,
    required String orgName,
    String? date,
    String? customerName,
    required List<RetailerPdfLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    required String typeLabel,
  }) async {
    final doc = pw.Document(title: '${customerName ?? ''} $voucherNumber'.trim(), creator: 'Opstation');
    final hasMoney = lines.any((l) => l.unitPrice != null || l.lineTotal != null);
    final showTotals = subtotal != null || discountTotal != null || grandTotal != null;
    final showOrg = orgName.trim().isNotEmpty;

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(24, 20, 24, 20),
      ),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: pw.TextStyle(fontSize: 9, color: _muted)),
            pw.Text('Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}',
                style: pw.TextStyle(fontSize: 9, color: _muted)),
          ],
        ),
      ),
      build: (ctx) => [
        // Header band
        pw.Container(
          padding: const pw.EdgeInsets.all(11),
          decoration: pw.BoxDecoration(color: _bg, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                if (showOrg)
                  pw.Text(orgName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
              ]),
            ),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text(typeLabel.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: showOrg ? 11 : 26,
                      color: _muted,
                      fontWeight: pw.FontWeight.bold,
                      letterSpacing: 1.2)),
              pw.SizedBox(height: 4),
              pw.Text(voucherNumber,
                  style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _accent)),
            ]),
          ]),
        ),
        pw.SizedBox(height: 9),
        // Meta grid
        pw.Container(
          padding: const pw.EdgeInsets.all(9),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(children: [
            if (date != null && date.isNotEmpty) _metaCell('Date', date),
            if (customerName != null && customerName.isNotEmpty) _metaCell('Customer', customerName),
          ]),
        ),
        pw.SizedBox(height: 9),
        // Lines
        _itemsTable(lines, hasMoney),
        pw.SizedBox(height: 6),
        pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Total Quantity: ${_n(lines.fold<double>(0, (s, l) => s + l.qty))}',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ),
        if (showTotals) ...[
          pw.SizedBox(height: 12),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 220,
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(children: [
                if (subtotal != null) _totalRow('Subtotal', _n(subtotal)),
                if (discountTotal != null && discountTotal > 0)
                  _totalRow('Discount', '- ${_n(discountTotal)}', color: PdfColors.orange),
                if (grandTotal != null) ...[
                  pw.Divider(color: _border, height: 8),
                  _totalRow('Grand Total', _n(grandTotal), bold: true),
                ],
              ]),
            ),
          ),
        ],
      ],
    ));

    return doc.save();
  }

  static pw.Widget _metaCell(String label, String value) {
    return pw.Expanded(
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(label.toUpperCase(),
            style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
        pw.SizedBox(height: 3),
        pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
      ]),
    );
  }

  static pw.Widget _totalRow(String label, String value, {bool bold = false, PdfColor? color}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(label,
            style: pw.TextStyle(
                fontSize: bold ? 12 : 10,
                color: color ?? _muted,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        pw.Text(value,
            style: pw.TextStyle(
                fontSize: bold ? 14 : 11,
                color: color,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ]),
    );
  }

  static pw.Widget _itemsTable(List<RetailerPdfLine> lines, bool hasMoney) {
    final headers = hasMoney
        ? ['#', 'Product', 'UOM', 'Qty', 'Unit Price', 'Disc %', 'Line Total']
        : ['#', 'Product', 'UOM', 'Qty'];
    final flex = hasMoney ? [1, 5, 1, 2, 2, 2, 2] : [1, 8, 1, 2];

    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: {
        for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i].toDouble()),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: headers
              .map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _muted)),
                  ))
              .toList(),
        ),
        ...lines.asMap().entries.map((entry) {
          final i = entry.key;
          final l = entry.value;
          final cells = hasMoney
              ? [
                  '${i + 1}',
                  l.product + (l.sku != null && l.sku!.isNotEmpty ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  _n(l.qty),
                  l.unitPrice != null ? _n(l.unitPrice) : '-',
                  l.discountPct != null && l.discountPct! > 0 ? '${_n(l.discountPct)}%' : '-',
                  l.lineTotal != null ? _n(l.lineTotal) : '-',
                ]
              : [
                  '${i + 1}',
                  l.product + (l.sku != null && l.sku!.isNotEmpty ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  _n(l.qty),
                ];
          return pw.TableRow(
            children: cells
                .map((c) => pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: pw.Text(c, style: const pw.TextStyle(fontSize: 10)),
                    ))
                .toList(),
          );
        }),
      ],
    );
  }
}
