import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/initial_avatar.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/customer.dart';
import '../providers/customers_controller.dart';

class CustomersListScreen extends ConsumerStatefulWidget {
  const CustomersListScreen({super.key});

  @override
  ConsumerState<CustomersListScreen> createState() =>
      _CustomersListScreenState();
}

class _CustomersListScreenState extends ConsumerState<CustomersListScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openFilters(CustomersState state) async {
    final newFilters = await showModalBottomSheet<CustomerFilters>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CustomerFiltersSheet(
        initial: state.filters,
        categories: state.allCategories,
        groups: state.allGroups,
      ),
    );
    if (newFilters != null) {
      ref.read(customersControllerProvider.notifier).updateFilters(newFilters);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = canManageCustomers(user?.role);

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Customers',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/customers/new'),
              icon: const Icon(Icons.add),
              label: const Text('New'),
            )
          : null,
      body: ref.watch(customersControllerProvider).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Failed to load customers: $e'),
              ),
            ),
            data: (state) => _buildBody(state),
          ),
    );
  }

  Widget _buildBody(CustomersState state) {
    final filtered = state.filtered;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) {
                    ref.read(customersControllerProvider.notifier).updateFilters(
                        state.filters.copyWith(query: v));
                  },
                  decoration: InputDecoration(
                    hintText: 'Search name, phone, code...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: state.filters.query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _searchCtrl.clear();
                              ref
                                  .read(customersControllerProvider.notifier)
                                  .updateFilters(
                                    state.filters.copyWith(query: ''),
                                  );
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _FiltersButton(
                state: state,
                onTap: () => _openFilters(state),
              ),
            ],
          ),
        ),
        if (!state.filters.isDefault)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: _ActiveFiltersStrip(
              state: state,
              onClear: () {
                ref
                    .read(customersControllerProvider.notifier)
                    .updateFilters(const CustomerFilters());
                _searchCtrl.clear();
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Text(
                '${filtered.length} of ${state.all.length} customers',
                style: const TextStyle(
                  color: AppColors.textSecondaryLight,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? const Center(child: Text('No customers match your filters.'))
              : _CustomersGroupedList(customers: filtered),
        ),
      ],
    );
  }
}

/// Alphabetically grouped list using the first letter of shopName.
class _CustomersGroupedList extends StatelessWidget {
  final List<Customer> customers;
  const _CustomersGroupedList({required this.customers});

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Customer>>{};
    for (final c in customers) {
      final letter = c.shopName.isEmpty
          ? '#'
          : c.shopName.substring(0, 1).toUpperCase();
      final key = RegExp(r'[A-Z]').hasMatch(letter) ? letter : '#';
      groups.putIfAbsent(key, () => []).add(c);
    }
    final keys = groups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final key = keys[i];
        final items = groups[key]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                key,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondaryLight,
                ),
              ),
            ),
            for (final c in items) _CustomerTile(customer: c),
          ],
        );
      },
    );
  }
}

class _CustomerTile extends StatelessWidget {
  final Customer customer;
  const _CustomerTile({required this.customer});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        context.push('/customers/${customer.id}');
      },
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
            InitialAvatar(initials: customer.initials),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          customer.shopName,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (!customer.isActive)
                        const StatusBadge(
                            label: 'Inactive', tone: StatusBadgeTone.neutral),
                      if (!customer.hasLocation)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.location_off_outlined,
                              size: 16, color: AppColors.warningDark),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    customer.address.isEmpty
                        ? 'No address'
                        : customer.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondaryLight,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      _MiniChip(text: '#${customer.code}'),
                      if (customer.category != null)
                        _MiniChip(text: customer.category!),
                    ],
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

class _MiniChip extends StatelessWidget {
  final String text;
  const _MiniChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.borderLight,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.textSecondaryLight,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FiltersButton extends StatelessWidget {
  final CustomersState state;
  final VoidCallback onTap;

  const _FiltersButton({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = !state.filters.isDefault;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? AppColors.primary : AppColors.borderLight,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.tune,
          color: active ? Colors.white : AppColors.textPrimaryLight,
          size: 20,
        ),
      ),
    );
  }
}

