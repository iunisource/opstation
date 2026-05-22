import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../auth/providers/auth_controller.dart';
import '../../dispatch/data/delivery_repository.dart';
import '../../dispatch/models/delivery.dart';

/// Home for the dispatch-manager role.
///
/// Two stat tiles at the top (active count, completed today). Below:
/// a status-filtered list of deliveries, newest first, with a big FAB
/// to create a new draft.
class DispatchHomeScreen extends ConsumerStatefulWidget {
  const DispatchHomeScreen({super.key});

  @override
  ConsumerState<DispatchHomeScreen> createState() =>
      _DispatchHomeScreenState();
}

class _DispatchHomeScreenState extends ConsumerState<DispatchHomeScreen> {
  DeliveryStatus? _filter;

  static const _defaultDays = 7;

  Future<List<Delivery>> _load() {
    final repo = ref.read(deliveryRepositoryProvider);
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: _defaultDays - 1));
    if (_filter == null) {
      return repo.list(from: from);
    }
    // Active statuses (draft, assigned, in_progress) are not date-capped
    // — a delivery assigned two weeks ago and still in-progress should
    // still appear.
    final activeStatuses = {
      DeliveryStatus.draft,
      DeliveryStatus.assigned,
      DeliveryStatus.inProgress,
    };
    if (activeStatuses.contains(_filter)) {
      return repo.list(statuses: {_filter!});
    }
    return repo.list(statuses: {_filter!}, from: from);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'Dispatch';

    return RoleHomeScaffold(
      appBarTitle: 'Dispatch',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await context.push<bool>('/dispatch/delivery/new');
          if (result == true && mounted) setState(() {});
        },
        icon: const Icon(Icons.add),
        label: const Text('New delivery'),
      ),
      body: FutureBuilder<List<Delivery>>(
        future: _load(),
        builder: (context, snap) {
          final all = snap.data ?? const <Delivery>[];
          final now = DateTime.now();
          final startOfDay = DateTime(now.year, now.month, now.day);
          final activeCount = all
              .where((d) =>
                  d.status == DeliveryStatus.assigned ||
                  d.status == DeliveryStatus.inProgress)
              .length;
          final completedTodayCount = all
              .where((d) =>
                  d.status == DeliveryStatus.completed &&
                  d.completedAt != null &&
                  d.completedAt!.isAfter(startOfDay))
              .length;

          return RefreshIndicator(
            onRefresh: () async => setState(() {}),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              children: [
                const SizedBox(height: 8),
                Text(
                  'Hi, $firstName',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Delivery operations',
                  style: TextStyle(
                    color: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.color
                        ?.withOpacity(0.65),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 20),
                const TempPasswordBanner(),
                Row(
                  children: [
                    Expanded(
                      child: StatTile(
                        icon: Icons.local_shipping_outlined,
                        iconBg: AppColors.warningLight,
                        iconFg: AppColors.warningDark,
                        value: '$activeCount',
                        label: 'Active deliveries',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: StatTile(
                        icon: Icons.check_circle_outline,
                        iconBg: AppColors.successLight,
                        iconFg: AppColors.successDark,
                        value: '$completedTodayCount',
                        label: 'Completed today',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const SectionLabel('Deliveries'),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => context.push('/dispatch/history'),
                      icon: const Icon(Icons.history, size: 14),
                      label: const Text('View all'),
                      style: TextButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _FilterBar(
                  selected: _filter,
                  onChanged: (v) => setState(() => _filter = v),
                ),
                const SizedBox(height: 12),
                if (_filter == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Showing last 7 days · tap View all for older deliveries',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondaryLight,
                      ),
                    ),
                  ),
                if (snap.connectionState == ConnectionState.waiting)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if (all.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.borderLight),
                    ),
                    child: const Center(
                      child: Text(
                        'No deliveries yet. Tap "New delivery" to create one.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  for (final d in all) _DeliveryRow(delivery: d),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final DeliveryStatus? selected;
  final ValueChanged<DeliveryStatus?> onChanged;
  const _FilterBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, DeliveryStatus? value) {
      final isSelected = selected == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isSelected ? AppColors.primary : AppColors.borderLight,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          pill('All', null),
          pill('Draft', DeliveryStatus.draft),
          pill('Assigned', DeliveryStatus.assigned),
          pill('In progress', DeliveryStatus.inProgress),
          pill('Completed', DeliveryStatus.completed),
          pill('Cancelled', DeliveryStatus.cancelled),
        ],
      ),
    );
  }
}

class _DeliveryRow extends StatelessWidget {
  final Delivery delivery;
  const _DeliveryRow({required this.delivery});

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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            context.push('/dispatch/delivery/${delivery.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      delivery.driverName ?? 'Unassigned',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
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
              const SizedBox(height: 4),
              Text(
                '${delivery.stops.length} stops · Rs ${delivery.totalAmount} (${delivery.cashAmount} cash, ${delivery.creditAmount} credit)',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                DateFormat('d MMM · HH:mm').format(delivery.createdAt),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textTertiaryLight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
