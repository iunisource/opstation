import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/services/sms_debug_screen.dart';
import '../../../core/services/device_gps_service.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../shared/widgets/role_home_scaffold.dart';
import '../../../shared/widgets/section_label.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/temp_password_banner.dart';
import '../../auth/providers/auth_controller.dart';
import '../../orders/presentation/order_create_modal.dart';
import 'dialogs/adhoc_collection_dialog.dart';
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

class _SalespersonHomeScreenState extends ConsumerState<SalespersonHomeScreen>
    with WidgetsBindingObserver {
  _Period _period = _Period.today;

  /// Id of the route currently being started, so its Start button can
  /// show a spinner while we await the trip controller. Other route
  /// cards' Start buttons disable during this window to prevent the
  /// user from kicking off a second trip.
  String? _startingRouteId;

  /// Realtime subscription so the home auto-refreshes within ~1s of an admin
  /// change — no app restart or manual pull needed. Watches THREE tables:
  /// route_assignments (assign/unassign), sales_routes and route_stops (route
  /// edits). Requires those tables to be in the supabase_realtime publication.
  ///
  /// Two deliberate choices, both fixing "stale until re-login" reports:
  ///  - NO server-side user_id filter on route_assignments: Postgres DELETE
  ///    events only carry the old row's primary key (default replica
  ///    identity), so a user_id filter silently drops every unassignment.
  ///    Events are rare and tiny; we refresh on any and let the pull decide.
  ///  - The channel is torn down and rebuilt every time the app returns to
  ///    the foreground: Android kills the websocket in the background and a
  ///    dead channel never recovers on its own. The resubscribe also runs a
  ///    catch-up pull for anything missed while suspended.
  RealtimeChannel? _routesRealtimeChannel;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _setupRealtime());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Heal a socket the OS killed while backgrounded, then catch up on
      // anything that changed while we weren't listening.
      _setupRealtime();
      _scheduleRefresh();
    }
  }

  void _setupRealtime() {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return;
    // Rebuild from scratch — resubscribing a dead channel is unreliable.
    try {
      _routesRealtimeChannel?.unsubscribe();
    } catch (_) {}
    _routesRealtimeChannel = Supabase.instance.client
        .channel('routes_realtime_${user.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'route_assignments',
          callback: (_) => _scheduleRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sales_routes',
          callback: (_) => _scheduleRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'route_stops',
          callback: (_) => _scheduleRefresh(),
        )
        .subscribe();
  }

  /// Debounced: an admin saving a route fires a burst of events (stops are
  /// replaced wholesale — N deletes + N inserts). Coalesce them into one pull.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce =
        Timer(const Duration(milliseconds: 600), _refreshAssignments);
  }

  Future<void> _refreshAssignments() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    if (user == null) return;
    print('Realtime: routes/assignments change -> refresh for ${user.id}');
    final pull = ref.read(supabasePullServiceProvider);
    try {
      await pull.pullRouteAssignmentsForUser(user.id);
      final orgId = user.organizationId;
      if (orgId != null) await pull.pullRoutesAndStops(orgId);
    } catch (e) {
      print('routes realtime refresh failed: $e');
    }
    if (mounted) ref.invalidate(_allRoutesProvider);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshDebounce?.cancel();
    _routesRealtimeChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _startRoute(SalesRoute route) async {
    if (_startingRouteId != null) return;
    setState(() => _startingRouteId = route.id);

    // Same gate as marking a visit and completing a route: no route may begin
    // with location switched off or permission denied, otherwise every visit
    // on it is unverifiable. A weak signal is allowed — the rep may be indoors
    // when they set off.
    final gate = await ref.read(deviceGpsServiceProvider).getFixResult();
    if (!mounted) return;
    String? blockReason;
    switch (gate.outcome) {
      case GpsOutcome.serviceDisabled:
        blockReason = 'Turn on your device location (GPS) to start a route.';
        break;
      case GpsOutcome.permissionBlocked:
        blockReason =
            'Location permission is blocked. Enable it for Opstation in your phone Settings, then try again.';
        break;
      case GpsOutcome.permissionDenied:
        blockReason = 'Location permission is required to start a route.';
        break;
      default:
        blockReason = null;
    }
    if (blockReason != null) {
      setState(() => _startingRouteId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(blockReason),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 5),
        ),
      );
      return;
    }

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

  /// The FAB opens a small chooser rather than jumping straight to a new order,
  /// so the rep can also record an ad-hoc cash receipt — a payment from a
  /// customer who isn't on the active route (or when no route is running).
  void _showCreateMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.shopping_cart_outlined,
                      color: AppColors.primary),
                ),
                title: const Text('New order',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Take an order for a customer'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  OrderCreateModal.show(context);
                },
              ),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.successLight,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.receipt_long_outlined,
                      color: AppColors.successDark),
                ),
                title: const Text('New CR (cash receipt)',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle:
                    const Text('Record a payment — any customer, no route needed'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final ok = await AdHocCollectionDialog.show(context);
                  if (ok == true && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cash receipt recorded'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
        onPressed: () => _showCreateMenu(context),
        icon: const Icon(Icons.add),
        label: const Text('New'),
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

    // The stat cards below follow the period selector. "Today" stays live from
    // trip state (updates the instant a collection is recorded); "This week" /
    // "This month" come from homePeriodStatsProvider, which folds the same
    // permissive coverage over the wider window (via the startedAt-bucketed
    // tripsInRangeForUser). While a wider period is still loading we show 0
    // rather than briefly flashing today's numbers under a week/month label.
    double displayScore = score;
    int displayCollected = totalCollected;
    if (_period != _Period.today) {
      final hp = _period == _Period.week
          ? HomeStatsPeriod.week
          : HomeStatsPeriod.month;
      final periodStats = ref.watch(homePeriodStatsProvider(hp)).valueOrNull;
      displayScore = periodStats?.score ?? 0.0;
      displayCollected = periodStats?.collected ?? 0;
    }

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
          // Long-press the greeting to open the on-device diagnostics log
          // (sync + SMS outcomes). Hidden rather than a visible menu item:
          // it's for support, not day-to-day use, but a rep needs to be able
          // to reach it in the field when their trips aren't showing up.
          GestureDetector(
            onLongPress: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SmsDebugScreen()),
            ),
            child: Text(
              'Hi, $firstName',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
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
          _VisitScoreCard(score: displayScore),
          const SizedBox(height: 12),
          _CollectedCard(amount: displayCollected),
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
                      trip.stopSnapshot.isEmpty
                          ? 'Off-route collections · ${trip.visits.length} receipt${trip.visits.length == 1 ? '' : 's'} · Rs ${trip.totalCollected}'
                          : 'Completed · ${trip.visitedCount}/${trip.totalStops} visited · Rs ${trip.totalCollected}',
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
