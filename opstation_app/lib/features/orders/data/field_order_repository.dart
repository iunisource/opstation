import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';

/// A line being captured in the order modal (in-memory before save).
class OrderLineInput {
  final String productId;
  final String name;
  final String? uomId;
  final double qty;
  final double price;
  const OrderLineInput({
    required this.productId,
    required this.name,
    required this.uomId,
    required this.qty,
    required this.price,
  });
}

/// Offline-first field-order capture + local catalog reads.
///
/// Save path is single-path local-then-sync: write parent + items to Drift as
/// `pending`, then the caller kicks `flushPending()` — online it drains in
/// milliseconds, offline it waits for reconnect. Mirrors the visit/customer
/// pattern so orders ride the existing sync engine.
class FieldOrderRepository {
  final AppDatabase _db;
  final String? _orgId;
  FieldOrderRepository(this._db, {String? orgId}) : _orgId = orgId;

  // ---- Local catalog reads (for the live searches) ----------------------

  /// Active customers, optionally filtered by a query on shop name or code.
  Future<List<CustomersData>> searchCustomers(String query) async {
    final q = _db.select(_db.customers)..where((c) => c.isActive.equals(true));
    if (_orgId != null) {
      q.where((c) => c.orgId.isNull() | c.orgId.equals(_orgId!));
    }
    final rows = await q.get();
    final ql = query.trim().toLowerCase();
    final filtered = ql.isEmpty
        ? rows
        : rows
            .where((c) =>
                c.shopName.toLowerCase().contains(ql) ||
                (c.code.toLowerCase().contains(ql)))
            .toList();
    filtered.sort((a, b) => a.shopName.compareTo(b.shopName));
    return filtered;
  }

  /// Distinct brand names (product_sub_group) from active catalog products.
  Future<List<String>> searchBrands(String query) async {
    final q = _db.select(_db.catalogProducts)
      ..where((p) => p.isActive.equals(true));
    if (_orgId != null) q.where((p) => p.orgId.equals(_orgId!));
    final rows = await q.get();
    final ql = query.trim().toLowerCase();
    final brands = <String>{};
    for (final p in rows) {
      final b = p.productSubGroup;
      if (b == null || b.isEmpty) continue;
      if (ql.isEmpty || b.toLowerCase().contains(ql)) brands.add(b);
    }
    final out = brands.toList()..sort();
    return out;
  }

  /// Active products within a brand, filtered live on name + sku.
  Future<List<CatalogProductRow>> searchProducts({
    required String brand,
    required String query,
  }) async {
    final q = _db.select(_db.catalogProducts)
      ..where((p) =>
          p.isActive.equals(true) & p.productSubGroup.equals(brand));
    if (_orgId != null) q.where((p) => p.orgId.equals(_orgId!));
    final rows = await q.get();
    final ql = query.trim().toLowerCase();
    final filtered = ql.isEmpty
        ? rows
        : rows
            .where((p) =>
                p.name.toLowerCase().contains(ql) ||
                ((p.sku ?? '').toLowerCase().contains(ql)))
            .toList();
    filtered.sort((a, b) => a.name.compareTo(b.name));
    return filtered;
  }

  // ---- Save (single-path local-then-sync) -------------------------------

  /// Writes the order + items to local Drift as `pending`. Returns the order
  /// id. Caller kicks the sync afterwards. Uses the same id scheme as the
  /// online path (`fo_<micros>` / `foi_<micros>_<i>`) so pushed rows are
  /// indistinguishable from online-created ones.
  Future<String> createLocal({
    required String customerId,
    required String salespersonId,
    required List<OrderLineInput> lines,
    String? notes,
  }) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    final foId = 'fo_$now';
    await _db.transaction(() async {
      await _db.into(_db.fieldOrders).insert(FieldOrdersCompanion(
            id: Value(foId),
            orgId: Value(_orgId ?? ''),
            customerId: Value(customerId),
            salespersonId: Value(salespersonId),
            status: const Value('submitted'),
            notes: Value(notes),
            createdAt: Value(DateTime.now()),
            syncStatus: const Value('pending'),
          ));
      var i = 0;
      for (final l in lines) {
        await _db.into(_db.fieldOrderItems).insert(FieldOrderItemsCompanion(
              id: Value('foi_${now}_${i++}'),
              fieldOrderId: Value(foId),
              productId: Value(l.productId),
              uomId: Value(l.uomId),
              quantity: Value(l.qty),
              priceAtSubmit: Value(l.price),
              syncStatus: const Value('pending'),
            ));
      }
    });
    return foId;
  }
}

final fieldOrderRepositoryProvider = Provider<FieldOrderRepository>((ref) {
  final db = ref.watch(appDatabaseProvider);
  final orgId = ref.watch(orgIdProvider);
  return FieldOrderRepository(db, orgId: orgId);
});
