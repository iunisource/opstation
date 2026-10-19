import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Opstation's own shipping label (100 × 150 mm thermal), used when the
/// courier doesn't send back a label file: sender, receiver, COD, and the
/// tracking number as a barcode (the same code the label check scans).
class ShippingLabelPdf {
  static String _t(Object? v) {
    final s = '${v ?? ''}'.replaceAll('—', '-').replaceAll('–', '-').replaceAll('×', 'x');
    return String.fromCharCodes(s.runes.map((c) => c < 256 ? c : 0x3F));
  }

  static Future<Uint8List> build({
    required Map<String, dynamic> order,
    required String courier,
    required String trackingNumber,
    required String storeName,
    required double cod,
    double? weightKg,
    int pieces = 1,
  }) async {
    final a = Map<String, dynamic>.from((order['ship_to'] as Map?) ?? const {});
    final money = NumberFormat('#,##0.##');
    final addr = [a['address1'], a['address2'], [a['city'], a['province'], a['zip']].where((x) => '${x ?? ''}'.isNotEmpty).join(', ')]
        .where((x) => '${x ?? ''}'.trim().isNotEmpty).join('\n');
    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: const PdfPageFormat(100 * PdfPageFormat.mm, 150 * PdfPageFormat.mm, marginAll: 4 * PdfPageFormat.mm),
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Row(children: [
          pw.Expanded(child: pw.Text(_t(courier), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold))),
          pw.Text(_t(order['order_no']), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 4),
        pw.Center(child: pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: trackingNumber,
            width: 82 * PdfPageFormat.mm, height: 20 * PdfPageFormat.mm, drawText: false)),
        pw.Center(child: pw.Text(_t(trackingNumber), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, letterSpacing: 1))),
        pw.Divider(thickness: 1),
        pw.Text('TO', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.Text(_t(a['name'] ?? order['customer_name']), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
        pw.Text(_t(addr), style: const pw.TextStyle(fontSize: 10.5)),
        pw.SizedBox(height: 2),
        pw.Text('Phone: ${_t(a['phone'] ?? order['phone'])}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.Divider(thickness: 1),
        pw.Row(children: [
          pw.Expanded(child: pw.Container(
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.2)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(cod > 0 ? 'COD - COLLECT' : 'PREPAID', style: const pw.TextStyle(fontSize: 8)),
              pw.Text(cod > 0 ? 'Rs ${money.format(cod)}' : 'Nothing to collect',
                  style: pw.TextStyle(fontSize: cod > 0 ? 16 : 11, fontWeight: pw.FontWeight.bold)),
            ]),
          )),
          pw.SizedBox(width: 6),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            if (weightKg != null) pw.Text('${money.format(weightKg)} kg', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('$pieces pc${pieces == 1 ? '' : 's'}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text(DateFormat('d MMM y').format(DateTime.now()), style: const pw.TextStyle(fontSize: 9)),
          ]),
        ]),
        pw.Spacer(),
        pw.Divider(thickness: 0.6),
        pw.Text('FROM: ${_t(storeName)}', style: const pw.TextStyle(fontSize: 9)),
      ]),
    ));
    return doc.save();
  }
}
