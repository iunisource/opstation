import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/sms_service.dart';
import '../services/notification_service.dart';
import '../../features/auth/providers/auth_controller.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';
import '../supabase/supabase_pull_service.dart';
import '../supabase/supabase_sync_service.dart';
import 'connectivity_service.dart';

enum SyncState { synced, syncing, error, offline }

class SyncStatus {
  final SyncState state;
  final int pendingCount;
  final int rejectedCount;
  final DateTime? lastSyncedAt;

  const SyncStatus({
    required this.state,
    required this.pendingCount,
    required this.rejectedCount,
    this.lastSyncedAt,
  });

  SyncStatus copyWith({
    SyncState? state,
    int? pendingCount,
    int? rejectedCount,
    DateTime? lastSyncedAt,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      pendingCount: pendingCount ?? this.pendingCount,
      rejectedCount: rejectedCount ?? this.rejectedCount,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }
}

class SyncController extends Notifier<SyncStatus> {
  Timer? _retryTimer;
  StreamSubscription<bool>? _onlineSub;
  bool _currentlyOnline = true;
  bool _flushing = false;

  AppDatabase get _db => ref.read(appDatabaseProvider);
  SupabaseSyncService get _supabase => ref.read(supabaseSyncServiceProvider);

  /// When the last nudge fired, so we repeat every 30 min rather than every
  /// timer tick. Reset when no route is open.
  DateTime? _lastIdleNudgeAt;

  /// Nudges a rep whose route has been open but untouched for an hour.
  ///
  /// Routes left running to the 23:00 cut-off are common — the rep finishes
  /// their day and simply doesn't close the route, so it stays "in progress"
  /// in monitoring and the cut-off has to guillotine it. This fires a local
  /// notification (device-generated, so it works offline) after 60 minutes
  /// with no visit marked, then every 30 minutes until they act.
  ///
  /// Scoped to the signed-in user's own trip: an admin device holds other
  /// reps' trips too, and nudging an admin about someone else's route would
  /// be noise.
  Future<void> _checkIdleRoute() async {
    try {
      final userId = ref.read(authControllerProvider).valueOrNull?.id;
      if (userId == null || userId.isEmpty) return;

      final active = await (_db.select(_db.trips)
            ..where((t) => t.userId.equals(userId) & t.endedAt.isNull())
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(1))
          .getSingleOrNull();
      if (active == null) {
        _lastIdleNudgeAt = null;
        return;
      }

      final visits = await (_db.select(_db.visits)
            ..where((v) => v.tripId.equals(active.id)))
          .get();
      var lastActivity = active.startedAt;
      for (final v in visits) {
        if (v.timestamp.isAfter(lastActivity)) lastActivity = v.timestamp;
      }

      final now = DateTime.now();
      if (now.difference(lastActivity) < const Duration(minutes: 60)) return;
      if (_lastIdleNudgeAt != null &&
          now.difference(_lastIdleNudgeAt!) < const Duration(minutes: 30)) {
        return;
      }
      _lastIdleNudgeAt = now;

      await ref.read(notificationServiceProvider).showLocalAlert(
            id: 90001,
            title: 'No visit marked in 60 minutes',
            body: "If you've finished your route, please close it. Thanks.",
          );
    } catch (_) {
      // Never let a reminder break the sync tick.
    }
  }

