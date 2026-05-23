import 'dart:typed_data';
// 
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Shared PDF generator for ERP vouchers (SO, DO, SI, PO, GRN, PI, etc.)
class VoucherPdf {
  static const _accent = PdfColor.fromInt(0xFF2563EB);
  static const _muted = PdfColor.fromInt(0xFF64748B);
  static const _border = PdfColor.fromInt(0xFFE2E8F0);
  static const _bg = PdfColor.fromInt(0xFFF8FAFC);

  /// Show the system print dialog with the generated PDF.
  static Future<void> printVoucher({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? createdBy,
    String? createdAt,
  }) async {
    final doc = await _buildDoc(
      voucherNumber: voucherNumber,
      voucherTypeLabel: voucherTypeLabel,
      orgName: orgName,
      branchName: branchName,
      date: date,
      customerOrSupplier: customerOrSupplier,
      status: status,
      remarks: remarks,
      lines: lines,
      subtotal: subtotal,
      discountTotal: discountTotal,
      grandTotal: grandTotal,
      createdBy: createdBy,
      createdAt: createdAt,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: '$voucherNumber.pdf',
    );
  }

  /// Save / share the PDF (download in web).
  static Future<Uint8List> generateBytes({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? createdBy,
    String? createdAt,
  }) async {
    final doc = await _buildDoc(
      voucherNumber: voucherNumber,
      voucherTypeLabel: voucherTypeLabel,
      orgName: orgName,
      branchName: branchName,
      date: date,
      customerOrSupplier: customerOrSupplier,
      status: status,
      remarks: remarks,
      lines: lines,
      subtotal: subtotal,
      discountTotal: discountTotal,
      grandTotal: grandTotal,
      createdBy: createdBy,
      createdAt: createdAt,
    );
    return doc.save();
  }

  static Future<pw.Document> _buildDoc({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? createdBy,
    String? createdAt,
  }) async {
    final doc = pw.Document();
    final showTotals = subtotal != null || discountTotal != null || grandTotal != null;
    final hasMoney = lines.any((l) => l.unitPrice != null || l.lineTotal != null);

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox.shrink()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                pw.Text(orgName, style: pw.TextStyle(fontSize: 9, color: _muted)),
                pw.Text('$voucherTypeLabel  $voucherNumber',
                    style: pw.TextStyle(fontSize: 9, color: _muted, fontWeight: pw.FontWeight.bold)),
              ]),
            ),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: pw.TextStyle(fontSize: 9, color: _muted)),
          pw.Text('Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}',
              style: pw.TextStyle(fontSize: 9, color: _muted)),
        ]),
      ),
      build: (ctx) => [
        // ── Header band ────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
            color: _bg,
            borderRadius: pw.BorderRadius.circular(8),
          ),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(orgName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                if (branchName != null) ...[
                  pw.SizedBox(height: 2),
                  pw.Text(branchName, style: pw.TextStyle(fontSize: 11, color: _muted)),
                ],
              ]),
            ),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              pw.Text(voucherTypeLabel.toUpperCase(),
                  style: pw.TextStyle(fontSize: 11, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 1.2)),
              pw.SizedBox(height: 4),
              pw.Text(voucherNumber, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _accent)),
              if (status != null) ...[
                pw.SizedBox(height: 4),
                pw.Text(status, style: pw.TextStyle(fontSize: 10, color: _muted)),
              ],
            ]),
          ]),
        ),

        pw.SizedBox(height: 16),

        // ── Meta grid ──────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(children: [
            if (date != null) _metaCell('Date', date),
            if (customerOrSupplier != null)
              _metaCell(voucherTypeLabel.toLowerCase().contains('purchase') || voucherTypeLabel.toLowerCase().contains('grn')
                  ? 'Supplier' : 'Customer', customerOrSupplier),
            if (branchName != null) _metaCell('Branch', branchName),
          ]),
        ),

        if (remarks != null && remarks.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Remarks', style: pw.TextStyle(fontSize: 9, color: _muted, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text(remarks, style: pw.TextStyle(fontSize: 11)),
            ]),
          ),
        ],

        pw.SizedBox(height: 16),

        // ── Line items ─────────────────────────────────────────────────
        _itemsTable(lines, hasMoney),

        // ── Totals ─────────────────────────────────────────────────────
        if (showTotals) ...[
          pw.SizedBox(height: 14),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 220,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
              child: pw.Column(children: [
                if (subtotal != null) _totalRow('Subtotal', subtotal.toStringAsFixed(2)),
                if (discountTotal != null && discountTotal > 0)
                  _totalRow('Discount', '- ${discountTotal.toStringAsFixed(2)}', color: PdfColors.orange),
                if (grandTotal != null) ...[
                  pw.Divider(color: _border, height: 8),
                  _totalRow('Grand Total', grandTotal.toStringAsFixed(2), bold: true),
                ],
              ]),
            ),
          ),
        ],

        if (createdBy != null || createdAt != null) ...[
          pw.SizedBox(height: 18),
          pw.Text(
            'Created by ${createdBy ?? '-'}${createdAt != null ? ' on $createdAt' : ''}',
            style: pw.TextStyle(fontSize: 9, color: _muted, fontStyle: pw.FontStyle.italic),
          ),
        ],
      ],
    ));

    return doc;
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
            style: pw.TextStyle(fontSize: bold ? 12 : 10, color: color ?? _muted,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        pw.Text(value,
            style: pw.TextStyle(fontSize: bold ? 14 : 11, color: color,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      ]),
    );
  }

  static pw.Widget _itemsTable(List<VoucherLine> lines, bool hasMoney) {
    final headers = hasMoney
        ? ['#', 'Product', 'UOM', 'Qty', 'Unit Price', 'Discount', 'Line Total']
        : ['#', 'Product', 'UOM', 'Qty'];
    final flex = hasMoney ? [1, 5, 1, 2, 2, 2, 2] : [1, 8, 1, 2];

    return pw.Table(
      border: pw.TableBorder.all(color: _border, width: 0.5),
      columnWidths: {
        for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i].toDouble()),
      },
      children: [
        // Header
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: headers.map((h) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _muted)),
          )).toList(),
        ),
        // Rows
        ...lines.asMap().entries.map((entry) {
          final i = entry.key; final l = entry.value;
          final cells = hasMoney
              ? [
                  '${i + 1}',
                  l.product + (l.sku != null ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  l.qty.toStringAsFixed(l.qty == l.qty.toInt() ? 0 : 2),
                  l.unitPrice?.toStringAsFixed(2) ?? '-',
                  l.discountPct != null ? '${l.discountPct!.toStringAsFixed(2)}%' : '-',
                  l.lineTotal?.toStringAsFixed(2) ?? '-',
                ]
              : [
                  '${i + 1}',
                  l.product + (l.sku != null ? '\n${l.sku}' : ''),
                  l.uom ?? '-',
                  l.qty.toStringAsFixed(l.qty == l.qty.toInt() ? 0 : 2),
                ];
          return pw.TableRow(
            children: cells.map((c) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: pw.Text(c, style: const pw.TextStyle(fontSize: 10)),
            )).toList(),
          );
        }),
      ],
    );
  }
}

class VoucherLine {
  final String product;
  final String? sku;
  final String? uom;
  final double qty;
  final double? unitPrice;
  final double? discountPct;
  final double? lineTotal;

  VoucherLine({
    required this.product,
    this.sku,
    this.uom,
    required this.qty,
    this.unitPrice,
    this.discountPct,
    this.lineTotal,
  });
}
