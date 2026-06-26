import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../auth/providers/auth_controller.dart';
import '../../orders/presentation/order_create_modal.dart';
import '../../reports/presentation/export_pdf_sheet.dart';
import '../data/salesperson_repository.dart';
import 'salesperson_drawer.dart';
import '../models/sales_route.dart';
import '../models/trip.dart';
import '../providers/trip_controller.dart';

/// Private provider for the full route list. Resolves via the DB repository.
///
/// We read from the DB only after the [tripControllerProvider] has finished
/// building — that provider is responsible for seeding the DB on first run.
/// Without this dependency, routes can be queried before seeding completes
/// and the user sees an empty home screen.
///
/// Filters routes by assignment — a salesperson only sees routes
/// explicitly assigned to them by admin.
final _allRoutesProvider = FutureProvider<List<SalesRoute>>((ref) async {
  await ref.watch(tripControllerProvider.future);
  final user = ref.watch(authControllerProvider).valueOrNull;
  if (user == null) return const [];
  final repo = ref.watch(salespersonRepositoryProvider);
  return repo.routesAssignedTo(user.id);
});

/// Salesperson home.
///
/// Route grouping:
///   1. Active              — the in-progress trip (hidden if none)
///   2. One-time assignments — not yet started today (hidden if none)
///   3. Always available    — recurring routes (always visible)
///   4. Completed today     — trips finished today (hidden if none)
///
/// A route never appears in more than one section.
///
/// Metric language:
///   - Salesperson-facing copy uses "visited" (any non-skipped visit:
///     verified, outside, or noLocation) and `Trip.coveragePercent` —
///     so a salesperson who reached every customer sees 100% even if
///     GPS sometimes failed.
///   - Admin-facing screens (leaderboard, monitoring) use the strict
///     `Trip.completionPercent` and split verified/unverified chips.
class SalespersonHomeScreen extends ConsumerStatefulWidget {
  const SalespersonHomeScreen({super.key});

  @override
  ConsumerState<SalespersonHomeScreen> createState() => _SalespersonHomeScreenState();
}

class _SalespersonHomeScreenState extends ConsumerState<SalespersonHomeScreen> {
  _Period _period = _Period.today;

  /// Id of the route currently being started, so its Start button can
  /// show a spinner while we await the trip controller. Other route
  /// cards' Start buttons disable during this window to prevent the
  /// user from kicking off a second trip.
  String? _startingRouteId;

