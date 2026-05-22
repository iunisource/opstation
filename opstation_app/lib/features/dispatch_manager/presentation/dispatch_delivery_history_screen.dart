import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';

/// Full delivery history for dispatch managers and admins.
/// Shows all deliveries across all dates with filter chips and a
/// custom date-range picker — mirrors the driver history screen pattern.
class DispatchDeliveryHistoryScreen extends ConsumerStatefulWidget {
  const DispatchDeliveryHistoryScreen({super.key});

  @override
  ConsumerState<DispatchDeliveryHistoryScreen> createState() =>
      _DispatchDeliveryHistoryScreenState();
}

class _DispatchDeliveryHistoryScreenState
    extends ConsumerState<DispatchDeliveryHistoryScreen> {
  DateTimeRange? _range;
  DeliveryStatus? _status;

  late final _presets = <_Preset>[
    _Preset('All time', null),
    _Preset('Last 7 days', _last(7)),
    _Preset('Last 30 days', _last(30)),
    _Preset('This month', _thisMonth()),
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
    return DateTimeRange(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 0, 23, 59, 59),
    );
  }

  bool _isPresetActive(_Preset p) {
    if (p.range == null && _range == null) return true;
    if (p.range == null || _range == null) return false;
    return p.range!.start == _range!.start &&
        p.range!.end.day == _range!.end.day &&
        p.range!.end.month == _range!.end.month &&
        p.range!.end.year == _range!.end.year;
  }

  Future<List<Delivery>> _load() {
    final repo = ref.read(deliveryRepositoryProvider);
    final statuses = _status == null
        ? null
        : <DeliveryStatus>{_status!};
    return repo.list(
      statuses: statuses != null ? statuses : null,
      from: _range?.start,
      to: _range?.end,
    );
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked != null && mounted) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM');
    String? customLabel;
    if (_range != null && !_presets.any(_isPresetActive)) {
      customLabel =
          '${fmt.format(_range!.start)} – ${fmt.format(_range!.end)}';
    }

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('All deliveries',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          // Date range filter row
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in _presets)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(p.label),
                        selected: _isPresetActive(p),
                        onSelected: (_) =>
                            setState(() => _range = p.range),
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
                    onPressed: _pickCustom,
                    icon: const Icon(Icons.date_range, size: 16),
                    label: const Text('Custom'),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Status filter row
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _statusChip('All', null),
                  _statusChip('Draft', DeliveryStatus.draft),
                  _statusChip('Assigned', DeliveryStatus.assigned),
                  _statusChip('In progress', DeliveryStatus.inProgress),
                  _statusChip('Completed', DeliveryStatus.completed),
                  _statusChip('Cancelled', DeliveryStatus.cancelled),
                ],
              ),
            ),
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
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.local_shipping_outlined,
                              size: 40,
                              color: AppColors.textTertiaryLight),
                          const SizedBox(height: 12),
                          Text(
                            _range == null && _status == null
                                ? 'No deliveries yet.'
                                : 'No deliveries match these filters.',
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final grouped = _groupByDay(list);
                return ListView.builder(
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: grouped.length,
                  itemBuilder: (_, i) => _DayGroup(
                    day: grouped[i].$1,
                    deliveries: grouped[i].$2,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, DeliveryStatus? value) {
    final selected = _status == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() {
          _status = value;
        }),
      ),
    );
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

class _Preset {
  final String label;
  final DateTimeRange? range;
  _Preset(this.label, this.range);
}

class _DayGroup extends StatelessWidget {
  final DateTime day;
  final List<Delivery> deliveries;
  const _DayGroup({required this.day, required this.deliveries});

  @override
  Widget build(BuildContext context) {
    final totalCash =
        deliveries.fold<int>(0, (s, d) => s + d.cashCollected);
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
                '${deliveries.length} ${deliveries.length == 1 ? "delivery" : "deliveries"} · Rs $totalCash',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondaryLight,
                ),
              ),
            ],
          ),
        ),
        for (final d in deliveries) _DeliveryHistoryRow(delivery: d),
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

class _DeliveryHistoryRow extends StatelessWidget {
  final Delivery delivery;
  const _DeliveryHistoryRow({required this.delivery});

  Color _statusColor() {
    switch (delivery.status) {
      case DeliveryStatus.draft:
        return AppColors.textTertiaryLight;
      case DeliveryStatus.assigned:
        return AppColors.primary;
      case DeliveryStatus.inProgress:
        return AppColors.warningDark;
      case DeliveryStatus.completed:
        return AppColors.success;
      case DeliveryStatus.cancelled:
        return AppColors.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    final when = delivery.completedAt ?? delivery.createdAt;
    return InkWell(
      onTap: () => GoRouter.of(context)
          .push('/dispatch/delivery/${delivery.id}'),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          delivery.driverName ?? 'Unassigned',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: _statusColor().withOpacity(0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          delivery.status.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: _statusColor(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${delivery.stops.length} ${delivery.stops.length == 1 ? "stop" : "stops"} · Rs ${delivery.cashAmount} to collect',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                  Text(
                    DateFormat('HH:mm').format(when),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondaryLight,
                    ),
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
