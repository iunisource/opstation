import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show PdfGoogleFonts;

import '../../../core/format/money.dart';
import '../../../core/pdf/pdf_output.dart';
import 'time_in_market.dart';

/// Time in Market print — laid out like the screen (one card per day), not a
/// grid. [detail] adds "The day, in order" and the summary (single-day print).
Future<void> printTimDays(
  List<TimDay> days,
  TimSettings s, {
  String? orgName,
  required String rangeLabel,
  bool detail = false,
  String fileName = 'Time in Market',
}) async {
  if (days.isEmpty) return;
  pw.ThemeData? theme;
  try {
    theme = pw.ThemeData.withFont(base: await PdfGoogleFonts.notoSansRegular(), bold: await PdfGoogleFonts.notoSansBold());
  } catch (_) {}
  final doc = pw.Document(title: fileName, theme: theme);
  const pageW = 595.28 - 56; // A4 portrait minus margins
  final now = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());

  // Overview figures (several days only).
  final withStops = days.where((d) => d.visits > 0).toList();
  final avgIn = withStops.isEmpty
      ? Duration.zero
      : Duration(minutes: withStops.fold<int>(0, (a, d) => a + d.inMarket.inMinutes) ~/ withStops.length);
  final late = days.where((d) => d.lateStart(s)).length;
  final gaps = days.fold<int>(0, (a, d) => a + d.longGapCount(s));
  final early = days.where((d) => d.earlyClose(s)).length;

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(28, 26, 28, 22),
    footer: (ctx) => pw.Row(children: [
      pw.Text('Printed $now', style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
      pw.Spacer(),
      pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
    ]),
    build: (ctx) => [
      // Header
      pw.Container(height: 3, color: _blue, margin: const pw.EdgeInsets.only(bottom: 10)),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if ((orgName ?? '').isNotEmpty)
              pw.Text(orgName!, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.Text(detail && days.length == 1 ? 'Time in Market — ${days.first.name}' : 'Time in Market',
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          ]),
        ),
        pw.Text(rangeLabel, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _blue)),
      ]),
      pw.SizedBox(height: 3),
      pw.Text(
          'Working day ${TimSettings.hm(s.dayStart)}–${TimSettings.hm(s.dayEnd)}  ·  late if first stop after ${TimSettings.hm(s.lateAfter)}  ·  '
          'early if finished before ${TimSettings.hm(s.earlyBefore)}  ·  gaps over ${s.gapMin} min flagged',
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
      pw.SizedBox(height: 10),
      if (days.length > 1) ...[
        pw.Row(children: [
          _kpi('${days.length}', 'days out'),
          _kpi(timDur(avgIn), 'avg time in market'),
          _kpi(timDur(timAvgPerStop(days, s)), 'avg time per stop'),
          _kpi('$late', 'late starts', bad: late > 0),
          _kpi('$gaps', 'long gaps', warn: gaps > 0),
          _kpi('$early', 'closed early', bad: early > 0, last: true),
        ]),
        pw.SizedBox(height: 10),
      ],
      _legend(s, days.any((d) => d.role == 'driver'), days.any((d) => d.role != 'driver')),
      pw.SizedBox(height: 8),
      for (final d in days) ...[
        _card(d, s, pageW),
        if (detail) ..._detail(d, s),
      ],
      pw.SizedBox(height: 4),
      pw.Text('Worked out from route / delivery start and end and the time each stop was marked. '
          'Time spent inside each shop is not measured.',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
    ],
  ));
  final Uint8List bytes = await doc.save();
  await outputPdf(bytes, fileName);
}

const _blue = PdfColor.fromInt(0xFF1E3A8A);
const _red = PdfColor.fromInt(0xFFB91C1C);
const _amber = PdfColor.fromInt(0xFFB45309);
const _line = PdfColor.fromInt(0xFFE5E7EB);
const _muted = PdfColor.fromInt(0xFF6B7280);

PdfColor _pc(Color c) => PdfColor.fromInt(c.value);

pw.Widget _kpi(String v, String l, {bool bad = false, bool warn = false, bool last = false}) => pw.Expanded(
      child: pw.Container(
        margin: pw.EdgeInsets.only(right: last ? 0 : 6),
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(5)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(v, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold,
              color: bad ? _red : warn ? _amber : PdfColors.black)),
          pw.Text(l, style: const pw.TextStyle(fontSize: 7, color: _muted)),
        ]),
      ),
    );

pw.Widget _dot(PdfColor c, {double size = 7}) =>
    pw.Container(width: size, height: size, decoration: pw.BoxDecoration(color: c, shape: pw.BoxShape.circle));

