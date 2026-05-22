import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/models/auth_user.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/sales_route.dart';
import '../../team/models/team_user.dart';
import '../models/audit_log_entry.dart';

/// Data access for audit_logs. Writes are insert-only; reads support
/// filtering by entity/actor/date range.
class AuditRepository {
  final AppDatabase _db;
  final String? _orgId;
  AuditRepository(this._db, {String? orgId}) : _orgId = orgId;

  Future<void> insert(AuditLogEntry e) async {
    await _db.into(_db.auditLogs).insert(
          AuditLogsCompanion(
            id: Value(e.id),
            entityType: Value(e.entityType),
            entityId: Value(e.entityId),
            action: Value(e.action),
            actorId: Value(e.actorId),
            actorName: Value(e.actorName),
            actorRole: Value(e.actorRole),
            timestamp: Value(e.timestamp),
            diffJson: Value(e.diffJson),
            summary: Value(e.summary),
            orgId: Value(_orgId),
          ),
        );
  }

  Future<List<AuditLogEntry>> query({
    DateTime? from,
    DateTime? to,
    String? entityType,
    String? actorId,
  }) async {
    final q = _db.select(_db.auditLogs);
    if (from != null) q.where((t) => t.timestamp.isBiggerOrEqualValue(from));
    if (to != null) q.where((t) => t.timestamp.isSmallerOrEqualValue(to));
    if (entityType != null && entityType.isNotEmpty) {
      q.where((t) => t.entityType.equals(entityType));
    }
    if (actorId != null && actorId.isNotEmpty) {
      q.where((t) => t.actorId.equals(actorId));
    }
    if (_orgId != null) {
      q.where((t) => t.orgId.isNull() | t.orgId.equals(_orgId!));
    }
    q.orderBy([(t) => OrderingTerm.desc(t.timestamp)]);
    final rows = await q.get();
    return [
      for (final r in rows)
        AuditLogEntry(
          id: r.id,
          entityType: r.entityType,
          entityId: r.entityId,
          action: r.action,
          actorId: r.actorId,
          actorName: r.actorName,
          actorRole: r.actorRole,
          timestamp: r.timestamp,
          diffJson: r.diffJson,
          summary: r.summary,
        ),
    ];
  }
}

final auditRepositoryProvider = Provider<AuditRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final orgId = ref.watch(orgIdProvider);
  return AuditRepository(db, orgId: orgId);
});

/// High-level logger — call from CRUD callsites. Never throws; logging
/// failures are swallowed so they can't break user flows.
class AuditLogger {
  final Ref _ref;
  AuditLogger(this._ref);

  AuditRepository get _repo => _ref.read(auditRepositoryProvider);

  AuthUser? get _actor => _ref.read(authControllerProvider).valueOrNull;

  String _id() {
    final rng = Random();
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = rng.nextInt(1 << 32).toRadixString(36).padLeft(6, '0');
    return 'audit_${ts}_$rand';
  }

  Future<void> _write({
    required String entityType,
    required String entityId,
    required String action,
    required String summary,
    Map<String, Object?>? diff,
  }) async {
    final actor = _actor;
    try {
      await _repo.insert(AuditLogEntry(
        id: _id(),
        entityType: entityType,
        entityId: entityId,
        action: action,
        actorId: actor?.id ?? '',
        actorName: actor?.name ?? 'System',
        actorRole: actor?.role.name ?? '',
        timestamp: DateTime.now(),
        diffJson: jsonEncode(diff ?? const {}),
        summary: summary,
      ));
    } catch (_) {
      // Swallow — audit must never block a CRUD flow.
    }
  }

  // ---- Customer events ------------------------------------------------

  Future<void> customerCreated(Customer c) => _write(
        entityType: 'customer',
        entityId: c.id,
        action: 'create',
        summary: 'Created customer ${c.shopName}',
        diff: {
          'code': {'new': c.code},
          'shopName': {'new': c.shopName},
          'phone': {'new': c.phone},
        },
      );

