import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../auth/models/user_role.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/sales_route.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import 'export_pdf_sheet.dart';

/// Admin/master-admin (and salesperson, scoped) reports screen.
///
/// Admin: period pills + user dropdown + route dropdown + date range
/// (date range overrides period if set).
/// Salesperson: period pills only; auto-scoped to their own trips.
class ReportsScreen extends ConsumerStatefulWidget {
  /// When set, hides the user filter and locks listing to this user's
  /// trips only. Used by the salesperson "Reports" tile.
  final String? scopedUserId;

  const ReportsScreen({super.key, this.scopedUserId});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Period { today, week, month, custom }

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Period _period = _Period.week;
  String? _selectedUserId;
  String? _selectedRouteId;
  DateTimeRange? _customRange;

  bool get _isScoped => widget.scopedUserId != null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Reports',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (!_isScoped &&
              (_selectedUserId != null ||
                  _selectedRouteId != null ||
                  _customRange != null))
            IconButton(
              icon: const Icon(Icons.filter_alt_off_outlined),
              tooltip: 'Clear filters',
              onPressed: () => setState(() {
                _selectedUserId = null;
                _selectedRouteId = null;
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
          Expanded(
            child: _TripList(
              period: _period,
              customRange: _customRange,
              userId: widget.scopedUserId ?? _selectedUserId,
              routeId: _selectedRouteId,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PeriodChip(
                label: 'Today',
                selected: _period == _Period.today,
                onTap: () => setState(() {
                  _period = _Period.today;
                  _customRange = null;
                }),
              ),
              _PeriodChip(
                label: 'This week',
                selected: _period == _Period.week,
                onTap: () => setState(() {
                  _period = _Period.week;
                  _customRange = null;
                }),
              ),
              _PeriodChip(
                label: 'This month',
                selected: _period == _Period.month,
                onTap: () => setState(() {
                  _period = _Period.month;
                  _customRange = null;
                }),
              ),
              _PeriodChip(
                label: _customRange == null
                    ? 'Date range'
                    : '${DateFormat('d MMM').format(_customRange!.start)} – ${DateFormat('d MMM').format(_customRange!.end)}',
                selected: _period == _Period.custom,
                onTap: _pickDateRange,
                icon: Icons.calendar_today_outlined,
              ),
            ],
          ),
          if (!_isScoped) ...[
            const SizedBox(height: 10),
            _UserDropdown(
              selectedUserId: _selectedUserId,
              onChanged: (id) => setState(() => _selectedUserId = id),
            ),
            const SizedBox(height: 8),
            _RouteDropdown(
              selectedRouteId: _selectedRouteId,
              onChanged: (id) => setState(() => _selectedRouteId = id),
            ),
          ],
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

class _TripList extends ConsumerWidget {
  final _Period period;
  final DateTimeRange? customRange;
  final String? userId;
  final String? routeId;

  const _TripList({
    required this.period,
    required this.customRange,
    required this.userId,
    required this.routeId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamRepo = ref.watch(teamRepositoryProvider);
    final salesRepo = ref.watch(salespersonRepositoryProvider);

    final now = DateTime.now();
    late DateTime start;
    late DateTime end;
    if (period == _Period.custom && customRange != null) {
      start = customRange!.start;
      end = customRange!.end;
    } else {
      end = now;
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

    return FutureBuilder<_Data>(
      future: _load(teamRepo, salesRepo, start, end),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final d = snap.data!;
        if (d.trips.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No trips match your filters.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: d.trips.length,
          itemBuilder: (_, i) {
            final t = d.trips[i];
            final user = d.usersById[t.userId];
            return _TripTile(trip: t, user: user);
          },
        );
      },
    );
  }

  Future<_Data> _load(
    TeamRepository teamRepo,
    SalespersonRepository salesRepo,
    DateTime start,
    DateTime end,
  ) async {
    final users = await teamRepo.all(includeInactive: true);
    final usersById = {for (final u in users) u.id: u};

    // Determine which salespersons to pull trips for.
    final targetIds = <String>[];
    if (userId != null) {
      targetIds.add(userId!);
    } else {
      for (final u in users) {
        if (u.role == UserRole.salesperson) targetIds.add(u.id);
      }
    }

    final trips = <Trip>[];
    for (final uid in targetIds) {
      final userTrips = await salesRepo.tripsInRangeForUser(start, end, uid);
      trips.addAll(userTrips);
    }
    final filtered = routeId == null
        ? trips
        : trips.where((t) => t.routeId == routeId).toList();
    filtered.sort((a, b) {
      final ae = a.endedAt ?? a.startedAt;
      final be = b.endedAt ?? b.startedAt;
      return be.compareTo(ae);
    });
    return _Data(trips: filtered, usersById: usersById);
  }
}

class _Data {
  final List<Trip> trips;
  final Map<String, TeamUser> usersById;
  _Data({required this.trips, required this.usersById});
}

class _UserDropdown extends ConsumerWidget {
  final String? selectedUserId;
  final ValueChanged<String?> onChanged;

  const _UserDropdown({
    required this.selectedUserId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamRepo = ref.watch(teamRepositoryProvider);
    return FutureBuilder<List<TeamUser>>(
      future: teamRepo.all(includeInactive: false),
      builder: (context, snap) {
        final salespersons = (snap.data ?? const <TeamUser>[])
            .where((u) => u.role == UserRole.salesperson)
            .toList();
        return DropdownButtonFormField<String?>(
          value: selectedUserId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Salesperson',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon:
                const Icon(Icons.person_outline, size: 18),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All salespersons'),
            ),
            for (final u in salespersons)
              DropdownMenuItem<String?>(
                value: u.id,
                child: Text(u.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

class _RouteDropdown extends ConsumerWidget {
  final String? selectedRouteId;
  final ValueChanged<String?> onChanged;

  const _RouteDropdown({
    required this.selectedRouteId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final salesRepo = ref.watch(salespersonRepositoryProvider);
    return FutureBuilder<List<SalesRoute>>(
      future: salesRepo.allRoutesIncludingInactive(),
      builder: (context, snap) {
        final routes = snap.data ?? const <SalesRoute>[];
        return DropdownButtonFormField<String?>(
          value: selectedRouteId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Route',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.route_outlined, size: 18),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All routes'),
            ),
            for (final r in routes)
              DropdownMenuItem<String?>(
                value: r.id,
                child: Text(
                  r.isActive ? r.name : '${r.name} (inactive)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

class _TripTile extends StatelessWidget {
  final Trip trip;
  final TeamUser? user;
  const _TripTile({required this.trip, required this.user});

  @override
  Widget build(BuildContext context) {
    final started = DateFormat('d MMM · HH:mm').format(trip.startedAt);
    final endedStr = trip.endedAt == null
        ? '—'
        : DateFormat('HH:mm').format(trip.endedAt!);

    return InkWell(
      onTap: () => showExportPdfSheet(context, trip: trip),
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
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.picture_as_pdf_outlined,
                  color: AppColors.primary, size: 20),
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
                          trip.routeName,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      StatusBadge(
                        label: trip.isOpen
                            ? 'In progress'
                            : (trip.closeReason == TripCloseReason.cutoff
                                ? 'Cut-off'
                                : 'Completed'),
                        tone: trip.isOpen
                            ? StatusBadgeTone.info
                            : (trip.closeReason == TripCloseReason.cutoff
                                ? StatusBadgeTone.warning
                                : StatusBadgeTone.success),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${user?.name ?? 'Unknown'} · $started → $endedStr · '
                    '${trip.verifiedCount}/${trip.totalStops} verified · Rs ${trip.totalCollected}',
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
              Icon(
                icon,
                size: 13,
                color: selected
                    ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
