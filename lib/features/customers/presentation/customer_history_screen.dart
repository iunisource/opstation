import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

class CustomerHistoryScreen extends ConsumerStatefulWidget {
  final String customerId;
  final String customerName;
  final String? customerCode;

  const CustomerHistoryScreen({
    super.key,
    required this.customerId,
    required this.customerName,
    this.customerCode,
  });

  @override
  ConsumerState<CustomerHistoryScreen> createState() =>
      _CustomerHistoryScreenState();
}

class _CustomerHistoryScreenState
    extends ConsumerState<CustomerHistoryScreen> {
  List<Map<String, dynamic>> _visits = [];
  Map<String, String> _signedUrls = {};
  bool _loading = true;
  String? _error;

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 90));
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

      final res = await Supabase.instance.client
          .from('visits')
          .select()
          .eq('customer_id', widget.customerId)
          .gte('timestamp', fromIso)
          .lt('timestamp', toIso)
          .order('timestamp', ascending: false);
      final visits = List<Map<String, dynamic>>.from(res);

      final paths = <String>{};
      for (final v in visits) {
        final j = v['photo_paths_json'] as String?;
        if (j == null || j.isEmpty) continue;
        try {
          for (final x in jsonDecode(j) as List) {
            if (x is String && x.isNotEmpty) paths.add(x);
          }
        } catch (_) {}
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
        _visits = visits;
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

  int get _totalCollected =>
      _visits.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));
  int get _uniqueSalespeople =>
      _visits.map((v) => v['user_id'] as String? ?? '').toSet().length;

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
                        const Text('Customer history',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(
                          widget.customerCode != null &&
                                  widget.customerCode!.isNotEmpty
                              ? '${widget.customerCode} · ${widget.customerName}'
                              : widget.customerName,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary),
                        ),
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
                  _StatPill(label: 'Visits', value: '${_visits.length}'),
                  const SizedBox(width: 8),
                  _StatPill(
                      label: 'Salespeople',
                      value: '$_uniqueSalespeople'),
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
    if (_visits.isEmpty) {
      return const Center(
        child: Text('No visits in this date range',
            style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      itemCount: _visits.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        return _VisitCard(visit: _visits[i], urls: _signedUrls);
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

// ---- Visit card -----------------------------------------------------

class _VisitCard extends StatelessWidget {
  final Map<String, dynamic> visit;
  final Map<String, String> urls;
  const _VisitCard({required this.visit, required this.urls});

  @override
  Widget build(BuildContext context) {
    final status = visit['status'] as String? ?? '';
    final ts = visit['timestamp'] != null
        ? DateTime.parse(visit['timestamp'] as String).toLocal()
        : null;
    final salesperson = visit['user_name'] as String? ?? '—';
    final role = visit['user_role'] as String? ?? '';
    final amount = (visit['amount'] as int?) ?? 0;
    final receipt = visit['receipt_number'] as String?;
    final notes = visit['notes'] as String?;
    final lat = (visit['captured_lat'] as num?)?.toDouble();
    final lng = (visit['captured_lng'] as num?)?.toDouble();
    final distance = (visit['distance_meters'] as num?)?.toDouble();
    final pathsJson = visit['photo_paths_json'] as String?;
    List<String> paths = const [];
    if (pathsJson != null && pathsJson.isNotEmpty) {
      try {
        paths = (jsonDecode(pathsJson) as List).whereType<String>().toList();
      } catch (_) {}
    }

    final (icon, color, label) = switch (status) {
      'verified' => (Icons.check_circle, AppTheme.success, 'Verified'),
      'outside' => (Icons.warning_amber_rounded, AppTheme.warning, 'Outside'),
      'noLocation' => (
        Icons.location_off_outlined,
        AppTheme.danger,
        'No location'
      ),
      'skipped' => (Icons.skip_next, AppTheme.textSecondary, 'Skipped'),
      _ => (Icons.circle_outlined, AppTheme.textSecondary, status),
    };

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
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
                  const SizedBox(width: 8),
                  if (ts != null)
                    Text(DateFormat('d MMM y · HH:mm').format(ts),
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.person_outline,
                      size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(role.isEmpty ? salesperson : '$salesperson · $role',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary)),
                ]),
                if (lat != null && lng != null) ...[
                  const SizedBox(height: 4),
                  _CoordsRow(lat: lat, lng: lng, distance: distance),
                ],
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(notes,
                      style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: AppTheme.textSecondary)),
                ],
                if (paths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _PhotoThumbStrip(paths: paths, urls: urls),
                ],
              ],
            ),
          ),
          if (amount > 0) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Rs $amount',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                if (receipt != null && receipt.isNotEmpty)
                  Text('#$receipt',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
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
  const _CoordsRow({required this.lat, required this.lng, this.distance});

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
          Text('· ${distance!.toStringAsFixed(0)} m away',
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
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
