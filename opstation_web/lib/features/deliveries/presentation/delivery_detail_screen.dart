import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              const SizedBox(width: 8),
              const Text('Delivery Details',
                  style: TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800)),
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
      } else {
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
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // Totals
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
            child: Text('No stops on this delivery.',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic))),
      );
    }
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
            Text('Stops (${_stops.length})',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
        const Divider(height: 1),
        for (int i = 0; i < _stops.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _StopRow(stop: _stops[i], statusColor: _statusColor),
        ],
      ]),
    );
  }
}

class _StopRow extends StatelessWidget {
  final Map<String, dynamic> stop;
  final Color Function(String) statusColor;
  const _StopRow({required this.stop, required this.statusColor});

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
    final verification =
        stop['verification'] as String? ?? 'pending';
    final failureReason = stop['failure_reason'] as String?;

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
                        '${stop['customer_code']} · ${stop['customer_name']}',
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
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
              child: Row(children: [
                _miniKV('Payment',
                    paymentType == 'cash' ? 'Cash' : 'Credit'),
                const SizedBox(width: 24),
                _miniKV('Amount', 'Rs $amount'),
                if (cashReceived != null) ...[
                  const SizedBox(width: 24),
                  _miniKV('Received', 'Rs $cashReceived'),
                ],
                const SizedBox(width: 24),
                _miniKV('Verification', verification),
                if (stop['delivered_at'] != null) ...[
                  const SizedBox(width: 24),
                  _miniKV('Delivered',
                      _fmtTime(stop['delivered_at'])),
                ],
              ]),
            ),
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
