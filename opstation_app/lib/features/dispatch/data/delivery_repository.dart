import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/supabase/supabase_sync_service.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';
import '../models/delivery.dart';

/// Describes one stop when building or editing a delivery. The ID is
/// optional — repo generates one for new stops, reuses existing for
/// edits.
class DeliveryStopInput {
  final String? id;
  final String customerId;
  final String customerCode;
  final String customerName;
  final String itemDescription;
  final int amount;
  final PaymentType paymentType;

  const DeliveryStopInput({
    this.id,
    required this.customerId,
    required this.customerCode,
    required this.customerName,
    required this.itemDescription,
    required this.amount,
    required this.paymentType,
  });
}

class DeliveryRepository {
  final AppDatabase _db;
  final String? _orgId;
  final SupabaseSyncService? _sync;
  DeliveryRepository(this._db, {String? orgId, SupabaseSyncService? sync})
      : _orgId = orgId,
        _sync = sync;

  String _newDeliveryId() => _newId('del');
  String _newStopId() => _newId('stp');

  String _newId(String prefix) {
    final rng = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = rng.nextInt(1 << 32).toRadixString(36).padLeft(6, '0');
    return '${prefix}_${ts}_$rand';
  }

  /// Helper: pushes the current state of a delivery row to Supabase.
  /// Best-effort; local state is the source of truth so any push failure
  /// just gets retried by the periodic sync. Without this call, the
  /// driver's "complete delivery" / "cancel" / "auto-complete" flows
  /// updated only the local DB, leaving Supabase forever in the prior
  /// status — which then re-hydrated on the next login as still-active.
  Future<void> _pushDeliveryById(String id) async {
    final sync = _sync;
    if (sync == null) return;
    try {
      final row = await (_db.select(_db.deliveries)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row != null) await sync.pushDelivery(row);
    } catch (_) {}
  }

  Future<void> _pushDeliveryStopsForDelivery(String deliveryId) async {
    final sync = _sync;
    if (sync == null) return;
    try {
      final stops = await (_db.select(_db.deliveryStops)
            ..where((t) => t.deliveryId.equals(deliveryId)))
          .get();
      for (final s in stops) {
        await sync.pushDeliveryStop(s);
      }
    } catch (_) {}
  }

  // ---- Creation ---------------------------------------------------------

  /// Creates a new delivery in DRAFT status with the given stops.
  /// Driver can be null (unassigned). Returns the full hydrated delivery.
  Future<Delivery> createDraft({
    String? driverId,
    String? driverName,
    String? driverRole,
    required String createdBy,
    required String createdByName,
    required String createdByRole,
    String? notes,
    required List<DeliveryStopInput> stops,
  }) async {
    final id = _newDeliveryId();
    final now = DateTime.now();
    await _db.transaction(() async {
      await _db.into(_db.deliveries).insert(DeliveriesCompanion(
            id: Value(id),
            driverId: Value(driverId),
            driverName: Value(driverName),
            driverRole: Value(driverRole),
            createdBy: Value(createdBy),
            createdByName: Value(createdByName),
            createdByRole: Value(createdByRole),
            createdAt: Value(now),
            status: const Value('draft'),
            notes: Value(notes),
            orgId: Value(_orgId),
          ));
      for (int i = 0; i < stops.length; i++) {
        final s = stops[i];
        await _db.into(_db.deliveryStops).insert(DeliveryStopsCompanion(
              id: Value(s.id ?? _newStopId()),
              deliveryId: Value(id),
              customerId: Value(s.customerId),
              customerCode: Value(s.customerCode),
              customerName: Value(s.customerName),
              sequence: Value(i),
              itemDescription: Value(s.itemDescription),
              amount: Value(s.amount),
              paymentType: Value(s.paymentType.wire),
              status: const Value('pending'),
            ));
      }
    });
    await _pushDeliveryById(id);
    await _pushDeliveryStopsForDelivery(id);
    return (await byId(id))!;
  }

  // ---- Read -------------------------------------------------------------