  /// Pushes trips without resurrecting ones the server has already closed.
  ///
  /// pushTrip is an upsert, so blindly pushing a local row whose `ended_at` is
  /// still null overwrites a server-side close — which is exactly how a trip
  /// shut by the 23:00 cut-off cron came back to life as "in progress" the
  /// next morning. The server is authoritative for cut-off, so when it reports
  /// a trip closed and the device still thinks it's open, we adopt the close
  /// locally instead of pushing over it.
  Future<void> _pushTripsRespectingServerClose(
    List<TripsData> trips, {
    String tag = 'sync',
  }) async {
    if (trips.isEmpty) return;
    final ids = trips.map((t) => t.id).toList();
    final closedOnServer = <String, DateTime>{};
    try {
      final client = Supabase.instance.client;
      // Batched: `in.(...)` rides in the URL, so a long id list 400s.
      for (var i = 0; i < ids.length; i += 40) {
        final batch =
            ids.sublist(i, i + 40 > ids.length ? ids.length : i + 40);
        final rows = await client
            .from('trips')
            .select('id, ended_at')
            .inFilter('id', batch);
        for (final r in (rows as List)) {
          final m = Map<String, dynamic>.from(r as Map);
          final ended = m['ended_at'] as String?;
          if (ended != null) {
            closedOnServer[m['id'] as String] = DateTime.parse(ended);
          }
        }
      }
    } catch (e) {
      // Can't tell what the server holds — pushing now risks reopening a
      // closed trip, so skip this round. The 30s timer retries.
      SmsService.note('$tag: skipped trip push, server state unreadable — $e');
      return;
    }

    int pushed = 0, adopted = 0, failed = 0;
    for (final t in trips) {
      final serverEnd = closedOnServer[t.id];
      if (serverEnd != null && t.endedAt == null) {
        await (_db.update(_db.trips)..where((r) => r.id.equals(t.id))).write(
          TripsCompanion(
            endedAt: Value(serverEnd),
            closeReason: const Value('cutoff'),
          ),
        );
        adopted++;
        continue;
      }
      try {
        await _supabase.pushTrip(t);
        pushed++;
      } catch (e) {
        failed++;
        SmsService.note('$tag: pushTrip FAILED ${t.id} — $e');
        print('$tag pushTrip FAILED for ${t.id}: $e');
      }
    }
    SmsService.note(
        '$tag: trips pushed=$pushed adopted-server-close=$adopted failed=$failed');
  }

  @override
  SyncStatus build() {
    _onlineSub = ref
        .read(connectivityServiceProvider)
        .watchOnline()
        .listen(_onConnectivityChanged);

    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      flushPending();
      _checkIdleRoute();
    });

    ref.onDispose(() {
      _retryTimer?.cancel();
      _onlineSub?.cancel();
    });

    Future.microtask(_refreshCounts);

