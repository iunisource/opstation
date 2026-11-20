import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/format/time_format.dart';
import '../logistics_reports/driver_job_report.dart';

/// The job sheet of a driver's job (deliveries, pickups, or the places visited on a free route),
/// printed from the Deliveries screen and the Logistics Reports page. With [route] (the job's
/// distances) it also shows where the job started and ended, the distance against each stop, the way
/// back to the return location and the total; without it the sheet is as it always was.
class JobSheetPdf {
  JobSheetPdf._();

  static bool isPickup(Map<String, dynamic> s) => (s['stop_type'] as String?) == 'pickup';
  static bool isVisit(Map<String, dynamic> s) => (s['stop_type'] as String?) == 'visit';

  /// "CODE · Name" for customers; suppliers and places have no code, so just the name.
  static String partyLabel(Map<String, dynamic> s) {
    final code = (s['customer_code'] as String? ?? '').trim();
    final name = (s['customer_name'] as String? ?? '').trim();
    return code.isEmpty ? name : '$code \u00B7 $name';
  }

  static String payLabel(String? pt) {
    switch (pt) {
      case 'cash':
        return 'Cash';
      case 'credit':
        return 'Credit';
      case 'not_required':
        return 'Not required';
      default:
        return pt ?? '';
    }
  }

  /// Location validation outcome, with the measured distance when outside.
  static String verLabel(Map<String, dynamic> s) {
    final v = s['verification'] as String? ?? 'pending';
    final dist = s['distance_meters'] as int?;
    switch (v) {
      case 'verified':
        return dist != null ? 'Verified (${dist}m)' : 'Verified';
      case 'outside':
        return dist != null ? 'Outside (${dist}m)' : 'Outside';
      case 'no_location':
        return 'No GPS';
      case 'pending':
      default:
        return 'Pending';
    }
  }

  /// Time for the PDF: the base PDF font cannot print the long dash, so "not yet" is a hyphen.
  static String pdfTime(dynamic v) {
    if (v == null) return '-';
    try {
      return DateFormat(orgTime('d MMM \u00B7 HH:mm')).format(DateTime.parse(v as String).toLocal());
    } catch (_) {
      return '-';
    }
  }

  /// "Place name (lat, lng)" of a recorded start / end point; "Not recorded" when there is none.
  static String placeText(List<double>? p, String? name) {
    if (p == null) return 'Not recorded';
    final pt = '${p[0].toStringAsFixed(5)}, ${p[1].toStringAsFixed(5)}';
    final n = (name ?? '').trim();
    return n.isEmpty ? pt : '$n ($pt)';
  }

  /// The distance cell of a stop: kilometres from the previous point; a dash when the stop has no
  /// GPS point (or is the first stop and the job's start was not recorded).
  static String kmText(double? km) => (km == null || km <= 0) ? '-' : km.toStringAsFixed(2);

