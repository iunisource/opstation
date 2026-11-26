import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// The approved copy of one reimbursement, as a PDF the salesperson can keep or share.
class ApprovedExpensePdfBuilder {
  static const _brand = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _green = PdfColor.fromInt(0xFF059669);
  static const _bg = PdfColor.fromInt(0xFFF3F4F6);

  static const _m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String date(dynamic v) {
    final d = DateTime.tryParse('$v');
    if (d == null) return '';
    final l = d.isUtc ? d.toLocal() : d;
    return '${l.day} ${_m[l.month - 1]} ${l.year}';
  }

  static String rs(num n) {
    final s = n.round().abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return 'Rs ${n < 0 ? '-' : ''}$b';
  }

  static num? _n(dynamic v) => v is num ? v : num.tryParse('${v ?? ''}');

  static String kmText(num k) => k % 1 == 0 ? k.toStringAsFixed(0) : k.toStringAsFixed(2);

  static Future<List<int>> build({required Map<String, dynamic> claim, String? orgName}) async {
    final c = claim;
    final paid = c['status'] == 'paid';
    final lines = [for (final l in (c['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
    final amount = _n(paid ? (c['paid_amount'] ?? c['amount']) : c['amount']);
    final rate = _n(c['rate']);
    final unpaidKm = _n(c['unpaid_km']) ?? _n(c['km']);
    final allow = _n(c['allowance_amount']);
    final claimed = _n(c['claimed_amount']);
    final note = '${c['adjust_note'] ?? ''}'.trim();
    final org = (orgName ?? '').trim();

    pw.Widget kv(String k, String v, {bool bold = false}) => v.trim().isEmpty
        ? pw.SizedBox()
        : pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 3),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.SizedBox(width: 120, child: pw.Text(k, style: const pw.TextStyle(fontSize: 10, color: _muted))),
              pw.Expanded(
                  child: pw.Text(v,
                      style: pw.TextStyle(
                          fontSize: 10.5, color: _ink, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal))),
            ]),
          );

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(32, 32, 32, 32),
        footer: (ctx) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('${org.isEmpty ? 'Opstation' : org} - approved copy',
                style: const pw.TextStyle(fontSize: 8.5, color: _muted)),
            pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                style: const pw.TextStyle(fontSize: 8.5, color: _muted)),
          ]),
        ),
        build: (ctx) => [
          if (org.isNotEmpty)
            pw.Text(org, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _brand)),
          pw.SizedBox(height: 2),
          pw.Text('Reimbursement - Approved Copy',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.SizedBox(height: 4),
          pw.Container(height: 2, color: _brand),
          pw.SizedBox(height: 12),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(color: _bg, borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text(paid ? 'PAID' : 'APPROVED - TO BE PAID',
                    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _green)),
                pw.SizedBox(height: 3),
                pw.Text(amount == null ? '-' : rs(amount),
                    style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: _ink)),
              ]),
              pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                pw.Text('${c['claimant_name'] ?? ''}',
                    style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _ink)),
                if ('${c['advice_number'] ?? ''}'.isNotEmpty)
                  pw.Text('Advice ${c['advice_number']}', style: const pw.TextStyle(fontSize: 10, color: _muted)),
              ]),
            ]),
          ),
          pw.SizedBox(height: 12),
          kv('Employee', '${c['claimant_name'] ?? ''}'),
          kv('Approved on', date(c['decided_at'])),
          kv('Approved by', '${c['decided_by_name'] ?? ''}'),
          if (paid) kv('Paid on', date(c['paid_on'])),
          if (paid) kv('Method', '${c['paid_method'] ?? ''}'),
          if (paid) kv('Reference', '${c['paid_ref'] ?? ''}'),
          pw.SizedBox(height: 10),
          pw.Text('Calculation', style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold, color: _brand)),
          pw.SizedBox(height: 4),
          pw.Divider(color: _rule, height: 1),
          if (unpaidKm != null) kv('Distance', '${kmText(unpaidKm)} km'),
          if (rate != null) kv('Rate', 'Rs $rate / km'),
          if (unpaidKm != null && rate != null) kv('Distance amount', rs(unpaidKm * rate)),
          if (allow != null && allow > 0) kv('Allowance', rs(allow)),
          if (claimed != null && amount != null && claimed.round() != amount.round()) kv('Worked out', rs(claimed)),
          kv('Approved amount', amount == null ? '' : rs(amount), bold: true),
          if (note.isNotEmpty) kv('Adjustment note', note),
          if (lines.isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Text('Expense dates', style: pw.TextStyle(fontSize: 11.5, fontWeight: pw.FontWeight.bold, color: _brand)),
            pw.SizedBox(height: 4),
            pw.Table(
              border: const pw.TableBorder(
                  horizontalInside: pw.BorderSide(color: _rule, width: 0.5), bottom: pw.BorderSide(color: _rule, width: 0.5)),
              columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1)},
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: _bg),
                  children: [
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text('Date', style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold))),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Align(
                            alignment: pw.Alignment.centerRight,
                            child: pw.Text('Km', style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)))),
                  ],
                ),
                for (final l in lines)
                  pw.TableRow(children: [
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Text(date(l['day']), style: const pw.TextStyle(fontSize: 10))),
                    pw.Padding(
                        padding: const pw.EdgeInsets.all(5),
                        child: pw.Align(
                            alignment: pw.Alignment.centerRight,
                            child: pw.Text(_n(l['km']) == null ? '${l['km'] ?? ''}' : kmText(_n(l['km'])!),
                                style: const pw.TextStyle(fontSize: 10)))),
                  ]),
              ],
            ),
          ],
          pw.SizedBox(height: 28),
          pw.Text('This is a system-generated copy of an approved reimbursement.',
              style: const pw.TextStyle(fontSize: 8.5, color: _muted)),
        ],
      ),
    );
    return doc.save();
  }
}
