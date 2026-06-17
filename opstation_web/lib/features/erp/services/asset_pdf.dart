import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Printable asset datasheet — spec, placement, custody history and the
/// maintenance log for a single asset. Styled to match VoucherPdf.
class AssetPdf {
  static const _accent = PdfColor.fromInt(0xFF2563EB);
  static const _muted = PdfColor.fromInt(0xFF64748B);
  static const _border = PdfColor.fromInt(0xFFE2E8F0);
  static const _bg = PdfColor.fromInt(0xFFF8FAFC);
  static const _danger = PdfColor.fromInt(0xFFDC2626);

  static Future<void> printSheet({
    required String orgName,
    required String code,
    required String name,
    String? status,
    String? condition,
    String? category,
    String? branch,
    String? location,
    String? custodian,
    String? serial,
    String? model,
    String? manufacturer,
    String? supplier,
    String? purchased,
    String? cost,
    String? warranty,
    String? description,
    String? notes,
    String? nextDue,
    bool nextDueOverdue = false,
    required List<Map<String, String>> history,
    required List<Map<String, String>> maintenance,
    String? generatedBy,
  }) async {
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                  style: pw.TextStyle(fontSize: 9, color: _muted)),
              pw.Text(
                  'Generated ${DateFormat('d MMM yyyy HH:mm').format(DateTime.now())}'
                  '${generatedBy != null ? ' · $generatedBy' : ''}',
                  style: pw.TextStyle(fontSize: 9, color: _muted)),
            ]),
      ),
      build: (ctx) => [
        // Header band
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
              color: _bg, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(orgName,
                            style: pw.TextStyle(
                                fontSize: 18,
                                fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 2),
                        pw.Text(name,
                            style: pw.TextStyle(fontSize: 12, color: _muted)),
                      ]),
                ),
                pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('ASSET',
                          style: pw.TextStyle(
                              fontSize: 11,
                              color: _muted,
                              fontWeight: pw.FontWeight.bold,
                              letterSpacing: 1.2)),
                      pw.SizedBox(height: 4),
                      pw.Text(code,
                          style: pw.TextStyle(
                              fontSize: 20,
                              fontWeight: pw.FontWeight.bold,
                              color: _accent)),
                      if (status != null) ...[
                        pw.SizedBox(height: 4),
                        pw.Text(status,
                            style: pw.TextStyle(fontSize: 10, color: _muted)),
                      ],
                    ]),
              ]),
        ),
        pw.SizedBox(height: 14),

        _block('Current placement', [
          _kv('Branch', branch),
          _kv('Location', location),
          _kv('Custodian', custodian),
          _kv('Condition', condition),
        ]),
        pw.SizedBox(height: 8),
        _block('Specification', [
          _kv('Category', category),
          _kv('Serial no.', serial),
          _kv('Model', model),
          _kv('Manufacturer', manufacturer),
          _kv('Supplier', supplier),
          _kv('Purchased', purchased),
          _kv('Purchase cost', cost),
          _kv('Warranty till', warranty),
        ]),

        if (nextDue != null) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
                color: nextDueOverdue
                    ? PdfColor.fromInt(0xFFFEE2E2)
                    : _bg,
                borderRadius: pw.BorderRadius.circular(6),
                border: pw.Border.all(
                    color: nextDueOverdue ? _danger : _border)),
            child: pw.Row(children: [
              pw.Text('NEXT MAINTENANCE DUE',
                  style: pw.TextStyle(
                      fontSize: 8,
                      color: nextDueOverdue ? _danger : _muted,
                      fontWeight: pw.FontWeight.bold,
                      letterSpacing: 0.8)),
              pw.SizedBox(width: 10),
              pw.Text(nextDue + (nextDueOverdue ? '  (overdue)' : ''),
                  style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: nextDueOverdue ? _danger : _accent)),
            ]),
          ),
        ],

        if ((description != null && description.isNotEmpty) ||
            (notes != null && notes.isNotEmpty)) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _border),
                borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (description != null && description.isNotEmpty)
                    pw.Text('Description: $description',
                        style: const pw.TextStyle(fontSize: 10)),
                  if (notes != null && notes.isNotEmpty) ...[
                    pw.SizedBox(height: 3),
                    pw.Text('Notes: $notes',
                        style: const pw.TextStyle(fontSize: 10)),
                  ],
                ]),
          ),
        ],

        pw.SizedBox(height: 14),
        pw.Text('Placement & custody history',
            style:
                pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        if (history.isEmpty)
          pw.Text('No movements logged.',
              style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          ...history.map((h) => pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 3),
                child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(h['text'] ?? '',
                          style: const pw.TextStyle(fontSize: 10)),
                      if ((h['when'] ?? '').isNotEmpty)
                        pw.Text(h['when']!,
                            style:
                                pw.TextStyle(fontSize: 8.5, color: _muted)),
                    ]),
              )),

        pw.SizedBox(height: 14),
        pw.Text('Maintenance log',
            style:
                pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 6),
        if (maintenance.isEmpty)
          pw.Text('No maintenance recorded.',
              style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          pw.Table(
            border: pw.TableBorder.all(color: _border, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(4),
              1: pw.FlexColumnWidth(3),
              2: pw.FlexColumnWidth(3),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: _bg),
                children: ['Detail', 'Date', 'Next due']
                    .map((h) => pw.Padding(
                          padding: const pw.EdgeInsets.symmetric(
                              horizontal: 6, vertical: 5),
                          child: pw.Text(h,
                              style: pw.TextStyle(
                                  fontSize: 9,
                                  fontWeight: pw.FontWeight.bold,
                                  color: _muted)),
                        ))
                    .toList(),
              ),
              ...maintenance.map((m) => pw.TableRow(children: [
                    _cell(m['text'] ?? ''),
                    _cell(m['date'] ?? ''),
                    _cell(m['next'] ?? ''),
                  ])),
            ],
          ),
      ],
    ));

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: '$code.pdf',
    );
  }

  static pw.Widget _cell(String s) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: pw.Text(s, style: const pw.TextStyle(fontSize: 9.5)),
      );

  static pw.Widget _block(String title, List<pw.Widget> cells) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _border),
          borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title.toUpperCase(),
                style: pw.TextStyle(
                    fontSize: 8,
                    color: _muted,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.8)),
            pw.SizedBox(height: 6),
            pw.Wrap(spacing: 24, runSpacing: 8, children: cells),
          ]),
    );
  }

  static pw.Widget _kv(String k, String? v) {
    return pw.SizedBox(
      width: 150,
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(k, style: pw.TextStyle(fontSize: 8, color: _muted)),
        pw.SizedBox(height: 2),
        pw.Text((v == null || v.isEmpty) ? '-' : v,
            style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
      ]),
    );
  }
}
