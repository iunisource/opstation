import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/sms_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/services/device_gps_service.dart';
import '../../../core/sync/sync_controller.dart';
import '../../../core/utils/geo_utils.dart';
import '../../admin_settings/providers/org_settings_controller.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../uploads/data/upload_queue_repository.dart';
import '../data/salesperson_repository.dart';
import '../models/customer.dart';
import '../models/sales_route.dart';
import '../models/trip.dart';

class TripState {
  final Trip? active;
  final List<Trip> completedToday;
  final Set<String> exhaustedOneTimeRouteIds;
  final DateTime dayStamp;
  final double geofenceRadiusMeters;
  final double accuracyWarnThresholdMeters;

  const TripState({
    this.active,
    this.completedToday = const [],
    this.exhaustedOneTimeRouteIds = const {},
    required this.dayStamp,
    this.geofenceRadiusMeters = 100,
    this.accuracyWarnThresholdMeters = 50,
  });

  bool get hasActiveTrip => active != null;

  TripState copyWith({
    Trip? active,
    bool clearActive = false,
    List<Trip>? completedToday,
    Set<String>? exhaustedOneTimeRouteIds,
    DateTime? dayStamp,
  }) {
    return TripState(
      active: clearActive ? null : (active ?? this.active),
      completedToday: completedToday ?? this.completedToday,
      exhaustedOneTimeRouteIds: exhaustedOneTimeRouteIds ?? this.exhaustedOneTimeRouteIds,
      dayStamp: dayStamp ?? this.dayStamp,
      geofenceRadiusMeters: geofenceRadiusMeters,
      accuracyWarnThresholdMeters: accuracyWarnThresholdMeters,
    );
  }

  static DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }
}

class TripController extends AsyncNotifier<TripState> {
  int _idCounter = 0;
  String _newId(String prefix) {
    _idCounter++;
    return '${prefix}_${DateTime.now().millisecondsSinceEpoch}_$_idCounter';
  }

  SalespersonRepository get _repo => ref.read(salespersonRepositoryProvider);

  @override
  Future<TripState> build() async {
    final today = TripState.today();
    final stamped = await _repo.dayStamp();
    if (stamped == null || _dateOnly(stamped) != today) {
      await _repo.setDayStamp(today);
    }

    final user = ref.watch(authControllerProvider).valueOrNull;
    final userId = user?.id ?? '';

    final active = userId.isEmpty ? null : await _repo.activeTripForUser(userId);
    final completed = userId.isEmpty ? <Trip>[] : await _repo.tripsClosedOnLocalDateForUser(today, userId);
    final exhausted = userId.isEmpty ? <String>{} : await _repo.exhaustedOneTimeRoutesForUser(userId);
    final settings = await ref.watch(orgSettingsProvider.future);

    return TripState(
      active: active,
      completedToday: completed,
      exhaustedOneTimeRouteIds: exhausted,
      dayStamp: today,
      geofenceRadiusMeters: settings.geofenceRadiusMeters.toDouble(),
      accuracyWarnThresholdMeters: settings.accuracyWarnMeters.toDouble(),
    );
  }

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  Future<void> rolloverIfNeeded() async {
    final s = state.valueOrNull;
    if (s == null) return;
    final today = TripState.today();
    if (s.dayStamp == today) return;
    await _refresh();
  }

  Future<void> refreshAfterCutoff() async {
    await _refresh();
  }

  Future<Trip> startTrip(SalesRoute route) async {
    final s = state.valueOrNull;
    if (s == null) throw StateError('Trip state not ready.');
    if (s.hasActiveTrip) throw StateError('A trip is already active. End it before starting another.');

    final today = TripState.today();
    final user = ref.read(authControllerProvider).valueOrNull;
    final fix = await ref.read(deviceGpsServiceProvider).getFix();

    final trip = Trip(
      id: _newId('trip'),
      routeId: route.id,
      routeName: route.name,
      routeKind: route.kind,
      stopSnapshot: List.unmodifiable(route.stops),
      startedAt: DateTime.now(),
      startLat: fix?.lat,
      startLng: fix?.lng,
      userId: user?.id ?? '',
      userName: user?.name ?? '',
      userRole: user?.role.label ?? '',
    );

    await _repo.createTrip(trip);
    await _repo.setDayStamp(today);
    state = AsyncData(s.copyWith(active: trip, dayStamp: today));

    // Notify admins that route started
    Future.microtask(() async {
      try {
        final db = ref.read(appDatabaseProvider);
        final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
        final admins = await (db.select(db.users)
              ..where((u) => u.orgId.equals(orgId ?? '')))
            .get();
        final notifService = ref.read(notificationServiceProvider);
        for (final a in admins) {
          if (a.role == 'masterAdmin' || a.role == 'admin') {
            await notifService.sendToUser(
              targetUserId: a.id,
              title: 'Route Started',
              body: '${user?.name ?? 'Salesperson'} started ${route.name} at ${_clock(DateTime.now())}',
            );
          }
        }
      } catch (e, st) {
        print('FCM trip-start notify loop failed: $e\n$st');
      }
    });

    return trip;
  }

