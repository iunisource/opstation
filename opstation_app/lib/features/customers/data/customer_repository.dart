import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/models/customer.dart';
import '../models/audit_entry.dart';

/// Context describing who made a change. Supplied by the controller from
/// the current auth session.
class AuditActor {
  final String id;
  final String name;
  final String role;

  const AuditActor({
    required this.id,
    required this.name,
    required this.role,
  });
}

class CustomerRepository {
  final AppDatabase _db;
  final String? _orgId;
  CustomerRepository(this._db, {String? orgId}) : _orgId = orgId;

  // ---- Reads -----------------------------------------------------------

  Future<List<Customer>> all({bool includeInactive = true}) async {
    final q = _db.select(_db.customers);
    if (!includeInactive) q.where((c) => c.isActive.equals(true));
    if (_orgId != null) {
      q.where((c) => c.orgId.isNull() | c.orgId.equals(_orgId!));
    }
    q.orderBy([(c) => OrderingTerm.asc(c.shopName)]);
    final rows = await q.get();
    return rows.map(_fromRow).toList();
  }

  Future<Customer?> byId(String id) async {
    final row = await (_db.select(_db.customers)..where((c) => c.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  Customer _fromRow(CustomersData r) {
    return Customer(
      id: r.id,
      code: r.code,
      shopName: r.shopName,
      contactPerson: r.contactPerson,
      phone: r.phone,
      address: r.address,
      category: r.category,
      group: r.groupName,
      latitude: r.latitude,
      longitude: r.longitude,
      isActive: r.isActive,
      updatedAt: r.updatedAt,
      ntnGst: r.ntnGst,
    );
  }

  // ---- Writes ----------------------------------------------------------

  Future<Customer> create(Customer c, AuditActor actor) async {
    final now = DateTime.now();
    final fresh = c.copyWith(updatedAt: now);
    await _db.into(_db.customers).insert(_toCompanion(fresh));
    await _writeAudit(
      entityType: 'customer',
      entityId: fresh.id,
      action: 'create',
      actor: actor,
      diff: {},
      summary: 'Created customer "${fresh.shopName}"',
    );
    return fresh;
  }

  Future<Customer> update(
    Customer updated,
    Customer previous,
    AuditActor actor,
  ) async {
    final now = DateTime.now();
    final fresh = updated.copyWith(updatedAt: now);
    await _db.update(_db.customers).replace(_toCompanion(fresh));

    final diff = _buildDiff(previous, fresh);
    if (diff.isNotEmpty) {
      await _writeAudit(
        entityType: 'customer',
        entityId: fresh.id,
        action: 'update',
        actor: actor,
        diff: diff,
        summary: _summariseDiff(diff),
      );
    }
    return fresh;
  }

  Future<void> setActive({
    required String id,
    required bool active,
    required AuditActor actor,
  }) async {
    final prev = await byId(id);
    if (prev == null) return;
    final now = DateTime.now();
    await (_db.update(_db.customers)..where((c) => c.id.equals(id))).write(
      CustomersCompanion(
        isActive: Value(active),
        updatedAt: Value(now),
        syncStatus: const Value('pending'),
      ),
    );
    await _writeAudit(
      entityType: 'customer',
      entityId: id,
      action: active ? 'activate' : 'deactivate',
      actor: actor,
      diff: {
        'isActive': {'old': prev.isActive, 'new': active},
      },
      summary: active ? 'Marked as active' : 'Marked as inactive',
    );
  }

  Future<Customer> setLocation({
    required String id,
    required double latitude,
    required double longitude,
    required AuditActor actor,
  }) async {
    final prev = await byId(id);
    if (prev == null) throw StateError('Customer not found.');
    final now = DateTime.now();
    final updated = prev.copyWith(
      latitude: latitude,
      longitude: longitude,
      updatedAt: now,
    );
    await _db.update(_db.customers).replace(_toCompanion(updated));
    await _writeAudit(
      entityType: 'customer',
      entityId: id,
      action: 'setLocation',
      actor: actor,
      diff: {
        'latitude': {'old': prev.latitude, 'new': latitude},
        'longitude': {'old': prev.longitude, 'new': longitude},
      },
      summary: prev.hasLocation
          ? 'Updated location'
          : 'Set location (${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)})',
    );
    return updated;
  }

  CustomersCompanion _toCompanion(Customer c) {
    return CustomersCompanion(
      id: Value(c.id),
      code: Value(c.code),
      shopName: Value(c.shopName),
      contactPerson: Value(c.contactPerson),
      phone: Value(c.phone),
      address: Value(c.address),
      category: Value(c.category),
      groupName: Value(c.group),
      latitude: Value(c.latitude),
      longitude: Value(c.longitude),
      isActive: Value(c.isActive),
      updatedAt: Value(c.updatedAt),
      ntnGst: Value(c.ntnGst),
      orgId: Value(_orgId),
      syncStatus: const Value('pending'),
    );
  }

  Map<String, Map<String, Object?>> _buildDiff(Customer o, Customer n) {
    final diff = <String, Map<String, Object?>>{};
    void cmp(String key, Object? oldV, Object? newV) {
      if (oldV != newV) diff[key] = {'old': oldV, 'new': newV};
    }

    cmp('code', o.code, n.code);
    cmp('shopName', o.shopName, n.shopName);
    cmp('contactPerson', o.contactPerson, n.contactPerson);
    cmp('phone', o.phone, n.phone);
    cmp('address', o.address, n.address);
    cmp('category', o.category, n.category);
    cmp('group', o.group, n.group);
    cmp('ntnGst', o.ntnGst, n.ntnGst);
    cmp('latitude', o.latitude, n.latitude);
    cmp('longitude', o.longitude, n.longitude);
    cmp('isActive', o.isActive, n.isActive);
    return diff;
  }

  String _summariseDiff(Map<String, Map<String, Object?>> diff) {
    if (diff.isEmpty) return 'No changes';
    final keys = diff.keys.toList();
    if (keys.length == 1) {
      return 'Changed ${_prettyField(keys.first)}';
    }
    return 'Changed ${keys.length} fields: ${keys.map(_prettyField).join(", ")}';
  }

  String _prettyField(String key) {
    switch (key) {
      case 'shopName':
        return 'shop name';
      case 'contactPerson':
        return 'contact person';
      case 'groupName':
      case 'group':
        return 'group';
      case 'latitude':
      case 'longitude':
        return 'location';
      case 'isActive':
        return 'status';
      case 'ntnGst':
        return 'NTN/GST';
      default:
        return key;
    }
  }

  // ---- Audit log reads -------------------------------------------------

  Future<List<AuditEntry>> recentForEntity(
    String entityType,
    String entityId, {
    int limit = 20,
  }) async {
    final rows = await (_db.select(_db.auditLogs)
          ..where((a) => a.entityType.equals(entityType) & a.entityId.equals(entityId))
          ..orderBy([(a) => OrderingTerm.desc(a.timestamp)])
          ..limit(limit))
        .get();
    return rows.map(_auditFromRow).toList();
  }

  AuditEntry _auditFromRow(AuditLogData r) {
    Map<String, Map<String, Object?>> diff = {};
    try {
      final decoded = jsonDecode(r.diffJson);
      if (decoded is Map) {
        diff = decoded.map((k, v) {
          if (v is Map) {
            return MapEntry(k.toString(), Map<String, Object?>.from(v));
          }
          return MapEntry(k.toString(), <String, Object?>{});
        });
      }
    } catch (_) {}
    return AuditEntry(
      id: r.id,
      entityType: r.entityType,
      entityId: r.entityId,
      action: r.action,
      actorId: r.actorId,
      actorName: r.actorName,
      actorRole: r.actorRole,
      timestamp: r.timestamp,
      diff: diff,
      summary: r.summary,
    );
  }

  // ---- Audit writes ----------------------------------------------------

  Future<void> _writeAudit({
    required String entityType,
    required String entityId,
    required String action,
    required AuditActor actor,
    required Map<String, Map<String, Object?>> diff,
    required String summary,
  }) async {
    final id = 'audit_${DateTime.now().microsecondsSinceEpoch}';
    await _db.into(_db.auditLogs).insert(
          AuditLogsCompanion.insert(
            id: id,
            entityType: entityType,
            entityId: entityId,
            action: action,
            actorId: actor.id,
            actorName: actor.name,
            actorRole: actor.role,
            timestamp: DateTime.now(),
            diffJson: Value(jsonEncode(diff)),
            summary: Value(summary),
          ),
        );
  }
}

final customerRepositoryProvider = Provider<CustomerRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final orgId = ref.watch(orgIdProvider);
  return CustomerRepository(db, orgId: orgId);
});
