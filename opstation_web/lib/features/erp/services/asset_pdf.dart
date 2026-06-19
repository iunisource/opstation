import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Printable asset datasheet — spec, placement, custody history and the
/// maintenance log for a single asset. Styled to match VoucherPdf.
class AssetPdf {
  static const _accent = PdfColor.fromInt(0xFF2563EB);
  static const _accentSoft = PdfColor.fromInt(0xFFBFDBFE);
  static const _ink = PdfColor.fromInt(0xFF0F172A);
  static const _muted = PdfColor.fromInt(0xFF64748B);
  static const _border = PdfColor.fromInt(0xFFE2E8F0);
  static const _bg = PdfColor.fromInt(0xFFF8FAFC);
  static const _danger = PdfColor.fromInt(0xFFDC2626);
  static const _dangerBg = PdfColor.fromInt(0xFFFEE2E2);
  static const _warn = PdfColor.fromInt(0xFFB45309);
  static const _warnBg = PdfColor.fromInt(0xFFFEF3C7);

  static Future<void> printSheet({
    required String orgName,
    required String code,
    required String name,
    Uint8List? imageBytes,
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
    bool nextDueSoon = false,
    String? qrData,
    required List<Map<String, String>> history,
    required List<Map<String, String>> maintenance,
    String? generatedBy,
  }) async {
    final doc = pw.Document();

    final placementCard = _block('Current placement', accent: true, cells: [
      _kv('Branch', branch),
      _kv('Location', location),
      _kv('Custodian', custodian),
      _kv('Condition', condition),
    ]);

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
        // ── Header band ──────────────────────────────────────────────
        pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(
            color: _bg,
            borderRadius: pw.BorderRadius.circular(8),
            border: pw.Border(left: pw.BorderSide(color: _accent, width: 3)),
          ),
          child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(_s(orgName),
                            style: pw.TextStyle(
                                fontSize: 18,
                                color: _ink,
                                fontWeight: pw.FontWeight.bold)),
                        pw.SizedBox(height: 3),
                        pw.Text(_s(name),
                            style: pw.TextStyle(fontSize: 12, color: _muted)),
                      ]),
                ),
                pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('ASSET',
                          style: pw.TextStyle(
                              fontSize: 10,
                              color: _muted,
                              fontWeight: pw.FontWeight.bold,
                              letterSpacing: 1.4)),
                      pw.SizedBox(height: 3),
                      pw.Text(_s(code),
                          style: pw.TextStyle(
                              fontSize: 20,
                              fontWeight: pw.FontWeight.bold,
                              color: _accent)),
                      if (status != null && status.isNotEmpty) ...[
                        pw.SizedBox(height: 6),
                        _statusPill(status),
                      ],
                      if (qrData != null && qrData.isNotEmpty) ...[
                        pw.SizedBox(height: 10),
                        _qr(qrData, 60),
                      ],
                    ]),
              ]),
        ),
        pw.SizedBox(height: 14),

        // ── Photo + current placement side by side ───────────────────
        if (imageBytes != null)
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Container(
              width: 150,
              padding: const pw.EdgeInsets.all(5),
              decoration: pw.BoxDecoration(
                  color: PdfColors.white,
                  border: pw.Border.all(color: _border),
                  borderRadius: pw.BorderRadius.circular(8)),
              child: pw.Image(pw.MemoryImage(imageBytes),
                  height: 132, fit: pw.BoxFit.contain),
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(child: placementCard),
          ])
        else
          placementCard,

        pw.SizedBox(height: 10),
        _block('Specification', cells: [
          _kv('Category', category),
          _kv('Serial no.', serial),
          _kv('Model', model),
          _kv('Manufacturer', manufacturer),
          _kv('Supplier', supplier),
          _kv('Purchased', purchased),
          _kv('Purchase cost', cost),
          _kv('Warranty till', warranty),
        ]),

        // ── Next maintenance banner ──────────────────────────────────
        if (nextDue != null && nextDue.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          _dueBanner(nextDue, nextDueOverdue, nextDueSoon),
        ],

        // ── Description / notes ──────────────────────────────────────
        if ((description != null && description.isNotEmpty) ||
            (notes != null && notes.isNotEmpty)) ...[
          pw.SizedBox(height: 10),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
                color: _bg, borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (description != null && description.isNotEmpty) ...[
                    _miniLabel('Description'),
                    pw.SizedBox(height: 2),
                    pw.Text(_s(description),
                        style: pw.TextStyle(fontSize: 10, color: _ink)),
                  ],
                  if (notes != null && notes.isNotEmpty) ...[
                    if (description != null && description.isNotEmpty)
                      pw.SizedBox(height: 8),
                    _miniLabel('Notes'),
                    pw.SizedBox(height: 2),
                    pw.Text(_s(notes),
                        style: pw.TextStyle(fontSize: 10, color: _ink)),
                  ],
                ]),
          ),
        ],

        // ── Custody history (timeline) ───────────────────────────────
        pw.SizedBox(height: 16),
        _sectionTitle('Placement & custody history'),
        pw.SizedBox(height: 8),
        if (history.isEmpty)
          pw.Text('No movements logged.',
              style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          _timeline(history),

        // ── Maintenance log ──────────────────────────────────────────
        pw.SizedBox(height: 16),
        _sectionTitle('Maintenance log'),
        pw.SizedBox(height: 8),
        if (maintenance.isEmpty)
          pw.Text('No maintenance recorded.',
              style: pw.TextStyle(fontSize: 10, color: _muted))
        else
          _maintenanceTable(maintenance),
      ],
    ));

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: '$code.pdf',
    );
  }

  /// A small, print-ready QR label (~70x50mm) to stick on the physical asset.
  /// Scanning it opens the public asset page.
  static Future<void> printLabel({
    required String code,
    required String name,
    required String url,
    String? orgName,
    String caption = 'Scan for asset details',
  }) async {
    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(
          70 * PdfPageFormat.mm, 50 * PdfPageFormat.mm,
          marginAll: 4 * PdfPageFormat.mm),
      build: (ctx) => pw.Container(
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _border, width: 0.8),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        padding: const pw.EdgeInsets.all(8),
        child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              _qr(url, 80),
              pw.SizedBox(width: 10),
              pw.Expanded(
                child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      if (orgName != null && orgName.isNotEmpty)
                        pw.Text(_s(orgName),
                            style: pw.TextStyle(fontSize: 8, color: _muted)),
                      pw.SizedBox(height: 1),
                      pw.Text(_s(code),
                          style: pw.TextStyle(
                              fontSize: 16,
                              fontWeight: pw.FontWeight.bold,
                              color: _accent)),
                      pw.SizedBox(height: 2),
                      pw.Text(_s(name),
                          maxLines: 2,
                          style: pw.TextStyle(fontSize: 9.5, color: _ink)),
                      pw.SizedBox(height: 5),
                      pw.Text(_s(caption),
                          style: pw.TextStyle(fontSize: 7, color: _muted)),
                    ]),
              ),
            ]),
      ),
    ));
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: '$code-label.pdf',
    );
  }

  static pw.Widget _qr(String data, double size) => pw.BarcodeWidget(
        barcode: pw.Barcode.qrCode(),
        data: data,
        width: size,
        height: size,
        drawText: false,
        color: _ink,
      );

  /// A full A4 sheet of QR labels (2 per row, ~12 per page) for printing many
  /// assets at once, then cutting them apart. Each entry: {code, name, url}.
  static Future<void> printLabelSheet({
    required List<Map<String, String>> labels,
    String? orgName,
    String caption = 'Scan for asset details',
  }) async {
    final doc = pw.Document();
    final rows = <pw.Widget>[];
    for (var i = 0; i < labels.length; i += 2) {
      final a = labels[i];
      final b = (i + 1) < labels.length ? labels[i + 1] : null;
      rows.add(pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: _labelCard(a, orgName, caption)),
          pw.SizedBox(width: 12),
          pw.Expanded(
              child: b == null ? pw.SizedBox() : _labelCard(b, orgName, caption)),
        ],
      ));
      rows.add(pw.SizedBox(height: 12));
    }
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      build: (ctx) => rows,
    ));
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => doc.save(),
      name: 'asset-qr-labels.pdf',
    );
  }

  static pw.Widget _labelCard(Map<String, String> l, String? orgName, String caption) {
    return pw.Container(
      height: 116,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: _border, width: 0.8),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      padding: const pw.EdgeInsets.all(8),
      child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            _qr(l['url'] ?? '', 92),
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    if (orgName != null && orgName.isNotEmpty)
                      pw.Text(_s(orgName),
                          style: pw.TextStyle(fontSize: 7.5, color: _muted)),
                    pw.SizedBox(height: 1),
                    pw.Text(_s(l['code'] ?? ''),
                        style: pw.TextStyle(
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold,
                            color: _accent)),
                    pw.SizedBox(height: 2),
                    pw.Text(_s(l['name'] ?? ''),
                        maxLines: 2,
                        style: pw.TextStyle(fontSize: 9, color: _ink)),
                    pw.SizedBox(height: 4),
                    pw.Text(_s(caption),
                        style: pw.TextStyle(fontSize: 6.5, color: _muted)),
                  ]),
            ),
          ]),
    );
  }

  // ── Status pill ────────────────────────────────────────────────────
  static pw.Widget _statusPill(String status) {
    final key = status.toLowerCase().replaceAll('_', ' ').trim();
    PdfColor fg, bg;
    switch (key) {
      case 'in use':
        fg = const PdfColor.fromInt(0xFF15803D);
        bg = const PdfColor.fromInt(0xFFDCFCE7);
        break;
      case 'in storage':
        fg = _accent;
        bg = const PdfColor.fromInt(0xFFDBEAFE);
        break;
      case 'under repair':
        fg = _warn;
        bg = _warnBg;
        break;
      case 'lost':
        fg = const PdfColor.fromInt(0xFFB91C1C);
        bg = _dangerBg;
        break;
      case 'retired':
      case 'disposed':
        fg = const PdfColor.fromInt(0xFF475569);
        bg = const PdfColor.fromInt(0xFFF1F5F9);
        break;
      default:
        fg = _muted;
        bg = _bg;
    }
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: pw.BoxDecoration(
          color: bg, borderRadius: pw.BorderRadius.circular(20)),
      child: pw.Text(_s(status).toUpperCase(),
          style: pw.TextStyle(
              fontSize: 8.5,
              color: fg,
              fontWeight: pw.FontWeight.bold,
              letterSpacing: 0.6)),
    );
  }

  // ── Next-maintenance banner ────────────────────────────────────────
  static pw.Widget _dueBanner(String nextDue, bool overdue, bool soon) {
    PdfColor fg = _accent, bg = _bg, bd = _border;
    String suffix = '';
    if (overdue) {
      fg = _danger;
      bg = _dangerBg;
      bd = _danger;
      suffix = '  (overdue)';
    } else if (soon) {
      fg = _warn;
      bg = _warnBg;
      bd = _warn;
      suffix = '  (due soon)';
    }
    return pw.Container(
      padding: const pw.EdgeInsets.all(11),
      decoration: pw.BoxDecoration(
          color: bg,
          borderRadius: pw.BorderRadius.circular(6),
          border: pw.Border.all(color: bd)),
      child: pw.Row(children: [
        pw.Text('NEXT MAINTENANCE DUE',
            style: pw.TextStyle(
                fontSize: 8,
                color: fg,
                fontWeight: pw.FontWeight.bold,
                letterSpacing: 0.8)),
        pw.SizedBox(width: 12),
        pw.Text(_s(nextDue) + suffix,
            style: pw.TextStyle(
                fontSize: 11, fontWeight: pw.FontWeight.bold, color: fg)),
      ]),
    );
  }

  // ── Custody timeline ───────────────────────────────────────────────
  static pw.Widget _timeline(List<Map<String, String>> history) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(left: 10),
      decoration: pw.BoxDecoration(
          border:
              pw.Border(left: pw.BorderSide(color: _accentSoft, width: 1.5))),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < history.length; i++)
            pw.Padding(
              padding: pw.EdgeInsets.only(top: i == 0 ? 0 : 7),
              child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      width: 7,
                      height: 7,
                      margin: const pw.EdgeInsets.only(top: 2),
                      decoration: pw.BoxDecoration(
                          color: i == 0 ? _accent : _muted,
                          borderRadius: pw.BorderRadius.circular(4)),
                    ),
                    pw.SizedBox(width: 9),
                    pw.Expanded(
                      child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(_s(history[i]['text']),
                                style: pw.TextStyle(
                                    fontSize: 10,
                                    color: _ink,
                                    fontWeight: i == 0
                                        ? pw.FontWeight.bold
                                        : pw.FontWeight.normal)),
                            if ((history[i]['when'] ?? '').isNotEmpty)
                              pw.Text(_s(history[i]['when']),
                                  style: pw.TextStyle(
                                      fontSize: 8.5, color: _muted)),
                          ]),
                    ),
                  ]),
            ),
        ],
      ),
    );
  }

  // ── Maintenance table ──────────────────────────────────────────────
  static pw.Widget _maintenanceTable(List<Map<String, String>> rows) {
    return pw.Table(
      border: const pw.TableBorder(
        top: pw.BorderSide(color: _border, width: 0.5),
        bottom: pw.BorderSide(color: _border, width: 0.5),
        horizontalInside: pw.BorderSide(color: _border, width: 0.5),
      ),
      columnWidths: const {
        0: pw.FlexColumnWidth(5),
        1: pw.FlexColumnWidth(2),
        2: pw.FlexColumnWidth(2),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: ['Detail', 'Date', 'Next due']
              .map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    child: pw.Text(h,
                        style: pw.TextStyle(
                            fontSize: 9,
                            fontWeight: pw.FontWeight.bold,
                            color: _muted,
                            letterSpacing: 0.4)),
                  ))
              .toList(),
        ),
        for (var i = 0; i < rows.length; i++)
          pw.TableRow(
            decoration:
                pw.BoxDecoration(color: i.isOdd ? _bg : PdfColors.white),
            children: [
              _cell(rows[i]['text'] ?? ''),
              _cell(rows[i]['date'] ?? '', muted: true),
              _cell(rows[i]['next'] ?? '', bold: true),
            ],
          ),
      ],
    );
  }

  static pw.Widget _cell(String s, {bool muted = false, bool bold = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: pw.Text(s.isEmpty ? '-' : _s(s),
            style: pw.TextStyle(
                fontSize: 9.5,
                color: muted ? _muted : _ink,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      );

  static pw.Widget _miniLabel(String s) => pw.Text(s.toUpperCase(),
      style: pw.TextStyle(
          fontSize: 7.5,
          color: _muted,
          fontWeight: pw.FontWeight.bold,
          letterSpacing: 0.8));

  static pw.Widget _sectionTitle(String title) => pw.Row(children: [
        pw.Container(width: 3, height: 13, color: _accent),
        pw.SizedBox(width: 7),
        pw.Text(title,
            style: pw.TextStyle(
                fontSize: 12, color: _ink, fontWeight: pw.FontWeight.bold)),
      ]);

  /// Map common Unicode punctuation to ASCII and drop any glyph outside the
  /// built-in Helvetica (Latin-1) range so nothing renders as tofu boxes.
  static String _s(String? v) {
    if (v == null) return '';
    final mapped = v
        .replaceAll('→', '->')
        .replaceAll('←', '<-')
        .replaceAll('—', '-')
        .replaceAll('–', '-')
        .replaceAll('•', '-')
        .replaceAll('…', '...')
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('‘', "'")
        .replaceAll('’', "'");
    final sb = StringBuffer();
    for (final r in mapped.runes) {
      if (r <= 0xFF) sb.writeCharCode(r);
    }
    return sb.toString();
  }

  static pw.Widget _block(String title,
      {required List<pw.Widget> cells, bool accent = false}) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: accent ? _bg : PdfColors.white,
        border: accent
            ? pw.Border(left: pw.BorderSide(color: _accent, width: 2.5))
            : pw.Border.all(color: _border),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title.toUpperCase(),
                style: pw.TextStyle(
                    fontSize: 8,
                    color: accent ? _accent : _muted,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.8)),
            pw.SizedBox(height: 8),
            pw.Wrap(spacing: 24, runSpacing: 10, children: cells),
          ]),
    );
  }

  static pw.Widget _kv(String k, String? v) {
    return pw.SizedBox(
      width: 150,
      child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(k, style: pw.TextStyle(fontSize: 8, color: _muted)),
            pw.SizedBox(height: 2),
            pw.Text((v == null || v.isEmpty) ? '-' : _s(v),
                style: pw.TextStyle(
                    fontSize: 10.5,
                    color: _ink,
                    fontWeight: pw.FontWeight.bold)),
          ]),
    );
  }
}