  Future<void> completeTrip() async {
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) return;

    final fix = await ref.read(deviceGpsServiceProvider).getFix();

    final closed = active.copyWith(
      endedAt: DateTime.now(),
      closeReason: TripCloseReason.userEnded,
      endLat: fix?.lat,
      endLng: fix?.lng,
    );
    await _repo.updateTrip(closed);

    final exhausted = Set<String>.from(s.exhaustedOneTimeRouteIds);
    if (active.routeKind == RouteKind.oneTime) {
      exhausted.add(active.routeId);
    }

    state = AsyncData(s.copyWith(
      clearActive: true,
      completedToday: [...s.completedToday, closed],
      exhaustedOneTimeRouteIds: exhausted,
    ));

    // Notify admins that route completed
    Future.microtask(() async {
      try {
        final db = ref.read(appDatabaseProvider);
        final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
        final admins = await (db.select(db.users)
              ..where((u) => u.orgId.equals(orgId ?? '')))
            .get();
        final notifService = ref.read(notificationServiceProvider);
        for (final a in admins) {
          if (a.role == 'masterAdmin' || a.role == 'admin') {
            await notifService.sendToUser(
              targetUserId: a.id,
              title: 'Route Completed',
              body: '${active.userName} completed ${active.routeName} at ${_clock(DateTime.now())}',
            );
          }
        }
      } catch (e, st) {
        print('FCM trip-end notify loop failed: $e\n$st');
      }
    });
  }

  Future<Visit> markVisit({
    required Customer customer,
    required double? capturedLat,
    required double? capturedLng,
    required double? accuracyMeters,
    required int amount,
    String? receiptNumber,
    String? notes,
    List<String> photoPaths = const [],
  }) async {
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) throw StateError('No active trip.');
    if (amount > 0 && (receiptNumber == null || receiptNumber.trim().isEmpty)) {
      throw ArgumentError('Receipt number is required when amount > 0.');
    }

    VisitStatus status;
    double? distance;
    if (!customer.hasLocation) {
      status = VisitStatus.noLocation;
    } else if (capturedLat == null || capturedLng == null) {
      status = VisitStatus.noLocation;
    } else {
      distance = GeoUtils.distanceMeters(
        customer.latitude!, customer.longitude!, capturedLat, capturedLng,
      );
      status = distance <= s.geofenceRadiusMeters ? VisitStatus.verified : VisitStatus.outside;
    }

    // Compute the remote storage paths *before* building the Visit row.
    // The Visit's photoPaths will hold the cloud paths (what the web
    // admin reads) while the upload queue gets a local→remote pair so
    // it can still find the file on disk to upload. This decouples
    // "where does the row point" from "where is the file on this phone."
    final visitId = _newId('visit');
    final userId = active.userId;
    final date = DateTime.now().toIso8601String().split('T').first;
    final safeCustomer = customer.code.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final safeSales = active.userName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final remotePaths = <String>[];
    final pathPairs = <({String local, String remote})>[];
    for (int i = 0; i < photoPaths.length; i++) {
      final p = photoPaths[i];
      final ext = p.split('.').last;
      final remote = 'visits/$userId/${safeSales}_${date}_${safeCustomer}_$i.$ext';
      remotePaths.add(remote);
      pathPairs.add((local: p, remote: remote));
    }

    final visit = Visit(
      id: visitId,
      customerId: customer.id,
      status: status,
      timestamp: DateTime.now(),
      capturedLat: capturedLat,
      capturedLng: capturedLng,
      accuracyMeters: accuracyMeters,
      distanceMeters: distance,
      amount: amount,
      receiptNumber: receiptNumber,
      notes: notes,
      photoPaths: remotePaths, // Cloud paths, not local — web admin reads these
      userId: active.userId,
      userName: active.userName,
      userRole: active.userRole,
    );

    _repo.setCurrentTripContext(active.id);
    await _repo.insertVisit(visit);

    // Enqueue uploads using the local→remote pairs we already computed.
    // We use the opstation-photos bucket (NOT visit-photos) — visit-photos
    // rejects writes with a misleading RLS error despite identical-looking
    // policies. Driver delivery photos use opstation-photos and work, so
    // we standardize on the same bucket.
    if (pathPairs.isNotEmpty) {
      Future.microtask(() async {
        try {
          final queue = ref.read(uploadQueueRepositoryProvider);
          for (final pair in pathPairs) {
            print('PHOTO ENQUEUE — entity=visit:$visitId bucket=opstation-photos remotePath=${pair.remote} localPath=${pair.local}');
            await queue.enqueue(
              localPath: pair.local,
              remotePath: pair.remote,
              bucket: 'opstation-photos',
              entityType: 'visit',
              entityId: visitId,
            );
          }
        } catch (e, st) {
          print('PHOTO ENQUEUE FAILED: $e');
          print(st);
        }
      });
    }

    // Fire the customer SMS HERE, at the real creation/sync point.
    // insertVisit (above) pushes the visit and marks it 'synced' immediately,
    // so the visit is no longer 'pending' by the time SyncController.flushPending
    // runs — which is why the flushPending SMS hook never fired for online
    // visits (the common case) and no SMS was ever sent. We have the customer
    // object in hand here, so there is no local-DB lookup and no null risk.
    // Fire-and-forget so marking the visit is never blocked; _send handles
    // config/network failures gracefully and logs the outcome to SMS Debug.
    // The flushPending hook remains as a backstop for visits that stayed
    // 'pending' because their initial push failed (e.g. offline at creation).
    if (amount > 0) {
      SmsService.note(
          'markVisit: firing SMS for ${customer.id} ${customer.phone} (amount=$amount)');
      Future.microtask(() async {
        try {
          await ref.read(smsServiceProvider).sendVisitSms(
                customerPhone: customer.phone,
                customerName: customer.shopName,
                amount: amount,
                receiptNo: receiptNumber ?? '',
                salespersonName: active.userName,
              );
        } catch (e) {
          SmsService.note('markVisit: SMS threw — $e');
        }
      });
    }

    ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
    final updated = active.copyWith(visits: [...active.visits, visit]);
    state = AsyncData(s.copyWith(active: updated));
    return visit;
  }

  Future<Visit> skipVisit({
    required Customer customer,
    required String reason,
  }) async {
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) throw StateError('No active trip.');

    // Capture salesperson's GPS for skipped stops so admin can see
    // where the salesperson actually was when the no-show was logged.
    final fix = await ref.read(deviceGpsServiceProvider).getFix();
    double? distance;
    if (fix != null && customer.hasLocation) {
      distance = GeoUtils.distanceMeters(
        customer.latitude!, customer.longitude!, fix.lat, fix.lng,
      );
    }

    final visit = Visit(
      id: _newId('visit'),
      customerId: customer.id,
      status: VisitStatus.skipped,
      timestamp: DateTime.now(),
      capturedLat: fix?.lat,
      capturedLng: fix?.lng,
      accuracyMeters: fix?.accuracy,
      distanceMeters: distance,
      skipReason: reason,
      notes: reason,
      userId: active.userId,
      userName: active.userName,
      userRole: active.userRole,
    );

    _repo.setCurrentTripContext(active.id);
    await _repo.insertVisit(visit);
    ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
    final updated = active.copyWith(visits: [...active.visits, visit]);
    state = AsyncData(s.copyWith(active: updated));
    return visit;
  }

  Visit? latestVisitFor(String customerId) {
    final s = state.valueOrNull;
    final active = s?.active;
    if (active == null) return null;
    Visit? latest;
    for (final v in active.visits) {
      if (v.customerId == customerId) latest = v;
    }
    return latest;
  }

  bool canVisit(String customerId) {
    final latest = latestVisitFor(customerId);
    if (latest == null) return true;
    // A skipped stop stays locked — reopening a no-show goes through its own
    // flow, not a silent re-collect.
    if (latest.status == VisitStatus.skipped) return false;
    // Otherwise the stop is always collectable again. A customer who paid in
    // the morning can pay again in the evening: that second payment is a new
    // transaction, appended as its own Visit line item (own receipt, own GPS
    // fix, own timestamp) via markVisit — it never overwrites the earlier one.
    // Trip.totalCollected already folds across every visit, so totals stack.
    // NOTE: this intentionally does NOT touch Visit.allowsRevisit, which still
    // gates Trip.pendingCount — a paid stop must remain "not pending" for
    // coverage/score math even though it can be collected from again.
    return true;
  }

  void noteNewPendingVisit() {
    ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
  }
}

