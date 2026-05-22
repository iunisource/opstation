import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import 'driver_export_pdf_sheet.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';

class DriverReportsScreen extends ConsumerStatefulWidget {
  const DriverReportsScreen({super.key});

  @override
  ConsumerState<DriverReportsScreen> createState() =>
      _DriverReportsScreenState();
}

enum _Period { today, week, month, custom }

class _DriverReportsScreenState extends ConsumerState<DriverReportsScreen> {
  _Period _period = _Period.week;
  DateTimeRange? _customRange;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Delivery reports',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (_customRange != null)
            IconButton(
              icon: const Icon(Icons.filter_alt_off_outlined),
              tooltip: 'Clear filter',
              onPressed: () => setState(() {
                _customRange = null;
                _period = _Period.week;
              }),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildFilters(),
          const Divider(height: 1),
          Expanded(child: _DeliveryList(period: _period, customRange: _customRange)),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _PeriodChip(
            label: 'Today',
            selected: _period == _Period.today,
            onTap: () => setState(() { _period = _Period.today; _customRange = null; }),
          ),
          _PeriodChip(
            label: 'This week',
            selected: _period == _Period.week,
            onTap: () => setState(() { _period = _Period.week; _customRange = null; }),
          ),
          _PeriodChip(
            label: 'This month',
            selected: _period == _Period.month,
            onTap: () => setState(() { _period = _Period.month; _customRange = null; }),
          ),
          _PeriodChip(
            label: _customRange == null
                ? 'Date range'
                : '${DateFormat('d MMM').format(_customRange!.start)} – ${DateFormat('d MMM').format(_customRange!.end)}',
            selected: _period == _Period.custom,
            icon: Icons.calendar_today_outlined,
            onTap: _pickDateRange,
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _customRange,
    );
    if (picked != null) {
      setState(() {
        _customRange = picked;
        _period = _Period.custom;
      });
    }
  }
}

class _DeliveryList extends ConsumerWidget {
  final _Period period;
  final DateTimeRange? customRange;

  const _DeliveryList({required this.period, required this.customRange});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;

    return FutureBuilder<List<Delivery>>(
      future: _load(ref, user?.id),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final list = snap.data ?? [];
        if (list.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No completed deliveries in this period.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        // Group by day
        final grouped = _groupByDay(list);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: grouped.length,
          itemBuilder: (_, i) {
            final (day, deliveries) = grouped[i];
            return _DayGroup(day: day, deliveries: deliveries);
          },
        );
      },
    );
  }

  Future<List<Delivery>> _load(WidgetRef ref, String? userId) async {
    if (userId == null) return [];
    final now = DateTime.now();
    DateTime start;
    DateTime end = now;

    if (period == _Period.custom && customRange != null) {
      start = customRange!.start;
      end = customRange!.end;
    } else {
      switch (period) {
        case _Period.today:
          start = DateTime(now.year, now.month, now.day);
          break;
        case _Period.week:
          start = DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6));
          break;
        case _Period.month:
          start = DateTime(now.year, now.month, 1);
          break;
        case _Period.custom:
          start = DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6));
          break;
      }
    }

    final repo = ref.read(deliveryRepositoryProvider);
    final results = await repo.list(
      statuses: {DeliveryStatus.completed, DeliveryStatus.cancelled},
      driverId: userId,
      from: start,
      to: end,
    );
    results.sort((a, b) {
      final at = a.completedAt ?? a.createdAt;
      final bt = b.completedAt ?? b.createdAt;
      return bt.compareTo(at);
    });
    return results;
  }

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

class _DayGroup extends StatelessWidget {
  final DateTime day;
  final List<Delivery> deliveries;
  const _DayGroup({required this.day, required this.deliveries});

  @override
  Widget build(BuildContext context) {
    final dayCash = deliveries.fold<int>(0, (s, d) => s + d.cashCollected);
    final dayStops = deliveries.fold<int>(0, (s, d) => s + d.stops.length);
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
                '$dayStops stops · Rs $dayCash collected',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondaryLight),
              ),
            ],
          ),
        ),
        for (final d in deliveries) _DeliveryTile(delivery: d),
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

class _DeliveryTile extends StatelessWidget {
  final Delivery delivery;
  const _DeliveryTile({required this.delivery});

  @override
  Widget build(BuildContext context) {
    final isCancelled = delivery.status == DeliveryStatus.cancelled;
    final when = delivery.completedAt ?? delivery.createdAt;

    return InkWell(
      onTap: () => showDriverExportSheet(context, delivery: delivery),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isCancelled
                    ? AppColors.dangerLight
                    : AppColors.successLight,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(
                isCancelled
                    ? Icons.cancel_outlined
                    : Icons.picture_as_pdf_outlined,
                color: isCancelled
                    ? AppColors.dangerDark
                    : AppColors.successDark,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          isCancelled
                              ? 'Cancelled · ${delivery.stops.length} stops'
                              : '${delivery.deliveredCount}/${delivery.stops.length} delivered',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      StatusBadge(
                        label: isCancelled ? 'Cancelled' : 'Completed',
                        tone: isCancelled
                            ? StatusBadgeTone.danger
                            : StatusBadgeTone.success,
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${DateFormat('d MMM · HH:mm').format(when)} · '
                    'Rs ${delivery.cashCollected} collected · '
                    '${delivery.stops.length} stops',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right,
                color: AppColors.textTertiaryLight, size: 20),
          ],
        ),
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.borderLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13,
                  color: selected ? Colors.white
                      : Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
