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
              body: '${user?.name ?? 'Salesperson'} started ${route.name}',
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
              body: '${active.userName} completed ${active.routeName}',
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

    // SMS firing moved to SyncController.flushPending — fires after a
    // successful pushVisit, so offline-created visits also notify the customer
    // when they later reach the server. The previous in-creation call silently
    // dropped SMS for offline visits (the Supabase config fetch failed offline).

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
    if (latest.status == VisitStatus.skipped) return false;
    return latest.allowsRevisit;
  }

  void noteNewPendingVisit() {
    ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
  }
}

final tripControllerProvider =
    AsyncNotifierProvider<TripController, TripState>(TripController.new);