final tripControllerProvider =
    AsyncNotifierProvider<TripController, TripState>(TripController.new);

/// Period selector for the salesperson home stats cards.
enum HomeStatsPeriod { today, week, month }

/// Aggregated home stats for a period. Uses the salesperson-facing PERMISSIVE
/// coverage (any non-skipped visit counts) — the same measure the home shows
/// for Today — not the strict verified-only score the admin leaderboard uses.
class HomePeriodStats {
  final int totalStops;
  final int visited;
  final int collected;

  const HomePeriodStats({
    required this.totalStops,
    required this.visited,
    required this.collected,
  });

  double get score =>
      totalStops == 0 ? 0.0 : (visited / totalStops) * 100.0;

  static const empty =
      HomePeriodStats(totalStops: 0, visited: 0, collected: 0);
}

/// This-week / this-month stats for the home cards. Reuses the SAME trip source
/// as the leaderboard — [SalespersonRepository.tripsInRangeForUser], which
/// buckets by the day a trip was RUN (startedAt) — and folds the permissive
/// per-trip coverage the home already sums for Today, just over a wider window.
///
/// Watches [tripControllerProvider] so a freshly-recorded collection refreshes
/// the numbers. Closed trips (from the range query) and the currently-active
/// trip never overlap — the range query requires endedAt to be set — so adding
/// the active trip cannot double-count.
final homePeriodStatsProvider = FutureProvider.autoDispose
    .family<HomePeriodStats, HomeStatsPeriod>((ref, period) async {
  await ref.watch(tripControllerProvider.future);

  final user = ref.watch(authControllerProvider).valueOrNull;
  final userId = user?.id ?? '';
  if (userId.isEmpty) return HomePeriodStats.empty;

  final repo = ref.watch(salespersonRepositoryProvider);
  final now = DateTime.now();
  late DateTime rangeStart;
  switch (period) {
    case HomeStatsPeriod.today:
      rangeStart = DateTime(now.year, now.month, now.day);
      break;
    case HomeStatsPeriod.week:
      // Calendar week, Monday-anchored (weekday: Mon=1 … Sun=7).
      final daysSinceMonday = now.weekday - 1;
      rangeStart = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: daysSinceMonday));
      break;
    case HomeStatsPeriod.month:
      rangeStart = DateTime(now.year, now.month, 1);
      break;
  }

  final trips = await repo.tripsInRangeForUser(rangeStart, now, userId);
  final active = await repo.activeTripForUser(userId);
  final all = [...trips, if (active != null) active];

  var totalStops = 0;
  var visited = 0;
  var collected = 0;
  for (final t in all) {
    totalStops += t.totalStops;
    visited += t.visitedCount;
    collected += t.totalCollected;
  }
  return HomePeriodStats(
    totalStops: totalStops,
    visited: visited,
    collected: collected,
  );
});

/// Local wall-clock time for notification bodies. An admin seeing "Musa started
/// Route A" has no idea whether that was five minutes ago or at 6am — the push
/// may arrive late, or be read hours later from the tray.
String _clock(DateTime t) {
  final l = t.toLocal();
  final h24 = l.hour;
  final h = h24 % 12 == 0 ? 12 : h24 % 12;
  final m = l.minute.toString().padLeft(2, '0');
  final ap = h24 < 12 ? 'AM' : 'PM';
  return '$h:$m $ap';
}
