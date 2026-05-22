import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

class DriverHistoryScreen extends ConsumerStatefulWidget {
  final String userId;
  final String userName;
  const DriverHistoryScreen({
    super.key,
    required this.userId,
    required this.userName,
  });

  @override
  ConsumerState<DriverHistoryScreen> createState() =>
      _DriverHistoryScreenState();
}

class _DriverHistoryScreenState extends ConsumerState<DriverHistoryScreen> {
  List<Map<String, dynamic>> _deliveries = [];
  Map<String, List<Map<String, dynamic>>> _stopsByDelivery = {};
  Map<String, String> _signedUrls = {};
  final Set<String> _expanded = {};
  bool _loading = true;
  String? _error;

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 30));
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fromIso = DateFormat('yyyy-MM-dd').format(_from);
      final toIso =
          DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));

      final delRes = await Supabase.instance.client
          .from('deliveries')
          .select()
          .eq('driver_id', widget.userId)
          .gte('created_at', fromIso)
          .lt('created_at', toIso)
          .order('created_at', ascending: false);
      final deliveries = List<Map<String, dynamic>>.from(delRes);

      final stopsByDelivery = <String, List<Map<String, dynamic>>>{};
      if (deliveries.isNotEmpty) {
        final ids = deliveries.map((d) => d['id'] as String).toList();
        final stopsRes = await Supabase.instance.client
            .from('delivery_stops')
            .select()
            .inFilter('delivery_id', ids)
            .order('sequence', ascending: true);
        final stops = List<Map<String, dynamic>>.from(stopsRes);
        for (final s in stops) {
          (stopsByDelivery[s['delivery_id'] as String] ??= []).add(s);
        }
      }

      // Sign delivery photos
      final paths = <String>{};
      for (final list in stopsByDelivery.values) {
        for (final s in list) {
          final j = s['photo_paths_json'] as String?;
          if (j == null || j.isEmpty) continue;
          try {
            for (final x in jsonDecode(j) as List) {
              if (x is String && x.isNotEmpty) paths.add(x);
            }
          } catch (_) {}
        }
      }
      final urls = <String, String>{};
      if (paths.isNotEmpty) {
        try {
          final r = await Supabase.instance.client.storage
              .from('opstation-photos')
              .createSignedUrls(paths.toList(), 3600);
          for (final s in r) {
            if (s.signedUrl != null) urls[s.path!] = s.signedUrl!;
          }
        } catch (_) {}
      }

      setState(() {
        _deliveries = deliveries;
        _stopsByDelivery = stopsByDelivery;
        _signedUrls = urls;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
    _load();
  }

  int get _totalStops =>
      _stopsByDelivery.values.fold(0, (s, l) => s + l.length);
  int get _totalDelivered => _stopsByDelivery.values.fold(0, (s, l) {
        return s + l.where((x) => x['status'] == 'delivered').length;
      });
  int get _totalCollected => _stopsByDelivery.values.fold(0, (s, l) {
        return s + l.fold<int>(0, (ss, x) => ss + ((x['cash_received'] as int?) ?? 0));
      });

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM y');
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 16, 32, 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Back',
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Delivery history',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(widget.userName,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
                    tooltip: 'Refresh',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
              child: Row(
                children: [
                  _DateChip(
                      label: 'From',
                      date: df.format(_from),
                      onTap: () => _pickDate(isFrom: true)),
                  const SizedBox(width: 8),
                  _DateChip(
                      label: 'To',
                      date: df.format(_to),
                      onTap: () => _pickDate(isFrom: false)),
                  const SizedBox(width: 16),
                  _StatPill(
                      label: 'Deliveries', value: '${_deliveries.length}'),
                  const SizedBox(width: 8),
                  _StatPill(label: 'Stops', value: '$_totalStops'),
                  const SizedBox(width: 8),
                  _StatPill(label: 'Delivered', value: '$_totalDelivered'),
                  const SizedBox(width: 8),
                  _StatPill(
                      label: 'Collected', value: 'Rs $_totalCollected'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Failed to load: $_error',
              style: const TextStyle(color: AppTheme.danger)),
        ),
      );
    }
    if (_deliveries.isEmpty) {
      return const Center(
        child: Text('No deliveries in this date range',
            style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      itemCount: _deliveries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final d = _deliveries[i];
        final id = d['id'] as String;
        final stops = _stopsByDelivery[id] ?? const [];
        return _DeliveryCard(
          delivery: d,
          stops: stops,
          urls: _signedUrls,
          expanded: _expanded.contains(id),
          onToggle: () => setState(() {
            if (_expanded.contains(id)) {
              _expanded.remove(id);
            } else {
              _expanded.add(id);
            }
          }),
        );
      },
    );
  }
}

