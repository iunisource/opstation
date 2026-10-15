import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Packing slips for online-store orders (Sales → Fulfillment), A4 or A5, one
/// page per order: store + order number (barcode + QR for scanning at
/// dispatch), ship-to, items with prices (bundles list what's inside), totals
/// with the amount to collect (COD), courier / tracking, who picked and
/// packed, the store's own text, and the customer's note.
class PackingSlipPdf {
  PackingSlipPdf._();

  static const _ink = PdfColor.fromInt(0xFF1F2937);
  static const _grey = PdfColor.fromInt(0xFF6B7280);
  static const _line = PdfColor.fromInt(0xFFD1D5DB);

  // The built-in PDF font only knows basic Latin characters.
  static String _t(Object? v) {
    final s = '${v ?? ''}'
        .replaceAll('—', '-').replaceAll('–', '-').replaceAll('×', 'x')
        .replaceAll('‘', "'").replaceAll('’', "'").replaceAll('“', '"').replaceAll('”', '"')
        .replaceAll('…', '...').replaceAll('•', '-');
    return String.fromCharCodes(s.runes.map((c) => c < 256 ? c : 0x3F));
  }

  static double _n(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  static String _q(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);

  /// [orders]: shop_orders rows. [products]: id → product (name).
  static Future<Uint8List> build({
    required List<Map<String, dynamic>> orders,
    required Map<String, Map<String, dynamic>> products,
    required String Function(String? storeId) storeName,
    required String? Function(String? storeId) storeNote,
    required String printedBy,
    bool a5 = false,
  }) async {
    final doc = pw.Document(title: 'Packing slips');
    final fmt = a5 ? PdfPageFormat.a5 : PdfPageFormat.a4;
    final s = a5 ? 0.82 : 1.0; // text scale for A5
    final money = NumberFormat('#,##0.##');
    final now = DateFormat('d MMM yyyy, HH:mm').format(DateTime.now());

    for (final o in orders) {
      final cur = _t(o['currency'] ?? '');
      String m(double v) => '$cur ${money.format(v)}'.trim();
      final ship = Map<String, dynamic>.from((o['ship_to'] as Map?) ?? const {});
      final address = [ship['address1'], ship['address2'], ship['city'], ship['province'], ship['zip'], ship['country']]
          .where((x) => x != null && '$x'.trim().isNotEmpty).join(', ');
      final lines = [for (final l in (o['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
      final placed = DateTime.tryParse('${o['placed_at'] ?? ''}')?.toLocal();
      final paid = '${o['financial_status'] ?? ''}'.toUpperCase() == 'PAID';
      final total = _n(o['total']);
      final collect = o['outstanding'] != null ? _n(o['outstanding']) : (paid ? 0.0 : total);
      final itemsSum = lines.fold<double>(0, (a, l) => a + _n(l['price']) * _n(l['qty']));
      final orderNo = _t(o['order_no'] ?? '');
      final note = storeNote(o['store_id'] as String?);

      pw.TextStyle st(double size, {bool bold = false, PdfColor color = _ink}) =>
          pw.TextStyle(fontSize: size * s, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color);

      pw.Widget kv(String k, String v) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 2),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.SizedBox(width: 70 * s, child: pw.Text(k, style: st(9, color: _grey))),
              pw.Expanded(child: pw.Text(_t(v), style: st(10, bold: true))),
            ]),
          );

      pw.Widget cell(String t, {bool bold = false, pw.TextAlign align = pw.TextAlign.left, double size = 9.5, PdfColor color = _ink}) =>
          pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: pw.Text(_t(t), textAlign: align, style: st(size, bold: bold, color: color)));

      final rows = <pw.TableRow>[
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
          children: [
            cell('#', bold: true), cell('Qty', bold: true, align: pw.TextAlign.center), cell('Item', bold: true),
            cell('Price', bold: true, align: pw.TextAlign.right), cell('Amount', bold: true, align: pw.TextAlign.right),
          ],
        ),
      ];
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        final qty = _n(l['qty']);
        final vt = '${l['variant_title'] ?? ''}'.trim();
        final title = '${l['title'] ?? ''}${vt.isNotEmpty && vt != 'Default Title' ? ' - $vt' : ''}';
        final p = products[l['product_id']];
        final comps = [for (final c in (l['components'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
        rows.add(pw.TableRow(children: [
          cell('${i + 1}'),
          cell(_q(qty), bold: true, align: pw.TextAlign.center, size: 11),
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(_t(title), style: st(9.5, bold: true)),
              if ('${l['sku'] ?? ''}'.isNotEmpty) pw.Text(_t('SKU ${l['sku']}'), style: st(8, color: _grey)),
              if (p != null && '${p['name']}' != title) pw.Text(_t('${p['name']}'), style: st(8, color: _grey)),
              for (final c in comps)
                pw.Text(_t('   - ${_q(_n(c['qty']))} x ${products[c['product_id']]?['name'] ?? 'item'}'), style: st(8.5)),
            ]),
          ),
          cell(money.format(_n(l['price'])), align: pw.TextAlign.right),
          cell(money.format(_n(l['price']) * qty), align: pw.TextAlign.right, bold: true),
        ]));
      }

      pw.Widget totalRow(String k, double v, {bool bold = false}) => pw.Row(children: [
            pw.Expanded(child: pw.Text(k, textAlign: pw.TextAlign.right, style: st(9.5, bold: bold))),
            pw.SizedBox(width: 90 * s, child: pw.Text(_t(m(v)), textAlign: pw.TextAlign.right, style: st(9.5, bold: bold))),
          ]);

      final pickedAt = DateTime.tryParse('${o['picked_at'] ?? ''}')?.toLocal();
      final packedAt = DateTime.tryParse('${o['packed_at'] ?? ''}')?.toLocal();
      final shipInfo = (o['ship_info'] as Map?) ?? const {};
      final courier = o['tracking_company'] ?? shipInfo['company'];
      final tracking = o['tracking_number'] ?? shipInfo['number'];

      // MultiPage: a long order flows onto a second page instead of failing.
      doc.addPage(pw.MultiPage(
        pageFormat: fmt,
        margin: pw.EdgeInsets.all(a5 ? 22 : 32),
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        footer: (ctx) => ctx.pagesCount > 1
            ? pw.Align(alignment: pw.Alignment.centerRight,
                child: pw.Text('Order $orderNo - page ${ctx.pageNumber}/${ctx.pagesCount}', style: st(8, color: _grey)))
            : pw.SizedBox(),
        build: (_) => [
          // Header
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(_t(storeName(o['store_id'] as String?)), style: st(16, bold: true)),
              pw.Text('PACKING SLIP', style: st(10, bold: true, color: _grey)),
              pw.SizedBox(height: 6),
              pw.Text('Order $orderNo', style: st(18, bold: true)),
              if (placed != null) pw.Text(_t('Placed ${DateFormat('d MMM yyyy, HH:mm').format(placed)}'), style: st(9, color: _grey)),
            ])),
            if (orderNo.isNotEmpty)
              pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                pw.Row(children: [
                  pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: orderNo, width: 130 * s, height: 40 * s,
                      drawText: true, textStyle: st(8)),
                  pw.SizedBox(width: 8),
                  pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: orderNo, width: 52 * s, height: 52 * s, drawText: false),
                ]),
              ]),
          ]),
          pw.SizedBox(height: 10),
          pw.Divider(color: _line),
          // Ship to + payment
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('SHIP TO', style: st(8.5, bold: true, color: _grey)),
              pw.SizedBox(height: 3),
              pw.Text(_t(o['customer_name'] ?? ship['name'] ?? '-'), style: st(12, bold: true)),
              if ('${o['phone'] ?? ''}'.isNotEmpty) pw.Text(_t(o['phone']), style: st(11, bold: true)),
              if (address.isNotEmpty) pw.Text(_t(address), style: st(10)),
              if ('${o['email'] ?? ''}'.isNotEmpty) pw.Text(_t(o['email']), style: st(9, color: _grey)),
            ])),
            pw.SizedBox(width: 16),
            pw.Container(
              width: 170 * s,
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: collect > 0 ? _ink : _line, width: collect > 0 ? 2 : 1)),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(collect > 0 ? 'COLLECT ON DELIVERY' : 'PAID', style: st(9, bold: true, color: _grey)),
                pw.Text(_t(collect > 0 ? m(collect) : m(total)), style: st(16, bold: true)),
                if ('${o['payment_methods'] ?? ''}'.isNotEmpty) pw.Text(_t(o['payment_methods']), style: st(8, color: _grey)),
              ]),
            ),
          ]),
          if (courier != null || tracking != null) ...[
            pw.SizedBox(height: 8),
            kv('Courier', '${courier ?? '-'}${tracking != null ? '   Tracking: $tracking' : ''}'),
          ],
          pw.SizedBox(height: 10),
          // Items
          pw.Table(
            border: pw.TableBorder(horizontalInside: const pw.BorderSide(color: _line, width: 0.5),
                bottom: const pw.BorderSide(color: _line, width: 0.5)),
            columnWidths: {
              0: pw.FixedColumnWidth(18 * s), 1: pw.FixedColumnWidth(32 * s), 2: const pw.FlexColumnWidth(),
              3: pw.FixedColumnWidth(60 * s), 4: pw.FixedColumnWidth(70 * s),
            },
            children: rows,
          ),
          pw.SizedBox(height: 6),
          totalRow('Items', o['subtotal'] != null ? _n(o['subtotal']) : itemsSum),
          if (_n(o['discounts']) > 0) totalRow('Discount', -_n(o['discounts'])),
          if (o['shipping_total'] != null) totalRow('Shipping', _n(o['shipping_total'])),
          totalRow('Total', total, bold: true),
          if (collect > 0) totalRow('To collect', collect, bold: true),
          if ('${o['note'] ?? ''}'.trim().isNotEmpty) ...[
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.all(6),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: _line)),
              child: pw.Text(_t('Customer note: ${o['note']}'), style: st(9.5)),
            ),
          ],
          pw.SizedBox(height: 16),
          if (note != null && note.trim().isNotEmpty) ...[
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF9FAFB)),
              child: pw.Text(_t(note), style: st(9.5)),
            ),
            pw.SizedBox(height: 8),
          ],
          pw.Divider(color: _line),
          pw.Text(_t([
            if (o['picked_by_name'] != null) 'Picked by ${o['picked_by_name']}${pickedAt != null ? ' (${DateFormat('d MMM, HH:mm').format(pickedAt)})' : ''}',
            if (o['packed_by_name'] != null) 'Packed by ${o['packed_by_name']}${packedAt != null ? ' (${DateFormat('d MMM, HH:mm').format(packedAt)})' : ''}',
            'Printed by $printedBy, $now',
          ].join('   |   ')), style: st(8, color: _grey)),
        ],
      ));
    }
    return doc.save();
  }
}
