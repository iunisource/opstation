import '../../../core/services/org_config_sync.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/services/sound_controller.dart';
import '../../../core/services/sms_debug_screen.dart';
import '../../../core/services/device_gps_service.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import '../../../shared/widgets/opstation_header.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/database/app_database_provider.dart';
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

/// Today's planned route(s) for this salesperson from the Route Roster (web),
/// plus the weekly rest day. Week-by-week plan first (with the "carry the
/// last plan for this weekday" fallback), else the standing weekday plan,
/// depending on the roster mode. Kept on the phone for offline starts.
class _RosterToday {
  final List<String> routeIds;
  final bool restDay;
  const _RosterToday(this.routeIds, this.restDay);
}

final _todayRosterProvider = FutureProvider<_RosterToday>((ref) async {
  final user = ref.watch(authControllerProvider).valueOrNull;
  final orgId = user?.organizationId;
  if (user == null || orgId == null) return const _RosterToday([], false);
  final db = ref.read(appDatabaseProvider);
  final now = DateTime.now();
  final today = DateFormat('yyyy-MM-dd').format(now);
  const cacheKey = 'cache.roster_today';
  try {
    final c = Supabase.instance.client;
    String? mode;
    int? rest;
    var autoCopy = true;
    final cfg = await c.from('app_config').select('key, value').eq('org_id', orgId)
        .inFilter('key', ['ops.route_roster_mode', 'org.weekly_rest_day', 'ops.route_roster_autocopy']);
    for (final r in cfg as List) {
      if (r['key'] == 'ops.route_roster_mode') mode = '${r['value']}';
      if (r['key'] == 'org.weekly_rest_day') rest = int.tryParse('${r['value'] ?? ''}');
      if (r['key'] == 'ops.route_roster_autocopy') autoCopy = '${r['value']}' != 'false';
    }
    List<String> ids = [];
    if (mode == 'standing') {
      final row = await c.from('route_roster_standing').select('route_ids')
          .eq('org_id', orgId).eq('user_id', user.id).eq('weekday', now.weekday).maybeSingle();
      ids = List<String>.from((row?['route_ids'] as List?) ?? const []);
    } else {
      final row = await c.from('route_roster').select('route_ids')
          .eq('org_id', orgId).eq('user_id', user.id).eq('day', today).maybeSingle();
      if (row != null) {
        ids = List<String>.from((row['route_ids'] as List?) ?? const []);
      } else if (autoCopy) {
        // Same weekday's latest earlier plan (up to 26 weeks back).
        final prev = await c.from('route_roster').select('day, route_ids')
            .eq('org_id', orgId).eq('user_id', user.id).lt('day', today)
            .gte('day', DateFormat('yyyy-MM-dd').format(now.subtract(const Duration(days: 182))))
            .order('day', ascending: false);
        for (final r in prev as List) {
          if (DateTime.parse('${r['day']}').weekday != now.weekday) continue;
          ids = List<String>.from((r['route_ids'] as List?) ?? const []);
          break;
        }
      }
    }
    // Rest day is 0 = Sunday … 6 = Saturday.
    final isRest = rest != null && rest == now.weekday % 7;
    await db.setConfig(cacheKey, jsonEncode({'day': today, 'ids': ids, 'rest': isRest}));
    return _RosterToday(ids, isRest);
  } catch (_) {
    // Offline / roster not set up: use today's saved copy, if any.
    try {
      final raw = await db.getConfig(cacheKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        if (m['day'] == today) {
          return _RosterToday(List<String>.from((m['ids'] as List?) ?? const []), m['rest'] == true);
        }
      }
    } catch (_) {}
    return const _RosterToday([], false);
  }
});