pw.Widget _legend(TimSettings s, bool drivers, bool sales) {
  final kinds = <String>{
    if (sales) ...['visited', 'outside', 'not_verified'],
    if (drivers) ...['delivered', 'outside', 'failed'],
  };
  pw.Widget item(pw.Widget mark, String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(right: 12),
        child: pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          mark,
          pw.SizedBox(width: 3),
          pw.Text(t, style: const pw.TextStyle(fontSize: 7, color: _muted)),
        ]),
      );
  return pw.Wrap(runSpacing: 3, children: [
    for (final k in kinds) item(_dot(_pc(timKindColor(k))), timKindLabel(k)),
    item(pw.Container(width: 12, height: 7, color: const PdfColor.fromInt(0x33B91C1C)), 'Gap over ${s.gapMin} min'),
    item(pw.Container(width: 12, height: 7, color: const PdfColor.fromInt(0x221E3A8A)),
        'Working day ${TimSettings.hm(s.dayStart)}–${TimSettings.hm(s.dayEnd)}'),
  ]);
}

pw.Widget _fig(String k, String v, {bool bad = false}) => pw.Padding(
      padding: const pw.EdgeInsets.only(right: 14, bottom: 2),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(k, style: const pw.TextStyle(fontSize: 6.8, color: _muted)),
        pw.Text(v, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: bad ? _red : PdfColors.black)),
      ]),
    );

pw.Widget _tag(String t, Color c) => pw.Container(
      margin: const pw.EdgeInsets.only(right: 4),
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromInt((c.value & 0x00FFFFFF) | 0x1F000000),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Text(t, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: _pc(c))),
    );

/// One day as a card: name / date, the figures, flags, timeline, and (detail)
/// the day in order plus the summary.
pw.Widget _card(TimDay d, TimSettings s, double pageW) {
  final inner = pageW - 20;
  final lg = d.longestGap(s);
  final head = pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(d.name, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text([
            if (d.role == 'driver') 'Driver',
            if (d.routes.isNotEmpty) d.routes.join(', '),
          ].join(' · '), style: const pw.TextStyle(fontSize: 8, color: _muted)),
        ]),
      ),
      pw.Text(DateFormat('EEE, d MMM yyyy').format(d.date),
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _blue)),
    ]),
    pw.SizedBox(height: 5),
    pw.Wrap(children: [
      _fig('Start', timClock(d.start)),
      _fig('First stop', timClock(d.first), bad: d.lateStart(s)),
      _fig('Last stop', timClock(d.last)),
      _fig('End', d.open ? 'out' : timClock(d.end), bad: d.earlyClose(s)),
      _fig('In market', timDur(d.inMarket)),
      _fig('Stops', d.totalStops > 0 ? '${d.visits} / ${d.totalStops}' : '${d.visits}'),
      _fig('Per hour', d.perHour.toStringAsFixed(1)),
      _fig('Per stop', timDur(d.avgPerStop(s))),
      _fig('Longest gap', timDur(lg), bad: (lg?.inMinutes ?? 0) > s.gapMin),
    ]),
    pw.SizedBox(height: 4),
    pw.Row(children: [for (final (t, c) in timFlags(d, s)) _tag(t, c)]),
    pw.SizedBox(height: 6),
    _timeline(d, s, inner),
  ]);

  return pw.Container(
    margin: const pw.EdgeInsets.only(bottom: 8),
    padding: const pw.EdgeInsets.all(10),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
    child: head,
  );
}

/// The day as a bar, like on screen.
pw.Widget _timeline(TimDay day, TimSettings s, double w) {
  int m(DateTime t) => t.hour * 60 + t.minute;
  var lo = 7 * 60, hi = 21 * 60;
  for (final t in [day.start, day.end, day.first, day.last]) {
    if (t == null) continue;
    if (m(t) < lo) lo = (m(t) ~/ 60) * 60;
    if (m(t) > hi) hi = ((m(t) ~/ 60) + 1) * 60;
  }
  double x(int mins) => ((mins - lo) / (hi - lo)).clamp(0.0, 1.0) * w;
  double wd(double v) => v < 2 ? 2 : (v > w ? w : v);
  final kids = <pw.Widget>[
    pw.Positioned(left: 0, top: 13, child: pw.Container(width: w, height: 4,
        decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0xFFEEF2F7), borderRadius: pw.BorderRadius.circular(2)))),
    pw.Positioned(left: x(s.dayStart), top: 11, child: pw.Container(width: wd(x(s.dayEnd) - x(s.dayStart)), height: 8,
        decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0x141E3A8A),
            border: pw.Border.all(color: const PdfColor.fromInt(0x591E3A8A), width: 0.5), borderRadius: pw.BorderRadius.circular(2)))),
  ];
  if (day.start != null) {
    final en = day.end ?? (day.open ? DateTime.now() : day.last) ?? day.start!;
    kids.add(pw.Positioned(left: x(m(day.start!)), top: 13, child: pw.Container(
        width: wd(x(m(en)) - x(m(day.start!))), height: 4,
        decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0x591E3A8A), borderRadius: pw.BorderRadius.circular(2)))));
  }
  for (final g in day.gaps(s)) {
    kids.add(pw.Positioned(left: x(m(g.from)), top: 10, child: pw.Container(
        width: wd(x(m(g.to)) - x(m(g.from))), height: 10,
        decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0x29B91C1C),
            border: pw.Border.all(color: const PdfColor.fromInt(0x80B91C1C), width: 0.5), borderRadius: pw.BorderRadius.circular(2)))));
  }
  for (final ev in day.sorted) {
    kids.add(pw.Positioned(left: x(m(ev.at)) - 3.5, top: 11.5, child: pw.Container(width: 7, height: 7,
        decoration: pw.BoxDecoration(color: _pc(timKindColor(ev.kind)), shape: pw.BoxShape.circle,
            border: pw.Border.all(color: PdfColors.white, width: 1)))));
  }
  for (final (t, l) in [(day.start, 'Start'), (day.end, 'End')]) {
    if (t == null) continue;
    final px = x(m(t)) - 10;
    kids.add(pw.Positioned(left: px < 0 ? 0 : (px > w - 20 ? w - 20 : px), top: 0,
        child: pw.Text(l, style: const pw.TextStyle(fontSize: 6.5, color: _muted))));
  }
  final step = (hi - lo) > 12 * 60 ? 120 : 60;
  for (var h = lo; h <= hi; h += step) {
    final px = x(h) - 10;
    kids.add(pw.Positioned(left: px < 0 ? 0 : (px > w - 22 ? w - 22 : px), top: 23,
        child: pw.Text(TimSettings.hm(h), style: const pw.TextStyle(fontSize: 6.5, color: _muted))));
  }
  return pw.SizedBox(width: w, height: 32, child: pw.Stack(children: kids));
}

