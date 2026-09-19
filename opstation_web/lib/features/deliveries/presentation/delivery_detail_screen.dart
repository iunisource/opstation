import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../../core/storage/photo_url.dart';
import '../../../core/theme/app_theme.dart';

/// Read-only-ish detail page for a single delivery. Pulls the
/// delivery row plus its stops from Supabase, shows everything that
/// drivers see in the field (item, payment, amount, status,
/// verification, photos), so admins can audit a delivery after the
/// fact without opening the mobile app.
///
/// Currently no editing — drafts can still be edited from the
/// list (assign / cancel buttons there). A future iteration could
/// add inline edit for stops in draft status.
class DeliveryDetailScreen extends ConsumerStatefulWidget {
  final String deliveryId;
  const DeliveryDetailScreen({super.key, required this.deliveryId});

  @override
  ConsumerState<DeliveryDetailScreen> createState() =>
      _DeliveryDetailScreenState();
}

class _DeliveryDetailScreenState
    extends ConsumerState<DeliveryDetailScreen> {
  Map<String, dynamic>? _delivery;
  List<Map<String, dynamic>> _stops = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final delivery = await client
          .from('deliveries')
          .select()
          .eq('id', widget.deliveryId)
          .maybeSingle();
      if (delivery == null) {
        setState(() {
          _loading = false;
          _error = 'Delivery not found.';
        });
        return;
      }
      final stops = await client
          .from('delivery_stops')
          .select()
          .eq('delivery_id', widget.deliveryId)
          .order('sequence');
      setState(() {
        _delivery = Map<String, dynamic>.from(delivery as Map);
        _stops = List<Map<String, dynamic>>.from(stops);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Failed to load: ${e.toString().split('\n').first}';
      });
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'assigned':
        return AppTheme.warning;
      case 'in_progress':
        return AppTheme.primary;
      case 'completed':
      case 'delivered':
        return AppTheme.success;
      case 'cancelled':
      case 'failed':
        return AppTheme.danger;
      case 'draft':
      case 'pending':
      default:
        return AppTheme.textSecondary;
    }
  }

  String _fmtTime(dynamic v) {
    if (v == null) return '—';
    try {
      return DateFormat('d MMM · HH:mm').format(
          DateTime.parse(v as String).toLocal());
    } catch (_) {
      return '—';
    }
  }

  /// PDF-safe time: the base PDF font can't render the em dash "—" (it
  /// showed as a box), so use a plain hyphen for "not yet".
  String _pdfTime(dynamic v) => v == null ? '-' : _fmtTime(v);

  // A job can mix stop types; behaviour is decided per stop.
  static bool isPickupStop(Map<String, dynamic> s) =>
      (s['stop_type'] as String?) == 'pickup';
  List<Map<String, dynamic>> get _deliveryStops =>
      _stops.where((s) => !isPickupStop(s)).toList();
  List<Map<String, dynamic>> get _pickupStops =>
      _stops.where(isPickupStop).toList();

  /// "CODE · Name" for customers; suppliers have no code, so just the name
  /// (avoids the stray leading "·").
  static String partyLabel(Map<String, dynamic> s) {
    final code = (s['customer_code'] as String? ?? '').trim();
    final name = (s['customer_name'] as String? ?? '').trim();
    return code.isEmpty ? name : '$code · $name';
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

  Future<void> _printDelivery() async {
    final d = _delivery;
    if (d == null) return;
    final dels = _deliveryStops;
    final picks = _pickupStops;
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
    final muted = PdfColor.fromInt(0xFF6B7280);
    final border = PdfColor.fromInt(0xFFE5E7EB);

    pw.Widget sectionTitle(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 12, bottom: 5),
          child: pw.Text(t,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        );

    // Deliveries: customer, DO/note, payment, amount, status, time, location.
    pw.Widget deliveriesTable() => pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          columnWidths: {
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
              decoration: pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
              children: [
                for (final h in ['#', 'Customer', 'DO# / Note', 'Payment', 'Amount', 'Status', 'Time', 'Location'])
                  _pdfCell(h, bold: true),
              ],
            ),
            for (final s in dels)
              pw.TableRow(children: [
                _pdfCell('${s['sequence'] ?? ''}'),
                _pdfCell(partyLabel(s)),
                _pdfCell([
                  if ((s['so_invoice_number'] as String?)?.trim().isNotEmpty == true)
                    'DO# ${s['so_invoice_number']}',
                  if ((s['driver_note'] as String?)?.trim().isNotEmpty == true)
                    'Note: ${s['driver_note']}',
                ].join('\n')),
                _pdfCell(payLabel(s['payment_type'] as String?)),
                _pdfCell('Rs ${(s['amount'] as int?) ?? 0}'),
                _pdfCell((s['status'] as String? ?? '').toUpperCase()),
                _pdfCell(_pdfTime(s['delivered_at'])),
                _pdfCell(verLabel(s)),
              ]),
          ],
        );

    // Pickups: supplier, remarks, status, time, location — no money columns.
    pw.Widget pickupsTable() => pw.Table(
          border: pw.TableBorder.all(color: border, width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(22),
            1: const pw.FlexColumnWidth(2.2),
            2: const pw.FlexColumnWidth(2.4),
            3: const pw.FlexColumnWidth(1),
            4: const pw.FlexColumnWidth(1.3),
            5: const pw.FlexColumnWidth(1.3),
          },
          children: [
            pw.TableRow(
              decoration: pw.BoxDecoration(color: PdfColor.fromInt(0xFFF3F4F6)),
              children: [
                for (final h in ['#', 'Supplier', 'Remarks', 'Status', 'Time', 'Location'])
                  _pdfCell(h, bold: true),
              ],
            ),
            for (final s in picks)
              pw.TableRow(children: [
                _pdfCell('${s['sequence'] ?? ''}'),
                _pdfCell(partyLabel(s)),
                _pdfCell([
                  if ((s['item_description'] as String?)?.trim().isNotEmpty == true)
                    s['item_description'] as String,
                  if ((s['driver_note'] as String?)?.trim().isNotEmpty == true)
                    'Note: ${s['driver_note']}',
                ].join('\n')),
                _pdfCell((s['status'] as String? ?? '').toUpperCase()),
                _pdfCell(_pdfTime(s['delivered_at'])),
                _pdfCell(verLabel(s)),
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
              pw.Text('Job Sheet',
                  style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text('Driver: ${d['driver_name'] ?? '-'}',
                  style: const pw.TextStyle(fontSize: 12)),
              pw.Text('Created ${_pdfTime(d['created_at'])} by ${d['created_by_name'] ?? '-'}',
                  style: pw.TextStyle(fontSize: 9, color: muted)),
            ]),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: border),
                  borderRadius: pw.BorderRadius.circular(4)),
              child: pw.Text((d['status'] as String? ?? '').toUpperCase(),
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Row(children: [
          pw.Text('Started ${_pdfTime(d['started_at'])}',
              style: pw.TextStyle(fontSize: 9, color: muted)),
          pw.SizedBox(width: 16),
          pw.Text('Completed ${_pdfTime(d['completed_at'])}',
              style: pw.TextStyle(fontSize: 9, color: muted)),
          pw.SizedBox(width: 16),
          pw.Text('Deliveries ${dels.length}   Pickups ${picks.length}',
              style: pw.TextStyle(fontSize: 9, color: muted)),
        ]),
        if (dels.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Text('Total Rs $totalAmount   ·   Cash Rs $totalCash   ·   Credit Rs $totalCredit',
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ],
        if (dels.isNotEmpty) ...[
          sectionTitle('Deliveries (${dels.length})'),
          deliveriesTable(),
        ],
        if (picks.isNotEmpty) ...[
          sectionTitle('Pickups (${picks.length})'),
          pickupsTable(),
        ],
        if ((d['notes'] as String?)?.trim().isNotEmpty == true) ...[
          pw.SizedBox(height: 12),
          pw.Text('Job notes: ${d['notes']}', style: const pw.TextStyle(fontSize: 10)),
        ],
      ],
    ));
    await Printing.layoutPdf(onLayout: (f) => doc.save());
  }

  static pw.Widget _pdfCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: pw.Text(text,
            style: pw.TextStyle(
                fontSize: 9,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              const SizedBox(width: 8),
              const Text('Job Details',
                  style: TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800)),
              const Spacer(),
              if (!_loading && _error == null && _delivery != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print / PDF'),
                  onPressed: _printDelivery,
                ),
            ]),
            const SizedBox(height: 24),
            if (_loading)
              const Expanded(
                child:
                    Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Expanded(
                child: Center(
                  child: Text(_error!,
                      style:
                          const TextStyle(color: AppTheme.danger)),
                ),
              )
            else if (_delivery != null)
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(),
                        const SizedBox(height: 24),
                        _buildStops(),
                      ]),
                ),
              ),
          ]),
    );
  }

  Widget _buildHeader() {
    final d = _delivery!;
    final status = d['status'] as String? ?? 'draft';
    final notes = d['notes'] as String?;

    int totalAmount = 0;
    int totalCash = 0;
    int totalCredit = 0;
    for (final s in _stops) {
      final amt = (s['amount'] as int?) ?? 0;
      totalAmount += amt;
      if (s['payment_type'] == 'cash') {
        totalCash += amt;
      } else if (s['payment_type'] == 'credit') {
        totalCredit += amt;
      }
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                          d['driver_name'] as String? ??
                              'Unassigned',
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                          'Created ${_fmtTime(d['created_at'])} by ${d['created_by_name'] ?? '—'}',
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary)),
                    ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: _statusColor(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(status.toUpperCase(),
                    style: TextStyle(
                        color: _statusColor(status),
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // Timestamps
            Row(children: [
              Expanded(
                  child: _kv('Started', _fmtTime(d['started_at']))),
              Expanded(
                  child: _kv(
                      'Completed', _fmtTime(d['completed_at']))),
              Expanded(child: _kv('Stops', '${_stops.length}')),
            ]),
            if (notes != null && notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              const Text('Notes',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 4),
              Text(notes, style: const TextStyle(fontSize: 13)),
            ],
            // Totals — money only applies to deliveries; pickups collect goods.
            if (_deliveryStops.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Expanded(
                      child: _totalCell(
                          'Rs $totalAmount', 'TOTAL')),
                  Container(
                      width: 1,
                      height: 32,
                      color: AppTheme.border),
                  Expanded(
                      child: _totalCell('Rs $totalCash', 'CASH')),
                  Container(
                      width: 1,
                      height: 32,
                      color: AppTheme.border),
                  Expanded(
                      child:
                          _totalCell('Rs $totalCredit', 'CREDIT')),
                ]),
              ),
            ],
          ]),
    );
  }

  Widget _kv(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(),
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppTheme.textSecondary)),
      const SizedBox(height: 2),
      Text(value,
          style:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _totalCell(String value, String label) {
    return Column(children: [
      Text(value,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(label,
          style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppTheme.textSecondary)),
    ]);
  }

  Widget _buildStops() {
    if (_stops.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: const Center(
            child: Text('No stops on this job.',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic))),
      );
    }
    // Bifurcated: deliveries first, then pickups, each in its own card.
    final dels = _deliveryStops;
    final picks = _pickupStops;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (dels.isNotEmpty) _stopSection('Deliveries', dels, isPickup: false),
      if (dels.isNotEmpty && picks.isNotEmpty) const SizedBox(height: 20),
      if (picks.isNotEmpty) _stopSection('Pickups', picks, isPickup: true),
    ]);
  }

  Widget _stopSection(String title, List<Map<String, dynamic>> stops,
      {required bool isPickup}) {
    final color = isPickup ? AppTheme.warning : AppTheme.primary;
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(12))),
          child: Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text('$title (${stops.length})',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
        const Divider(height: 1),
        for (int i = 0; i < stops.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _StopRow(stop: stops[i], statusColor: _statusColor, isPickup: isPickup),
        ],
      ]),
    );
  }
}