  static Future<Uint8List> build({
    required Map<String, dynamic> delivery,
    required List<Map<String, dynamic>> stops,
    DriverJobReportContext? route,
  }) async {
    final d = delivery;
    final ordered = DriverJobReport.orderedStops(stops);
    final dels = [for (final s in ordered) if (!isPickup(s) && !isVisit(s)) s];
    final picks = [for (final s in ordered) if (isPickup(s)) s];
    final visits = [for (final s in ordered) if (isVisit(s)) s];
    final free = d['job_type'] == 'free';
    final withKm = route != null;
    final legKm = route?.legKmByStop ?? const <String, double>{};

    int totalAmount = 0, totalCash = 0, totalCredit = 0;
    for (final s in dels) {
      final amt = (s['amount'] as int?) ?? 0;
      totalAmount += amt;
      if (s['payment_type'] == 'cash') {
        totalCash += amt;
      } else if (s['payment_type'] == 'credit') {
        totalCredit += amt;
      }
    }
    const muted = PdfColor.fromInt(0xFF6B7280);
    const border = PdfColor.fromInt(0xFFE5E7EB);

    pw.Widget cell(String text, {bool bold = false, bool right = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: pw.Align(
            alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
            child: pw.Text(text, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ),
        );
    pw.Widget sectionTitle(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 12, bottom: 5),
          child: pw.Text(t, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        );
    pw.Widget kmCell(Map<String, dynamic> s) => cell(kmText(legKm['${s['id']}']), right: true);

    // Deliveries: customer, DO/note, payment, amount, status, time, location, distance.
    pw.Widget deliveriesTable() => pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          // With the distance column the others are a little narrower, but still wide enough for
          // "Payment" and "DELIVERED" to stay on one line.
          columnWidths: withKm
              ? {
                  0: const pw.FixedColumnWidth(22),
                  1: const pw.FlexColumnWidth(1.8),
                  2: const pw.FlexColumnWidth(1.2),
                  3: const pw.FlexColumnWidth(1.05),
                  4: const pw.FlexColumnWidth(0.9),
                  5: const pw.FlexColumnWidth(1.3),
                  6: const pw.FlexColumnWidth(1.25),
                  7: const pw.FlexColumnWidth(1.15),
                  8: const pw.FlexColumnWidth(1.05),
                }
              : {
                  0: const pw.FixedColumnWidth(22),
                  1: const pw.FlexColumnWidth(2.0),
                  2: const pw.FlexColumnWidth(1.5),
                  3: const pw.FlexColumnWidth(0.9),
                  4: const pw.FlexColumnWidth(0.9),
                  5: const pw.FlexColumnWidth(1),
                  6: const pw.FlexColumnWidth(1.3),
                  7: const pw.FlexColumnWidth(1.3),
                },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
              children: [
                for (final h in ['#', 'Customer', 'DO# / Note', 'Payment', 'Amount', 'Status', 'Time', 'Location', if (withKm) 'Distance (km)']) cell(h, bold: true),
              ],
            ),
            for (final s in dels)
              pw.TableRow(children: [
                cell('${s['sequence'] ?? ''}'),
                cell(partyLabel(s)),
                cell([
                  if ((s['so_invoice_number'] as String?)?.trim().isNotEmpty == true) 'DO# ${s['so_invoice_number']}',
                  if ((s['driver_note'] as String?)?.trim().isNotEmpty == true) 'Note: ${s['driver_note']}',
                ].join('\n')),
                cell(payLabel(s['payment_type'] as String?)),
                cell('Rs ${(s['amount'] as int?) ?? 0}'),
                cell((s['status'] as String? ?? '').toUpperCase()),
                cell(pdfTime(s['delivered_at'])),
                cell(verLabel(s)),
                if (withKm) kmCell(s),
              ]),
          ],
        );