/// "The day, in order" + "Summary" (side by side), like the expanded tile.
List<pw.Widget> _detail(TimDay day, TimSettings s) {
  final gaps = day.gaps(s);
  pw.Widget line(String t, String text, {bool gap = false, PdfColor? dot, PdfColor? color}) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: pw.BoxDecoration(
          color: gap ? const PdfColor.fromInt(0x10B91C1C) : null,
          border: const pw.Border(
            left: pw.BorderSide(color: _line, width: 0.5),
            right: pw.BorderSide(color: _line, width: 0.5),
            bottom: pw.BorderSide(color: _line, width: 0.5),
          ),
        ),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 30, child: pw.Text(t, style: const pw.TextStyle(fontSize: 8, color: _muted))),
          if (dot != null) pw.Padding(padding: const pw.EdgeInsets.only(top: 2.5, right: 5), child: _dot(dot, size: 5.5)),
          pw.Expanded(child: pw.Text(text, style: pw.TextStyle(fontSize: 8.2,
              fontWeight: gap ? pw.FontWeight.bold : null, color: gap ? _red : color))),
        ]),
      );
  final lines = <pw.Widget>[];
  if (day.start != null) lines.add(line(timClock(day.start), day.role == 'driver' ? 'Delivery started' : 'Route started'));
  var gi = 0;
  for (final ev in day.sorted) {
    while (gi < gaps.length && !gaps[gi].to.isAfter(ev.at)) {
      final g = gaps[gi++];
      lines.add(line(timClock(g.from),
          g.beforeFirst ? '${timDur(g.length)} before the first stop' : '${timDur(g.length)} gap — nothing marked until ${timClock(g.to)}',
          gap: true));
    }
    lines.add(line(timClock(ev.at),
        '${ev.place} · ${timKindLabel(ev.kind)}${ev.amount > 0 ? ' · Rs ${money(ev.amount)}' : ''}',
        dot: _pc(timKindColor(ev.kind))));
  }
  if (day.end != null && !day.open) {
    lines.add(line(timClock(day.end), day.role == 'driver' ? 'Delivery completed' : 'Route ended'));
  } else if (day.open) {
    lines.add(line('', 'Still out', color: _blue));
  }

  final summary = <(String, String, bool)>[
    ('Time in market (first to last stop)', timDur(day.inMarket), false),
    if (day.routeOpen != null) ('Route open (start to end)', timDur(day.routeOpen), false),
    ('Time in gaps over ${s.gapMin} min', timDur(day.lostToGaps(s)), gaps.isNotEmpty),
    ('Stops · per hour in market', '${day.visits} · ${day.perHour.toStringAsFixed(1)}', false),
    ('Average time per stop', timDur(day.avgPerStop(s)), false),
    if (day.totalStops > 0) ('Planned stops not marked', '${(day.totalStops - day.visits).clamp(0, 100000)} of ${day.totalStops}', false),
    if (day.collected > 0) ('Collected', 'Rs ${money(day.collected)}', false),
  ];
  pw.Widget title(String t) => pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Text(t, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)));
  final box = pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(5));

  return [
    pw.SizedBox(height: 2),
    title('Summary'),
    pw.Container(
      decoration: box,
      child: pw.Column(children: [
        for (final (l, v, bad) in summary)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _line, width: 0.5))),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text(l, style: const pw.TextStyle(fontSize: 8.2))),
              pw.Text(v, style: pw.TextStyle(fontSize: 8.2, fontWeight: pw.FontWeight.bold, color: bad ? _red : null)),
            ]),
          ),
      ]),
    ),
    pw.SizedBox(height: 10),
    title('The day, in order'),
    pw.Container(height: 0.5, color: _line),
    ...lines,
    pw.SizedBox(height: 12),
  ];
}
