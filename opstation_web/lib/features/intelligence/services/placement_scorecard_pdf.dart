import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'placement_scorecard.dart';

/// The SKU Placement Scorecard: one page of headline numbers and the ranking of every SKU by how well it is
/// displayed in the shops audited — made to be shared with the sales team, so it explains itself (what the
/// score means, how to read the colours, which SKUs need attention) and needs no other screen to understand.
class PlacementScorecardPdf {
  PlacementScorecardPdf._();

  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);
  static const _track = PdfColor.fromInt(0xFFE5E7EB);

  static const _green = PdfColor.fromInt(0xFF059669);
  static const _greenTint = PdfColor.fromInt(0xFFD1FAE5);
  static const _amber = PdfColor.fromInt(0xFFD97706);
  static const _amberTint = PdfColor.fromInt(0xFFFEF3C7);
  static const _red = PdfColor.fromInt(0xFFDC2626);
  static const _redTint = PdfColor.fromInt(0xFFFEE2E2);
  static const _grey = PdfColor.fromInt(0xFF9CA3AF);

  static PdfColor bandColor(ScoreBand b) {
    switch (b) {
      case ScoreBand.strong:
        return _green;
      case ScoreBand.average:
        return _amber;
      case ScoreBand.weak:
        return _red;
      case ScoreBand.none:
        return _grey;
    }
  }

  static PdfColor _tint(ScoreBand b) {
    switch (b) {
      case ScoreBand.strong:
        return _greenTint;
      case ScoreBand.average:
        return _amberTint;
      case ScoreBand.weak:
        return _redTint;
      case ScoreBand.none:
        return _track;
    }
  }

  static final _num = NumberFormat('#,##0');
  static String _n(int v) => _num.format(v);

  /// The whole-number score as printed ("86%"), or a dash when the SKU was never audited.
  static String pct(double? v) => v == null ? '-' : '${v.round()}%';

  /// The PDF font has no long dashes or curly quotes (they print as boxes).
  static String _safe(String t) => t
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"');

  static Future<Uint8List> build({
    required String orgName,
    required String scope,
    required PlacementScorecard card,
    DateTime? at,
  }) async {
    final when = at ?? DateTime.now();
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 26, 28, 26),
      header: (c) => _pageHeader(orgName, repeatColumns: c.pageNumber > 1 && card.skus.isNotEmpty),
      footer: (c) => _pageFooter(c, orgName),
      build: (c) => [
        _title(scope, card, when),
        pw.SizedBox(height: 14),
        _kpiRow(card),
        pw.SizedBox(height: 12),
        _howToRead(),
        pw.SizedBox(height: 14),
        if (card.withData.isNotEmpty) ...[_focusRow(card), pw.SizedBox(height: 16)],
        _sectionTitle('All SKUs, best placed first'),
        pw.SizedBox(height: 6),
        if (card.skus.isEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 20),
            child: pw.Text('There are no SKUs in this report. Adjust the filters on the Placement Audit screen and export again.',
                style: const pw.TextStyle(fontSize: 10, color: _muted)),
          )
        else ...[
          _columnHeader(),
          for (var i = 0; i < card.skus.length; i++) _skuRow(i + 1, card.skus[i], i.isOdd),
        ],
        pw.SizedBox(height: 10),
        pw.Text('Each shop is counted by its most recent audit. A shop that was never audited for a SKU is not counted against it.',
            style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
      ],
    ));
    return doc.save();
  }

  // ---- page furniture --------------------------------------------------------------------

  static pw.Widget _pageHeader(String orgName, {required bool repeatColumns}) {
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(_safe(orgName).toUpperCase(), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _brandBlue, letterSpacing: 1.2)),
        pw.Text('SKU PLACEMENT SCORECARD', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 1.2)),
      ]),
      pw.Divider(color: _brandBlue, thickness: 1.5),
      if (repeatColumns) ...[_columnHeader(), pw.SizedBox(height: 2)] else pw.SizedBox(height: 4),
    ]);
  }

  static pw.Widget _pageFooter(pw.Context c, String orgName) {
    return pw.Column(children: [
      pw.Divider(color: _rule, thickness: 0.5),
      pw.SizedBox(height: 4),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Generated by Opstation \u00B7 ${_safe(orgName)}', style: const pw.TextStyle(fontSize: 8, color: _muted)),
        pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _muted)),
      ]),
    ]);
  }

  static pw.Widget _title(String scope, PlacementScorecard card, DateTime when) {
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('SKU Placement Scorecard', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: _ink)),
      pw.SizedBox(height: 3),
      pw.Text('How well each product is displayed in our shops', style: const pw.TextStyle(fontSize: 12, color: _muted)),
      pw.SizedBox(height: 6),
      pw.Text('${_safe(scope)}   \u00B7   As at ${DateFormat('d MMM y').format(when)}', style: const pw.TextStyle(fontSize: 9, color: _muted)),
    ]);
  }

  // ---- headline numbers -------------------------------------------------------------------

  static const double _kpiHeight = 108;

  static pw.Widget _card({required pw.Widget child, PdfColor? fill}) => pw.Expanded(
        child: pw.Container(
          height: _kpiHeight,
          margin: const pw.EdgeInsets.only(right: 8),
          padding: const pw.EdgeInsets.all(11),
          decoration: pw.BoxDecoration(
            color: fill ?? _bg,
            border: pw.Border.all(color: _ruleSoft, width: 0.6),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
          ),
          child: child,
        ),
      );

  static pw.Widget _cardLabel(String t) => pw.Text(t.toUpperCase(), style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, letterSpacing: 0.7, color: _muted));

  static pw.Widget _bar(double? score, double width, {double height = 8}) {
    final band = scoreBand(score);
    final frac = score == null ? 0.0 : (score / 100).clamp(0.0, 1.0);
    final fill = score == null ? 0.0 : (frac * width < 2 && frac > 0 ? 2.0 : frac * width);
    return pw.Container(
      width: width,
      height: height,
      decoration: pw.BoxDecoration(color: _track, borderRadius: pw.BorderRadius.all(pw.Radius.circular(height / 2))),
      child: pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Container(
          width: fill,
          height: height,
          decoration: pw.BoxDecoration(color: bandColor(band), borderRadius: pw.BorderRadius.all(pw.Radius.circular(height / 2))),
        ),
      ),
    );
  }

  static pw.Widget _kpiRow(PlacementScorecard card) {
    final overall = card.overall;
    final band = card.overallBand;
    return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _card(
        fill: _tint(band),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _cardLabel('Overall score'),
          pw.SizedBox(height: 4),
          pw.Text(pct(overall), style: pw.TextStyle(fontSize: 30, fontWeight: pw.FontWeight.bold, color: bandColor(band))),
          pw.SizedBox(height: 4),
          _bar(overall, 120, height: 7),
          pw.SizedBox(height: 5),
          pw.Text(
            overall == null ? 'No audits yet' : '${_n(card.displayedChecks)} of ${_n(card.auditedChecks)} checks show it',
            style: const pw.TextStyle(fontSize: 7.5, color: _muted),
          ),
        ]),
      ),
      _card(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _cardLabel('Shops audited'),
          pw.SizedBox(height: 4),
          pw.Text('${card.shops}', style: pw.TextStyle(fontSize: 30, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.SizedBox(height: 5),
          pw.Text('shops in this report', style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
        ]),
      ),
      _card(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _cardLabel('SKUs listed'),
          pw.SizedBox(height: 4),
          pw.Text('${card.skus.length}', style: pw.TextStyle(fontSize: 30, fontWeight: pw.FontWeight.bold, color: _ink)),
          pw.SizedBox(height: 5),
          pw.Text(card.withoutData.isEmpty ? 'all audited' : '${card.withData.length} audited, ${card.withoutData.length} not yet',
              style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
        ]),
      ),
      pw.Expanded(
        child: pw.Container(
          height: _kpiHeight,
          padding: const pw.EdgeInsets.all(11),
          decoration: pw.BoxDecoration(color: _bg, border: pw.Border.all(color: _ruleSoft, width: 0.6), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _cardLabel('SKUs by result'),
            pw.SizedBox(height: 6),
            _countLine(card.count(ScoreBand.strong), 'strong', ScoreBand.strong),
            pw.SizedBox(height: 4),
            _countLine(card.count(ScoreBand.average), 'average', ScoreBand.average),
            pw.SizedBox(height: 4),
            _countLine(card.count(ScoreBand.weak), 'weak', ScoreBand.weak),
          ]),
        ),
      ),
    ]);
  }

  static pw.Widget _countLine(int n, String label, ScoreBand b) => pw.Row(children: [
        pw.Container(width: 8, height: 8, decoration: pw.BoxDecoration(color: bandColor(b), shape: pw.BoxShape.circle)),
        pw.SizedBox(width: 6),
        pw.Text('$n', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _ink)),
        pw.SizedBox(width: 4),
        pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: _muted)),
      ]);

  // ---- explanation --------------------------------------------------------------------------

  static pw.Widget _howToRead() {
    pw.Widget swatch(ScoreBand b, String t) => pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          pw.Container(width: 24, height: 8, decoration: pw.BoxDecoration(color: bandColor(b), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)))),
          pw.SizedBox(width: 6),
          pw.Text(t, style: const pw.TextStyle(fontSize: 8.5, color: _ink)),
        ]);
    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFF6FF), borderRadius: pw.BorderRadius.all(pw.Radius.circular(8))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('How to read this report', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _brandBlue)),
        pw.SizedBox(height: 5),
        pw.RichText(
          text: pw.TextSpan(style: const pw.TextStyle(fontSize: 9, color: _ink), children: [
            pw.TextSpan(text: 'Placement score', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            const pw.TextSpan(text: ' = shops where the SKU is displayed \u00F7 shops where it was audited. 100% means every audited shop displays it.'),
          ]),
        ),
        pw.SizedBox(height: 7),
        pw.Wrap(spacing: 18, runSpacing: 4, children: [
          swatch(ScoreBand.strong, '80% and above: strong'),
          swatch(ScoreBand.average, '50% to 79%: average'),
          swatch(ScoreBand.weak, 'Below 50%: weak, needs attention'),
        ]),
      ]),
    );
  }

  // ---- who to look at -----------------------------------------------------------------------

  static pw.Widget _focusRow(PlacementScorecard card) {
    final weak = card.weakest(5);
    final strong = card.strongest(3);
    return pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Expanded(child: _focusBox('Needs attention', 'lowest placement first', weak, ScoreBand.weak)),
      pw.SizedBox(width: 12),
      pw.Expanded(child: _focusBox('Best placed', 'highest first', strong, ScoreBand.strong)),
    ]);
  }

  static pw.Widget _focusBox(String title, String sub, List<SkuScore> list, ScoreBand tone) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(11),
      decoration: pw.BoxDecoration(color: _tint(tone), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text(title, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: bandColor(tone))),
          pw.SizedBox(width: 6),
          pw.Text(sub, style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
        ]),
        pw.SizedBox(height: 7),
        for (final s in list)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Row(children: [
              pw.Expanded(child: pw.Text(_safe(s.name), maxLines: 1, style: const pw.TextStyle(fontSize: 9, color: _ink))),
              pw.SizedBox(width: 6),
              pw.Text(pct(s.score), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: bandColor(s.band))),
            ]),
          ),
      ]),
    );
  }

  // ---- the ranking --------------------------------------------------------------------------

  static pw.Widget _sectionTitle(String text) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text(text.toUpperCase(), style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _brandBlue, letterSpacing: 1.0)),
        pw.Divider(color: _rule, thickness: 0.5),
      ]);

  static const double _wRank = 24, _wBar = 150, _wNum = 56, _wAud = 78;

  static pw.Widget _columnHeader() {
    pw.TextStyle h() => pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 0.4);
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: const pw.BoxDecoration(color: _bg),
      child: pw.Row(children: [
        pw.SizedBox(width: _wRank, child: pw.Text('#', style: h())),
        pw.Expanded(child: pw.Text('SKU', style: h())),
        pw.SizedBox(width: _wBar, child: pw.Text('PLACEMENT SCORE', style: h())),
        pw.SizedBox(width: _wNum, child: pw.Text('DISPLAYED', textAlign: pw.TextAlign.right, style: h())),
        pw.SizedBox(width: _wNum + 6, child: pw.Text('NOT DISPLAYED', textAlign: pw.TextAlign.right, style: h())),
        pw.SizedBox(width: _wAud, child: pw.Text('AUDITED IN', textAlign: pw.TextAlign.right, style: h())),
      ]),
    );
  }

  static pw.Widget _skuRow(int rank, SkuScore s, bool shaded) {
    final band = s.band;
    final has = s.audited > 0;
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: pw.BoxDecoration(
        color: shaded ? _bg : null,
        border: const pw.Border(bottom: pw.BorderSide(color: _ruleSoft, width: 0.4)),
      ),
      child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
        pw.SizedBox(width: _wRank, child: pw.Text('$rank', style: const pw.TextStyle(fontSize: 8.5, color: _muted))),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(_safe(s.name), maxLines: 2, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: _ink)),
            if (s.code.isNotEmpty) pw.Text(_safe(s.code), style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
          ]),
        ),
        pw.SizedBox(
          width: _wBar,
          child: has
              ? pw.Row(children: [
                  _bar(s.score, 92),
                  pw.SizedBox(width: 8),
                  pw.Text(pct(s.score), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: bandColor(band))),
                ])
              : pw.Text('Not audited yet', style: const pw.TextStyle(fontSize: 8.5, color: _grey)),
        ),
        pw.SizedBox(width: _wNum, child: pw.Text(has ? '${s.displayed}' : '-', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: has ? _green : _grey))),
        pw.SizedBox(width: _wNum + 6, child: pw.Text(has ? '${s.notDisplayed}' : '-', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: has ? _red : _grey))),
        pw.SizedBox(width: _wAud, child: pw.Text(has ? '${s.audited} of ${s.totalShops} shops' : '0 of ${s.totalShops} shops', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 8, color: _muted))),
      ]),
    );
  }
}
