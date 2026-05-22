import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';

/// All past deliveries for the signed-in driver, with a date range
/// filter. Covers the case a driver needs to look beyond the 7-day
/// recent window on the home screen (auditor question, disputed
/// payment, etc.) without contacting dispatch.
///
/// Only completed and cancelled deliveries are shown — active/assigned
/// deliveries belong on home.
class DriverHistoryScreen extends ConsumerStatefulWidget {
  const DriverHistoryScreen({super.key});

  @override
  ConsumerState<DriverHistoryScreen> createState() =>
      _DriverHistoryScreenState();
}

class _DriverHistoryScreenState extends ConsumerState<DriverHistoryScreen> {
  DateTimeRange? _range;

  /// Preset ranges shown as chips above the list. "All time" is the
  /// default — no filter applied.
  late final _presets = <_RangePreset>[
    _RangePreset('All time', null),
    _RangePreset('Last 7 days', _last(7)),
    _RangePreset('Last 30 days', _last(30)),
    _RangePreset('This month', _thisMonth()),
  ];

  DateTimeRange _last(int days) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
    final start = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: days - 1));
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange _thisMonth() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    return DateTimeRange(start: start, end: end);
  }

  Future<List<Delivery>> _load() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return [];
    return ref.read(deliveryRepositoryProvider).list(
          statuses: const {
            DeliveryStatus.completed,
            DeliveryStatus.cancelled,
          },
          driverId: user.id,
          from: _range?.start,
          to: _range?.end,
        );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null) {
      setState(() => _range = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Delivery history',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          _FilterBar(
            presets: _presets,
            current: _range,
            onPreset: (r) => setState(() => _range = r),
            onCustom: _pickCustomRange,
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<Delivery>>(
              future: _load(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snap.data ?? const <Delivery>[];
                if (list.isEmpty) {
                  return _EmptyState(range: _range);
                }
                final grouped = _groupByDay(list);
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: grouped.length,
                  itemBuilder: (_, i) {
                    final entry = grouped[i];
                    return _DayGroup(
                      day: entry.$1,
                      deliveries: entry.$2,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Groups the flat list into (date, deliveries) tuples keyed by
  /// delivery day. Expects the repo to return newest-first.
  List<(DateTime, List<Delivery>)> _groupByDay(List<Delivery> items) {
    final map = <DateTime, List<Delivery>>{};
    for (final d in items) {
      final w = d.completedAt ?? d.createdAt;
      final day = DateTime(w.year, w.month, w.day);
      map.putIfAbsent(day, () => []).add(d);
    }
    final entries = map.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return [for (final e in entries) (e.key, e.value)];
  }
}

class _RangePreset {
  final String label;
  final DateTimeRange? range;
  _RangePreset(this.label, this.range);
}

class _FilterBar extends StatelessWidget {
  final List<_RangePreset> presets;
  final DateTimeRange? current;
  final ValueChanged<DateTimeRange?> onPreset;
  final VoidCallback onCustom;

  const _FilterBar({
    required this.presets,
    required this.current,
    required this.onPreset,
    required this.onCustom,
  });

  bool _isActive(_RangePreset p) {
    if (p.range == null && current == null) return true;
    if (p.range == null || current == null) return false;
    return p.range!.start == current!.start &&
        p.range!.end.day == current!.end.day &&
        p.range!.end.month == current!.end.month &&
        p.range!.end.year == current!.end.year;
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM');
    String? customLabel;
    if (current != null && !presets.any(_isActive)) {
      customLabel =
          '${fmt.format(current!.start)} – ${fmt.format(current!.end)}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in presets)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(p.label),
                  selected: _isActive(p),
                  onSelected: (_) => onPreset(p.range),
                ),
              ),
            if (customLabel != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(customLabel),
                  selected: true,
                  onSelected: (_) {},
                ),
              ),
            TextButton.icon(
              onPressed: onCustom,
              icon: const Icon(Icons.date_range, size: 16),
              label: const Text('Custom'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final DateTimeRange? range;
  const _EmptyState({this.range});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.history,
                size: 40, color: AppColors.textTertiaryLight),
            const SizedBox(height: 12),
            Text(
              range == null
                  ? 'No past deliveries yet.'
                  : 'No deliveries in this range.',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (range != null) ...[
              const SizedBox(height: 4),
              const Text(
                'Try a wider range or \"All time\".',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  final DateTime day;
  final List<Delivery> deliveries;
  const _DayGroup({required this.day, required this.deliveries});

  @override
  Widget build(BuildContext context) {
    // Sum what the driver actually collected on this day — useful for
    // end-of-day reconciliation at a glance.
    final dayCash = deliveries.fold<int>(0, (s, d) => s + d.cashCollected);
    final dayStops =
        deliveries.fold<int>(0, (s, d) => s + d.stops.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(
            children: [
              Text(
                _formatDay(day),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const Spacer(),
              Text(
                '$dayStops stops · Rs $dayCash',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondaryLight,
                ),
              ),
            ],
          ),
        ),
        for (final d in deliveries) _HistoryRow(delivery: d),
      ],
    );
  }

  String _formatDay(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == today) return 'TODAY';
    if (day == yesterday) return 'YESTERDAY';
    return DateFormat('EEE, d MMM y').format(day).toUpperCase();
  }
}

class _HistoryRow extends StatelessWidget {
  final Delivery delivery;
  const _HistoryRow({required this.delivery});

  @override
  Widget build(BuildContext context) {
    final isCancelled = delivery.status == DeliveryStatus.cancelled;
    final when = delivery.completedAt ?? delivery.createdAt;
    return InkWell(
      onTap: () => GoRouter.of(context)
          .push('/driver/delivery/${delivery.id}'),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Icon(
              isCancelled
                  ? Icons.cancel_outlined
                  : Icons.check_circle_outline,
              size: 20,
              color: isCancelled ? AppColors.danger : AppColors.success,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isCancelled
                        ? 'Cancelled · ${delivery.stops.length} stops'
                        : '${delivery.deliveredCount}/${delivery.stops.length} delivered · Rs ${delivery.cashCollected}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        DateFormat('HH:mm').format(when),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondaryLight,
                        ),
                      ),
                      if (delivery.failedCount > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${delivery.failedCount} failed',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.danger,
                          ),
                        ),
                      ],
                      if (delivery.outsideGeofenceCount > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${delivery.outsideGeofenceCount} outside',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.warningDark,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 18, color: AppColors.textTertiaryLight),
          ],
        ),
      ),
    );
  }
}