class _ActiveFiltersStrip extends StatelessWidget {
  final CustomersState state;
  final VoidCallback onClear;

  const _ActiveFiltersStrip({required this.state, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    final f = state.filters;

    if (f.activeFilter != CustomerActiveFilter.active) {
      chips.add(_chip(
          f.activeFilter == CustomerActiveFilter.inactive ? 'Inactive' : 'All statuses'));
    }
    if (f.locationFilter == CustomerLocationFilter.hasLocation) {
      chips.add(_chip('Has location'));
    } else if (f.locationFilter == CustomerLocationFilter.noLocation) {
      chips.add(_chip('No location'));
    }
    if (f.category != null) chips.add(_chip('Category: ${f.category}'));
    if (f.group != null) chips.add(_chip('Group: ${f.group}'));

    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < chips.length; i++) ...[
                  chips[i],
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ),
        TextButton(
          onPressed: onClear,
          child: const Text('Clear'),
        ),
      ],
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _CustomerFiltersSheet extends StatefulWidget {
  final CustomerFilters initial;
  final List<String> categories;
  final List<String> groups;

  const _CustomerFiltersSheet({
    required this.initial,
    required this.categories,
    required this.groups,
  });

  @override
  State<_CustomerFiltersSheet> createState() => _CustomerFiltersSheetState();
}

class _CustomerFiltersSheetState extends State<_CustomerFiltersSheet> {
  late CustomerFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text('Filters',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 16),
              const _SectionLabel('Status'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  _pill('Active', _filters.activeFilter == CustomerActiveFilter.active,
                      () => setState(() => _filters =
                          _filters.copyWith(activeFilter: CustomerActiveFilter.active))),
                  _pill(
                      'Inactive',
                      _filters.activeFilter == CustomerActiveFilter.inactive,
                      () => setState(() => _filters = _filters.copyWith(
                          activeFilter: CustomerActiveFilter.inactive))),
                  _pill(
                      'All',
                      _filters.activeFilter == CustomerActiveFilter.all,
                      () => setState(() => _filters = _filters.copyWith(
                          activeFilter: CustomerActiveFilter.all))),
                ],
              ),
              const SizedBox(height: 16),
              const _SectionLabel('Location'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  _pill(
                      'Any',
                      _filters.locationFilter == CustomerLocationFilter.all,
                      () => setState(() => _filters = _filters.copyWith(
                          locationFilter: CustomerLocationFilter.all))),
                  _pill(
                      'Has location',
                      _filters.locationFilter == CustomerLocationFilter.hasLocation,
                      () => setState(() => _filters = _filters.copyWith(
                          locationFilter: CustomerLocationFilter.hasLocation))),
                  _pill(
                      'No location',
                      _filters.locationFilter == CustomerLocationFilter.noLocation,
                      () => setState(() => _filters = _filters.copyWith(
                          locationFilter: CustomerLocationFilter.noLocation))),
                ],
              ),
              if (widget.categories.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _SectionLabel('Category'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _pill('All', _filters.category == null,
                        () => setState(() => _filters = _filters.copyWith(clearCategory: true))),
                    for (final cat in widget.categories)
                      _pill(cat, _filters.category == cat,
                          () => setState(() => _filters = _filters.copyWith(category: cat))),
                  ],
                ),
              ],
              if (widget.groups.isNotEmpty) ...[
                const SizedBox(height: 16),
                const _SectionLabel('Group'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _pill('All', _filters.group == null,
                        () => setState(() => _filters = _filters.copyWith(clearGroup: true))),
                    for (final g in widget.groups)
                      _pill(g, _filters.group == g,
                          () => setState(() => _filters = _filters.copyWith(group: g))),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        setState(() => _filters = const CustomerFilters());
                      },
                      child: const Text('Reset'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(_filters),
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, bool selected, VoidCallback onTap) {
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
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Theme.of(context).textTheme.bodyMedium?.color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: AppColors.textSecondaryLight,
      ),
    );
  }
}
