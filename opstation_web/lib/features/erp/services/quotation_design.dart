import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// ============================================================================
// QUOTATION DESIGNS for brands
// A design is a set of choices (header style, logo side, title wording, fonts,
// colours, where the customer / quote details sit, table style, totals, notes,
// footer…). The generator combines them at random, so the number of looks is
// practically unlimited. Content is always the same; only placement and style
// change. A brand keeps its design until "Generate new design" is pressed.
// ============================================================================

class QuoteDesign {
  final Map<String, dynamic> p;
  const QuoteDesign(this.p);

  String s(String k, String d) => (p[k] as String?) ?? d;
  int i(String k, int d) => (p[k] as num?)?.toInt() ?? d;
  bool b(String k, bool d) => (p[k] as bool?) ?? d;

  static const headers = ['band', 'split', 'centered', 'minimal', 'sidebar', 'boxed', 'stripe'];
  static const titles = ['QUOTATION', 'Quotation', 'PRICE QUOTATION', 'Price Quotation', 'SALES QUOTATION', 'QUOTE'];
  static const fonts = ['helvetica', 'times'];
  static const parties = ['left-right', 'right-left', 'stacked', 'row'];
  static const tables = ['grid', 'striped', 'lines', 'minimal', 'boxed'];
  static const headRows = ['filled', 'outline', 'underline', 'tint'];
  static const totalsPos = ['right', 'left', 'band'];
  static const notesPos = ['below', 'beside'];
  static const footers = ['line', 'band', 'plain'];
  static const signPos = ['left', 'right', 'center'];

  /// Curated accent colours — every one prints well and looks professional.
  static const palette = [
    0xFF1D4ED8, 0xFF0F766E, 0xFF7C3AED, 0xFFB45309, 0xFFBE123C, 0xFF15803D,
    0xFF0369A1, 0xFF4338CA, 0xFF9D174D, 0xFF334155, 0xFF0E7490, 0xFF854D0E,
    0xFF166534, 0xFF6D28D9, 0xFFC2410C, 0xFF1E3A8A, 0xFF065F46, 0xFF7F1D1D,
    0xFF374151, 0xFF0C4A6E, 0xFF581C87, 0xFF92400E, 0xFF134E4A, 0xFF3F3F46,
  ];

  /// A fresh random design. [avoid] = the current one (never repeat it).
  static QuoteDesign generate({QuoteDesign? avoid, int? brandColor}) {
    final r = Random();
    T pick<T>(List<T> xs) => xs[r.nextInt(xs.length)];
    for (var tries = 0; tries < 20; tries++) {
      final head = pick(headers);
      final d = <String, dynamic>{
        'seed': r.nextInt(1 << 30),
        'header': head,
        'logo': pick(['left', 'right']),
        'title': pick(titles),
        'font': pick(fonts),
        'headFont': pick(fonts),
        'accent': brandColor ?? pick(palette),
        'party': pick(parties),
        'table': pick(tables),
        'headRow': pick(headRows),
        'totals': pick(totalsPos),
        'notes': pick(notesPos),
        'footer': pick(footers),
        'sign': pick(signPos),
        'radius': pick([0, 3, 6, 10]),
        'size': pick([9, 9.5, 10]),
        'numberBadge': r.nextBool(),
        'caps': r.nextBool(),
        'rule': pick([0.5, 1.0, 2.0]),
      };
      final nd = QuoteDesign(d);
      if (avoid == null || nd.signature != avoid.signature) return nd;
    }
    return QuoteDesign({'header': 'split', 'accent': brandColor ?? palette.first});
  }

  /// Layout fingerprint — two designs with the same one look alike.
  String get signature => [s('header', ''), s('party', ''), s('table', ''), s('totals', ''), p['accent']].join('|');

  PdfColor get accent => PdfColor.fromInt(i('accent', palette.first));
  PdfColor get tint => _mix(accent, PdfColors.white, 0.88);
  PdfColor get soft => _mix(accent, PdfColors.white, 0.7);

  static PdfColor _mix(PdfColor a, PdfColor b, double t) =>
      PdfColor(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t);

  String toJson() => jsonEncode(p);
}

