import 'dart:typed_data';
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

  static Future<void> printVoucher({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? footerNote,
    Map<String, String>? relatedRefs, // e.g. {'SO #': 'SO-2026-0001', 'DO #': 'DO-...'}
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
  }) async {
    final doc = await _buildDoc(
      voucherNumber: voucherNumber, voucherTypeLabel: voucherTypeLabel,
      orgName: orgName, branchName: branchName, date: date,
      customerOrSupplier: customerOrSupplier,
      customerAddress: customerAddress, customerContact: customerContact, customerPhone: customerPhone,
      salespersonName: salespersonName,
      status: status, remarks: remarks, lines: lines,
      subtotal: subtotal, discountTotal: discountTotal, grandTotal: grandTotal,
      preparedBy: preparedBy, createdAt: createdAt,
      footerNote: footerNote, relatedRefs: relatedRefs,
      watermark: watermark,
    );
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: '$voucherNumber.pdf',
    );
  }

  static Future<Uint8List> generateBytes({
    required String voucherNumber,
    required String voucherTypeLabel,
    required String orgName,
    String? branchName,
    String? date,
    String? customerOrSupplier,
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? footerNote,
    Map<String, String>? relatedRefs,
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
  }) async {
    final doc = await _buildDoc(
      voucherNumber: voucherNumber, voucherTypeLabel: voucherTypeLabel,
      orgName: orgName, branchName: branchName, date: date,
      customerOrSupplier: customerOrSupplier,
      customerAddress: customerAddress, customerContact: customerContact, customerPhone: customerPhone,
      salespersonName: salespersonName,
      status: status, remarks: remarks, lines: lines,
      subtotal: subtotal, discountTotal: discountTotal, grandTotal: grandTotal,
      preparedBy: preparedBy, createdAt: createdAt,
      footerNote: footerNote, relatedRefs: relatedRefs,
      watermark: watermark,
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
    String? customerAddress,
    String? customerContact,
    String? customerPhone,
    String? salespersonName,
    String? status,
    String? remarks,
    required List<VoucherLine> lines,
    double? subtotal,
    double? discountTotal,
    double? grandTotal,
    String? preparedBy,
    String? createdAt,
    String? footerNote,
    Map<String, String>? relatedRefs,
    String? watermark, // optional diagonal page watermark, e.g. 'VOIDED'
  }) async {
    final doc = pw.Document();
    final showTotals = subtotal != null || discountTotal != null || grandTotal != null;
    final hasMoney = lines.any((l) => l.unitPrice != null || l.lineTotal != null);
    final isPurchase = voucherTypeLabel.toLowerCase().contains('purchase') || voucherTypeLabel.toLowerCase().contains('grn');

    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        buildBackground: (watermark == null || watermark.isEmpty)
            ? null
            : (ctx) => pw.FullPage(
                  ignoreMargins: true,
                  child: pw.Center(
                    child: pw.Transform.rotate(
                      angle: 0.6,
                      child: pw.Opacity(
                        opacity: 0.12,
                        child: pw.Column(
                          mainAxisSize: pw.MainAxisSize.min,
                          children: [
                            pw.Text(
                              watermark,
                              style: pw.TextStyle(
                                fontSize: 130,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.red,
                              ),
                            ),
                            pw.Text(
                              'This document is no longer valid',
                              style: pw.TextStyle(
                                fontSize: 22,
                                fontWeight: pw.FontWeight.bold,
                                color: PdfColors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
      ),
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
          decoration: pw.BoxDecoration(color: _bg, borderRadius: pw.BorderRadius.circular(8)),
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

        pw.SizedBox(height: 14),

        // ── Meta grid ──────────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Row(children: [
            if (date != null) _metaCell('Date', date),
            if (customerOrSupplier != null)
              _metaCell(isPurchase ? 'Supplier' : 'Customer', customerOrSupplier),
            if (branchName != null) _metaCell('Branch', branchName),
            if (salespersonName != null) _metaCell('Salesperson', salespersonName),
          ]),
        ),

        // ── Related references (SO # in DO, SO+DO in SI) ────────────────
        if (relatedRefs != null && relatedRefs.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Row(children: [
              for (final e in relatedRefs.entries) _metaCell(e.key, e.value),
            ]),
          ),
        ],

        // ── Customer details (address / contact / phone) ────────────────
        if (customerAddress != null || customerContact != null || customerPhone != null) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(isPurchase ? 'SUPPLIER DETAILS' : 'BILL TO',
                  style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
              pw.SizedBox(height: 4),
              if (customerAddress != null && customerAddress.isNotEmpty)
                pw.Text(customerAddress, style: pw.TextStyle(fontSize: 11)),
              if ((customerContact != null && customerContact.isNotEmpty) ||
                  (customerPhone != null && customerPhone.isNotEmpty)) ...[
                pw.SizedBox(height: 3),
                pw.Row(children: [
                  if (customerContact != null && customerContact.isNotEmpty)
                    pw.Text('Attn: $customerContact', style: pw.TextStyle(fontSize: 10, color: _muted)),
                  if (customerContact != null && customerContact.isNotEmpty &&
                      customerPhone != null && customerPhone.isNotEmpty)
                    pw.Text('  ·  ', style: pw.TextStyle(fontSize: 10, color: _muted)),
                  if (customerPhone != null && customerPhone.isNotEmpty)
                    pw.Text('Ph: $customerPhone', style: pw.TextStyle(fontSize: 10, color: _muted)),
                ]),
              ],
            ]),
          ),
        ],

        if (remarks != null && remarks.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _border), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('REMARKS', style: pw.TextStyle(fontSize: 8, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.8)),
              pw.SizedBox(height: 4),
              pw.Text(remarks, style: pw.TextStyle(fontSize: 11)),
            ]),
          ),
        ],

        pw.SizedBox(height: 14),

        // ── Line items ─────────────────────────────────────────────────
        _itemsTable(lines, hasMoney),

        // ── Totals ─────────────────────────────────────────────────────
        if (showTotals) ...[
          pw.SizedBox(height: 12),
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

        // ── Signature blocks ───────────────────────────────────────────
        pw.SizedBox(height: 36),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _signatureBlock('Prepared By', preparedBy),
          _signatureBlock('Checked By', null),
          _signatureBlock('Approved By', null),
        ]),

        // ── Footer note + audit ─────────────────────────────────────────
        if (footerNote != null && footerNote.isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _border))),
            child: pw.Text(footerNote, style: pw.TextStyle(fontSize: 9, color: _muted, fontStyle: pw.FontStyle.italic)),
          ),
        ],
        if (createdAt != null) ...[
          pw.SizedBox(height: 6),
          pw.Text(
            'Created ${preparedBy != null ? "by $preparedBy " : ""}on $createdAt',
            style: pw.TextStyle(fontSize: 8, color: _muted),
          ),
        ],
      ],
    ));

    return doc;
  }

  static pw.Widget _signatureBlock(String label, String? name) {
    return pw.Expanded(
      child: pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Container(
            width: double.infinity,
            decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _muted))),
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Column(children: [
              pw.Text(label,
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
              pw.SizedBox(height: 4),
              pw.Text(name ?? ' ', style: pw.TextStyle(fontSize: 11, color: _muted)),
            ]),
          ),
        ]),
      ),
    );
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
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: headers.map((h) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: pw.Text(h, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _muted)),
          )).toList(),
        ),
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