    // Pickups: supplier, remarks, status, time, location, distance — no money columns.
    pw.Widget pickupsTable() => pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(22),
            1: const pw.FlexColumnWidth(2.2),
            2: const pw.FlexColumnWidth(2.0),
            3: const pw.FlexColumnWidth(1.3),
            4: const pw.FlexColumnWidth(1.3),
            5: const pw.FlexColumnWidth(1.3),
            if (withKm) 6: const pw.FlexColumnWidth(1.1),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
              children: [for (final h in ['#', 'Supplier', 'Remarks', 'Status', 'Time', 'Location', if (withKm) 'Distance (km)']) cell(h, bold: true)],
            ),
            for (final s in picks)
              pw.TableRow(children: [
                cell('${s['sequence'] ?? ''}'),
                cell(partyLabel(s)),
                cell([
                  if ((s['item_description'] as String?)?.trim().isNotEmpty == true) s['item_description'] as String,
                  if ((s['driver_note'] as String?)?.trim().isNotEmpty == true) 'Note: ${s['driver_note']}',
                ].join('\n')),
                cell((s['status'] as String? ?? '').toUpperCase()),
                cell(pdfTime(s['delivered_at'])),
                cell(verLabel(s)),
                if (withKm) kmCell(s),
              ]),
          ],
        );

    // Places marked on a free route: place, time, location, distance.
    pw.Widget visitsTable() => pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(22),
            1: const pw.FlexColumnWidth(3.4),
            2: const pw.FlexColumnWidth(1.1),
            3: const pw.FlexColumnWidth(1.3),
            4: const pw.FlexColumnWidth(1.3),
            if (withKm) 5: const pw.FlexColumnWidth(0.9),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
              children: [for (final h in ['#', 'Place', 'Status', 'Time', 'Location', if (withKm) 'Distance (km)']) cell(h, bold: true)],
            ),
            for (final s in visits)
              pw.TableRow(children: [
                cell('${((s['sequence'] as num?) ?? 0).toInt() + 1}'),
                cell(partyLabel(s)),
                cell('VISITED'),
                cell(pdfTime(s['delivered_at'])),
                cell(verLabel(s)),
                if (withKm) kmCell(s),
              ]),
          ],
        );

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 28, 28, 28),
      build: (ctx) => [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(free ? 'Free Route' : 'Job Sheet', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text('Driver: ${d['driver_name'] ?? '-'}', style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Created ${pdfTime(d['created_at'])} by ${d['created_by_name'] ?? '-'}', style: const pw.TextStyle(fontSize: 9, color: muted)),
            ]),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: pw.BoxDecoration(border: pw.Border.all(color: border), borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text((d['status'] as String? ?? '').replaceAll('_', ' ').toUpperCase(), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Row(children: [
          pw.Text('Started ${pdfTime(d['started_at'])}', style: const pw.TextStyle(fontSize: 9, color: muted)),
          pw.SizedBox(width: 16),
          pw.Text('Completed ${pdfTime(d['completed_at'])}', style: const pw.TextStyle(fontSize: 9, color: muted)),
          pw.SizedBox(width: 16),
          pw.Text(free ? 'Visits ${visits.length}' : 'Deliveries ${dels.length}   Pickups ${picks.length}', style: const pw.TextStyle(fontSize: 9, color: muted)),
        ]),
        if (route != null) ...[
          pw.SizedBox(height: 3),
          if (d['started_at'] != null)
            pw.Text('Start location: ${placeText(route.startPoint, route.startAddress)}', style: const pw.TextStyle(fontSize: 9, color: muted)),
          if (d['completed_at'] != null)
            pw.Text('End location: ${placeText(route.endPoint, route.endAddress)}', style: const pw.TextStyle(fontSize: 9, color: muted)),
        ],
        if (dels.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Text('Total Rs $totalAmount   \u00B7   Cash Rs $totalCash   \u00B7   Credit Rs $totalCredit',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ],
        if (route != null && route.totalDistanceKm > 0) ...[
          pw.SizedBox(height: 4),
          pw.Text('Distance ${route.totalDistanceKm.toStringAsFixed(2)} km', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ],
        if (dels.isNotEmpty) ...[sectionTitle('Deliveries (${dels.length})'), deliveriesTable()],
        if (picks.isNotEmpty) ...[sectionTitle('Pickups (${picks.length})'), pickupsTable()],
        if (visits.isNotEmpty) ...[sectionTitle('Visits (${visits.length})'), visitsTable()],
        // The way back and the total, under the stops.
        if (route != null && (route.returnDistanceKm > 0 || route.totalDistanceKm > 0)) ...[
          pw.SizedBox(height: 8),
          if (route.returnDistanceKm > 0)
            pw.Text('Return to end location: ${route.returnDistanceKm.toStringAsFixed(2)} km', style: const pw.TextStyle(fontSize: 10)),
          if (route.totalDistanceKm > 0)
            pw.Text('Total distance: ${route.totalDistanceKm.toStringAsFixed(2)} km', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ],
        if ((d['notes'] as String?)?.trim().isNotEmpty == true) ...[
          pw.SizedBox(height: 12),
          pw.Text('Job notes: ${d['notes']}', style: const pw.TextStyle(fontSize: 10)),
        ],
      ],
    ));
    return doc.save();
  }
}