  Future<Delivery?> byId(String id) async {
    final row = await (_db.select(_db.deliveries)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    final stops = await _stopsFor(id);
    return Delivery.fromRow(row, stops);
  }

  Future<List<DeliveryStop>> _stopsFor(String deliveryId) async {
    final rows = await (_db.select(_db.deliveryStops)
          ..where((t) => t.deliveryId.equals(deliveryId))
          ..orderBy([(t) => OrderingTerm.asc(t.sequence)]))
        .get();
    return [for (final r in rows) DeliveryStop.fromRow(r)];
  }

  /// Returns all deliveries matching the filters, newest first. Nulls
  /// mean "no filter."
  Future<List<Delivery>> list({
    Set<DeliveryStatus>? statuses,
    String? driverId,
    DateTime? from,
    DateTime? to,
  }) async {
    var q = _db.select(_db.deliveries)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (statuses != null && statuses.isNotEmpty) {
      q.where((t) => t.status.isIn(statuses.map((s) => s.wire).toList()));
    }
    if (driverId != null) q.where((t) => t.driverId.equals(driverId));
    if (from != null) q.where((t) => t.createdAt.isBiggerOrEqualValue(from));
    if (to != null) q.where((t) => t.createdAt.isSmallerThanValue(to));
    if (_orgId != null) {
      q.where((t) => t.orgId.isNull() | t.orgId.equals(_orgId!));
    }
    final rows = await q.get();
    final out = <Delivery>[];
    for (final r in rows) {
      out.add(Delivery.fromRow(r, await _stopsFor(r.id)));
    }
    return out;
  }

  // ---- Edit (drafts and assigned only) ---------------------------------

  /// Replaces the driver + notes + stops on an existing delivery.
  /// Stops are replaced in full (simpler than diffing). Only legal when
  /// the delivery is in draft or assigned status; once in_progress we
  /// freeze the shape.
  Future<Delivery> updateDelivery({
    required String id,
    String? driverId,
    String? driverName,
    String? driverRole,
    String? notes,
    required List<DeliveryStopInput> stops,
  }) async {
    final existing = await byId(id);
    if (existing == null) {
      throw StateError('Delivery $id not found');
    }
    if (existing.status != DeliveryStatus.draft &&
        existing.status != DeliveryStatus.assigned) {
      throw StateError(
          'Cannot edit a delivery in status ${existing.status.label}');
    }
    await _db.transaction(() async {
      await (_db.update(_db.deliveries)..where((t) => t.id.equals(id))).write(
        DeliveriesCompanion(
          driverId: Value(driverId),
          driverName: Value(driverName),
          driverRole: Value(driverRole),
          notes: Value(notes),
        ),
      );
      // Replace stops wholesale.
      await (_db.delete(_db.deliveryStops)
            ..where((t) => t.deliveryId.equals(id)))
          .go();
      for (int i = 0; i < stops.length; i++) {
        final s = stops[i];
        await _db.into(_db.deliveryStops).insert(DeliveryStopsCompanion(
              id: Value(s.id ?? _newStopId()),
              deliveryId: Value(id),
              customerId: Value(s.customerId),
              customerCode: Value(s.customerCode),
              customerName: Value(s.customerName),
              sequence: Value(i),
              itemDescription: Value(s.itemDescription),
              amount: Value(s.amount),
              paymentType: Value(s.paymentType.wire),
              status: const Value('pending'),
            ));
      }
    });
    await _pushDeliveryById(id);
    await _pushDeliveryStopsForDelivery(id);
    return (await byId(id))!;
  }

  // ---- Status transitions ----------------------------------------------

  /// Flips a draft to 'assigned'. Requires a driver to be set.
  Future<void> assign(String id) async {
    final existing = await byId(id);
    if (existing == null) return;
    if (existing.driverId == null) {
      throw StateError('Cannot assign: no driver set');
    }
    if (existing.status != DeliveryStatus.draft) {
      throw StateError(
          'Cannot assign: delivery is already ${existing.status.label}');
    }
    await (_db.update(_db.deliveries)..where((t) => t.id.equals(id))).write(
      const DeliveriesCompanion(status: Value('assigned')),
    );
    await _pushDeliveryById(id);
  }

  /// Reverts an assigned delivery back to draft (unassign / re-edit).
  Future<void> unassign(String id) async {
    final existing = await byId(id);
    if (existing == null) return;
    if (existing.status != DeliveryStatus.assigned) {
      throw StateError(
          'Cannot unassign: delivery is ${existing.status.label}');
    }
    await (_db.update(_db.deliveries)..where((t) => t.id.equals(id))).write(
      const DeliveriesCompanion(status: Value('draft')),
    );
    await _pushDeliveryById(id);
  }

  /// Cancels a delivery. Allowed from draft, assigned, or in_progress.
  /// Completed deliveries can't be cancelled.
  Future<void> cancel(String id) async {
    final existing = await byId(id);
    if (existing == null) return;
    if (existing.status == DeliveryStatus.completed) {
      throw StateError('Cannot cancel a completed delivery');
    }
    await (_db.update(_db.deliveries)..where((t) => t.id.equals(id))).write(
      DeliveriesCompanion(
        status: const Value('cancelled'),
        completedAt: Value(DateTime.now()),
      ),
    );
    await _pushDeliveryById(id);
  }

  /// Hard-delete a draft. Only permitted while in draft — assigned or
  /// later should be cancelled, not deleted, so the record persists for
  /// audit.
  Future<void> deleteDraft(String id) async {
    final existing = await byId(id);
    if (existing == null) return;
    if (existing.status != DeliveryStatus.draft) {
      throw StateError(
          'Only drafts can be deleted; this is ${existing.status.label}. Cancel it instead.');
    }
    await _db.transaction(() async {
      await (_db.delete(_db.deliveryStops)
            ..where((t) => t.deliveryId.equals(id)))
          .go();
      await (_db.delete(_db.deliveries)..where((t) => t.id.equals(id))).go();
    });
  }

  // ---- Driver-side execution (slice 6b) --------------------------------

  /// Flips an assigned delivery to `in_progress` and stamps `startedAt`.
  /// Throws if the delivery is not currently `assigned`, or if the
  /// driver already has another delivery in progress (business rule:
  /// one active delivery per driver).
  Future<void> startDelivery({
    required String id,
    required String driverId,
  }) async {
    final d = await byId(id);
    if (d == null) throw StateError('Delivery not found');
    if (d.driverId != driverId) {
      throw StateError('Not your delivery');
    }
    if (d.status != DeliveryStatus.assigned) {
      throw StateError(
          'Cannot start: delivery is ${d.status.label}');
    }
    // Enforce the single-active-delivery rule.
    final others = await list(
      statuses: {DeliveryStatus.inProgress},
      driverId: driverId,
    );
    if (others.isNotEmpty) {
      throw StateError(
          'You already have a delivery in progress. Complete it before starting another.');
    }
    await (_db.update(_db.deliveries)..where((t) => t.id.equals(id))).write(
      DeliveriesCompanion(
        status: const Value('in_progress'),
        startedAt: Value(DateTime.now()),
      ),
    );
    await _pushDeliveryById(id);
  }

  /// Marks a single stop as delivered. Auto-completes the parent
  /// delivery if every stop is now settled. Pass [cashReceived] to
  /// record the actual cash collected (may differ from dispatched
  /// amount); null for credit stops.
  Future<void> markStopDelivered({
    required String stopId,
    required int? cashReceived,
    double? lat,
    double? lng,
    int? distanceMeters,
    List<String> photoPaths = const [],
  }) async {
    final now = DateTime.now();
    final stopRow = await (_db.select(_db.deliveryStops)
          ..where((t) => t.id.equals(stopId)))
        .getSingleOrNull();
    if (stopRow == null) throw StateError('Stop not found');

    final verification = await _classifyVerification(
      lat: lat,
      lng: lng,
      distanceMeters: distanceMeters,
    );

    await _db.transaction(() async {
      await (_db.update(_db.deliveryStops)
            ..where((t) => t.id.equals(stopId)))
          .write(
        DeliveryStopsCompanion(
          status: const Value('delivered'),
          deliveredAt: Value(now),
          cashReceived: Value(cashReceived),
          capturedLat: Value(lat),
          capturedLng: Value(lng),
          distanceMeters: Value(distanceMeters),
          verification: Value(verification.wire),
          photoPathsJson: Value(jsonEncode(photoPaths)),
          failureReason: const Value(null),
        ),
      );
      await _maybeAutoComplete(stopRow.deliveryId);
    });
    // Push outside the transaction. We push the delivery row in case
    // _maybeAutoComplete flipped it to 'completed', and the stop row
    // because its status/verification/photo paths changed.
    await _pushDeliveryById(stopRow.deliveryId);
    await _pushDeliveryStopsForDelivery(stopRow.deliveryId);
  }

  /// Marks a single stop as failed with a reason.
  Future<void> markStopFailed({
    required String stopId,
    required String reason,
    double? lat,
    double? lng,
    int? distanceMeters,
    List<String> photoPaths = const [],
  }) async {
    final stopRow = await (_db.select(_db.deliveryStops)
          ..where((t) => t.id.equals(stopId)))
        .getSingleOrNull();
    if (stopRow == null) throw StateError('Stop not found');

    final verification = await _classifyVerification(
      lat: lat,
      lng: lng,
      distanceMeters: distanceMeters,
    );

    await _db.transaction(() async {
      await (_db.update(_db.deliveryStops)
            ..where((t) => t.id.equals(stopId)))
          .write(
        DeliveryStopsCompanion(
          status: const Value('failed'),
          failureReason: Value(reason),
          deliveredAt: Value(DateTime.now()),
          capturedLat: Value(lat),
          capturedLng: Value(lng),
          distanceMeters: Value(distanceMeters),
          verification: Value(verification.wire),
          photoPathsJson: Value(jsonEncode(photoPaths)),
          cashReceived: const Value(null),
        ),
      );
      await _maybeAutoComplete(stopRow.deliveryId);
    });
    await _pushDeliveryById(stopRow.deliveryId);
    await _pushDeliveryStopsForDelivery(stopRow.deliveryId);
  }

  /// Classifies the GPS capture at a stop against the org's geofence
  /// radius. Matches the salesperson visit-verification logic exactly
  /// so drivers and salespersons share the same semantic ("verified"
  /// means the same thing for both roles, which admin reports depend
  /// on).
  ///
  /// - verified    : GPS available AND distance <= geofence radius
  /// - outside     : GPS available AND distance > geofence radius
  /// - no_location : no GPS fix (permission denied, timeout) OR
  ///                 customer has no saved location (distance null)
  Future<DeliveryStopVerification> _classifyVerification({
    required double? lat,
    required double? lng,
    required int? distanceMeters,
  }) async {
    if (lat == null || lng == null || distanceMeters == null) {
      return DeliveryStopVerification.noLocation;
    }
    // Reads the same org.geofenceRadiusMeters config the admin settings
    // screen writes. Default 100m matches the default in OrgSettings.
    final raw = await _db.getConfig('org.geofenceRadiusMeters');
    final radius = int.tryParse(raw ?? '') ?? 100;
    return distanceMeters <= radius
        ? DeliveryStopVerification.verified
        : DeliveryStopVerification.outside;
  }

  /// If all stops for [deliveryId] are settled (delivered or failed)
  /// and the delivery is currently in_progress, auto-flip it to
  /// completed. Called inside the stop-update transactions.
  Future<void> _maybeAutoComplete(String deliveryId) async {
    final allStops = await (_db.select(_db.deliveryStops)
          ..where((t) => t.deliveryId.equals(deliveryId)))
        .get();
    final anyPending = allStops.any((s) => s.status == 'pending');
    if (anyPending) return;
    final deliv = await (_db.select(_db.deliveries)
          ..where((t) => t.id.equals(deliveryId)))
        .getSingleOrNull();
    if (deliv == null) return;
    if (deliv.status != 'in_progress') return;
    await (_db.update(_db.deliveries)
          ..where((t) => t.id.equals(deliveryId)))
        .write(
      DeliveriesCompanion(
        status: const Value('completed'),
        completedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Driver manually closes a delivery before every stop is settled.
  /// Any stops still `pending` get marked `failed` with reason
  /// 'Delivery closed early by driver'. The delivery flips to
  /// completed with `completedAt` stamped.
  Future<void> completeEarly({
    required String deliveryId,
  }) async {
    final d = await byId(deliveryId);
    if (d == null) throw StateError('Delivery not found');
    if (d.status != DeliveryStatus.inProgress) {
      throw StateError(
          'Cannot complete: delivery is ${d.status.label}');
    }
    final now = DateTime.now();
    await _db.transaction(() async {
      for (final s in d.stops) {
        if (s.status != DeliveryStopStatus.pending) continue;
        await (_db.update(_db.deliveryStops)
              ..where((t) => t.id.equals(s.id)))
            .write(
          DeliveryStopsCompanion(
            status: const Value('failed'),
            failureReason:
                const Value('Delivery closed early by driver'),
            deliveredAt: Value(now),
          ),
        );
      }
      await (_db.update(_db.deliveries)
            ..where((t) => t.id.equals(deliveryId)))
          .write(
        DeliveriesCompanion(
          status: const Value('completed'),
          completedAt: Value(now),
        ),
      );
    });
    // Push outside the transaction. Pushes the delivery row (now
    // completed) and each stop (some flipped to failed).
    await _pushDeliveryById(deliveryId);
    await _pushDeliveryStopsForDelivery(deliveryId);
  }

  /// Returns the one delivery currently in progress for [driverId], or
  /// null. Used by driver home to decide whether to nudge "resume"
  /// instead of "start" on other assigned deliveries.
  Future<Delivery?> activeForDriver(String driverId) async {
    final rows = await list(
      statuses: {DeliveryStatus.inProgress},
      driverId: driverId,
    );
    return rows.isEmpty ? null : rows.first;
  }
}

final deliveryRepositoryProvider = Provider<DeliveryRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final orgId = ref.watch(orgIdProvider);
  final sync = ref.watch(supabaseSyncServiceProvider);
  return DeliveryRepository(db, orgId: orgId, sync: sync);
});