  /// Realtime subscription to route_assignments changes for this user so
  /// the home auto-refreshes within ~1s of admin saving — no app restart
  /// or manual pull needed. Requires the route_assignments table to be in
  /// the supabase_realtime publication.
  RealtimeChannel? _routeAssignmentsChannel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setupRealtime());
  }

  void _setupRealtime() {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return;
    _routeAssignmentsChannel = Supabase.instance.client
        .channel('route_assignments_${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'route_assignments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: user.id,
          ),
          callback: (_) => _refreshAssignments(),
        )
        .subscribe();
  }

  Future<void> _refreshAssignments() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return;
    print('Realtime: route_assignments change for ${user.id} -> refresh');
    try {
      await ref
          .read(supabasePullServiceProvider)
          .pullRouteAssignmentsForUser(user.id);
    } catch (e) {
      print('pullRouteAssignmentsForUser failed: $e');
    }
    if (mounted) ref.invalidate(_allRoutesProvider);
  }

  @override
  void dispose() {
    _routeAssignmentsChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _startRoute(SalesRoute route) async {
    if (_startingRouteId != null) return;
    setState(() => _startingRouteId = route.id);
    try {
      await ref.read(tripControllerProvider.notifier).startTrip(route);
      ref.read(soundControllerProvider.notifier).play(AppSound.routeStart);
      if (!mounted) return;
      setState(() => _startingRouteId = null);
      context.push('/salesperson/route');
    } on StateError catch (e) {
      if (!mounted) return;
      setState(() => _startingRouteId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _startingRouteId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start: $e')),
      );
    }
  }

  void _openActiveRoute() {
    context.push('/salesperson/route');
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'there';
    final dateStr = DateFormat('EEEE, d MMMM y').format(DateTime.now());

    // If the local date has changed since last build, clear "today" state.
    // Deferred to post-frame so we don't mutate state mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Async rollover; fire-and-forget.
      ref.read(tripControllerProvider.notifier).rolloverIfNeeded();
    });

    final tripAsync = ref.watch(tripControllerProvider);
    final routesAsync = ref.watch(_allRoutesProvider);

    return RoleHomeScaffold(
      appBarTitle: 'Home',
      drawer: const SalespersonDrawer(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => OrderCreateModal.show(context),
        icon: const Icon(Icons.add),
        label: const Text('Order'),
      ),
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to load trips: $e'),
          ),
        ),
        data: (tripState) {
          return routesAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Failed to load routes: $e'),
              ),
            ),
            data: (routes) => _buildBody(
              context,
              firstName: firstName,
              dateStr: dateStr,
              tripState: tripState,
              routes: routes,
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required String firstName,
    required String dateStr,
    required TripState tripState,
    required List<SalesRoute> routes,
  }) {
    final activeTrip = tripState.active;
    final hasActive = activeTrip != null;
    final exhaustedOneTimeIds = tripState.exhaustedOneTimeRouteIds;

    final oneTimeAvailable = routes.where((r) {
      if (!r.isOneTime) return false;
      if (exhaustedOneTimeIds.contains(r.id)) return false;
      if (hasActive && activeTrip.routeId == r.id) return false;
      return true;
    }).toList();

    final recurring = routes.where((r) => r.isRecurring).toList();
    final completedTrips = tripState.completedToday;

    final todaysTrips = [
      if (activeTrip != null) activeTrip,
      ...completedTrips,
    ];
    final totalStopsToday =
        todaysTrips.fold<int>(0, (s, t) => s + t.totalStops);
    // Salesperson view = permissive coverage: any non-skipped visit counts.
    final visitedToday =
        todaysTrips.fold<int>(0, (s, t) => s + t.visitedCount);
    final score = totalStopsToday == 0
        ? 0.0
        : (visitedToday / totalStopsToday) * 100.0;
    final totalCollected =
        todaysTrips.fold<int>(0, (s, t) => s + t.totalCollected);

    return RefreshIndicator(
      // Pull-to-refresh triggers a real Supabase fetch so newly-assigned
      // routes (e.g. assigned via the web admin's team screen) appear
      // without requiring the salesperson to log out and back in.
      // Riverpod stream providers downstream pick up the new local DB
      // rows and rebuild automatically.
      onRefresh: () async {
        final orgId = ref
            .read(authControllerProvider)
            .valueOrNull
            ?.organizationId;
        if (orgId != null && orgId.isNotEmpty) {
          try {
            await ref
                .read(supabasePullServiceProvider)
                .pullOrgData(orgId);
          } catch (_) {
            // Network error → fall through. Local DB still drives the UI.
          }
        }
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const SizedBox(height: 8),
          Text(
            'Hi, $firstName',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            dateStr,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),

          const TempPasswordBanner(),

          // --- ACTIVE -----------------------------------------------------
          if (hasActive) ...[
            SectionLabel(
              'Active',
              trailing: const StatusBadge(label: 'In progress', tone: StatusBadgeTone.info),
            ),
            const SizedBox(height: 10),
            _ActiveRouteCard(trip: activeTrip, onTap: _openActiveRoute),
            const SizedBox(height: 24),
          ],

          // --- ONE-TIME ASSIGNMENTS ---------------------------------------
          if (!hasActive && oneTimeAvailable.isNotEmpty) ...[
            SectionLabel(
              'One-time assignments',
              trailing: StatusBadge(
                label: oneTimeAvailable.length.toString(),
                tone: StatusBadgeTone.info,
              ),
            ),
            const SizedBox(height: 10),
            for (final r in oneTimeAvailable) ...[
              _StartableRouteCard(
                route: r,
                onStart: () => _startRoute(r),
                loading: _startingRouteId == r.id,
                disabled: _startingRouteId != null && _startingRouteId != r.id,
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 14),
          ],

          // --- ALWAYS AVAILABLE -------------------------------------------
          if (recurring.isNotEmpty) ...[
            Row(
              children: [
                const SectionLabel('Always available'),
                const SizedBox(width: 8),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: AppColors.successLight,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    recurring.length.toString(),
                    style: const TextStyle(
                      color: AppColors.successDark,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Start these routes anytime. Each start creates a fresh trip.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                  ),
            ),
            const SizedBox(height: 10),
            for (final r in recurring) ...[
              _StartableRouteCard(
                route: r,
                onStart: () => _startRoute(r),
                loading: _startingRouteId == r.id,
                disabled: hasActive ||
                    (_startingRouteId != null && _startingRouteId != r.id),
                recurring: true,
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 14),
          ],

          // --- COMPLETED TODAY --------------------------------------------
          if (completedTrips.isNotEmpty) ...[
            SectionLabel(
              'Completed today',
              trailing: StatusBadge(
                label: completedTrips.length.toString(),
                tone: StatusBadgeTone.success,
              ),
            ),
            const SizedBox(height: 10),
            for (final t in completedTrips) ...[
              _CompletedTripCard(trip: t, onTap: _openActiveRoute),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 14),
          ],

          // --- STATS ------------------------------------------------------
          _PeriodSelector(
            selected: _period,
            onChanged: (p) => setState(() => _period = p),
          ),
          const SizedBox(height: 16),
          _VisitScoreCard(score: score),
          const SizedBox(height: 12),
          _CollectedCard(amount: totalCollected),
        ],
      ),
    );
  }
}

enum _Period { today, week, month }

class _PeriodSelector extends StatelessWidget {
  final _Period selected;
  final ValueChanged<_Period> onChanged;

  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final p in _Period.values) ...[
          _PeriodChip(
            label: _label(p),
            selected: p == selected,
            onTap: () => onChanged(p),
          ),
          if (p != _Period.values.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  String _label(_Period p) {
    switch (p) {
      case _Period.today:
        return 'Today';
      case _Period.week:
        return 'This week';
      case _Period.month:
        return 'This month';
    }
  }
}

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PeriodChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
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
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _ActiveRouteCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  const _ActiveRouteCard({required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.directions_run,
                        color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(trip.routeName,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          '${trip.totalStops} stops',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.color
                                    ?.withOpacity(0.65),
                              ),
                        ),
                      ],
                    ),
                  ),
                  const StatusBadge(
                      label: 'In progress', tone: StatusBadgeTone.info),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  // Salesperson-facing progress bar uses permissive coverage
                  // (verified + outside + noLocation). Admin views use the
                  // strict completionPercent.
                  value: trip.coveragePercent / 100,
                  minHeight: 4,
                  backgroundColor: AppColors.borderLight,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.check_circle_outline,
                          size: 16, color: AppColors.success),
                      const SizedBox(width: 6),
                      Text(
                          '${trip.visitedCount} / ${trip.totalStops} visited',
                          style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                  Row(
                    children: const [
                      Icon(Icons.arrow_forward, size: 16, color: AppColors.primary),
                      SizedBox(width: 6),
                      Text(
                        'Tap to continue',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartableRouteCard extends StatelessWidget {
  final SalesRoute route;
  final VoidCallback onStart;
  final bool disabled;
  final bool recurring;
  /// True while a startTrip call is in flight for this route. Shows a
  /// spinner in the Start button and prevents re-tapping. Independent
  /// of [disabled] so we can render a different visual state.
  final bool loading;
  const _StartableRouteCard({
    required this.route,
    required this.onStart,
    this.disabled = false,
    this.recurring = false,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconBg =
        recurring ? AppColors.successLight : AppColors.warningLight;
    final iconFg =
        recurring ? AppColors.successDark : AppColors.warningDark;
    final icon =
        recurring ? Icons.all_inclusive : Icons.event_available_outlined;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: Icon(icon, color: iconFg, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(route.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    recurring
                        ? '${route.stops.length} customers · Recurring'
                        : '${route.stops.length} stops · One-time',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                        ),
                  ),
                ],
              ),
            ),
            loading
                ? ElevatedButton(
                    onPressed: null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      // Override disabled appearance so the button still
                      // looks active while loading — only the contents
                      // change to a spinner.
                      disabledBackgroundColor: AppColors.success,
                      disabledForegroundColor: Colors.white,
                      minimumSize: const Size(0, 42),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: disabled ? null : onStart,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      disabledBackgroundColor: AppColors.borderLight,
                      disabledForegroundColor: AppColors.textTertiaryLight,
                      minimumSize: const Size(0, 42),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _CompletedTripCard extends StatelessWidget {
  final Trip trip;
  final VoidCallback onTap;

  const _CompletedTripCard({required this.trip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.successLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.check_circle_outline,
                    color: AppColors.successDark, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(trip.routeName,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      'Completed · ${trip.visitedCount}/${trip.totalStops} visited · Rs ${trip.totalCollected}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.65),
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
                tooltip: 'Export PDF',
                onPressed: () => showExportPdfSheet(context, trip: trip),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisitScoreCard extends StatelessWidget {
  final double score;

  const _VisitScoreCard({required this.score});

  @override
  Widget build(BuildContext context) {
    final below = score < 60;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: score / 100,
                    strokeWidth: 4,
                    backgroundColor: AppColors.borderLight,
                    valueColor: AlwaysStoppedAnimation(below ? AppColors.danger : AppColors.success),
                  ),
                  Text(
                    '${score.round()}%',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Visit score', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                    below ? 'Below 60% threshold' : 'On target',
                    style: TextStyle(color: below ? AppColors.danger : AppColors.success, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (below) const Icon(Icons.error_outline, color: AppColors.danger),
          ],
        ),
      ),
    );
  }
}

class _CollectedCard extends StatelessWidget {
  final int amount;

  const _CollectedCard({required this.amount});

  @override
  Widget build(BuildContext context) {
    final formatted = NumberFormat.decimalPattern().format(amount);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.successLight,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.payments_outlined, color: AppColors.successDark, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total collected',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.65),
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Rs $formatted',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
