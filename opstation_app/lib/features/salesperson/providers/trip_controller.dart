import 'dart:convert';
import '../../../core/utils/customer_locations.dart';
import '../../../core/utils/receipt_books.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/sms_service.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/services/device_gps_service.dart';
import '../../../core/services/cutoff_service.dart';
import '../../../core/services/device_guard.dart';
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

    var active = userId.isEmpty ? null : await _repo.activeTripForUser(userId);
    // A route left open from an earlier day (not ended, phone offline at the
    // cut-off): close it here the way the server's cut-off does, so today's
    // visits never land in yesterday's trip and today's route can start.
    if (active != null && _dateOnly(active.startedAt).isBefore(today)) {
      try {
        active = await _closeStale(active);
      } catch (_) {}
    }
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

  /// Returns null once [t] is closed, or [t] if it can't be closed yet.
  Future<Trip?> _closeStale(Trip t) async {
    final cut = await ref.read(cutoffServiceProvider).currentCutoff();
    final parts = cut.split(':');
    final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 23;
    final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    final d = _dateOnly(t.startedAt);
    var at = DateTime(d.year, d.month, d.day, h, m);
    if (at.isBefore(t.startedAt)) at = t.startedAt;
    if (DateTime.now().isBefore(at)) return t;

    final db = ref.read(appDatabaseProvider);
    Trip closed = t.copyWith(endedAt: at, closeReason: TripCloseReason.cutoff);
    // Reopened earlier that day and never ended again: put back the
    // salesperson's own end (time and location) if nothing happened after it.
    try {
      final raw = await db.getConfig('trip.reopen.${t.id}');
      if (raw != null) {
        final m0 = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final prev = m0['ended'] == null ? null : DateTime.tryParse('${m0['ended']}')?.toLocal();
        if (prev != null && !t.visits.any((v) => v.timestamp.isAfter(prev))) {
          closed = t.copyWith(
            endedAt: prev,
            closeReason: TripCloseReason.userEnded,
            endLat: (m0['lat'] as num?)?.toDouble(),
            endLng: (m0['lng'] as num?)?.toDouble(),
          );
        }
        await db.deleteConfig('trip.reopen.${t.id}');
      }
    } catch (_) {}
    await _repo.updateTrip(closed);
    return null;
  }

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
    if (DeviceGuard.blocked) throw StateError(DeviceGuard.blockedMessage);
    final s = state.valueOrNull;
    if (s == null) throw StateError('Trip state not ready.');
    if (s.hasActiveTrip) throw StateError('A trip is already active. End it before starting another.');

    final today = TripState.today();
    final user = ref.read(authControllerProvider).valueOrNull;

    // Same route started again today by the same person: continue today's
    // trip instead of opening a second one — one summary per route per day,
    // and the CR# check covers every visit of the day on this route.
    // (Only trips the person ended themselves; a cut-off close stays closed.)
    Trip? earlier;
    for (final t in s.completedToday) {
      if (t.routeId != route.id || t.isFree) continue;
      if (t.closeReason != TripCloseReason.userEnded) continue;
      if (user != null && t.userId.isNotEmpty && t.userId != user.id) continue;
      if (_dateOnly(t.startedAt) != today) continue;
      if (earlier == null || t.startedAt.isAfter(earlier.startedAt)) earlier = t;
    }
    if (earlier != null) {
      // Shops added to the route since the first start join this trip too.
      final have = {for (final c in earlier.stopSnapshot) c.id};
      final added = [for (final c in route.stops) if (!have.contains(c.id)) c];
      for (var i = 0; i < added.length; i++) {
        await _repo.addTripStop(earlier.id, added[i].id, earlier.stopSnapshot.length + i);
      }
      // Remember the end being undone, so the sync can tell this deliberate
      // reopen from a server close, and can put the salesperson's own end
      // back if the reopened trip is never ended again.
      try {
        await ref.read(appDatabaseProvider).setConfig('trip.reopen.${earlier.id}', jsonEncode({
          'ended': earlier.endedAt?.toUtc().toIso8601String(),
          'lat': earlier.endLat,
          'lng': earlier.endLng,
        }));
      } catch (_) {}
      final resumed = earlier.copyWith(
        reopen: true,
        stopSnapshot: added.isEmpty ? null : List.unmodifiable([...earlier.stopSnapshot, ...added]),
      );
      await _repo.updateTrip(resumed);
      await _repo.setDayStamp(today);
      final exhausted = Set<String>.from(s.exhaustedOneTimeRouteIds)..remove(route.id);
      state = AsyncData(s.copyWith(
        active: resumed,
        completedToday: [for (final t in s.completedToday) if (t.id != earlier.id) t],
        exhaustedOneTimeRouteIds: exhausted,
        dayStamp: today,
      ));
      Future.microtask(() async {
        try {
          final db = ref.read(appDatabaseProvider);
          final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
          final admins = await (db.select(db.users)..where((u) => u.orgId.equals(orgId ?? ''))).get();
          final notifService = ref.read(notificationServiceProvider);
          for (final a in admins) {
            if (a.role == 'masterAdmin' || a.role == 'admin') {
              await notifService.sendToUser(
                targetUserId: a.id,
                title: 'Route Resumed',
                body: '${user?.name ?? 'Salesperson'} resumed ${route.name} at ${_clock(DateTime.now())}',
              );
            }
          }
        } catch (_) {}
      });
      return resumed;
    }

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

  /// Start an open-ended "Free Route": a trip with no predefined stops. The
  /// salesperson adds customers on the fly (addFreeStop) and each add opens the
  /// normal visit modal. Closes and summarizes exactly like a regular route.
  Future<Trip> startFreeTrip() async {
    if (DeviceGuard.blocked) throw StateError(DeviceGuard.blockedMessage);
    final route = SalesRoute(
      id: _newId('freeroute'),
      name: 'Free Route',
      stops: const [],
      kind: RouteKind.free,
    );
    return startTrip(route);
  }

  /// Append a customer as a stop to the active free route (once per route),
  /// persisting + syncing the stop so it renders and can be visited normally.
  Future<void> addFreeStop(Customer customer) async {
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) throw StateError('No active trip.');
    if (active.stopSnapshot.any((c) => c.id == customer.id)) return; // once per route
    await _repo.addTripStop(active.id, customer.id, active.stopSnapshot.length);
    final updated =
        active.copyWith(stopSnapshot: [...active.stopSnapshot, customer]);
    state = AsyncData(s.copyWith(active: updated));
  }

  /// A shop location added from the field: update this route's copy of the
  /// customer so the card and the next visit use it straight away.
  void updateStopLocation(String customerId, double lat, double lng) {
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) return;
    final stops = [
      for (final c in active.stopSnapshot)
        c.id == customerId ? c.copyWith(latitude: lat, longitude: lng) : c,
    ];
    state = AsyncData(s.copyWith(active: active.copyWith(stopSnapshot: stops)));
  }

  Future<void> completeTrip() async {
    if (DeviceGuard.blocked) throw StateError(DeviceGuard.blockedMessage);
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
    try {
      await ref.read(appDatabaseProvider).deleteConfig('trip.reopen.${active.id}');
    } catch (_) {}

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

  /// Slips on today's collections on this phone (a phone's not-yet-synced
  /// collections aren't in the server's count yet).
  Set<int> localReceiptSlips() {
    final s = state.valueOrNull;
    final out = <int>{};
    if (s == null) return out;
    void scan(Iterable<Visit> vs) {
      for (final v in vs) {
        if (v.amount <= 0) continue;
        final r = v.receiptNumber;
        if (r == null || r.trim().isEmpty) continue;
        out.addAll(receiptSlips(r));
      }
    }
    if (s.active != null) scan(s.active!.visits);
    for (final t in s.completedToday) {
      scan(t.visits);
    }
    return out;
  }

  /// Receipt books ON (Admin Settings): the CR# must be an unused slip from
  /// this salesperson's own open book.
  Future<void> _checkReceiptBook(int amount, String? receiptNumber) async {
    if (amount <= 0 || receiptNumber == null) return;
    await ReceiptBooks.ensureLoaded(ref.read(appDatabaseProvider));
    final p = ReceiptBooks.problem(receiptNumber, localReceiptSlips());
    if (p != null) throw ArgumentError(p);
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
    if (DeviceGuard.blocked) throw StateError(DeviceGuard.blockedMessage);
    final s = state.valueOrNull;
    final active = s?.active;
    if (s == null || active == null) throw StateError('No active trip.');
    // Nothing collected → no receipt slip is used. Don't keep a CR#, so the
    // slip stays free for the next visit where money is collected.
    if (amount <= 0) receiptNumber = null;
    if (amount > 0 && (receiptNumber == null || receiptNumber.trim().isEmpty)) {
      throw ArgumentError('Receipt number is required when amount > 0.');
    }
    await _checkReceiptBook(amount, receiptNumber);
    // A physical CR slip number is unique, so the same number appearing twice
    // in a trip means a typo. Reject it here — otherwise the two collections
    // collapse into one in the report and COLLECTED under-reports.
    if (amount > 0 && receiptNumber != null && receiptNumber.trim().isNotEmpty) {
      final rn = receiptNumber.trim();
      for (final v in active.visits) {
        if (v.amount > 0 && (v.receiptNumber ?? '').trim() == rn) {
          throw ArgumentError(
              'CR# $rn is already entered on this trip (Rs ${v.amount}). '
              'Check the slip and enter the correct receipt number.');
        }
      }
    }

    // Verified when inside the fence of ANY of the customer's locations
    // (Main + extra ones such as a godown) — same radius for all.
    await CustomerLocations.ensureLoaded(ref.read(appDatabaseProvider));
    VisitStatus status;
    double? distance;
    final nearest = (capturedLat == null || capturedLng == null)
        ? null
        : CustomerLocations.nearest(
            customer.id, customer.latitude, customer.longitude, capturedLat, capturedLng);
    if (nearest == null) {
      status = VisitStatus.noLocation;
    } else {
      distance = nearest.distanceMeters;
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
                visitId: visitId,
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

  /// Record an ad-hoc cash receipt for ANY customer — used when a customer from
  /// an inactive route (or no route at all) pays. Location is skipped entirely
  /// (no GPS gate) and the SMS still fires.
  ///
  /// Routing of the payment:
  ///   - If a planned route is ACTIVE, the receipt joins that route's summary
  ///     (via the normal [markVisit] path). It does not become a planned stop,
  ///     so it never distorts that route's coverage / visit score — it simply
  ///     appears as an additional collection on the report.
  ///   - If NO route is active, the receipt is recorded into a standalone,
  ///     already-completed "Off-route collections" summary. That summary never
  ///     occupies the active-trip slot (so a real route can still be started)
  ///     and needs no closing. Multiple ad-hoc receipts in the same day
  ///     aggregate into the one off-route summary.
  Future<Visit> recordAdHocCollection({
    required Customer customer,
    required int amount,
    String? receiptNumber,
    String? notes,
  }) async {
    if (DeviceGuard.blocked) throw StateError(DeviceGuard.blockedMessage);
    final s = state.valueOrNull;
    if (s == null) throw StateError('Trip state not ready.');

    if (s.active != null) {
      // A route is running → attach to it (no location).
      return markVisit(
        customer: customer,
        capturedLat: null,
        capturedLng: null,
        accuracyMeters: null,
        amount: amount,
        receiptNumber: receiptNumber,
        notes: notes,
      );
    }

    return _recordStandaloneOffRoute(
      customer: customer,
      amount: amount,
      receiptNumber: receiptNumber,
      notes: notes,
    );
  }

  /// Record an off-route receipt when no route is active, into a self-contained
  /// "Off-route collections" summary that is created ALREADY completed (so it
  /// never blocks starting a real route and never needs closing). Subsequent
  /// off-route receipts the same day append to the same summary.
  Future<Visit> _recordStandaloneOffRoute({
    required Customer customer,
    required int amount,
    String? receiptNumber,
    String? notes,
  }) async {
    final s = state.valueOrNull;
    if (s == null) throw StateError('Trip state not ready.');
    if (amount <= 0) receiptNumber = null; // nothing collected → no slip used
    if (amount > 0 && (receiptNumber == null || receiptNumber.trim().isEmpty)) {
      throw ArgumentError('Receipt number is required when amount > 0.');
    }
    await _checkReceiptBook(amount, receiptNumber);

    final today = TripState.today();
    final user = ref.read(authControllerProvider).valueOrNull;
    final now = DateTime.now();

    // Reuse today's off-route summary if one exists; otherwise create it as an
    // already-closed trip.
    final existing =
        s.completedToday.where((t) => t.routeId == 'offroute').toList();
    final bool isNew = existing.isEmpty;
    Trip trip = isNew
        ? Trip(
            id: _newId('trip'),
            routeId: 'offroute',
            routeName: 'Off-route collections',
            routeKind: RouteKind.recurring,
            stopSnapshot: const <Customer>[],
            startedAt: now,
            endedAt: now,
            closeReason: TripCloseReason.userEnded,
            startLat: null,
            startLng: null,
            userId: user?.id ?? '',
            userName: user?.name ?? '',
            userRole: user?.role.label ?? '',
          )
        : existing.first;

    if (isNew) {
      await _repo.createTrip(trip);
      await _repo.setDayStamp(today);
    }

    // Reject a receipt number already used in today's off-route summary (same
    // uniqueness rule as an on-route trip — see markVisit).
    if (amount > 0 && receiptNumber != null && receiptNumber.trim().isNotEmpty) {
      final rn = receiptNumber.trim();
      for (final v in trip.visits) {
        if (v.amount > 0 && (v.receiptNumber ?? '').trim() == rn) {
          throw ArgumentError(
              'CR# $rn is already entered today (Rs ${v.amount}). '
              'Check the slip and enter the correct receipt number.');
        }
      }
    }

    final visit = Visit(
      id: _newId('visit'),
      customerId: customer.id,
      status: VisitStatus.noLocation,
      timestamp: now,
      capturedLat: null,
      capturedLng: null,
      accuracyMeters: null,
      distanceMeters: null,
      amount: amount,
      receiptNumber: receiptNumber,
      notes: notes,
      photoPaths: const [],
      userId: trip.userId,
      userName: trip.userName,
      userRole: trip.userRole,
    );

    _repo.setCurrentTripContext(trip.id);
    await _repo.insertVisit(visit);

    // Persist the appended visit and keep endedAt fresh so the summary sorts
    // as the most recent completed trip.
    final updated = trip.copyWith(
      visits: [...trip.visits, visit],
      endedAt: now,
    );
    await _repo.updateTrip(updated);

    // SMS at the real creation point (mirrors markVisit).
    if (amount > 0) {
      SmsService.note(
          'adhoc CR: firing SMS for ${customer.id} ${customer.phone} (amount=$amount)');
      Future.microtask(() async {
        try {
          await ref.read(smsServiceProvider).sendVisitSms(
                customerPhone: customer.phone,
                customerName: customer.shopName,
                amount: amount,
                receiptNo: receiptNumber ?? '',
                salespersonName: trip.userName,
                visitId: visit.id,
              );
        } catch (e) {
          SmsService.note('adhoc CR: SMS threw — $e');
        }
      });
    }

    ref.read(syncControllerProvider.notifier).noteNewPendingVisit();

    final others =
        s.completedToday.where((t) => t.routeId != 'offroute').toList();
    state = AsyncData(s.copyWith(completedToday: [...others, updated]));
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