class QuoteBrand {
  final String name;
  final String? tagline, phone, email, address, website, taxNo, footer;
  final Uint8List? logo;
  const QuoteBrand({required this.name, this.tagline, this.phone, this.email, this.address,
      this.website, this.taxNo, this.footer, this.logo});

  static Uint8List? logoFromData(String? data) {
    if (data == null || !data.startsWith('data:')) return null;
    final i = data.indexOf(',');
    if (i < 0) return null;
    try {
      return base64Decode(data.substring(i + 1));
    } catch (_) {
      return null;
    }
  }

  factory QuoteBrand.fromRow(Map<String, dynamic> r) => QuoteBrand(
        name: '${r['name'] ?? ''}',
        tagline: r['tagline'] as String?,
        phone: r['phone'] as String?,
        email: r['email'] as String?,
        address: r['address'] as String?,
        website: r['website'] as String?,
        taxNo: r['tax_no'] as String?,
        footer: r['footer'] as String?,
        logo: logoFromData(r['logo_data'] as String?),
      );
}

class QuoteLine {
  final String item;
  final String? sku, uom;
  final double qty, price, discPct, total;
  const QuoteLine({required this.item, this.sku, this.uom, required this.qty, required this.price,
      this.discPct = 0, required this.total});
}

class QuoteData {
  final String number, date;
  final String? validUntil, customer, customerPhone, preparedBy, remarks;
  final List<QuoteLine> lines;
  final double subtotal, discount, grandTotal;
  const QuoteData({required this.number, required this.date, this.validUntil, this.customer,
      this.customerPhone, this.preparedBy, this.remarks, required this.lines,
      required this.subtotal, required this.discount, required this.grandTotal});

  static QuoteData sample() => QuoteData(
        number: 'QT-2026-0001',
        date: DateFormat('dd MMM yyyy').format(DateTime.now()),
        validUntil: DateFormat('dd MMM yyyy').format(DateTime.now().add(const Duration(days: 7))),
        customer: 'Sample Customer',
        customerPhone: '0300 0000000',
        preparedBy: 'Sales Team',
        remarks: 'Prices include delivery within the city.',
        lines: const [
          QuoteLine(item: 'Product one', sku: 'P-001', uom: 'pcs', qty: 10, price: 1250, total: 12500),
          QuoteLine(item: 'Product two', sku: 'P-002', uom: 'box', qty: 4, price: 3400, discPct: 5, total: 12920),
          QuoteLine(item: 'Product three', sku: 'P-003', uom: 'pcs', qty: 25, price: 180, total: 4500),
        ],
        subtotal: 30600,
        discount: 680,
        grandTotal: 29920,
      );
}

final _money = NumberFormat('#,##0.00');
final _qtyFmt = NumberFormat('#,##0.####');