/// When each route was last run by this salesperson (last 60 days, phone data).
final _lastRunProvider = FutureProvider<Map<String, DateTime>>((ref) async {
  await ref.watch(tripControllerProvider.future);
  final user = ref.watch(authControllerProvider).valueOrNull;
  if (user == null) return const {};
  final now = DateTime.now();
  try {
    final trips = await ref.read(salespersonRepositoryProvider)
        .tripsInRangeForUser(now.subtract(const Duration(days: 60)), now, user.id);
    final out = <String, DateTime>{};
    for (final t in trips) {
      final cur = out[t.routeId];
      if (cur == null || t.startedAt.isAfter(cur)) out[t.routeId] = t.startedAt;
    }
    return out;
  } catch (_) {
    return const {};
  }
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
  // Route list: 'always' (recurring) or 'once' (one-time) — the switch only
  // shows when there is at least one one-time route.
  String _routeTab = 'always';
  String _routeQuery = '';
  bool _searching = false;

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
    if (mounted) ref.invalidate(_todayRosterProvider);
    // Settings changed in Admin Settings apply without logging out.
    if (mounted) unawaited(ref.read(orgConfigSyncProvider).sync());
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
    unawaited(ref.read(orgConfigSyncProvider).sync());
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
      final t = await ref.read(tripControllerProvider.notifier).startTrip(route);
      ref.read(soundControllerProvider.notifier).play(AppSound.routeStart);
      if (!mounted) return;
      setState(() => _startingRouteId = null);
      if (t.visits.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Continuing today\'s ${route.name} — ${t.visits.length} earlier visit${t.visits.length == 1 ? '' : 's'} kept in the same summary'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      }
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
        SnackBar(content: Text('Could not start the route. Please try again.')),
      );
    }
  }

  void _openActiveRoute() {
    context.push('/salesperson/route');
  }


  /// Quick Actions: New CR, New order, Free route — fanned out above the
  /// button over a dimmed screen; tap outside to close.
  Future<void> _showQuickActions(BuildContext context) async {
    final picked = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withOpacity(0.45),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (ctx, _, __) => SafeArea(
        child: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
              _QuickAction(
                label: 'New CR', hint: 'Record a payment, any customer',
                icon: Icons.receipt_long_outlined, bg: AppColors.successLight, fg: AppColors.successDark,
                onTap: () => Navigator.of(ctx).pop('cr'),
              ),
              const SizedBox(height: 12),
              _QuickAction(
                label: 'New order', hint: 'Take an order for a customer',
                icon: Icons.shopping_cart_outlined, bg: AppColors.primaryLight, fg: AppColors.primary,
                onTap: () => Navigator.of(ctx).pop('order'),
              ),
              const SizedBox(height: 12),
              _QuickAction(
                label: 'Free route', hint: 'Add customers as you go',
                icon: Icons.add_road, bg: AppColors.warningLight, fg: AppColors.warningDark,
                onTap: () => Navigator.of(ctx).pop('free'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 46, height: 46,
                child: FloatingActionButton(
                  heroTag: 'qa_close',
                  elevation: 3,
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Icon(Icons.close),
                ),
              ),
            ]),
          ),
        ),
      ),
      transitionBuilder: (ctx, a, __, child) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.05), end: Offset.zero).animate(a),
          child: child,
        ),
      ),
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'order':
        OrderCreateModal.show(context);
        break;
      case 'cr':
        final ok = await AdHocCollectionDialog.show(context);
        if (ok == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cash receipt recorded'), behavior: SnackBarBehavior.floating),
          );
        }
        break;
      case 'free':
        try {
          await ref.read(tripControllerProvider.notifier).startFreeTrip();
          ref.read(soundControllerProvider.notifier).play(AppSound.routeStart);
          if (!mounted) return;
          context.push('/salesperson/route');
        } on StateError catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not start a free route. Please try again.')));
        }
        break;
    }
  }

  Future<void> _refresh() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    if (orgId != null && orgId.isNotEmpty) {
      try {
        await ref.read(supabasePullServiceProvider).pullOrgData(orgId);
      } catch (_) {
        // Network error → the phone's data still drives the screen.
      }
    }
    if (!mounted) return;
    ref.invalidate(_allRoutesProvider);
    ref.invalidate(_todayRosterProvider);
    ref.invalidate(_lastRunProvider);
    unawaited(ref.read(orgConfigSyncProvider).sync());
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final firstName = user?.name.split(' ').first ?? 'there';
    final dateStr = DateFormat('EEEE, d MMMM').format(DateTime.now());

    // If the local date has changed since last build, clear "today" state.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tripControllerProvider.notifier).rolloverIfNeeded();
    });

    final tripAsync = ref.watch(tripControllerProvider);
    final routesAsync = ref.watch(_allRoutesProvider);

    return Scaffold(
      drawer: const SalespersonDrawer(),
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: _HomeColors.top,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: const Text('Home', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: Colors.white)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _refresh),
          // Sync / sound / theme / sign-out on a light pill so their own
          // colours stay readable on the blue bar.
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
            child: IconTheme(
              data: const IconThemeData(color: Color(0xFF334155)),
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(foregroundColor: const Color(0xFF334155)),
                ),
                child: const OpstationHeaderActions(),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'quick_actions',
        onPressed: () => _showQuickActions(context),
        icon: const Icon(Icons.bolt, size: 20),
        label: const Text('Quick Actions', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
        extendedPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      body: tripAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Padding(padding: EdgeInsets.all(24), child: Text('Could not load your routes. Pull down to try again.')),
        ),
        data: (tripState) => routesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => const Center(
            child: Padding(padding: EdgeInsets.all(24), child: Text('Could not load your routes. Pull down to try again.')),
          ),
          data: (routes) => _buildBody(context, firstName: firstName, dateStr: dateStr,
              tripState: tripState, routes: routes),
        ),
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
    final roster = ref.watch(_todayRosterProvider).valueOrNull ?? const _RosterToday([], false);
    final lastRun = ref.watch(_lastRunProvider).valueOrNull ?? const <String, DateTime>{};

    final oneTimeAvailable = routes.where((r) {
      if (!r.isOneTime) return false;
      if (exhaustedOneTimeIds.contains(r.id)) return false;
      if (activeTrip != null && activeTrip.routeId == r.id) return false;
      return true;
    }).toList();
    final activeRouteId = activeTrip?.routeId;
    final recurring = routes.where((r) => r.isRecurring && r.id != activeRouteId).toList();

    // Today's route(s) from the roster — only when nothing is running yet.
    final planned = hasActive
        ? <SalesRoute>[]
        : [
            for (final id in roster.routeIds)
              ...routes.where((r) => r.id == id && !exhaustedOneTimeIds.contains(r.id)),
          ];
    final plannedIds = {for (final r in planned) r.id};

    final showTabs = oneTimeAvailable.isNotEmpty;
    final tab = showTabs ? _routeTab : 'always';
    var list = (tab == 'once' ? oneTimeAvailable : recurring).where((r) => !plannedIds.contains(r.id)).toList();
    // Route you ran longest ago first (never-run at the top).
    list.sort((a, b) {
      final x = lastRun[a.id], y = lastRun[b.id];
      if (x == null && y == null) return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (x == null) return -1;
      if (y == null) return 1;
      return x.compareTo(y);
    });
    final q = _routeQuery.trim().toLowerCase();
    if (q.isNotEmpty) list = list.where((r) => r.name.toLowerCase().contains(q)).toList();

    final completedTrips = tripState.completedToday;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          // ── Header: greeting, date, sync ───────────────────────────────
          GestureDetector(
            // Long-press the greeting: on-device diagnostics (support only).
            onLongPress: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SmsDebugScreen()),
            ),
            child: _HeroHeader(firstName: firstName, dateStr: dateStr),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: TempPasswordBanner()),

          if (roster.restDay && !hasActive)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: _InfoBanner(icon: Icons.weekend_outlined, text: 'Today is your weekly day off.'),
            ),

          // ── On route now ───────────────────────────────────────────────
          if (activeTrip != null) ...[
            _SectionTitle('On route now'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _ActiveRouteHero(trip: activeTrip, onContinue: _openActiveRoute),
            ),
          ],

          // ── Today's route (roster) ─────────────────────────────────────
          if (planned.isNotEmpty) ...[
            _SectionTitle("Today's route"),
            for (final r in planned)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: _PlannedRouteCard(
                  route: r,
                  lastRun: lastRun[r.id],
                  loading: _startingRouteId == r.id,
                  disabled: _startingRouteId != null && _startingRouteId != r.id,
                  onStart: () => _startRoute(r),
                ),
              ),
          ],

          // ── Routes ─────────────────────────────────────────────────────
          if (recurring.isNotEmpty || oneTimeAvailable.isNotEmpty) ...[
            _SectionTitle(
              planned.isNotEmpty || hasActive ? 'Other routes' : 'My routes',
              trailing: IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _searching ? 'Close search' : 'Search routes',
                icon: Icon(_searching ? Icons.close : Icons.search, size: 20, color: AppColors.primary),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _routeQuery = '';
                }),
              ),
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search routes…'),
                  onChanged: (v) => setState(() => _routeQuery = v),
                ),
              ),
            if (showTabs)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: _Segmented(
                  left: 'Always available · ${recurring.where((r) => !plannedIds.contains(r.id)).length}',
                  right: 'One-time · ${oneTimeAvailable.where((r) => !plannedIds.contains(r.id)).length}',
                  rightSelected: tab == 'once',
                  onChanged: (right) => setState(() => _routeTab = right ? 'once' : 'always'),
                ),
              ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Center(child: Text(q.isEmpty ? 'No other routes.' : 'No route matches.',
                    style: const TextStyle(color: AppColors.textSecondaryLight))),
              ),
            for (final r in list)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _RouteTile(
                  route: r,
                  lastRun: lastRun[r.id],
                  loading: _startingRouteId == r.id,
                  disabled: hasActive || (_startingRouteId != null && _startingRouteId != r.id),
                  onStart: () => _startRoute(r),
                ),
              ),
          ],

          // ── Done today ─────────────────────────────────────────────────
          if (completedTrips.isNotEmpty) ...[
            _SectionTitle('Done today'),
            for (final t in completedTrips)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _DoneTile(trip: t),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Look ─────────────────────────────────────────────────────────────────────

class _HomeColors {
  static const top = Color(0xFF3B82F6);
  static const bottom = Color(0xFF1D4ED8);
  static const green = Color(0xFF10B981);
}

String _ago(DateTime? d) {
  if (d == null) return 'not run yet';
  final today = DateTime.now();
  final days = DateTime(today.year, today.month, today.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return 'last run today';
  if (days == 1) return 'last run yesterday';
  if (days < 7) return 'last run ${DateFormat('EEE').format(d)}';
  return 'last run ${DateFormat('EEE d MMM').format(d)}';
}

class _HeroHeader extends ConsumerWidget {
  final String firstName;
  final String dateStr;
  const _HeroHeader({required this.firstName, required this.dateStr});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final h = DateTime.now().hour;
    final greet = h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
    String syncText;
    Color dot;
    if (sync.pendingCount > 0) {
      syncText = '${sync.pendingCount} waiting to sync';
      dot = const Color(0xFFFBBF24);
    } else if (sync.state == SyncState.offline) {
      syncText = 'Offline · will sync when back';
      dot = const Color(0xFFFBBF24);
    } else {
      final at = sync.lastSyncedAt;
      final mins = at == null ? null : DateTime.now().difference(at).inMinutes;
      syncText = mins == null ? 'All synced' : (mins < 1 ? 'All synced · just now' : 'All synced · $mins min ago');
      dot = const Color(0xFF34D399);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [_HomeColors.top, _HomeColors.bottom]),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$greet, $firstName',
            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(dateStr, style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(syncText, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const _SectionTitle(this.text, {this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))),
          if (trailing != null) trailing!,
        ]),
      );
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoBanner({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(14)),
        child: Row(children: [
          Icon(icon, color: AppColors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

BoxDecoration _cardBox(BuildContext context, {Color? border, double width = 1}) => BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: border ?? AppColors.borderLight, width: width),
    );

/// The route being run: progress ring, time out, next shop, green pulsing
/// "Continue route".
class _ActiveRouteHero extends StatelessWidget {
  final Trip trip;
  final VoidCallback onContinue;
  const _ActiveRouteHero({required this.trip, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final total = trip.totalStops;
    final done = trip.visitedCount;
    final status = trip.statusByCustomer;
    String? next;
    for (final c in trip.stopSnapshot) {
      if (status[c.id] == VisitStatus.pending) {
        next = c.shopName;
        break;
      }
    }
    final out = DateTime.now().difference(trip.startedAt);
    final outTxt = out.inMinutes < 60 ? '${out.inMinutes}m out' : '${out.inHours}h ${out.inMinutes % 60}m out';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardBox(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (total > 0)
            SizedBox(
              width: 70, height: 70,
              child: Stack(alignment: Alignment.center, children: [
                SizedBox(width: 70, height: 70, child: CircularProgressIndicator(
                  value: (done / total).clamp(0.0, 1.0),
                  strokeWidth: 8,
                  backgroundColor: AppColors.borderLight,
                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                )),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$done', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  Text('of $total', style: const TextStyle(fontSize: 10, color: AppColors.textSecondaryLight)),
                ]),
              ]),
            )
          else
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.directions_run, color: AppColors.primary),
            ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trip.routeName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('Started ${DateFormat('HH:mm').format(trip.startedAt)} · $outTxt',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
              if (next != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(9)),
                  child: Text('Next: $next', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        _PulsingGreenButton(label: 'Continue route', onTap: onContinue),
      ]),
    );
  }
}

/// Green button with a fast, soft pulsing glow — to catch the eye.
class _PulsingGreenButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _PulsingGreenButton({required this.label, required this.onTap});
  @override
  State<_PulsingGreenButton> createState() => _PulsingGreenButtonState();
}

