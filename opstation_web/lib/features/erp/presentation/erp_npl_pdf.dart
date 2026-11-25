import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Print / PDF of one New Product Launch: summary, scheme results and the outlet table.
class NplPdf {
  NplPdf._();
  static const _navy = PdfColor.fromInt(0xFF0B1B3A);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static final _num = NumberFormat('#,##0.##');
  static final _d = DateFormat('d MMM yyyy');
  static final _stamp = DateFormat('d MMM yyyy, HH:mm');

  static String _s(Object? v) => (v == null ? '' : '$v')
      .replaceAll('–', '-').replaceAll('—', '-').replaceAll('→', '->')
      .replaceAll('‘', "'").replaceAll('’', "'").replaceAll('“', '"').replaceAll('”', '"');
  static double _n(Object? v) => (v as num?)?.toDouble() ?? 0;
  static String _date(Object? v) {
    if (v == null) return '-';
    final d = DateTime.tryParse('$v');
    return d == null ? '$v' : _d.format(d);
  }

  static Future<Uint8List> build({
    required Map<String, dynamic> launch,
    required List<Map<String, dynamic>> outlets,
    required List<Map<String, dynamic>> schemes,
    required String viewLabel,
    required String orgName,
    required String preparedBy,
  }) async {
    final total = outlets.length;
    final covered = outlets.where((o) => _n(o['orders']) > 0).length;
    final repeat = outlets.where((o) => _n(o['orders']) >= 2).length;
    final qty = outlets.fold<double>(0, (a, o) => a + _n(o['qty']));
    final value = outlets.fold<double>(0, (a, o) => a + _n(o['value']));
    final tq = _n(launch['target_qty']);
    final tv = _n(launch['target_value']);
    final status = '${launch['status']}';
    final statusLabel = status == 'void' ? 'VOID' : status == 'closed' ? 'Closed' : 'Active';

    pw.Widget kpi(String t, String big, String sub) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(8),
            margin: const pw.EdgeInsets.only(right: 6),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _rule), borderRadius: pw.BorderRadius.circular(5)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(t, style: const pw.TextStyle(fontSize: 8, color: _muted)),
              pw.SizedBox(height: 3),
              pw.Text(big, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text(sub, style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
            ]),
          ),
        );

    final shown = outlets;
    final pdf = pw.Document();
    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 34),
      footer: (c) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Prepared by ${_s(preparedBy)}  |  ${_stamp.format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 8, color: _muted)),
        pw.Text('Page ${c.pageNumber} / ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _muted)),
      ]),
      build: (c) => [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(_s(orgName), style: pw.TextStyle(fontSize: 10, color: _muted, fontWeight: pw.FontWeight.bold)),
          pw.Text('NEW PRODUCT LAUNCH', style: pw.TextStyle(fontSize: 10, color: _navy, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 6),
        pw.Text(_s(launch['name']), style: pw.TextStyle(fontSize: 20, color: _navy, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 3),
        pw.Text(
            '${_s(launch['product_name'])}  |  ${_date(launch['start_date'])} to ${launch['end_date'] == null ? 'open' : _date(launch['end_date'])}  |  Status: $statusLabel',
            style: const pw.TextStyle(fontSize: 10, color: _muted)),
        if (status == 'void')
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
                'Voided ${_stamp.format(DateTime.tryParse('${launch['voided_at']}')?.toLocal() ?? DateTime.now())} by ${_s(launch['voided_by'])}. Reason: ${_s(launch['void_reason'])}',
                style: pw.TextStyle(fontSize: 9, color: PdfColors.red800, fontWeight: pw.FontWeight.bold)),
          ),
        if (_s(launch['notes']).isNotEmpty)
          pw.Padding(padding: const pw.EdgeInsets.only(top: 4), child: pw.Text(_s(launch['notes']), style: const pw.TextStyle(fontSize: 9))),
        pw.SizedBox(height: 12),
        pw.Row(children: [
          kpi('Outlets covered', '$covered / $total', total > 0 ? '${(covered * 100 / total).toStringAsFixed(0)}% of target outlets' : 'No target outlets'),
          kpi('Repeat outlets', '$repeat', covered > 0 ? '${(repeat * 100 / covered).toStringAsFixed(0)}% of covered' : 'Ordered 2+ times'),
          kpi('Quantity sold', _num.format(qty), tq > 0 ? 'Target ${_num.format(tq)}' : 'No target set'),
          kpi('Value sold', 'Rs ${_num.format(value)}', tv > 0 ? 'Target Rs ${_num.format(tv)}' : 'No target set'),
        ]),
        if (schemes.isNotEmpty) ...[
          pw.SizedBox(height: 14),
          pw.Text('Launch schemes', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _navy)),
          pw.SizedBox(height: 4),
          pw.TableHelper.fromTextArray(
            headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
            border: pw.TableBorder.symmetric(inside: const pw.BorderSide(color: _rule, width: .4)),
            cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
            headers: ['Scheme', 'Times applied', 'Free qty given', 'Discount given (Rs)'],
            data: [
              for (final s in schemes)
                [_s(s['name']), '${_n(s['times']).toInt()}', _num.format(_n(s['free_qty'])), _num.format(_n(s['discount']))],
            ],
          ),
        ],
        pw.SizedBox(height: 14),
        pw.Text('Outlets  ($viewLabel, ${shown.length})',
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _navy)),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
          border: pw.TableBorder.symmetric(inside: const pw.BorderSide(color: _rule, width: .4)),
          cellAlignments: {3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          columnWidths: {
            0: const pw.FlexColumnWidth(3.2), 1: const pw.FlexColumnWidth(1.1), 2: const pw.FlexColumnWidth(1.6),
            3: const pw.FlexColumnWidth(.9), 4: const pw.FlexColumnWidth(1), 5: const pw.FlexColumnWidth(1.4),
            6: const pw.FlexColumnWidth(1.4), 7: const pw.FlexColumnWidth(1.4), 8: const pw.FlexColumnWidth(1.1),
          },
          headers: ['Outlet', 'Code', 'Group', 'Orders', 'Qty', 'Value (Rs)', 'First order', 'Last order', 'Status'],
          data: [
            for (final o in shown)
              [
                _s(o['shop_name']), _s(o['code']), _s(o['group_name']),
                '${_n(o['orders']).toInt()}', _num.format(_n(o['qty'])), _num.format(_n(o['value'])),
                _date(o['first_date']), _date(o['last_date']),
                _n(o['orders']) == 0 ? 'Not yet' : _n(o['orders']) == 1 ? 'Ordered' : 'Repeat',
              ],
          ],
        ),
      ],
    ));
    return pdf.save();
  }
}
