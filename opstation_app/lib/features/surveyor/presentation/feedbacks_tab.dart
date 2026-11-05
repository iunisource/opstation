import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/database/app_database.dart';
import '../services/survey_feedback.dart';

/// "Feedbacks" tab on Surveyed shops and Non-surveyed shops: every auditor's
/// feedback on the shops of that screen. Mine / All auditors, a period,
/// search, and a PDF of the period (the auditors' work).
class FeedbacksTab extends StatefulWidget {
  final List<Map<String, dynamic>> audits; // server + waiting on phone, newest first
  final Map<String, CustomersData> shops; // shops of this screen
  final Set<String> surveyed; // shop ids that have a survey
  final String? myId;
  final String orgName;
  final String title; // e.g. "Surveyed shops"
  final Future<void> Function() onRefresh;
  final bool showLocation; // Admin Settings → Auditor location tracking
  const FeedbacksTab({
    this.showLocation = true,
    super.key,
    required this.audits,
    required this.shops,
    required this.surveyed,
    required this.myId,
    required this.orgName,
    required this.title,
    required this.onRefresh,
  });
  @override
  State<FeedbacksTab> createState() => _FeedbacksTabState();
}

DateTime? _ts(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

class _FeedbacksTabState extends State<FeedbacksTab> with AutomaticKeepAliveClientMixin {
  bool _mine = true;
  String _q = '';
  late DateTimeRange _range;
  String _rangeLabel = 'This month';
  bool _exporting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month, now.day));
  }

  List<Map<String, dynamic>> get _rows {
    final from = DateTime(_range.start.year, _range.start.month, _range.start.day);
    final to = DateTime(_range.end.year, _range.end.month, _range.end.day).add(const Duration(days: 1));
    final q = _q.trim().toLowerCase();
    return [
      for (final a in widget.audits)
        if (widget.shops.containsKey('${a['customer_id']}') &&
            (!_mine || '${a['auditor_id']}' == widget.myId) &&
            _ts(a['audited_at']) != null &&
            !_ts(a['audited_at'])!.isBefore(from) &&
            _ts(a['audited_at'])!.isBefore(to) &&
            (q.isEmpty ||
                (widget.shops['${a['customer_id']}']!.shopName).toLowerCase().contains(q) ||
                (widget.shops['${a['customer_id']}']!.code).toLowerCase().contains(q) ||
                '${a['comment'] ?? ''}'.toLowerCase().contains(q) ||
                '${a['auditor_name'] ?? ''}'.toLowerCase().contains(q)))
          a
    ];
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final o in const ['Today', 'Last 7 days', 'This month', 'Last month', 'Pick dates…'])
            ListTile(title: Text(o), onTap: () => Navigator.pop(ctx, o)),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    final today = DateTime(now.year, now.month, now.day);
    DateTimeRange? r = switch (choice) {
      'Today' => DateTimeRange(start: today, end: today),
      'Last 7 days' => DateTimeRange(start: today.subtract(const Duration(days: 6)), end: today),
      'This month' => DateTimeRange(start: DateTime(now.year, now.month, 1), end: today),
      'Last month' => DateTimeRange(start: DateTime(now.year, now.month - 1, 1), end: DateTime(now.year, now.month, 0)),
      _ => null,
    };
    var label = choice;
    if (r == null) {
      r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: now, initialDateRange: _range);
      if (r == null) return;
      final f = DateFormat('d MMM');
      label = '${f.format(r.start)} – ${f.format(r.end)}';
    }
    setState(() {
      _range = r!;
      _rangeLabel = label;
    });
  }

  String _loc(Map<String, dynamic> a) {
    final d = (a['distance_m'] as num?)?.round();
    return switch ('${a['location_status']}') {
      'inside' => 'At shop',
      'outside' => d == null ? 'Away from shop' : '$d m away',
      'no_shop_location' => 'No shop location',
      _ => 'No GPS',
    };
  }

  String _result(dynamic r) => switch ('$r') {
        'issue' => 'Issue',
        'ok' => 'Matches',
        _ => 'Feedback',
      };

  Future<void> _export(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No feedback in this period.')));
      return;
    }
    setState(() => _exporting = true);
    try {
      final list = [...rows]..sort((a, b) => '${a['audited_at']}'.compareTo('${b['audited_at']}'));
      final df = DateFormat('d MMM yyyy');
      final tf = DateFormat('d MMM yyyy, h:mm a');
      final byAuditor = <String, List<Map<String, dynamic>>>{};
      for (final a in list) {
        byAuditor.putIfAbsent('${a['auditor_name'] ?? '-'}', () => []).add(a);
      }
      const head = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
      const cell = pw.TextStyle(fontSize: 7.5);
      pw.Widget table(List<String> h, List<List<String>> rows, Map<int, pw.TableColumnWidth> w) => pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: w,
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                children: [for (final x in h) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(x, style: head))],
              ),
              for (final r in rows)
                pw.TableRow(children: [for (final x in r) pw.Padding(padding: const pw.EdgeInsets.all(3), child: pw.Text(x, style: cell))]),
            ],
          );
      final doc = pw.Document();
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        maxPages: 500,
        build: (_) => [
          pw.Text(widget.orgName, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.Text('Auditor feedback · ${widget.title}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text('${df.format(_range.start)} to ${df.format(_range.end)}  ·  ${list.length} feedback  ·  '
              '${_mine ? 'My feedback' : 'All auditors'}${_q.trim().isEmpty ? '' : '  ·  search "${_q.trim()}"'}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
          pw.SizedBox(height: 10),
          pw.Text('By auditor', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          table(
            ['Auditor', 'Feedback', 'Shops', 'Days active', if (widget.showLocation) ...['At shop', 'Away / no location'], 'With photo'],
            [
              for (final e in byAuditor.entries)
                [
                  e.key,
                  '${e.value.length}',
                  '${e.value.map((a) => a['customer_id']).toSet().length}',
                  '${e.value.map((a) => df.format(_ts(a['audited_at'])!)).toSet().length}',
                  if (widget.showLocation) ...[
                    '${e.value.where((a) => a['location_status'] == 'inside').length}',
                    '${e.value.where((a) => a['location_status'] != 'inside').length}',
                  ],
                  '${e.value.where((a) => (a['photo_path'] ?? a['local_photo']) != null).length}',
                ]
            ],
            const {0: pw.FlexColumnWidth(2.2)},
          ),
          pw.SizedBox(height: 14),
          pw.Text('All feedback', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          table(
            ['Date', 'Auditor', 'Shop', if (widget.showLocation) 'Location', 'Feedback'],
            [
              for (final a in list)
                [
                  tf.format(_ts(a['audited_at'])!),
                  '${a['auditor_name'] ?? ''}',
                  () {
                    final s = widget.shops['${a['customer_id']}'];
                    return s == null
                        ? '${a['customer_id']}'
                        : '${s.shopName}\n${s.code}${widget.surveyed.contains(s.id) ? '' : ' · not surveyed'}';
                  }(),
                  if (widget.showLocation) _loc(a),
                  '${a['result'] == 'feedback' ? '' : '[${_result(a['result'])}] '}${a['comment'] ?? ''}'
                      '${(a['photo_path'] ?? a['local_photo']) != null ? '\n(photo attached)' : ''}',
                ]
            ],
            widget.showLocation
                ? const {
                    0: pw.FlexColumnWidth(1.4),
                    1: pw.FlexColumnWidth(1.2),
                    2: pw.FlexColumnWidth(2.4),
                    3: pw.FlexColumnWidth(1.1),
                    4: pw.FlexColumnWidth(3.6),
                  }
                : const {
                    0: pw.FlexColumnWidth(1.4),
                    1: pw.FlexColumnWidth(1.2),
                    2: pw.FlexColumnWidth(2.4),
                    3: pw.FlexColumnWidth(4.0),
                  },
          ),
        ],
      ));
      await Printing.sharePdf(
        bytes: await doc.save(),
        filename: 'auditor_feedback_${DateFormat('yyyyMMdd').format(_range.start)}_${DateFormat('yyyyMMdd').format(_range.end)}.pdf',
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create the PDF.')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c)),
      );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final hint = Theme.of(context).hintColor;
    final rows = _rows;
    final tf = DateFormat('d MMM, h:mm a');
    const green = Color(0xFF059669), red = Color(0xFFDC2626), blue = Color(0xFF2563EB), amber = Color(0xFFB45309);
    const grey = Color(0xFF475569);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _q = v),
          decoration: InputDecoration(
            hintText: 'Search shop, code, feedback or auditor',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          ChoiceChip(label: const Text('Mine'), selected: _mine, onSelected: (_) => setState(() => _mine = true)),
          const SizedBox(width: 6),
          ChoiceChip(label: const Text('All auditors'), selected: !_mine, onSelected: (_) => setState(() => _mine = false)),
          const SizedBox(width: 6),
          ActionChip(
            avatar: const Icon(Icons.date_range_outlined, size: 16),
            label: Text(_rangeLabel),
            onPressed: _pickRange,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(children: [
          Expanded(
            child: Text('${rows.length} feedback', style: TextStyle(fontSize: 12.5, color: hint)),
          ),
          TextButton.icon(
            onPressed: _exporting ? null : () => _export(rows),
            icon: _exporting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('PDF'),
          ),
        ]),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: rows.isEmpty
              ? ListView(children: const [
                  Padding(padding: EdgeInsets.all(40), child: Center(child: Text('No feedback here.'))),
                ])
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: rows.length,
                  itemBuilder: (_, i) {
                    final a = rows[i];
                    final s = widget.shops['${a['customer_id']}']!;
                    final at = _ts(a['audited_at']);
                    final hasPhoto = (a['photo_path'] ?? a['local_photo']) != null;
                    final inside = a['location_status'] == 'inside';
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(
                              child: Text(s.shopName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                            ),
                            const SizedBox(width: 8),
                            Text(at == null ? '' : tf.format(at), style: TextStyle(fontSize: 12, color: hint)),
                          ]),
                          if ('${a['comment'] ?? ''}'.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text('${a['comment']}'.trim(), style: const TextStyle(fontSize: 13.5)),
                            ),
                          const SizedBox(height: 8),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            _badge('${a['auditor_name'] ?? ''}', grey),
                            if (widget.showLocation) _badge(_loc(a), inside ? green : red),
                            if (a['result'] != 'feedback') _badge(_result(a['result']), a['result'] == 'issue' ? red : green),
                            if (!widget.surveyed.contains(s.id)) _badge('Not surveyed', amber),
                            if (a['_pending'] == true) _badge('Not sent yet', amber),
                            if (hasPhoto)
                              GestureDetector(
                                onTap: () => showFeedbackPhoto(context, a),
                                child: _badge('📷 Photo', blue),
                              ),
                          ]),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}
