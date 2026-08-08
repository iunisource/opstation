import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Team report PDFs — same design language as IntelligencePdfService:
/// org header bar with title + date, grey bordered tables, page footer.
class TeamReportPdf {
  /// Period summary for a member: trips (salesperson) or survey days
  /// (surveyor), with a TOTAL row.
  static Future<Uint8List> periodReport({
    required String orgName,
    required String memberName,
    required String period,
    required bool surveyMode,
    List<Map<String, dynamic>> trips = const [],
    List<Map<String, dynamic>> surveyDays = const [],
  }) async {
    final pdf = pw.Document();
    final theme = await _loadTheme();
    final df = DateFormat('d MMM yyyy');
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: theme,
        header: (ctx) => _header(orgName, 'Team Report — $memberName', _today()),
        footer: (ctx) => _footer(ctx),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Text('Period: $period',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.SizedBox(height: 12),
          if (surveyMode)
            _surveyTable(surveyDays, df)
          else
            _tripsTable(trips, df),
        ],
      ),
    );
    return pdf.save();
  }

  /// Detailed Market Visit Report for ONE trip: header info + every visit
  /// with time, shop, status, amount and receipt.
  static Future<Uint8List> marketVisitReport({
    required String orgName,
    required String salesperson,
    required Map<String, dynamic> trip,
    required List<Map<String, dynamic>> visits,
    required Map<String, Map<String, dynamic>> customers,
  }) async {
    final pdf = pw.Document();
    final theme = await _loadTheme();
    final df = DateFormat('d MMM yyyy');
    final tf = DateFormat('HH:mm');

    final started = trip['started_at'] != null
        ? DateTime.parse(trip['started_at'] as String).toLocal()
        : null;
    final ended = trip['ended_at'] != null
        ? DateTime.parse(trip['ended_at'] as String).toLocal()
        : null;
    final status = ended == null
        ? 'Active'
        : ((trip['close_reason'] as String?) == 'cutoff'
            ? 'Cut-off'
            : 'Completed');
    final verified = visits.where((v) => v['status'] == 'verified').length;
    final collected =
        visits.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));

    pw.Widget kv(String k, String v) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 2),
          child: pw.Row(children: [
            pw.SizedBox(
                width: 90,
                child: pw.Text(k,
                    style: const pw.TextStyle(
                        fontSize: 9, color: PdfColors.grey600))),
            pw.Text(v,
                style:
                    pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          ]),
        );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        theme: theme,
        header: (ctx) => _header(orgName, 'Market Visit Report', _today()),
        footer: (ctx) => _footer(ctx),
        build: (ctx) => [
          pw.SizedBox(height: 12),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  kv('Salesperson', salesperson),
                  kv('Route', trip['route_name'] as String? ?? '—'),
                  kv('Date', started != null ? df.format(started) : '—'),
                  kv(
                      'Time',
                      started == null
                          ? '—'
                          : '${tf.format(started)}${ended != null ? ' → ${tf.format(ended)}' : ' (ongoing)'}'),
                  kv('Status', status),
                ],
              ),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Row(children: [
                  _bigStat('${visits.length}', 'VISITS'),
                  pw.SizedBox(width: 18),
                  _bigStat('$verified', 'VERIFIED'),
                  pw.SizedBox(width: 18),
                  _bigStat('Rs $collected', 'COLLECTED'),
                ]),
              ),
            ],
          ),
          pw.SizedBox(height: 14),
          if (visits.isEmpty)
            pw.Text('No visits recorded on this trip.',
                style: const pw.TextStyle(color: PdfColors.grey600))
          else
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
              columnWidths: const {
                0: pw.FixedColumnWidth(40),
                1: pw.FlexColumnWidth(3),
                2: pw.FixedColumnWidth(55),
                3: pw.FixedColumnWidth(60),
                4: pw.FixedColumnWidth(60),
                5: pw.FlexColumnWidth(2),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                  children: [
                    _th('Time'),
                    _th('Shop'),
                    _th('Status'),
                    _th('Amount', right: true),
                    _th('Receipt'),
                    _th('Notes'),
                  ],
                ),
                ...visits.map((v) {
                  final ts = v['timestamp'] != null
                      ? DateTime.parse(v['timestamp'] as String).toLocal()
                      : null;
                  final cust = customers[v['customer_id']];
                  final name = cust?['shop_name'] as String? ?? '(unknown)';
                  final code = cust?['code'] as String? ?? '';
                  final st = v['status'] as String? ?? '';
                  final stLabel = switch (st) {
                    'verified' => 'Verified',
                    'outside' => 'Outside',
                    'noLocation' => 'No location',
                    'skipped' => 'Skipped',
                    _ => st,
                  };
                  final stColor = switch (st) {
                    'verified' => PdfColors.green700,
                    'outside' => PdfColors.orange700,
                    'noLocation' => PdfColors.red700,
                    _ => PdfColors.grey600,
                  };
                  final amount = (v['amount'] as int?) ?? 0;
                  return pw.TableRow(children: [
                    _td(ts == null ? '—' : tf.format(ts)),
                    _padCell(pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(name, style: const pw.TextStyle(fontSize: 8)),
                          if (code.isNotEmpty)
                            pw.Text(code,
                                style: const pw.TextStyle(
                                    fontSize: 6.5, color: PdfColors.grey600)),
                        ])),
                    _padCell(pw.Text(stLabel,
                        style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                            color: stColor))),
                    _padCell(pw.Text(amount > 0 ? 'Rs $amount' : '-',
                        textAlign: pw.TextAlign.right,
                        style: pw.TextStyle(
                            fontSize: 8, fontWeight: pw.FontWeight.bold))),
                    _td((v['receipt_number'] as String?) ?? '-'),
                    _td((v['notes'] as String?) ?? ''),
                  ]);
                }),
              ],
            ),
          ..._receiptGaps(visits),
        ],
      ),
    );
    return pdf.save();
  }

  /// Admin-only "Missing receipts" line — skips in the receipt sequence that
  /// often mean a collection was made but never entered. Big jumps (> 20) are
  /// treated as a new receipt book and ignored. Returns [] (renders nothing)
  /// when the sequence is clean.
  static List<int> _receiptSlipNumbers(String raw) {
    final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
    final out = <int>[];
    int? prevFull;
    for (final t in toks) {
      final n = int.parse(t);
      final prevLen = prevFull?.toString().length ?? 0;
      if (prevFull == null || t.length >= prevLen) {
        out.add(n); prevFull = n;
      } else {
        var p10 = 1; for (var i = 0; i < t.length; i++) p10 *= 10;
        final e = (prevFull - (prevFull % p10)) + n;
        out.add(e); prevFull = e;
      }
    }
    return out;
  }

  static List<pw.Widget> _receiptGaps(List<Map<String, dynamic>> visits) {
    final nums = <int>[];
    for (final v in visits) {
      nums.addAll(_receiptSlipNumbers((v['receipt_number'] as String?) ?? ''));
    }
    nums.sort();
    final missing = <int>[];
    for (var i = 1; i < nums.length; i++) {
      final gap = nums[i] - nums[i - 1];
      if (gap > 1 && gap <= 20) {
        for (var n = nums[i - 1] + 1; n < nums[i]; n++) missing.add(n);
      }
    }
    if (missing.isEmpty) return [];
    return [
      pw.SizedBox(height: 8),
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: pw.BoxDecoration(
          color: PdfColor.fromInt(0xFFFFF7ED),
          border:
              pw.Border.all(color: PdfColor.fromInt(0xFFFB923C), width: 0.5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.RichText(
          text: pw.TextSpan(children: [
            pw.TextSpan(
                text: 'Missing receipts:  ',
                style: pw.TextStyle(
                    fontSize: 9.5,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromInt(0xFF9A3412))),
            pw.TextSpan(
                text: missing.join(', '),
                style: pw.TextStyle(
                    fontSize: 9.5, color: PdfColor.fromInt(0xFF9A3412))),
          ]),
        ),
      ),
    ];
  }

  // ── tables for the period report ─────────────────────────────────────────

  static pw.Widget _tripsTable(
      List<Map<String, dynamic>> trips, DateFormat df) {
    if (trips.isEmpty) {
      return pw.Text('Nothing to report for this period.',
          style: const pw.TextStyle(color: PdfColors.grey600));
    }
    final totVisits =
        trips.fold<int>(0, (s, t) => s + ((t['_visits'] as int?) ?? 0));
    final totAmt =
        trips.fold<int>(0, (s, t) => s + ((t['_amount'] as int?) ?? 0));
    String status(Map<String, dynamic> t) => t['ended_at'] == null
        ? 'Active'
        : ((t['close_reason'] as String?) == 'cutoff' ? 'Cut-off' : 'Completed');
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: const {
        0: pw.FixedColumnWidth(65),
        1: pw.FlexColumnWidth(3),
        2: pw.FixedColumnWidth(45),
        3: pw.FixedColumnWidth(70),
        4: pw.FixedColumnWidth(60),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _th('Date'),
            _th('Route'),
            _th('Visits', right: true),
            _th('Collected', right: true),
            _th('Status'),
          ],
        ),
        ...trips.map((t) {
          final s =
              DateTime.tryParse(t['started_at'] as String? ?? '')?.toLocal();
          return pw.TableRow(children: [
            _td(s == null ? '—' : df.format(s)),
            _td(t['route_name'] as String? ?? '—'),
            _td('${t['_visits'] ?? 0}', right: true),
            _td('Rs ${t['_amount'] ?? 0}', right: true, bold: true),
            _td(status(t)),
          ]);
        }),
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _td('TOTAL', bold: true),
            _td(''),
            _td('$totVisits', right: true, bold: true),
            _td('Rs $totAmt', right: true, bold: true),
            _td(''),
          ],
        ),
      ],
    );
  }

  static pw.Widget _surveyTable(
      List<Map<String, dynamic>> days, DateFormat df) {
    if (days.isEmpty) {
      return pw.Text('Nothing to report for this period.',
          style: const pw.TextStyle(color: PdfColors.grey600));
    }
    final totShops = <String>{};
    var totAudits = 0, totSpots = 0;
    for (final r in days) {
      totShops.addAll((r['shops'] as Set).cast<String>());
      totAudits += r['audits'] as int;
      totSpots += r['spottings'] as int;
    }
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(2),
        1: pw.FlexColumnWidth(1),
        2: pw.FlexColumnWidth(1),
        3: pw.FlexColumnWidth(1),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _th('Date'),
            _th('Shops', right: true),
            _th('Shelf Checks', right: true),
            _th('Spottings', right: true),
          ],
        ),
        ...days.map((r) => pw.TableRow(children: [
              _td(df.format(DateTime.parse(r['day'] as String))),
              _td('${(r['shops'] as Set).length}', right: true),
              _td('${r['audits']}', right: true),
              _td('${r['spottings']}', right: true),
            ])),
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey100),
          children: [
            _td('TOTAL', bold: true),
            _td('${totShops.length}', right: true, bold: true),
            _td('$totAudits', right: true, bold: true),
            _td('$totSpots', right: true, bold: true),
          ],
        ),
      ],
    );
  }

  // ── shared helpers (same look as IntelligencePdfService) ─────────────────

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static Future<pw.ThemeData?> _loadTheme() async {
    try {
      final font = await PdfGoogleFonts.notoSansRegular();
      final fontBold = await PdfGoogleFonts.notoSansBold();
      return pw.ThemeData.withFont(base: font, bold: fontBold);
    } catch (_) {
      return null;
    }
  }

  static pw.Widget _header(String orgName, String title, String dateStr) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
            bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.5)),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(orgName,
                  style: pw.TextStyle(
                      fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text(title,
                  style: const pw.TextStyle(
                      fontSize: 18, color: PdfColors.grey800)),
            ],
          ),
          pw.Text(dateStr,
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
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

  static pw.Widget _bigStat(String value, String label) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(value,
              style:
                  pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.Text(label,
              style:
                  const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
        ],
      );

  static pw.Widget _padCell(pw.Widget child) =>
      pw.Padding(padding: const pw.EdgeInsets.all(6), child: child);

  static pw.Widget _th(String text, {bool right = false}) => _padCell(
        pw.Text(text,
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
      );

  static pw.Widget _td(String text, {bool right = false, bool bold = false}) =>
      _padCell(
        pw.Text(text,
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(
                fontSize: 8,
                fontWeight: bold ? pw.FontWeight.bold : null)),
      );
}