// ---- Filter chips ----------------------------------------------------

class _DateChip extends StatelessWidget {
  final String label;
  final String date;
  final VoidCallback onTap;
  const _DateChip(
      {required this.label, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Text('$label: ',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          Text(date,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.calendar_today_outlined,
              size: 14, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  const _StatPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(width: 6),
        Text(value,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.primary)),
      ]),
    );
  }
}

// ---- Delivery card --------------------------------------------------

class _DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> delivery;
  final List<Map<String, dynamic>> stops;
  final Map<String, String> urls;
  final bool expanded;
  final VoidCallback onToggle;

  const _DeliveryCard({
    required this.delivery,
    required this.stops,
    required this.urls,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final status = delivery['status'] as String? ?? 'planned';
    final createdAt = delivery['created_at'] != null
        ? DateTime.parse(delivery['created_at'] as String).toLocal()
        : null;
    final completedAt = delivery['completed_at'] != null
        ? DateTime.parse(delivery['completed_at'] as String).toLocal()
        : null;
    final createdBy = delivery['created_by_name'] as String? ?? '—';
    final dfDate = DateFormat('d MMM y');
    final dfTime = DateFormat('HH:mm');

    final delivered =
        stops.where((s) => s['status'] == 'delivered').length;
    final amount =
        stops.fold<int>(0, (s, x) => s + ((x['cash_received'] as int?) ?? 0));

    final (statusColor, statusLabel) = switch (status) {
      'completed' => (AppTheme.success, 'Completed'),
      'in_progress' => (AppTheme.warning, 'In progress'),
      'planned' => (AppTheme.textSecondary, 'Planned'),
      'cancelled' => (AppTheme.danger, 'Cancelled'),
      _ => (AppTheme.textSecondary, status),
    };

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.local_shipping_outlined,
                        color: statusColor, size: 20),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Text(
                            'Dispatched by $createdBy',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Row(children: [
                          if (createdAt != null) ...[
                            Text(dfDate.format(createdAt),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                            const SizedBox(width: 6),
                            Text('· created ${dfTime.format(createdAt)}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                          ],
                          if (completedAt != null) ...[
                            const SizedBox(width: 6),
                            Text('· done ${dfTime.format(completedAt)}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                          ],
                        ]),
                      ],
                    ),
                  ),
                  _MiniStat(label: 'stops', value: '${stops.length}'),
                  const SizedBox(width: 10),
                  _MiniStat(label: 'delivered', value: '$delivered'),
                  const SizedBox(width: 10),
                  _MiniStat(label: 'collected', value: 'Rs $amount'),
                  const SizedBox(width: 10),
                  _StatusPill(label: statusLabel, color: statusColor),
                  const SizedBox(width: 8),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (stops.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No stops on this delivery',
                    style: TextStyle(color: AppTheme.textSecondary)),
              )
            else
              Column(
                children: [
                  for (final s in stops) _StopRow(stop: s, urls: urls),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        Text(label,
            style:
                const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ---- Stop row -------------------------------------------------------

class _StopRow extends StatelessWidget {
  final Map<String, dynamic> stop;
  final Map<String, String> urls;
  const _StopRow({required this.stop, required this.urls});

  @override
  Widget build(BuildContext context) {
    final status = stop['status'] as String? ?? 'pending';
    final verification = stop['verification'] as String? ?? '';
    final seq = (stop['sequence'] as int?) ?? 0;
    final custName = stop['customer_name'] as String? ?? '(unknown)';
    final custCode = stop['customer_code'] as String? ?? '';
    final item = stop['item_description'] as String? ?? '';
    final amount = (stop['amount'] as int?) ?? 0;
    final cashReceived = (stop['cash_received'] as int?) ?? 0;
    final paymentType = stop['payment_type'] as String? ?? '';
    final deliveredAt = stop['delivered_at'] != null
        ? DateTime.parse(stop['delivered_at'] as String).toLocal()
        : null;
    final failureReason = stop['failure_reason'] as String?;
    final lat = (stop['captured_lat'] as num?)?.toDouble();
    final lng = (stop['captured_lng'] as num?)?.toDouble();
    final distance = (stop['distance_meters'] as num?)?.toDouble();
    final pathsJson = stop['photo_paths_json'] as String?;
    List<String> paths = const [];
    if (pathsJson != null && pathsJson.isNotEmpty) {
      try {
        paths = (jsonDecode(pathsJson) as List).whereType<String>().toList();
      } catch (_) {}
    }

    final (icon, color, label) = switch (status) {
      'delivered' => (Icons.check_circle, AppTheme.success, 'Delivered'),
      'failed' => (Icons.cancel_outlined, AppTheme.danger, 'Failed'),
      'skipped' => (Icons.skip_next, AppTheme.textSecondary, 'Skipped'),
      'pending' => (Icons.schedule, AppTheme.textSecondary, 'Pending'),
      _ => (Icons.circle_outlined, AppTheme.textSecondary, status),
    };

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Text('$seq',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      custCode.isNotEmpty
                          ? '$custCode · $custName'
                          : custName,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 10,
                            color: color,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
                if (item.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(item,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ],
                if (deliveredAt != null) ...[
                  const SizedBox(height: 4),
                  Text(DateFormat('HH:mm · d MMM').format(deliveredAt),
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary)),
                ],
                if (lat != null && lng != null) ...[
                  const SizedBox(height: 4),
                  _CoordsRow(
                      lat: lat,
                      lng: lng,
                      distance: distance,
                      verification: verification),
                ],
                if (failureReason != null && failureReason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('Reason: $failureReason',
                      style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: AppTheme.danger)),
                ],
                if (paths.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _PhotoThumbStrip(paths: paths, urls: urls),
                ],
              ],
            ),
          ),
          if (amount > 0 || cashReceived > 0) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (cashReceived > 0)
                  Text('Rs $cashReceived',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w800))
                else
                  Text('Rs $amount',
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w600)),
                if (paymentType.isNotEmpty)
                  Text(paymentType,
                      style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CoordsRow extends StatelessWidget {
  final double lat;
  final double lng;
  final double? distance;
  final String verification;
  const _CoordsRow(
      {required this.lat,
      required this.lng,
      this.distance,
      this.verification = ''});

  @override
  Widget build(BuildContext context) {
    final formatted = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.location_on_outlined,
            size: 12, color: AppTheme.textSecondary),
        const SizedBox(width: 3),
        InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: formatted));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Coordinates copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            }
          },
          child: Text(formatted,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: () async {
            final uri = Uri.parse(
                'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          child: const Text('Open in Maps',
              style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w700)),
        ),
        if (distance != null) ...[
          const SizedBox(width: 8),
          Text('· ${distance!.toStringAsFixed(0)} m',
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ],
        if (verification.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text('· $verification',
              style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.textSecondary,
                  fontStyle: FontStyle.italic)),
        ],
      ],
    );
  }
}

// ---- Photos ---------------------------------------------------------

class _PhotoThumbStrip extends StatelessWidget {
  final List<String> paths;
  final Map<String, String> urls;
  const _PhotoThumbStrip({required this.paths, required this.urls});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in paths)
          if (urls[p] != null) _Thumb(url: urls[p]!),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final String url;
  const _Thumb({required this.url});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => showDialog(
        context: context,
        barrierColor: Colors.black87,
        builder: (_) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: Colors.transparent,
          child: InteractiveViewer(
            child: Image.network(url, fit: BoxFit.contain),
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          url,
          width: 56,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 56,
            height: 56,
            color: AppTheme.background,
            child: const Icon(Icons.broken_image,
                color: AppTheme.textSecondary, size: 20),
          ),
        ),
      ),
    );
  }
}