/// Builds the quotation PDF for [brand] in [design].
Future<Uint8List> buildBrandQuotationPdf(QuoteDesign design, QuoteBrand brand, QuoteData q) async {
  final base = design.s('font', 'helvetica') == 'times' ? pw.Font.times() : pw.Font.helvetica();
  final bold = design.s('font', 'helvetica') == 'times' ? pw.Font.timesBold() : pw.Font.helveticaBold();
  final headBold = design.s('headFont', 'helvetica') == 'times' ? pw.Font.timesBold() : pw.Font.helveticaBold();
  final fs = (design.p['size'] as num?)?.toDouble() ?? 9.5;
  final accent = design.accent;
  final tint = design.tint;
  final soft = design.soft;
  const ink = PdfColor.fromInt(0xFF0F172A);
  const muted = PdfColor.fromInt(0xFF64748B);
  const border = PdfColor.fromInt(0xFFE2E8F0);
  final radius = design.i('radius', 4).toDouble();
  final caps = design.b('caps', false);
  String cap(String t) => caps ? t.toUpperCase() : t;
  final rule = (design.p['rule'] as num?)?.toDouble() ?? 1.0;
  final logo = brand.logo == null ? null : pw.MemoryImage(brand.logo!);
  final hasDisc = q.lines.any((l) => l.discPct > 0);

  pw.TextStyle t({double? size, bool b = false, PdfColor? c, double? ls}) =>
      pw.TextStyle(font: b ? bold : base, fontSize: size ?? fs, color: c ?? ink, letterSpacing: ls);

  // ---------- pieces ----------
  pw.Widget logoBox(double h) => logo == null ? pw.SizedBox() : pw.Container(height: h, child: pw.Image(logo, fit: pw.BoxFit.contain));

  List<String> contacts() => [
        if ((brand.address ?? '').trim().isNotEmpty) brand.address!.trim(),
        [
          if ((brand.phone ?? '').trim().isNotEmpty) brand.phone!.trim(),
          if ((brand.email ?? '').trim().isNotEmpty) brand.email!.trim(),
          if ((brand.website ?? '').trim().isNotEmpty) brand.website!.trim(),
        ].join('  ·  '),
        if ((brand.taxNo ?? '').trim().isNotEmpty) 'NTN / STRN: ${brand.taxNo!.trim()}',
      ].where((s) => s.isNotEmpty).toList();

  pw.Widget brandText({PdfColor? c, PdfColor? sub, pw.CrossAxisAlignment al = pw.CrossAxisAlignment.start, pw.TextAlign ta = pw.TextAlign.left}) =>
      pw.Column(crossAxisAlignment: al, children: [
        pw.Text(brand.name, textAlign: ta, style: pw.TextStyle(font: headBold, fontSize: fs + 9, color: c ?? accent)),
        if ((brand.tagline ?? '').trim().isNotEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(top: 1), child: pw.Text(brand.tagline!.trim(), textAlign: ta, style: t(size: fs, c: sub ?? muted))),
        pw.SizedBox(height: 4),
        for (final l in contacts()) pw.Text(l, textAlign: ta, style: t(size: fs - 1, c: sub ?? muted)),
      ]);

  pw.Widget titleBlock({PdfColor? c, pw.CrossAxisAlignment al = pw.CrossAxisAlignment.end, PdfColor? sub}) {
    final title = design.s('title', 'QUOTATION');
    return pw.Column(crossAxisAlignment: al, children: [
      pw.Text(title, style: pw.TextStyle(font: headBold, fontSize: fs + 8, color: c ?? accent, letterSpacing: title == title.toUpperCase() ? 1.5 : 0)),
      pw.SizedBox(height: 4),
      design.b('numberBadge', false)
          ? pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: pw.BoxDecoration(color: c == null ? tint : PdfColors.white, borderRadius: pw.BorderRadius.circular(radius + 2)),
              child: pw.Text(q.number, style: t(b: true, c: accent)))
          : pw.Text(q.number, style: t(b: true, size: fs + 1, c: c ?? ink)),
    ]);
  }

  final logoRight = design.s('logo', 'left') == 'right';

  pw.Widget header() {
    switch (design.s('header', 'split')) {
      case 'band':
        final left = pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          if (logo != null) ...[logoBox(42), pw.SizedBox(width: 12)],
          pw.Expanded(child: brandText(c: PdfColors.white, sub: PdfColors.white)),
        ]);
        return pw.Container(
          padding: const pw.EdgeInsets.all(16),
          decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(radius)),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: logoRight
              ? [titleBlock(c: PdfColors.white, al: pw.CrossAxisAlignment.start), pw.Spacer(), pw.Expanded(flex: 3, child: pw.Align(alignment: pw.Alignment.topRight, child: brandText(c: PdfColors.white, sub: PdfColors.white, al: pw.CrossAxisAlignment.end, ta: pw.TextAlign.right)))]
              : [pw.Expanded(flex: 3, child: left), pw.SizedBox(width: 12), titleBlock(c: PdfColors.white)]),
        );
      case 'centered':
        return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          if (logo != null) ...[pw.Center(child: logoBox(46)), pw.SizedBox(height: 6)],
          pw.Center(child: brandText(al: pw.CrossAxisAlignment.center, ta: pw.TextAlign.center)),
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 6),
            decoration: pw.BoxDecoration(color: tint, borderRadius: pw.BorderRadius.circular(radius)),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, children: [
              pw.Text(design.s('title', 'QUOTATION'), style: pw.TextStyle(font: headBold, fontSize: fs + 5, color: accent, letterSpacing: 1.2)),
              pw.SizedBox(width: 12),
              pw.Text(q.number, style: t(b: true)),
            ]),
          ),
        ]);
      case 'minimal':
        return pw.Column(children: [
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: logoRight
              ? [titleBlock(al: pw.CrossAxisAlignment.start, c: muted), pw.Spacer(), brandText(al: pw.CrossAxisAlignment.end, ta: pw.TextAlign.right), if (logo != null) ...[pw.SizedBox(width: 10), logoBox(36)]]
              : [if (logo != null) ...[logoBox(36), pw.SizedBox(width: 10)], pw.Expanded(child: brandText()), titleBlock(c: muted)]),
          pw.SizedBox(height: 8),
          pw.Divider(color: accent, thickness: rule),
        ]);
      case 'sidebar':
        return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Container(width: 6, height: 70, color: accent),
          pw.SizedBox(width: 12),
          if (logo != null && !logoRight) ...[logoBox(44), pw.SizedBox(width: 10)],
          pw.Expanded(child: brandText()),
          if (logo != null && logoRight) ...[logoBox(44), pw.SizedBox(width: 10)],
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: accent, width: 1), borderRadius: pw.BorderRadius.circular(radius)),
            child: titleBlock(),
          ),
        ]);
      case 'boxed':
        return pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: soft, width: 1.2), borderRadius: pw.BorderRadius.circular(radius + 2)),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: logoRight
              ? [titleBlock(al: pw.CrossAxisAlignment.start), pw.Spacer(), brandText(al: pw.CrossAxisAlignment.end, ta: pw.TextAlign.right), if (logo != null) ...[pw.SizedBox(width: 10), logoBox(44)]]
              : [if (logo != null) ...[logoBox(44), pw.SizedBox(width: 10)], pw.Expanded(child: brandText()), titleBlock()]),
        );
      case 'stripe':
        return pw.Column(children: [
          pw.Container(height: 5, color: accent),
          pw.SizedBox(height: 10),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: logoRight
              ? [titleBlock(al: pw.CrossAxisAlignment.start), pw.Spacer(), brandText(al: pw.CrossAxisAlignment.end, ta: pw.TextAlign.right), if (logo != null) ...[pw.SizedBox(width: 10), logoBox(42)]]
              : [if (logo != null) ...[logoBox(42), pw.SizedBox(width: 10)], pw.Expanded(child: brandText()), titleBlock()]),
        ]);
      case 'split':
      default:
        return pw.Column(children: [
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: logoRight
              ? [titleBlock(al: pw.CrossAxisAlignment.start), pw.Spacer(), brandText(al: pw.CrossAxisAlignment.end, ta: pw.TextAlign.right), if (logo != null) ...[pw.SizedBox(width: 10), logoBox(46)]]
              : [if (logo != null) ...[logoBox(46), pw.SizedBox(width: 10)], pw.Expanded(child: brandText()), titleBlock()]),
          pw.SizedBox(height: 8),
          pw.Container(height: rule + 1, color: accent),
        ]);
    }
  }

  pw.Widget label(String s) => pw.Text(cap(s), style: t(size: fs - 1.5, b: true, c: muted, ls: caps ? 0.8 : 0));

  pw.Widget customerBox() => pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(color: tint, borderRadius: pw.BorderRadius.circular(radius)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          label('Quotation for'),
          pw.SizedBox(height: 3),
          pw.Text(q.customer ?? '-', style: t(b: true, size: fs + 2)),
          if ((q.customerPhone ?? '').isNotEmpty) pw.Text(q.customerPhone!, style: t(c: muted)),
        ]),
      );

  pw.Widget metaRow(String k, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(children: [
          pw.SizedBox(width: 70, child: pw.Text(k, style: t(c: muted))),
          pw.Expanded(child: pw.Text(v, textAlign: pw.TextAlign.right, style: t(b: true))),
        ]),
      );

  pw.Widget metaBox() => pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: border), borderRadius: pw.BorderRadius.circular(radius)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          metaRow('Quote no.', q.number),
          metaRow('Date', q.date),
          if ((q.validUntil ?? '').isNotEmpty) metaRow('Valid until', q.validUntil!),
          if ((q.preparedBy ?? '').isNotEmpty) metaRow('Prepared by', q.preparedBy!),
        ]),
      );

  pw.Widget party() {
    switch (design.s('party', 'left-right')) {
      case 'right-left':
        return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: metaBox()), pw.SizedBox(width: 12), pw.Expanded(child: customerBox()),
        ]);
      case 'stacked':
        return pw.Column(children: [customerBox(), pw.SizedBox(height: 8), metaBox()]);
      case 'row':
        pw.Widget cell(String k, String v) => pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                label(k), pw.SizedBox(height: 2), pw.Text(v, style: t(b: true)),
              ]),
            );
        return pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: accent, width: rule), bottom: const pw.BorderSide(color: border)),
          ),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            cell('Quotation for', [q.customer ?? '-', if ((q.customerPhone ?? '').isNotEmpty) q.customerPhone!].join('\n')),
            cell('Date', q.date),
            if ((q.validUntil ?? '').isNotEmpty) cell('Valid until', q.validUntil!),
            if ((q.preparedBy ?? '').isNotEmpty) cell('Prepared by', q.preparedBy!),
          ]),
        );
      case 'left-right':
      default:
        return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: customerBox()), pw.SizedBox(width: 12), pw.Expanded(child: metaBox()),
        ]);
    }
  }

  pw.Widget table() {
    final style = design.s('table', 'grid');
    final headRow = design.s('headRow', 'filled');
    final headColor = headRow == 'filled' ? PdfColors.white : accent;
    final cols = <(String, int, pw.TextAlign)>[
      ('#', 4, pw.TextAlign.center),
      ('Item', 40, pw.TextAlign.left),
      ('Unit', 8, pw.TextAlign.center),
      ('Qty', 9, pw.TextAlign.right),
      ('Rate', 13, pw.TextAlign.right),
      if (hasDisc) ('Disc %', 9, pw.TextAlign.right),
      ('Amount', 15, pw.TextAlign.right),
    ];
    pw.Widget cell(String s, pw.TextAlign a, {bool head = false, String? sub}) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(horizontal: 5, vertical: style == 'minimal' ? 5 : 4),
          child: pw.Column(crossAxisAlignment: a == pw.TextAlign.left ? pw.CrossAxisAlignment.start : (a == pw.TextAlign.center ? pw.CrossAxisAlignment.center : pw.CrossAxisAlignment.end), children: [
            pw.Text(head ? cap(s) : s, textAlign: a, style: head ? t(b: true, size: fs - 0.5, c: headColor) : t()),
            if (sub != null && sub.isNotEmpty) pw.Text(sub, style: t(size: fs - 2, c: muted)),
          ]),
        );
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: switch (headRow) {
          'filled' => pw.BoxDecoration(color: accent),
          'tint' => pw.BoxDecoration(color: tint),
          'outline' => pw.BoxDecoration(border: pw.Border.all(color: accent, width: 0.8)),
          _ => pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: accent, width: rule + 0.5))),
        },
        children: [for (final c in cols) cell(c.$1, c.$3, head: true)],
      ),
    ];
    for (var n = 0; n < q.lines.length; n++) {
      final l = q.lines[n];
      final values = <String>[
        '${n + 1}',
        l.item,
        l.uom ?? '',
        _qtyFmt.format(l.qty),
        _money.format(l.price),
        if (hasDisc) (l.discPct > 0 ? l.discPct.toStringAsFixed(l.discPct == l.discPct.roundToDouble() ? 0 : 1) : '-'),
        _money.format(l.total),
      ];
      rows.add(pw.TableRow(
        decoration: style == 'striped' && n.isOdd
            ? pw.BoxDecoration(color: tint)
            : (style == 'lines' ? const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: border, width: 0.6))) : null),
        children: [
          for (var c = 0; c < cols.length; c++) cell(values[c], cols[c].$3, sub: c == 1 ? l.sku : null),
        ],
      ));
    }
    final tbl = pw.Table(
      columnWidths: {for (var c = 0; c < cols.length; c++) c: pw.FlexColumnWidth(cols[c].$2.toDouble())},
      border: style == 'grid'
          ? pw.TableBorder.all(color: border, width: 0.6)
          : (style == 'boxed' ? pw.TableBorder(left: const pw.BorderSide(color: border), right: const pw.BorderSide(color: border), bottom: const pw.BorderSide(color: border), horizontalInside: const pw.BorderSide(color: border, width: 0.4)) : null),
      children: rows,
    );
    return tbl;
  }

  pw.Widget totals() {
    pw.Widget row(String k, String v, {bool big = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Row(children: [
            pw.Expanded(child: pw.Text(k, style: big ? t(b: true, size: fs + 1) : t(c: muted))),
            pw.Text(v, style: big ? pw.TextStyle(font: headBold, fontSize: fs + 3, color: accent) : t(b: true)),
          ]),
        );
    final box = pw.Container(
      width: 220,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(color: design.s('totals', 'right') == 'band' ? null : tint, borderRadius: pw.BorderRadius.circular(radius)),
      child: pw.Column(children: [
        row('Subtotal', _money.format(q.subtotal)),
        if (q.discount > 0.004) row('Discount', '- ${_money.format(q.discount)}'),
        pw.Divider(color: soft, thickness: 0.6),
        row('Total (PKR)', _money.format(q.grandTotal), big: true),
      ]),
    );
    final notes = (q.remarks ?? '').trim().isEmpty
        ? null
        : pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: border), borderRadius: pw.BorderRadius.circular(radius)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              label('Remarks'), pw.SizedBox(height: 3), pw.Text(q.remarks!.trim(), style: t()),
            ]),
          );
    switch (design.s('totals', 'right')) {
      case 'band':
        return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(radius)),
            child: pw.Row(children: [
              pw.Text('Subtotal ${_money.format(q.subtotal)}', style: t(c: PdfColors.white)),
              if (q.discount > 0.004) ...[pw.SizedBox(width: 14), pw.Text('Discount ${_money.format(q.discount)}', style: t(c: PdfColors.white))],
              pw.Spacer(),
              pw.Text('Total PKR ${_money.format(q.grandTotal)}', style: pw.TextStyle(font: headBold, fontSize: fs + 3, color: PdfColors.white)),
            ]),
          ),
          if (notes != null) ...[pw.SizedBox(height: 10), notes],
        ]);
      case 'left':
        return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          box,
          pw.SizedBox(width: 14),
          pw.Expanded(child: notes ?? pw.SizedBox()),
        ]);
      case 'right':
      default:
        if (design.s('notes', 'below') == 'beside' && notes != null) {
          return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: notes), pw.SizedBox(width: 14), box,
          ]);
        }
        return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Align(alignment: pw.Alignment.centerRight, child: box),
          if (notes != null) ...[pw.SizedBox(height: 10), notes],
        ]);
    }
  }

  pw.Widget signature() {
    final al = switch (design.s('sign', 'right')) {
      'left' => pw.Alignment.centerLeft,
      'center' => pw.Alignment.center,
      _ => pw.Alignment.centerRight,
    };
    return pw.Align(
      alignment: al,
      child: pw.Column(children: [
        pw.SizedBox(height: 28),
        pw.Container(width: 160, height: 0.8, color: muted),
        pw.SizedBox(height: 3),
        pw.Text('Authorised signature', style: t(size: fs - 1, c: muted)),
        if ((q.preparedBy ?? '').isNotEmpty) pw.Text(q.preparedBy!, style: t(size: fs - 1)),
      ]),
    );
  }

  pw.Widget footer(pw.Context ctx) {
    final text = [
      if ((brand.footer ?? '').trim().isNotEmpty) brand.footer!.trim(),
      'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
    ].join('     ');
    switch (design.s('footer', 'line')) {
      case 'band':
        return pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          color: tint,
          child: pw.Text(text, textAlign: pw.TextAlign.center, style: t(size: fs - 2, c: muted)),
        );
      case 'plain':
        return pw.Text(text, textAlign: pw.TextAlign.center, style: t(size: fs - 2, c: muted));
      case 'line':
      default:
        return pw.Column(children: [
          pw.Divider(color: soft, thickness: 0.6),
          pw.Text(text, textAlign: pw.TextAlign.center, style: t(size: fs - 2, c: muted)),
        ]);
    }
  }

  final doc = pw.Document(title: '${brand.name} ${q.number}');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 28),
    footer: footer,
    build: (ctx) => [
      header(),
      pw.SizedBox(height: 14),
      party(),
      pw.SizedBox(height: 14),
      table(),
      pw.SizedBox(height: 12),
      totals(),
      signature(),
    ],
  ));
  return doc.save();
}