class _StopRow extends StatelessWidget {
  final Map<String, dynamic> stop;
  final Color Function(String) statusColor;
  final bool isPickup;
  const _StopRow({required this.stop, required this.statusColor, this.isPickup = false});

  String _fmtTime(dynamic v) {
    if (v == null) return '—';
    try {
      return DateFormat('d MMM · HH:mm').format(
          DateTime.parse(v as String).toLocal());
    } catch (_) {
      return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = stop['status'] as String? ?? 'pending';
    final paymentType = stop['payment_type'] as String? ?? 'cash';
    final amount = (stop['amount'] as int?) ?? 0;
    final cashReceived = stop['cash_received'] as int?;
    final failureReason = stop['failure_reason'] as String?;
    final doRef = (stop['so_invoice_number'] as String?)?.trim();
    final driverNote = (stop['driver_note'] as String?)?.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppTheme.primary.withOpacity(0.1),
                child: Text('${stop['sequence']}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary)),
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        _DeliveryDetailScreenState.partyLabel(stop),
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                    if (doRef != null && doRef.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text('DO# $doRef',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary)),
                    ],
                    const SizedBox(height: 2),
                    Text(stop['item_description'] as String? ?? '',
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary)),
                  ])),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: statusColor(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(status.toUpperCase(),
                    style: TextStyle(
                        color: statusColor(status),
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Wrap(spacing: 24, runSpacing: 8, children: [
                // Money only applies to deliveries.
                if (!isPickup) ...[
                  _miniKV('Payment',
                      _DeliveryDetailScreenState.payLabel(paymentType)),
                  if (paymentType != 'not_required')
                    _miniKV('Amount', 'Rs $amount'),
                  if (cashReceived != null)
                    _miniKV('Received', 'Rs $cashReceived'),
                ],
                // Timestamp + location validation — shown for every stop
                // (pending ones read "—" / "Pending") so the audit is complete.
                _miniKV(isPickup ? 'Picked up' : 'Delivered',
                    _fmtTime(stop['delivered_at'])),
                _miniKV('Location check',
                    _DeliveryDetailScreenState.verLabel(stop)),
                if (stop['captured_lat'] != null && stop['captured_lng'] != null)
                  _miniKV('GPS',
                      '${(stop['captured_lat'] as num).toStringAsFixed(5)}, '
                      '${(stop['captured_lng'] as num).toStringAsFixed(5)}'),
              ]),
            ),
            if (driverNote != null && driverNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.sticky_note_2_outlined,
                      size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Note: $driverNote',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                ]),
              ),
            ],
            if (failureReason != null && failureReason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppTheme.danger.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    const Icon(Icons.error_outline,
                        size: 14, color: AppTheme.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(failureReason,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.danger)),
                    ),
                  ]),
                ),
              ),
            ],
            // Proof-of-delivery photos. Reads photo_paths_json from the
            // stop row, builds public URLs via PhotoUrl, renders small
            // tappable thumbnails. Tapping any opens a full-screen viewer.
            ..._buildPhotoStrip(context),
          ]),
    );
  }

  /// Parses the stop's photo_paths_json and returns the list-children to
  /// render. Empty list when there are no photos. Defensive against
  /// malformed JSON — bad data simply hides the strip rather than
  /// breaking the whole detail page.
  List<Widget> _buildPhotoStrip(BuildContext context) {
    final raw = stop['photo_paths_json'] as String?;
    if (raw == null || raw.isEmpty || raw == '[]') return const [];
    List<String> paths;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      paths = decoded.whereType<String>().toList();
    } catch (_) {
      return const [];
    }
    if (paths.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.only(left: 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('PHOTOS',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: paths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                return InkWell(
                  onTap: () => _openFullscreen(context, paths, i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      PhotoUrl.build(paths[i]),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: AppTheme.background,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            size: 20, color: AppTheme.textSecondary),
                      ),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          width: 64,
                          height: 64,
                          color: AppTheme.background,
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    ];
  }

  void _openFullscreen(BuildContext context, List<String> paths, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _PhotoViewer(paths: paths, initialIndex: initialIndex),
    ));
  }

  Widget _miniKV(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(),
          style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppTheme.textSecondary)),
      const SizedBox(height: 2),
      Text(value,
          style:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ]);
  }
}

/// Full-screen swipeable photo viewer for delivery photos. Pinch-to-zoom
/// via InteractiveViewer; close with the X button.
class _PhotoViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const _PhotoViewer({required this.paths, required this.initialIndex});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _ctrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _ctrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_current + 1} / ${widget.paths.length}',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _ctrl,
        onPageChanged: (i) => setState(() => _current = i),
        itemCount: widget.paths.length,
        itemBuilder: (_, i) => InteractiveViewer(
          child: Center(
            child: Image.network(
              PhotoUrl.build(widget.paths[i]),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Center(
                child: Icon(Icons.broken_image_outlined,
                    size: 48, color: Colors.white54),
              ),
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
