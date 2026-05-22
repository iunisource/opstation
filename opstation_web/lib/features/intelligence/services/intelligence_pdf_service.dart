import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// PDF generation for Intelligence reports — Placement Audit (matrix of
/// shops x products with green/red dots) and Competitor Spotting (matrix
/// of shops x categories with brand names, plus a detail appendix listing
/// each entry's price and specs).
class IntelligencePdfService {
  static Future<Uint8List> generatePlacementAuditPdf({
    required String orgName,
    required List<Map<String, dynamic>> customers,
    required List<Map<String, dynamic>> products,
    required Map<String, Map<String, Map<String, dynamic>>> latest,
  }) async {
    final pdf = pw.Document();
    final dateStr = _today();
    final theme = await _loadTheme();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        theme: theme,
        header: (ctx) => _header(orgName, 'Placement Audit', dateStr),
        footer: (ctx) => _footer(ctx),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Text(
            '${customers.length} shops audited x ${products.length} products. '
            'Green = displayed, red = not displayed, dash = not surveyed.',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 12),
          _placementMatrix(customers, products, latest),
        ],
      ),
    );
    return pdf.save();
  }

  static Future<Uint8List> generateCompetitorSpottingPdf({
    required String orgName,
    required List<Map<String, dynamic>> customers,
    required List<Map<String, dynamic>> categories,
    required Map<String, Map<String, Map<String, dynamic>>> latest,
  }) async {
    final pdf = pw.Document();
    final dateStr = _today();
    final theme = await _loadTheme();

    // Flatten into detail rows for the appendix table
    final details = <Map<String, dynamic>>[];
    for (final cid in latest.keys) {
      final customer = customers.firstWhere(
        (c) => c['id'] == cid,
        orElse: () => <String, dynamic>{},
      );
      if (customer.isEmpty) continue;
      for (final catId in latest[cid]!.keys) {
        final cat = categories.firstWhere(
          (c) => c['id'] == catId,
          orElse: () => <String, dynamic>{},
        );
        if (cat.isEmpty) continue;
        final spotting = latest[cid]![catId]!;
        details.add({
          'shop': customer['shop_name'],
          'category': cat['name'],
          'brand': spotting['brand_name'],
          'price': spotting['price'],
          'specs': spotting['specs'],
        });
      }
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        theme: theme,
        header: (ctx) => _header(orgName, 'Competitor Spotting', dateStr),
        footer: (ctx) => _footer(ctx),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Text(
            '${customers.length} shops x ${categories.length} categories. '
            'Each cell shows the latest known competitor brand.',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 16),
          if (details.isNotEmpty) ...[
            pw.Text(
              'Brand spottings by shop',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            _competitorDetails(details),
          ] else
            pw.Text('No competitor spottings recorded.',
                style: const pw.TextStyle(color: PdfColors.grey600)),
        ],
      ),
    );
    return pdf.save();
  }

  // ----- helpers -----

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  // Load Noto Sans so we can render ✓ / ✗ in PDF cells. Default PDF
  // Helvetica is WinAnsi-encoded and lacks those glyphs.
  static Future<pw.ThemeData?> _loadTheme() async {
    try {
      final font = await PdfGoogleFonts.notoSansRegular();
      final fontBold = await PdfGoogleFonts.notoSansBold();
      List<pw.Font>? fallback;
      try {
        // Noto Sans Symbols 2 has the U+2713 (✓) and U+2717 (✗)
        // codepoints that base Noto Sans is missing.
        final symbols = await PdfGoogleFonts.notoSansSymbols2Regular();
        fallback = [symbols];
      } catch (_) {
        // symbols font failed to load — body text still works
      }
      return pw.ThemeData.withFont(base: font, bold: fontBold, fontFallback: fallback);
    } catch (e) {
      print('PDF font load failed, using default: $e');
      return null;
    }
  }

  static pw.Widget _header(String orgName, String title, String dateStr) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(orgName, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text(title, style: const pw.TextStyle(fontSize: 18, color: PdfColors.grey800)),
            ],
          ),
          pw.Text(dateStr, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
        ],
      ),
    );
  }

  static pw.Widget _footer(pw.Context ctx) {
    return pw.Container(
      alignment: pw.Alignment.centerRight,
      padding: const pw.EdgeInsets.only(top: 8),
      child: pw.Text(
        'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ),
    );
  }

  static pw.Widget _placementMatrix(
    List<Map<String, dynamic>> customers,
    List<Map<String, dynamic>> products,
    Map<String, Map<String, Map<String, dynamic>>> latest,
  ) {
    if (customers.isEmpty || products.isEmpty) {
      return pw.Text('No data', style: const pw.TextStyle(color: PdfColors.grey600));
    }
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: {
        0: const pw.FixedColumnWidth(140),
        for (int i = 1; i <= products.length; i++) i: const pw.FixedColumnWidth(50),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _padCell(
              pw.Text('Shop', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ),
            ...products.map((p) => _padCell(
              pw.Text(p['name'] as String,
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center,
              ),
            )),
          ],
        ),
        ...customers.map((c) {
          final cid = c['id'] as String;
          return pw.TableRow(children: [
            _padCell(pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(c['shop_name'] as String, style: const pw.TextStyle(fontSize: 9)),
                pw.Text(c['code'] as String? ?? '',
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
              ],
            )),
            ...products.map((p) {
              final pid = p['id'] as String;
              final audit = latest[cid]?[pid];
              if (audit == null) {
                return _padCell(pw.Center(child: pw.Text('-',
                  style: const pw.TextStyle(color: PdfColors.grey500, fontSize: 10))));
              }
              final isPresent = audit['is_present'] as bool;
              return _padCell(pw.Center(
                child: pw.Text(
                  isPresent ? '✓' : '✗',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: isPresent ? PdfColors.green600 : PdfColors.red600,
                  ),
                ),
              ));
            }),
          ]);
        }),
      ],
    );
  }

  static pw.Widget _competitorMatrix(
    List<Map<String, dynamic>> customers,
    List<Map<String, dynamic>> categories,
    Map<String, Map<String, Map<String, dynamic>>> latest,
  ) {
    if (customers.isEmpty || categories.isEmpty) {
      return pw.Text('No data', style: const pw.TextStyle(color: PdfColors.grey600));
    }
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: {
        0: const pw.FixedColumnWidth(140),
        for (int i = 1; i <= categories.length; i++) i: const pw.FixedColumnWidth(80),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _padCell(pw.Text('Shop',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
            ...categories.map((cat) => _padCell(
              pw.Text(cat['name'] as String,
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center,
              ),
            )),
          ],
        ),
        ...customers.map((c) {
          final cid = c['id'] as String;
          return pw.TableRow(children: [
            _padCell(pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(c['shop_name'] as String, style: const pw.TextStyle(fontSize: 9)),
                pw.Text(c['code'] as String? ?? '',
                  style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
              ],
            )),
            ...categories.map((cat) {
              final catId = cat['id'] as String;
              final spotting = latest[cid]?[catId];
              if (spotting == null) {
                return _padCell(pw.Center(child: pw.Text('-',
                  style: const pw.TextStyle(color: PdfColors.grey500, fontSize: 10))));
              }
              return _padCell(pw.Center(child: pw.Text(
                spotting['brand_name'] as String? ?? '',
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                textAlign: pw.TextAlign.center,
              )));
            }),
          ]);
        }),
      ],
    );
  }

  static pw.Widget _competitorDetails(List<Map<String, dynamic>> details) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(2),
        1: pw.FlexColumnWidth(1.5),
        2: pw.FlexColumnWidth(1.5),
        3: pw.FlexColumnWidth(1),
        4: pw.FlexColumnWidth(2),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _detailHeader('Shop'),
            _detailHeader('Category'),
            _detailHeader('Brand'),
            _detailHeader('Price'),
            _detailHeader('Specs'),
          ],
        ),
        ...details.map((d) => pw.TableRow(children: [
          _detailCell(d['shop'] as String? ?? ''),
          _detailCell(d['category'] as String? ?? ''),
          _detailCell(d['brand'] as String? ?? ''),
          _detailCell(d['price'] == null ? '-' : 'PKR ${d['price']}'),
          _detailCell(d['specs'] as String? ?? ''),
        ])),
      ],
    );
  }

  static pw.Widget _padCell(pw.Widget child) =>
      pw.Padding(padding: const pw.EdgeInsets.all(6), child: child);

  static pw.Widget _detailHeader(String text) => _padCell(
    pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
  );

  static pw.Widget _detailCell(String text) => _padCell(
    pw.Text(text, style: const pw.TextStyle(fontSize: 8)),
  );
}