class _PulsingGreenButtonState extends State<_PulsingGreenButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = _c.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: _HomeColors.green.withOpacity(0.55 * (1 - t)),
                blurRadius: 4 + 10 * t,
                spreadRadius: 12 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Material(
        color: _HomeColors.green,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward, color: Colors.white, size: 18),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Today's route from the roster: big Start.
class _PlannedRouteCard extends StatelessWidget {
  final SalesRoute route;
  final DateTime? lastRun;
  final bool loading;
  final bool disabled;
  final VoidCallback onStart;
  const _PlannedRouteCard({required this.route, required this.lastRun, required this.loading,
      required this.disabled, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('EEEE').format(DateTime.now()).toUpperCase();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardBox(context, border: AppColors.primary.withOpacity(0.35)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('FROM ROUTE ROSTER · $day',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3,
                color: AppColors.textSecondaryLight)),
        const SizedBox(height: 3),
        Text(route.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text('${route.stops.length} shops · ${_ago(lastRun)}',
            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
        const SizedBox(height: 12),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: disabled || loading ? null : onStart,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: loading ? AppColors.primary : AppColors.borderLight,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                : const Icon(Icons.play_arrow),
            label: const Text('Start route', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          ),
        ),
      ]),
    );
  }
}

class _RouteTile extends StatelessWidget {
  final SalesRoute route;
  final DateTime? lastRun;
  final bool loading;
  final bool disabled;
  final VoidCallback onStart;
  const _RouteTile({required this.route, required this.lastRun, required this.loading,
      required this.disabled, required this.onStart});