  Future<void> customerUpdated(Customer before, Customer after) {
    final diff = <String, Object?>{};
    void comp(String k, Object? a, Object? b) {
      if (a != b) diff[k] = {'old': a, 'new': b};
    }

    comp('shopName', before.shopName, after.shopName);
    comp('address', before.address, after.address);
    comp('phone', before.phone, after.phone);
    comp('category', before.category, after.category);
    comp('group', before.group, after.group);
    comp('code', before.code, after.code);
    comp('latitude', before.latitude, after.latitude);
    comp('longitude', before.longitude, after.longitude);

    return _write(
      entityType: 'customer',
      entityId: after.id,
      action: 'update',
      summary: 'Updated customer ${after.shopName}',
      diff: diff,
    );
  }

  Future<void> customerDeleted(Customer c) => _write(
        entityType: 'customer',
        entityId: c.id,
        action: 'delete',
        summary: 'Deleted customer ${c.shopName}',
      );

  Future<void> customerLocationSet(Customer c, double lat, double lng) =>
      _write(
        entityType: 'customer',
        entityId: c.id,
        action: 'setLocation',
        summary: 'Set location for ${c.shopName}',
        diff: {
          'lat': {'new': lat},
          'lng': {'new': lng},
        },
      );

  // ---- Route events ---------------------------------------------------

  Future<void> routeCreated(SalesRoute r) => _write(
        entityType: 'route',
        entityId: r.id,
        action: 'create',
        summary: 'Created route ${r.name}',
        diff: {
          'name': {'new': r.name},
          'kind': {'new': r.kind.name},
          'stopCount': {'new': r.stops.length},
        },
      );

  Future<void> routeUpdated(SalesRoute before, SalesRoute after) {
    final diff = <String, Object?>{};
    if (before.name != after.name) {
      diff['name'] = {'old': before.name, 'new': after.name};
    }
    if (before.kind != after.kind) {
      diff['kind'] = {'old': before.kind.name, 'new': after.kind.name};
    }
    if (before.stops.length != after.stops.length) {
      diff['stopCount'] = {
        'old': before.stops.length,
        'new': after.stops.length,
      };
    }
    return _write(
      entityType: 'route',
      entityId: after.id,
      action: 'update',
      summary: 'Updated route ${after.name}',
      diff: diff,
    );
  }

  Future<void> routeDeleted(SalesRoute r) => _write(
        entityType: 'route',
        entityId: r.id,
        action: 'delete',
        summary: 'Deleted route ${r.name}',
      );

  // ---- Assignment events ----------------------------------------------

  Future<void> assignmentChanged({
    required String userId,
    required String userName,
    required Set<String> before,
    required Set<String> after,
    required Map<String, String> routeNamesById,
  }) async {
    final added = after.difference(before);
    final removed = before.difference(after);
    if (added.isEmpty && removed.isEmpty) return;
    final addedNames = added.map((id) => routeNamesById[id] ?? id).join(', ');
    final removedNames =
        removed.map((id) => routeNamesById[id] ?? id).join(', ');
    final parts = <String>[];
    if (added.isNotEmpty) parts.add('+ $addedNames');
    if (removed.isNotEmpty) parts.add('- $removedNames');
    await _write(
      entityType: 'assignment',
      entityId: userId,
      action: added.isNotEmpty && removed.isEmpty
          ? 'assign'
          : (removed.isNotEmpty && added.isEmpty ? 'unassign' : 'update'),
      summary: 'Assignments for $userName: ${parts.join('  ')}',
      diff: {
        'added': added.toList(),
        'removed': removed.toList(),
      },
    );
  }

  // ---- User events ----------------------------------------------------

  Future<void> userCreated(TeamUser u) => _write(
        entityType: 'user',
        entityId: u.id,
        action: 'create',
        summary: 'Created user ${u.name} (${u.role.name})',
        diff: {
          'name': {'new': u.name},
          'email': {'new': u.email},
          'role': {'new': u.role.name},
          'active': {'new': u.isActive},
        },
      );

