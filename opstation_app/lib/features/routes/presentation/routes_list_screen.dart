import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../salesperson/models/sales_route.dart';
import '../providers/routes_controller.dart';

class RoutesListScreen extends ConsumerStatefulWidget {
  const RoutesListScreen({super.key});

  @override
  ConsumerState<RoutesListScreen> createState() => _RoutesListScreenState();
}

class _RoutesListScreenState extends ConsumerState<RoutesListScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(routesControllerProvider);
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Routes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/admin/routes/new'),
        icon: const Icon(Icons.add_road),
        label: const Text('New route'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: _buildBody,
      ),
    );
  }

  Widget _buildBody(RouteListState state) {
    final filtered = state.filtered;
    final filters = state.filters;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => ref
                .read(routesControllerProvider.notifier)
                .updateFilters(filters.copyWith(query: v)),
            decoration: InputDecoration(
              hintText: 'Search route name...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: filters.query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        ref
                            .read(routesControllerProvider.notifier)
                            .updateFilters(filters.copyWith(query: ''));
                      },
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _KindChip(
                label: 'All',
                selected: filters.kindFilter == null,
                onTap: () => ref
                    .read(routesControllerProvider.notifier)
                    .updateFilters(filters.copyWith(clearKind: true)),
              ),
              _KindChip(
                label: 'Recurring',
                selected: filters.kindFilter == RouteKind.recurring,
                onTap: () => ref
                    .read(routesControllerProvider.notifier)
                    .updateFilters(filters.copyWith(
                        kindFilter: RouteKind.recurring)),
              ),
              _KindChip(
                label: 'One-time',
                selected: filters.kindFilter == RouteKind.oneTime,
                onTap: () => ref
                    .read(routesControllerProvider.notifier)
                    .updateFilters(
                        filters.copyWith(kindFilter: RouteKind.oneTime)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Row(
            children: [
              Text(
                '${filtered.length} of ${state.all.where((r) => r.isActive).length} active',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => ref
                    .read(routesControllerProvider.notifier)
                    .updateFilters(filters.copyWith(
                        includeInactive: !filters.includeInactive)),
                icon: Icon(
                  filters.includeInactive
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                ),
                label: Text(
                  filters.includeInactive
                      ? 'Hide inactive'
                      : 'Show inactive',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No routes match your filters.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _RouteTile(route: filtered[i]),
                ),
        ),
      ],
    );
  }
}

class _RouteTile extends StatelessWidget {
  final SalesRoute route;
  const _RouteTile({required this.route});

  @override
  Widget build(BuildContext context) {
    final kindColor = route.kind == RouteKind.recurring
        ? AppColors.success
        : AppColors.warningDark;
    final kindBg = route.kind == RouteKind.recurring
        ? AppColors.successLight
        : AppColors.warningLight;
    final kindIcon = route.kind == RouteKind.recurring
        ? Icons.all_inclusive
        : Icons.event_outlined;

    return InkWell(
      onTap: () => context.push('/admin/routes/${route.id}'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: kindBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(kindIcon, color: kindColor, size: 22),
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
                          route.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!route.isActive)
                        const StatusBadge(
                            label: 'Inactive',
                            tone: StatusBadgeTone.neutral),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${route.stops.length} stops · ${route.kind == RouteKind.recurring ? "Recurring" : "One-time"}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 20, color: AppColors.textTertiaryLight),
          ],
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _KindChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.borderLight,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? Colors.white
                  : Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }
}