  @override
  Widget build(BuildContext context) {
    final once = route.isOneTime;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: _cardBox(context),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: once ? AppColors.warningLight : AppColors.successLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(once ? Icons.event_available_outlined : Icons.autorenew,
              color: once ? AppColors.warningDark : AppColors.successDark, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(route.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('${route.stops.length} shops · ${once ? 'one-time' : _ago(lastRun)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
          ]),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 38,
          child: ElevatedButton(
            onPressed: disabled || loading ? null : onStart,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: loading ? AppColors.primary : AppColors.borderLight,
              disabledForegroundColor: loading ? Colors.white : AppColors.textTertiaryLight,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
            ),
            child: loading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                : const Text('Start', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ]),
    );
  }
}

class _Segmented extends StatelessWidget {
  final String left, right;
  final bool rightSelected;
  final ValueChanged<bool> onChanged;
  const _Segmented({required this.left, required this.right, required this.rightSelected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(String t, bool on, bool isRight) => Expanded(
          child: GestureDetector(
            onTap: () => onChanged(isRight),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: on ? Theme.of(context).cardColor : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                boxShadow: on ? const [BoxShadow(color: Colors.black12, blurRadius: 3)] : null,
              ),
              alignment: Alignment.center,
              child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                  color: on ? null : AppColors.textSecondaryLight)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: AppColors.borderLight.withOpacity(0.7), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [seg(left, !rightSelected, false), seg(right, rightSelected, true)]),
    );
  }
}

class _DoneTile extends StatelessWidget {
  final Trip trip;
  const _DoneTile({required this.trip});
  @override
  Widget build(BuildContext context) {
    final end = trip.endedAt;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: _cardBox(context),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: const BoxDecoration(color: AppColors.successLight, shape: BoxShape.circle),
          child: const Icon(Icons.check, color: AppColors.successDark, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(trip.routeName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            Text(end == null ? 'Finished' : 'Finished ${DateFormat('HH:mm').format(end)}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 20),
          tooltip: 'Reports',
          onPressed: () => showExportPdfSheet(context, trip: trip),
        ),
      ]),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final String label, hint;
  final IconData icon;
  final Color bg, fg;
  final VoidCallback onTap;
  const _QuickAction({required this.label, required this.hint, required this.icon,
      required this.bg, required this.fg, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5)),
              Text(hint, style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondaryLight)),
            ]),
          ),
          const SizedBox(width: 10),
          Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              color: bg, shape: BoxShape.circle,
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
            ),
            child: Icon(icon, color: fg, size: 22),
          ),
        ]),
      ),
    );
  }
}