  Future<void> userUpdated(TeamUser before, TeamUser after) {
    final diff = <String, Object?>{};
    if (before.name != after.name) {
      diff['name'] = {'old': before.name, 'new': after.name};
    }
    if (before.email != after.email) {
      diff['email'] = {'old': before.email, 'new': after.email};
    }
    if (before.phone != after.phone) {
      diff['phone'] = {'old': before.phone, 'new': after.phone};
    }
    if (before.role != after.role) {
      diff['role'] = {'old': before.role.name, 'new': after.role.name};
    }
    if (before.isActive != after.isActive) {
      diff['active'] = {'old': before.isActive, 'new': after.isActive};
    }
    return _write(
      entityType: 'user',
      entityId: after.id,
      action: 'update',
      summary: 'Updated user ${after.name}',
      diff: diff,
    );
  }

  // ---- Delivery events ------------------------------------------------

  /// Called right after a draft delivery is created. Stops list is
  /// flattened into a readable diff.
  Future<void> deliveryCreated({
    required String deliveryId,
    required int stopCount,
    required int totalAmount,
    String? driverName,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'create',
        summary: driverName == null
            ? 'Created delivery ($stopCount stops, Rs $totalAmount)'
            : 'Created delivery for $driverName ($stopCount stops, Rs $totalAmount)',
        diff: {
          'stops': {'new': stopCount},
          'amount': {'new': totalAmount},
          if (driverName != null) 'driver': {'new': driverName},
        },
      );

  Future<void> deliveryAssigned({
    required String deliveryId,
    required String driverName,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'assign',
        summary: 'Assigned delivery to $driverName',
        diff: {
          'driver': {'new': driverName},
          'status': {'old': 'draft', 'new': 'assigned'},
        },
      );

  Future<void> deliveryUnassigned({
    required String deliveryId,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'unassign',
        summary: 'Reverted delivery to draft',
        diff: {
          'status': {'old': 'assigned', 'new': 'draft'},
        },
      );

  Future<void> deliveryUpdated({
    required String deliveryId,
    required int stopCount,
    required int totalAmount,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'update',
        summary: 'Updated delivery ($stopCount stops, Rs $totalAmount)',
        diff: {
          'stops': {'new': stopCount},
          'amount': {'new': totalAmount},
        },
      );

  Future<void> deliveryCancelled({
    required String deliveryId,
    required String previousStatus,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'delete',
        summary: 'Cancelled delivery',
        diff: {
          'status': {'old': previousStatus, 'new': 'cancelled'},
        },
      );

  Future<void> deliveryDraftDeleted({required String deliveryId}) => _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'delete',
        summary: 'Deleted draft delivery',
        diff: const {},
      );

  Future<void> deliveryStarted({
    required String deliveryId,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'update',
        summary: 'Started delivery',
        diff: {
          'status': {'old': 'assigned', 'new': 'in_progress'},
        },
      );

  Future<void> stopDelivered({
    required String deliveryId,
    required String stopId,
    required String customerName,
    required int? cashReceived,
  }) =>
      _write(
        entityType: 'delivery_stop',
        entityId: stopId,
        action: 'update',
        summary: cashReceived == null
            ? 'Delivered to $customerName'
            : 'Delivered to $customerName (Rs $cashReceived)',
        diff: {
          'deliveryId': {'new': deliveryId},
          'status': {'old': 'pending', 'new': 'delivered'},
          if (cashReceived != null) 'cashReceived': {'new': cashReceived},
        },
      );

  Future<void> stopFailed({
    required String deliveryId,
    required String stopId,
    required String customerName,
    required String reason,
  }) =>
      _write(
        entityType: 'delivery_stop',
        entityId: stopId,
        action: 'update',
        summary: 'Failed at $customerName: $reason',
        diff: {
          'deliveryId': {'new': deliveryId},
          'status': {'old': 'pending', 'new': 'failed'},
          'reason': {'new': reason},
        },
      );

  Future<void> deliveryCompleted({
    required String deliveryId,
    required bool early,
  }) =>
      _write(
        entityType: 'delivery',
        entityId: deliveryId,
        action: 'update',
        summary:
            early ? 'Completed delivery early' : 'Completed delivery',
        diff: {
          'status': {'old': 'in_progress', 'new': 'completed'},
          if (early) 'closedEarly': {'new': true},
        },
      );
}

final auditLoggerProvider = Provider<AuditLogger>((ref) => AuditLogger(ref));
