import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../logistics_reports/driver_job_report.dart';

/// The Delivery Report of a driver's job, on the web: the same document as the one the driver's phone
/// makes (header, details block, summary strip, STOP DETAILS table, signatures). With [route] (the
/// job's distances) it adds: where the job started and ended, a DISTANCE figure in the summary, a
/// Distance (km) column against each stop, the way back to the return location and the total.
/// Without [route] it is the phone's report exactly.
class DeliveryReportPdf {
  DeliveryReportPdf._();

  static const _brandBlue = PdfColor.fromInt(0xFF1E3A8A);
  static const _ink = PdfColor.fromInt(0xFF111827);
  static const _muted = PdfColor.fromInt(0xFF6B7280);
  static const _rule = PdfColor.fromInt(0xFFD1D5DB);
  static const _ruleSoft = PdfColor.fromInt(0xFFE5E7EB);
  static const _bg = PdfColor.fromInt(0xFFF9FAFB);
  static const _successGreen = PdfColor.fromInt(0xFF059669);
  static const _dangerRed = PdfColor.fromInt(0xFFDC2626);

  static final _dtFmt = DateFormat('d MMM y \u00B7 HH:mm');
  static final _timeFmt = DateFormat('HH:mm \u00B7 d MMM y');

  // ---- data helpers (the server's rows) ------------------------------------------------