    return const SyncStatus(
      state: SyncState.synced,
      pendingCount: 0,
      rejectedCount: 0,
    );
  }

  void _onConnectivityChanged(bool online) {
    _currentlyOnline = online;
    SmsService.note('sync: connectivity -> ${online ? "online" : "offline"}');
    if (online) {
      flushPending();
    } else {
      state = state.copyWith(state: SyncState.offline);
    }
  }

  Future<void> _refreshCounts() async {
    final pending = await (_db.select(_db.visits)
          ..where((v) => v.syncStatus.equals('pending')))
        .get();
    final rejected = await (_db.select(_db.visits)
          ..where((v) => v.syncStatus.equals('rejected')))
        .get();
    final pendingCustomers = await (_db.select(_db.customers)
          ..where((c) => c.syncStatus.equals('pending')))
        .get();

    SyncState s;
    if (!_currentlyOnline) {
      s = SyncState.offline;
    } else if (rejected.isNotEmpty) {
      s = SyncState.error;
    } else if (pending.isNotEmpty || pendingCustomers.isNotEmpty) {
      s = SyncState.syncing;
    } else {
      s = SyncState.synced;
    }

    state = state.copyWith(
      state: s,
      pendingCount: pending.length + pendingCustomers.length,
      rejectedCount: rejected.length,
    );
  }

  Future<void> pushAll(String? orgId) async {
    if (!_currentlyOnline) return;
    if (_flushing) return;
    _flushing = true;
    state = state.copyWith(state: SyncState.syncing);
    try {
      final orgs = await _db.select(_db.orgs).get();
      for (final o in orgs) {
        try {
          await _supabase.pushOrg(o);
        } catch (e) {
          print('pushOrg FAILED: $e');
        }
      }

      final users = await _db.select(_db.users).get();
      for (final u in users) {
        try {
          // If user has null org_id but we have an orgId context,
          // fix it locally and in Supabase before pushing
          if (u.orgId == null && orgId != null && u.role != 'superAdmin') {
            await (_db.update(_db.users)..where((t) => t.id.equals(u.id)))
                .write(UsersCompanion(orgId: Value(orgId)));
            await _supabase.pushUser(u.copyWith(orgId: Value(orgId)));
          } else if (u.orgId != null || u.role == 'superAdmin') {
            await _supabase.pushUser(u);
          }
        } catch (_) {}
      }

      // Only push customers that actually changed. Pushing the entire local
      // customer table row-by-row on every login / manual sync was the cause
      // of multi-minute syncs — thousands of sequential round-trips to flush
      // a single real edit. Pending-only mirrors the visits / deliveryStops
      // loops below and _pushPendingCustomers(); the backlog still self-heals
      // because any dirty row is 'pending'.
      final customers = orgId == null
          ? await (_db.select(_db.customers)
                ..where((c) => c.syncStatus.equals('pending')))
              .get()
          : await (_db.select(_db.customers)
                ..where((c) =>
                    c.orgId.equals(orgId) & c.syncStatus.equals('pending')))
              .get();
      for (final c in customers) {
        try {
          await _supabase.pushCustomer(c);
          await (_db.update(_db.customers)..where((t) => t.id.equals(c.id)))
              .write(const CustomersCompanion(syncStatus: Value('synced')));
        } catch (e) {
          print('pushCustomer FAILED: $e');
        }
      }

      await _pushPendingFieldOrders();

      final routes = orgId == null
          ? await _db.select(_db.salesRoutesTable).get()
          : await (_db.select(_db.salesRoutesTable)..where((r) => r.orgId.equals(orgId))).get();
      for (final r in routes) {
        try {
          await _supabase.pushRoute(r);
        } catch (e) {
          print('pushRoute FAILED: $e');
        }
      }

      final routeStops = await _db.select(_db.routeStops).get();
      for (final s in routeStops) {
        try {
          await _supabase.pushRouteStop(s);
        } catch (e) {
          print('pushRouteStop FAILED: $e');
        }
      }

      final assignments = await _db.select(_db.routeAssignments).get();
      for (final a in assignments) {
        try {
          await _supabase.pushRouteAssignment(a);
        } catch (e) {
          print('pushRouteAssignment FAILED: $e');
        }
      }

      final trips = orgId == null
          ? await _db.select(_db.trips).get()
          : await (_db.select(_db.trips)..where((t) => t.orgId.equals(orgId))).get();
      await _pushTripsRespectingServerClose(trips, tag: 'pushAll');

      final tripStops = await _db.select(_db.tripStops).get();
      for (final s in tripStops) {
        try {
          await _supabase.pushTripStop(s);
        } catch (e) {
          print('pushTripStop FAILED: $e');
        }
      }

      final visits = await (_db.select(_db.visits)
            ..where((v) => v.syncStatus.equals('pending')))
          .get();
      for (final v in visits) {
        try {
          await _supabase.pushVisit(v);
          await (_db.update(_db.visits)..where((t) => t.id.equals(v.id)))
              .write(const VisitsCompanion(syncStatus: Value('synced')));

          // Same post-push SMS hook as flushPending — covers the case where
          // pushAll syncs leftover offline visits at login (e.g. after the OS
          // killed the backgrounded app and the user reopened it).
          SmsService.note(
              'pushAll: visit ${v.id} pushed (amount=${v.amount}, cust=${v.customerId})');
          if (v.amount > 0) {
            Future.microtask(() async {
              try {
                final customer = await (_db.select(_db.customers)
                      ..where((c) => c.id.equals(v.customerId)))
                    .getSingleOrNull();
                if (customer == null) {
                  SmsService.note(
                      'pushAll: visit ${v.id} customer NOT in local db → SMS skipped');
                  return;
                }
                await ref.read(smsServiceProvider).sendVisitSms(
                  customerPhone: customer.phone,
                  customerName: customer.shopName,
                  amount: v.amount,
                  receiptNo: v.receiptNumber ?? '',
                  salespersonName: v.userName,
                );
              } catch (e) {
                SmsService.note('pushAll: visit ${v.id} SMS threw — $e');
                print('post-sync SMS failed for visit ${v.id}: $e');
              }
            });
          } else {
            SmsService.note('pushAll: visit ${v.id} amount 0 → no SMS');
          }
        } catch (e) {
          print('pushAll pushVisit FAILED for visit ${v.id}: $e');
        }
      }

      final deliveries = orgId == null
          ? await _db.select(_db.deliveries).get()
          : await (_db.select(_db.deliveries)..where((d) => d.orgId.equals(orgId))).get();
      for (final d in deliveries) {
        try {
          await _supabase.pushDelivery(d);
        } catch (e) {
          print('pushDelivery FAILED: $e');
        }
      }

      final deliveryStops = await (_db.select(_db.deliveryStops)
            ..where((s) => s.syncStatus.equals('pending')))
          .get();
      for (final stop in deliveryStops) {
        try {
          await _supabase.pushDeliveryStop(stop);
          await (_db.update(_db.deliveryStops)
                ..where((t) => t.id.equals(stop.id)))
              .write(const DeliveryStopsCompanion(
                  syncStatus: Value('synced')));

          // Same post-push SMS hook as flushPending. Covers the OS-kill
          // scenario: app killed in background, user reopens, login fires
          // pushAll, leftover offline stops sync and SMS goes out here.
          if ((stop.cashReceived ?? 0) > 0) {
            Future.microtask(() async {
              try {
                final customer = await (_db.select(_db.customers)
                      ..where((c) => c.id.equals(stop.customerId)))
                    .getSingleOrNull();
                if (customer == null || customer.phone.isEmpty) return;
                final delivery = await (_db.select(_db.deliveries)
                      ..where((d) => d.id.equals(stop.deliveryId)))
                    .getSingleOrNull();
                await ref.read(smsServiceProvider).sendDeliverySms(
                  customerPhone: customer.phone,
                  customerName: stop.customerName,
                  amount: stop.cashReceived ?? 0,
                  driverName: delivery?.driverName ?? '',
                );
              } catch (e) {
                print('post-sync delivery SMS failed for ${stop.id}: $e');
              }
            });
          }
        } catch (e) {
          print('pushAll pushDeliveryStop FAILED for ${stop.id}: $e');
        }
      }

      await _pushIntelligencePending();

      state = state.copyWith(
        state: SyncState.synced,
        lastSyncedAt: DateTime.now(),
      );
    } catch (_) {
      // Non-fatal
    } finally {
      _flushing = false;
      await _refreshCounts();
    }
  }

  Future<void> flushPending() async {
    print('FLUSH: entry online=$_currentlyOnline flushing=$_flushing');
    if (!_currentlyOnline) {
      print('FLUSH: BAIL — offline');
      // Visible in the debug screen: a device that bails here every cycle
      // never uploads anything all day, which looks identical (from the
      // server) to a rep who simply didn't work.
      SmsService.note('sync: BAIL — connectivity reports offline');
      return;
    }
    // Note: no auth check — visits should sync regardless of Supabase session
    if (_flushing) { print('FLUSH: BAIL — already flushing'); return; }
    _flushing = true;
    try {
      // PRIORITY: push intel data BEFORE the customer/visits/deliveries
      // push loops, which may iterate over thousands of pending rows and
      // retry every one on DNS failure with no backoff. Without this,
      // intel data would never get a turn under network flakiness.
      print('FLUSH: pushing intel first (priority)');
      try {
        await _pushIntelligencePending();
        print('FLUSH: intel priority push completed');
      } catch (e) {
        print('FLUSH: intel priority push failed: $e');
      }

      await _refreshCounts();
      if (!_currentlyOnline) return;

      // Push locally-edited customers (location capture, create, update, active
      // toggle) before visits. Mirrors the visit dirty-flag pattern so customer
      // edits drain automatically on reconnect / timer / kick, not only on the
      // manual sync button.
      await _pushPendingCustomers();
      if (!_currentlyOnline) return;

      await _pushPendingFieldOrders();
      if (!_currentlyOnline) return;

      final pending = await (_db.select(_db.visits)
            ..where((v) => v.syncStatus.equals('pending')))
          .get();
      SmsService.note('flushPending: ${pending.length} pending visit(s) to push');

      // Re-push recent trips on EVERY cycle, before the pending-visits check.
      //
      // createTrip pushes best-effort inside a bare catch, and trips carry no
      // syncStatus flag — so a push that failed at route-start leaves a local
      // row indistinguishable from a synced one. Previously the only in-day
      // retry lived below the `pending.isEmpty` early return and only covered
      // trips referenced by a pending visit, so a device with no pending
      // visits never retried its trip: the rep stayed invisible in live
      // monitoring and their collections went unaggregated until the next
      // login ran pushAll. pushTrip is an upsert, so re-pushing an
      // already-present trip is a harmless no-op. Scoped to the last 2 days
      // so this stays a couple of rows, not the device's whole history.
      try {
        // Scoped to the signed-in org. An admin device holds other orgs'
        // trips too, and pushing those is refused by the `Tenant scoped` RLS
        // policy (42501), so an unscoped re-push failed on every cycle.
        final orgId = ref.read(orgIdProvider);
        final cutoff = DateTime.now().subtract(const Duration(days: 2));
        final localTrips = orgId == null
            ? await _db.select(_db.trips).get()
            : await (_db.select(_db.trips)
                  ..where((t) => t.orgId.equals(orgId)))
                .get();
        final recentTrips =
            localTrips.where((t) => t.startedAt.isAfter(cutoff)).toList();
        await _pushTripsRespectingServerClose(recentTrips, tag: 'flushPending');
      } catch (e) {
        SmsService.note('sync: recent-trip re-push block threw — $e');
      }

      if (pending.isEmpty) {
        await _refreshCounts();
        return;
      }

      state = state.copyWith(state: SyncState.syncing);

      // Push parent trips first. Visits FK to trips on the server, so each
      // trip must exist there before its child visits can be inserted.
      // Without this, offline-created visits fail with a 23503 FK error
      // until pushAll runs (login / manual Retry).
      final tripIds = pending
          .map((v) => v.tripId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      if (tripIds.isNotEmpty) {
        final trips = await (_db.select(_db.trips)
              ..where((t) => t.id.isIn(tripIds.toList())))
            .get();
        await _pushTripsRespectingServerClose(trips, tag: 'flushPending-parent');
        final tripStops = await (_db.select(_db.tripStops)
              ..where((s) => s.tripId.isIn(tripIds.toList())))
            .get();
        for (final s in tripStops) {
          try {
            await _supabase.pushTripStop(s);
          } catch (e) {
            print('flushPending pushTripStop FAILED: $e');
          }
        }
      }

      for (final v in pending) {
        try {
          await _supabase.pushVisit(v);
          await (_db.update(_db.visits)..where((t) => t.id.equals(v.id)))
              .write(const VisitsCompanion(syncStatus: Value('synced')));
          state = state.copyWith(lastSyncedAt: DateTime.now());

          // Fire SMS post-push (fire-and-forget) so offline-created visits also
          // notify the customer. Mirrors the original microtask pattern from
          // trip_controller. Gated on amount > 0, same as before.
          SmsService.note(
              'visit ${v.id} pushed (amount=${v.amount}, cust=${v.customerId})');
          if (v.amount > 0) {
            Future.microtask(() async {
              try {
                final customer = await (_db.select(_db.customers)
                      ..where((c) => c.id.equals(v.customerId)))
                    .getSingleOrNull();
                if (customer == null) {
                  SmsService.note(
                      'visit ${v.id}: customer ${v.customerId} NOT in local db → SMS skipped');
                  return;
                }
                await ref.read(smsServiceProvider).sendVisitSms(
                  customerPhone: customer.phone,
                  customerName: customer.shopName,
                  amount: v.amount,
                  receiptNo: v.receiptNumber ?? '',
                  salespersonName: v.userName,
                );
              } catch (e) {
                SmsService.note('visit ${v.id}: SMS call threw — $e');
                print('post-sync SMS failed for visit ${v.id}: $e');
              }
            });
          } else {
            SmsService.note('visit ${v.id}: amount is 0 → no SMS');
          }
        } catch (e, st) {
          // ignore: avoid_print
          print('pushVisit FAILED for visit ${v.id}: $e');
          await Sentry.captureException(e, stackTrace: st);
        }
      }

      // === DELIVERY STOPS === same shape as visits: pending stops + parent
      // deliveries (FK), then push stop, mark synced, fire SMS post-push.
      final pendingStops = await (_db.select(_db.deliveryStops)
            ..where((s) => s.syncStatus.equals('pending')))
          .get();
      if (pendingStops.isNotEmpty) {
        final deliveryIds = pendingStops
            .map((s) => s.deliveryId)
            .where((id) => id.isNotEmpty)
            .toSet();
        if (deliveryIds.isNotEmpty) {
          final deliveries = await (_db.select(_db.deliveries)
                ..where((d) => d.id.isIn(deliveryIds.toList())))
              .get();
          for (final d in deliveries) {
            try {
              await _supabase.pushDelivery(d);
            } catch (e) {
              print('flushPending pushDelivery FAILED for ${d.id}: $e');
            }
          }
        }

        for (final stop in pendingStops) {
          try {
            await _supabase.pushDeliveryStop(stop);
            await (_db.update(_db.deliveryStops)
                  ..where((t) => t.id.equals(stop.id)))
                .write(const DeliveryStopsCompanion(
                    syncStatus: Value('synced')));
            state = state.copyWith(lastSyncedAt: DateTime.now());

            // SMS — only when cash collected (same rule as visit amount > 0).
            if ((stop.cashReceived ?? 0) > 0) {
              Future.microtask(() async {
                try {
                  final customer = await (_db.select(_db.customers)
                        ..where((c) => c.id.equals(stop.customerId)))
                      .getSingleOrNull();
                  if (customer == null || customer.phone.isEmpty) return;
                  final delivery = await (_db.select(_db.deliveries)
                        ..where((d) => d.id.equals(stop.deliveryId)))
                      .getSingleOrNull();
                  await ref.read(smsServiceProvider).sendDeliverySms(
                    customerPhone: customer.phone,
                    customerName: stop.customerName,
                    amount: stop.cashReceived ?? 0,
                    driverName: delivery?.driverName ?? '',
                  );
                } catch (e) {
                  print('post-sync delivery SMS failed for ${stop.id}: $e');
                }
              });
            }
          } catch (e, st) {
            print('pushDeliveryStop FAILED for ${stop.id}: $e');
            await Sentry.captureException(e, stackTrace: st);
          }
        }
      }

      print('FLUSH: about to push intel');
      await _pushIntelligencePending();
      print('FLUSH: intel push returned, refreshing counts');

      await _refreshCounts();
    } catch (e, st) {
      print('FLUSH: SWALLOWED EXCEPTION: $e');
      print('FLUSH: stack: $st');
      // Try intel push even if visits/deliveries broke earlier
      try {
        await _pushIntelligencePending();
        print('FLUSH: intel push completed after outer exception');
      } catch (e2) {
        print('FLUSH: intel push ALSO failed after outer exception: $e2');
      }
    } finally {
      _flushing = false;
    }
  }

  void noteNewPendingVisit() {
    _refreshCounts();
    flushPending();
  }

  /// Kick an immediate flush after a customer write (location / create / update
  /// / active toggle). Online → pushes the change now; offline → flushPending
  /// bails and it drains on reconnect via the connectivity listener.
  void noteCustomerChanged() {
    _refreshCounts();
    flushPending();
  }

  /// Push locally-edited customers (sync_status = 'pending') and mark them
  /// synced. Called from flushPending, so it fires on reconnect, on the 30s
  /// retry, and on a noteCustomerChanged() kick.
  Future<void> _pushPendingCustomers() async {
    final pending = await (_db.select(_db.customers)
          ..where((c) => c.syncStatus.equals('pending')))
        .get();
    if (pending.isEmpty) return;
    state = state.copyWith(state: SyncState.syncing);
    for (final c in pending) {
      try {
        await _supabase.pushCustomer(c);
        await (_db.update(_db.customers)..where((t) => t.id.equals(c.id)))
            .write(const CustomersCompanion(syncStatus: Value('synced')));
        state = state.copyWith(lastSyncedAt: DateTime.now());
      } catch (e, st) {
        print('pushCustomer FAILED for ${c.id}: $e');
        await Sentry.captureException(e, stackTrace: st);
      }
    }
  }

  /// Push locally-captured field orders (parent first, then its items),
  /// marking each row synced on success. Mirrors the customer/visit pattern
  /// so offline-taken orders drain on reconnect / timer / kick.
  Future<void> _pushPendingFieldOrders() async {
    final orders = await (_db.select(_db.fieldOrders)
          ..where((o) => o.syncStatus.equals('pending')))
        .get();
    if (orders.isEmpty) return;
    state = state.copyWith(state: SyncState.syncing);
    for (final o in orders) {
      try {
        await _supabase.pushFieldOrder(o);
        // Push this order's items (push all its items; they share the parent's
        // sync lifecycle — mark them synced alongside the parent).
        final items = await (_db.select(_db.fieldOrderItems)
              ..where((i) => i.fieldOrderId.equals(o.id)))
            .get();
        for (final it in items) {
          await _supabase.pushFieldOrderItem(it);
          await (_db.update(_db.fieldOrderItems)
                ..where((t) => t.id.equals(it.id)))
              .write(const FieldOrderItemsCompanion(
                  syncStatus: Value('synced')));
        }
        await (_db.update(_db.fieldOrders)..where((t) => t.id.equals(o.id)))
            .write(const FieldOrdersCompanion(syncStatus: Value('synced')));
        state = state.copyWith(lastSyncedAt: DateTime.now());
      } catch (e, st) {
        print('pushFieldOrder FAILED for ${o.id}: $e');
        await Sentry.captureException(e, stackTrace: st);
      }
    }
  }

  /// Manual refresh — pushes pending writes AND pulls fresh route_assignments
  /// for the current user. Wired to the "Retry now" button on the sync
  /// status chip. Targeted pull avoids dragging down all trips/visits.
  Future<void> refreshNow({String? orgId, String? userId}) async {
    state = state.copyWith(state: SyncState.syncing);
    try {
      if (orgId != null) {
        await pushAll(orgId);
      } else {
        await flushPending();
      }
      if (userId != null) {
        try {
          await ref
              .read(supabasePullServiceProvider)
              .pullRouteAssignmentsForUser(userId);
        } catch (e) {
          print('refreshNow pull failed: $e');
        }
      }
    } finally {
      await _refreshCounts();
      state = state.copyWith(
        state: _currentlyOnline ? SyncState.synced : SyncState.offline,
        lastSyncedAt: DateTime.now(),
      );
    }
  }

  /// Push pending Intelligence rows (competitor_spotting + placement_audit).
  /// No parent-FK chain to worry about — customers/products/categories are
  /// reference data managed via web admin and already exist on the server
  /// before any surveyor entry can reference them.
  ///
  /// Batched: one survey of N products creates N placement_audit rows, so a
  /// single Supabase insert beats N round-trips when reconnecting after a
  /// long offline stretch.
  Future<void> _pushIntelligencePending() async {
    print('INTEL PUSH: entered');
    // Competitor spotting
    final pendingSpottings = await (_db.select(_db.competitorSpottings)
          ..where((cs) => cs.syncStatus.equals('pending')))
        .get();
    print('INTEL PUSH: pending competitor_spotting=${pendingSpottings.length}');
    if (pendingSpottings.isNotEmpty) {
      try {
        final payload = pendingSpottings.map((cs) => {
          'id': cs.id,
          'org_id': cs.orgId,
          'customer_id': cs.customerId,
          'category_id': cs.categoryId,
          'brand_name': cs.brandName,
          'price': cs.price,
          'specs': cs.specs,
          'surveyed_by_user_id': cs.surveyedByUserId,
          'surveyed_at': cs.surveyedAt.toUtc().toIso8601String(),
          'created_at': cs.createdAt.toUtc().toIso8601String(),
        }).toList();
        await Supabase.instance.client
            .from('competitor_spotting')
            .insert(payload);
        final ids = pendingSpottings.map((cs) => cs.id).toList();
        await (_db.update(_db.competitorSpottings)
              ..where((t) => t.id.isIn(ids)))
            .write(const CompetitorSpottingsCompanion(
                syncStatus: Value('synced')));
        state = state.copyWith(lastSyncedAt: DateTime.now());
        print('Pushed ${pendingSpottings.length} competitor_spotting rows');
      } catch (e, st) {
        print('pushCompetitorSpotting batch FAILED: $e');
        await Sentry.captureException(e, stackTrace: st);
      }
    }

    // Placement audit
    final pendingAudits = await (_db.select(_db.placementAudits)
          ..where((pa) => pa.syncStatus.equals('pending')))
        .get();
    print('INTEL PUSH: pending placement_audit=${pendingAudits.length}');
    if (pendingAudits.isNotEmpty) {
      try {
        final payload = pendingAudits.map((pa) => {
          'id': pa.id,
          'org_id': pa.orgId,
          'customer_id': pa.customerId,
          'product_id': pa.productId,
          'is_present': pa.isPresent,
          'surveyed_by_user_id': pa.surveyedByUserId,
          'surveyed_at': pa.surveyedAt.toUtc().toIso8601String(),
          'created_at': pa.createdAt.toUtc().toIso8601String(),
        }).toList();
        await Supabase.instance.client
            .from('placement_audit')
            .insert(payload);
        final ids = pendingAudits.map((pa) => pa.id).toList();
        await (_db.update(_db.placementAudits)
              ..where((t) => t.id.isIn(ids)))
            .write(const PlacementAuditsCompanion(
                syncStatus: Value('synced')));
        state = state.copyWith(lastSyncedAt: DateTime.now());
        print('Pushed ${pendingAudits.length} placement_audit rows');
      } catch (e, st) {
        print('pushPlacementAudit batch FAILED: $e');
        await Sentry.captureException(e, stackTrace: st);
      }
    }
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncStatus>(SyncController.new);