  static DateTime? _dt(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();
  static int _int(Object? v) => v is num ? v.toInt() : 0;
  static String _s(Object? v) => v == null ? '' : '$v';

  /// The PDF font has no long dashes or curly quotes (they print as boxes).
  static String _safe(String t) => t
      .replaceAll('\u2013', '-')
      .replaceAll('\u2014', '-')
      .replaceAll('\u2018', "'")
      .replaceAll('\u2019', "'")
      .replaceAll('\u201C', '"')
      .replaceAll('\u201D', '"');

  static String statusLabel(String? s) {
    switch (s) {
      case 'draft':
        return 'Draft';
      case 'assigned':
        return 'Assigned';
      case 'in_progress':
        return 'In progress';
      case 'completed':
        return 'Completed';
      case 'cancelled':
        return 'Cancelled';
    }
    return _s(s);
  }

  static String payLabel(String? pt) {
    switch (pt) {
      case 'cash':
        return 'Cash';
      case 'credit':
        return 'Credit';
      case 'not_required':
        return 'Not required';
    }
    return _s(pt);
  }

  static bool hasPhotos(Map<String, dynamic> s) {
    final raw = s['photo_paths_json'];
    try {
      final v = raw is String ? jsonDecode(raw) : raw;
      return v is List && v.any((p) => p is String && p.trim().isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  /// "Place name (lat, lng)" of a recorded start / end point; "Not recorded" when there is none.
  static String placeText(List<double>? p, String? name) {
    if (p == null) return 'Not recorded';
    final pt = '${p[0].toStringAsFixed(5)}, ${p[1].toStringAsFixed(5)}';
    final n = (name ?? '').trim();
    return n.isEmpty ? pt : '$n ($pt)';
  }

  /// The distance cell of a stop: kilometres from the previous point; a dash when the stop has no GPS
  /// point (or is the first stop and the job's start was not recorded).
  static String kmText(double? km) => (km == null || km <= 0) ? '-' : km.toStringAsFixed(2);

  /// SHOULD COLLECT: every cash stop's amount. COLLECTED: what was actually received at the delivered cash stops.
  static int shouldCollect(List<Map<String, dynamic>> stops) =>
      stops.where((s) => s['payment_type'] == 'cash').fold<int>(0, (a, s) => a + _int(s['amount']));
  static int collected(List<Map<String, dynamic>> stops) => stops
      .where((s) => s['status'] == 'delivered' && s['payment_type'] == 'cash' && s['cash_received'] != null)
      .fold<int>(0, (a, s) => a + _int(s['cash_received']));

  // ---- the document ---------------------------------------------------------------------

  static Future<Uint8List> build({
    required Map<String, dynamic> delivery,
    required List<Map<String, dynamic>> stops,
    required String orgName,
    DriverJobReportContext? route,
  }) async {
    final ordered = DriverJobReport.orderedStops(stops);
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
        header: (c) => _pageHeader(orgName),
        footer: (c) => _pageFooter(c, orgName),
        build: (c) => [
          _metaBlock(delivery, route),
          pw.SizedBox(height: 14),
          _summaryStrip(ordered, route),
          pw.SizedBox(height: 14),
          _sectionTitle('Stop Details'),
          pw.SizedBox(height: 6),
          _stopsTable(ordered, route),
          pw.SizedBox(height: 24),
          _signatureLine(),
        ],
      ),
    );
    return doc.save();
  }

  static pw.Widget _pageHeader(String orgName) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(_safe(orgName).toUpperCase(), style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _brandBlue, letterSpacing: 1.2)),
            pw.Text('DELIVERY REPORT', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _muted, letterSpacing: 1.2)),
          ],
        ),
        pw.Divider(color: _brandBlue, thickness: 1.5),
        pw.SizedBox(height: 4),
      ],
    );
  }

  static pw.Widget _pageFooter(pw.Context c, String orgName) {
    return pw.Column(
      children: [
        pw.Divider(color: _rule, thickness: 0.5),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('Generated by Opstation \u00B7 ${_safe(orgName)}', style: const pw.TextStyle(fontSize: 8, color: _muted)),
            pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: _muted)),
          ],
        ),
      ],
    );
  }

  static pw.Widget _metaBlock(Map<String, dynamic> d, DriverJobReportContext? route) {
    final started = _dt(d['started_at']);
    final completed = _dt(d['completed_at']);
    final created = _dt(d['created_at']);
    final status = _s(d['status']);
    final notes = _s(d['notes']);
    final rows = <List<String>>[
      ['Driver', _safe(d['driver_name'] == null ? 'Unassigned' : _s(d['driver_name']))],
      ['Created by', _safe('${_s(d['created_by_name'])} (${_s(d['created_by_role'])})')],
      ['Created', created == null ? '-' : _dtFmt.format(created)],
      if (started != null) ['Started', _dtFmt.format(started)],
      if (route != null && started != null) ['Start location', _safe(placeText(route.startPoint, route.startAddress))],
      if (completed != null) [status == 'cancelled' ? 'Cancelled' : 'Completed', _dtFmt.format(completed)],
      if (route != null && completed != null) ['End location', _safe(placeText(route.endPoint, route.endAddress))],
      ['Status', statusLabel(status)],
      if (notes.isNotEmpty) ['Notes', _safe(notes)],
    ];
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(color: _bg, borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)), border: pw.Border.all(color: _ruleSoft, width: 0.5)),
      child: pw.Column(
        children: [
          for (final r in rows)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Row(children: [
                pw.SizedBox(width: 90, child: pw.Text(r[0], style: pw.TextStyle(fontSize: 9, color: _muted, fontWeight: pw.FontWeight.bold))),
                pw.Expanded(child: pw.Text(r[1], style: const pw.TextStyle(fontSize: 9, color: _ink))),
              ]),
            ),
        ],
      ),
    );
  }

  static pw.Widget _summaryStrip(List<Map<String, dynamic>> stops, DriverJobReportContext? route) {
    final delivered = stops.where((s) => s['status'] == 'delivered').length;
    final failed = stops.where((s) => s['status'] == 'failed').length;
    return pw.Container(
      decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFF6FF), borderRadius: pw.BorderRadius.all(pw.Radius.circular(4))),
      padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 14),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
        children: [
          _summaryCell('STOPS', '${stops.length}', _ink),
          _summaryCell('DELIVERED', '$delivered', _successGreen),
          _summaryCell('FAILED', '$failed', _dangerRed),
          _summaryCell('SHOULD COLLECT', 'Rs ${shouldCollect(stops)}', _brandBlue),
          _summaryCell('COLLECTED', 'Rs ${collected(stops)}', _successGreen),
          if (route != null) _summaryCell('DISTANCE', route.totalDistanceKm > 0 ? '${route.totalDistanceKm.toStringAsFixed(2)} km' : '-', _brandBlue),
        ],
      ),
    );
  }

  static pw.Widget _summaryCell(String label, String value, PdfColor color) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(value, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: color)),
        pw.SizedBox(height: 2),
        pw.Text(label, style: const pw.TextStyle(fontSize: 7, color: _muted)),
      ],
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(text.toUpperCase(), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _brandBlue, letterSpacing: 1.0)),
        pw.Divider(color: _rule, thickness: 0.5),
      ],
    );
  }

  static pw.Widget _th(String text, pw.TextStyle style) =>
      pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5), child: pw.Text(text, style: style));

  static pw.Widget _td(String text, pw.TextStyle style) =>
      pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5), child: pw.Text(text, style: style));

  static pw.Widget _stopsTable(List<Map<String, dynamic>> stops, DriverJobReportContext? route) {
    pw.TextStyle headerBold() => pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _muted);
    final legKm = route?.legKmByStop ?? const <String, double>{};
    final withKm = route != null;
    pw.Widget kmCell(String text, {bool bold = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(text, style: pw.TextStyle(fontSize: 8, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ),
        );
    // The way back and the total, under the stops.
    pw.TableRow extraRow(String label, double km, {bool bold = false}) => pw.TableRow(children: [
          _td('', const pw.TextStyle(fontSize: 8)),
          _td(label, pw.TextStyle(fontSize: 8, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          for (var i = 0; i < 5; i++) _td('', const pw.TextStyle(fontSize: 8)),
          kmCell('${km.toStringAsFixed(2)}${bold ? ' km' : ''}', bold: bold),
        ]);

    return pw.Table(
      columnWidths: {
        0: const pw.FixedColumnWidth(18), // #
        1: const pw.FlexColumnWidth(3), // Customer + timestamp
        2: const pw.FlexColumnWidth(3), // Item
        3: const pw.FixedColumnWidth(52), // Should collect
        4: const pw.FixedColumnWidth(46), // Collected
        5: const pw.FixedColumnWidth(50), // Outcome
        6: const pw.FixedColumnWidth(36), // Photo
        if (withKm) 7: const pw.FixedColumnWidth(46), // Distance (km)
      },
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _ruleSoft, width: 0.5)),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _bg),
          children: [
            _th('#', headerBold()),
            _th('Customer', headerBold()),
            _th('Item', headerBold()),
            _th('Should Collect', headerBold()),
            _th('Collected', headerBold()),
            _th('Outcome', headerBold()),
            _th('Photo', headerBold()),
            if (withKm) _th('Distance (km)', headerBold()),
          ],
        ),
        for (final s in stops) _stopRow(s, legKm, withKm, kmCell),
        if (route != null && route.returnDistanceKm > 0) extraRow('Return to end location', route.returnDistanceKm),
        if (route != null && route.totalDistanceKm > 0) extraRow('Total distance', route.totalDistanceKm, bold: true),
      ],
    );
  }

  static pw.TableRow _stopRow(Map<String, dynamic> s, Map<String, double> legKm, bool withKm, pw.Widget Function(String, {bool bold}) kmCell) {
    final status = _s(s['status']);
    final delivered = status == 'delivered';
    final at = _dt(s['delivered_at']);
    final item = _s(s['item_description']);
    final amount = _int(s['amount']);
    return pw.TableRow(
      decoration: pw.BoxDecoration(color: delivered ? const PdfColor.fromInt(0xFFF0FDF4) : status == 'failed' ? const PdfColor.fromInt(0xFFFEF2F2) : null),
      children: [
        _td('${_int(s['sequence']) + 1}', const pw.TextStyle(fontSize: 8)),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(_safe(_s(s['customer_name'])), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
              pw.Text(_safe(_s(s['customer_code'])), style: const pw.TextStyle(fontSize: 7, color: _muted)),
              if (at != null) pw.Text(_timeFmt.format(at), style: const pw.TextStyle(fontSize: 7, color: _muted)),
            ],
          ),
        ),
        _td(item.isEmpty ? '-' : _safe(item), const pw.TextStyle(fontSize: 8, color: _muted)),
        _td('Rs $amount\n${payLabel(s['payment_type'] as String?)}', const pw.TextStyle(fontSize: 8)),
        _td(delivered ? 'Rs ${s['cash_received'] == null ? amount : _int(s['cash_received'])}' : '-',
            pw.TextStyle(fontSize: 8, color: delivered ? _successGreen : _muted)),
        _outcomeCell(s),
        _photoCell(s),
        if (withKm) kmCell(kmText(legKm['${s['id']}'])),
      ],
    );
  }

  static pw.Widget _outcomeCell(Map<String, dynamic> s) {
    final status = _s(s['status']);
    PdfColor color;
    String label;
    switch (status) {
      case 'delivered':
        color = _successGreen;
        label = s['stop_type'] == 'visit' ? 'Visited' : 'Delivered'; // a place marked on a free route
        break;
      case 'failed':
        color = _dangerRed;
        label = 'Failed';
        final reason = _s(s['failure_reason']);
        if (reason.isNotEmpty) label += '\n${_safe(reason)}';
        break;
      default:
        color = _muted;
        label = 'Pending';
    }
    String verif = '';
    final dist = s['distance_meters'];
    if (s['verification'] == 'outside' && dist is num) {
      verif = dist >= 1000 ? '\n${(dist / 1000).toStringAsFixed(1)}km off' : '\n${dist.toInt()}m off';
    } else if (s['verification'] == 'no_location') {
      verif = '\nNo GPS';
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text('$label$verif', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: color)),
    );
  }

  static pw.Widget _photoCell(Map<String, dynamic> s) {
    final has = hasPhotos(s);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: pw.Text(has ? 'Yes' : 'No', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: has ? _successGreen : _muted)),
    );
  }

  static pw.Widget _signatureLine() => pw.Row(children: [_sigBox('Driver Signature'), pw.SizedBox(width: 24), _sigBox('Dispatch Manager')]);

  static pw.Widget _sigBox(String label) {
    return pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(height: 40, decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.8)))),
          pw.SizedBox(height: 4),
          pw.Text(label, style: const pw.TextStyle(fontSize: 8, color: _muted)),
        ],
      ),
    );
  }
}
