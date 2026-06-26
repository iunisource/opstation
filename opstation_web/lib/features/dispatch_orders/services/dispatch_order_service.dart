import 'package:supabase_flutter/supabase_flutter.dart';
import '../../orders/models/order.dart';

class DispatchOrderService {
  final SupabaseClient _client;
  DispatchOrderService(this._client);

  Future<List<Order>> listOrdersForDispatch({
    required String orgId,
    String? status,
    String? driverId,
    DateTime? from,
    DateTime? to,
  }) async {
    var query = _client.from('orders').select('*').eq('org_id', orgId);
    if (status != null) {
      query = query.eq('status', status);
    } else {
      query = query.inFilter('status', ['approved', 'dispatched', 'on_hold']);
    }
    if (driverId != null) query = query.eq('driver_id', driverId);
    if (from != null) query = query.gte('created_at', from.toIso8601String());
    if (to != null) query = query.lte('created_at', to.toIso8601String());
    final rows = await query.order('created_at', ascending: false);
    return (rows as List)
        .map((r) => Order.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> listDrivers(String orgId) async {
    final rows = await _client
        .from('users')
        .select('id, name, role')
        .eq('org_id', orgId)
        .eq('role', 'driver')
        .eq('is_active', true)
        .order('name');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Assigns one or more orders to a single driver as one multi-stop delivery.
  /// Optional override maps (orderId → value) override what's currently on
  /// the order and are also persisted onto the order row.
  Future<void> assignOrdersToDriver({
    required List<Order> orders,
    required String driverId,
    required String driverName,
    required String currentUserId,
    required String currentUserName,
    required String orgId,
    Map<String, String?>? driverNoteOverrides,
    Map<String, String?>? soInvoiceOverrides,
  }) async {
    if (orders.isEmpty) return;
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;
    final hex = ts.toRadixString(16);
    final deliveryId = 'delivery_${ts}_$hex';

    await _client.from('deliveries').insert({
      'id': deliveryId,
      'driver_id': driverId,
      'driver_name': driverName,
      'driver_role': 'driver',
      'created_by': currentUserId,
      'created_by_name': currentUserName,
      'created_by_role': 'dispatchManager',
      'created_at': now.toIso8601String(),
      'status': 'assigned',
      'org_id': orgId,
      'order_id': orders.length == 1 ? orders.first.id : null,
    });

    final stopRows = <Map<String, dynamic>>[];
    for (var i = 0; i < orders.length; i++) {
      final o = orders[i];
      final dn = (driverNoteOverrides != null &&
              driverNoteOverrides.containsKey(o.id))
          ? driverNoteOverrides[o.id]
          : o.driverNote;
      final so = (soInvoiceOverrides != null &&
              soInvoiceOverrides.containsKey(o.id))
          ? soInvoiceOverrides[o.id]
          : o.soInvoiceNumber;
      stopRows.add({
        'id': 'stop_${ts}_${i}_$hex',
        'delivery_id': deliveryId,
        'customer_id': o.customerId,
        'customer_name': o.customerName ?? '',
        'customer_code': o.customerCode ?? '',
        'sequence': i + 1,
        'item_description': '',
        'amount': o.amount,
        'payment_type': o.paymentType,
        'status': 'pending',
        'verification': 'none',
        'photo_paths_json': '[]',
        'order_id': o.id,
        'driver_note':
            (dn == null || dn.trim().isEmpty) ? null : dn.trim(),
        'so_invoice_number':
            (so == null || so.trim().isEmpty) ? null : so.trim(),
      });
    }
    await _client.from('delivery_stops').insert(stopRows);

    for (final o in orders) {
      final payload = <String, dynamic>{
        'status': 'dispatched',
        'dispatched_at': now.toIso8601String(),
        'dispatched_by': currentUserId,
        'driver_id': driverId,
        'driver_name': driverName,
        'delivery_id': deliveryId,
        'updated_at': now.toIso8601String(),
      };
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        payload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        payload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      await _client.from('orders').update(payload).eq('id', o.id);
    }

    // Fire-and-forget FCM notification to the driver. Don't fail the
    // assignment if the edge function errors.
    try {
      final firstName = orders.first.customerName ?? 'a stop';
      final body = orders.length == 1
          ? 'New delivery for $firstName'
          : '${orders.length} stops assigned';
      // ignore: avoid_print
      print('FCM: invoking send-notification for driver $driverId');
      await _client.functions.invoke('send-notification', body: {
        'userId': driverId,
        'title': 'New delivery assigned',
        'body': body,
        'data': {
          'type': 'delivery_assigned',
          'delivery_id': deliveryId,
        },
      });
    } catch (e, st) {
      // notification failures shouldn't break dispatch, but log them
      // so we can see what's happening during debugging.
      // ignore: avoid_print
      print('FCM notify failed: $e\n$st');
    }
  }

  Future<void> updateStatus({
    required String orderId,
    required String newStatus,
    required String note,
  }) async {
    await _client.from('orders').update({
      'status': newStatus,
      'status_note': note,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', orderId);
  }

  /// Fetch all orders attached to a given delivery via `orders.delivery_id`.
  Future<List<Order>> listOrdersInDelivery(String deliveryId) async {
    final rows = await _client
        .from('orders')
        .select('*')
        .eq('delivery_id', deliveryId)
        .order('created_at');
    return (rows as List)
        .map((row) => Order.fromRow(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  /// Update an existing delivery's per-order driver_note and so_invoice_number,
  /// and optionally reassign the driver. Does NOT change order status. Writes
  /// to both `orders` and the matching `delivery_stops` rows so the driver
  /// app sees the changes on next sync.
  Future<void> updateExistingDelivery({
    required String deliveryId,
    required List<Order> orders,
    String? newDriverId,
    String? newDriverName,
    Map<String, String?>? driverNoteOverrides,
    Map<String, String?>? soInvoiceOverrides,
  }) async {
    final now = DateTime.now().toIso8601String();
    final driverChanged = newDriverId != null && newDriverName != null;

    if (driverChanged) {
      await _client.from('deliveries').update({
        'driver_id': newDriverId,
        'driver_name': newDriverName,
      }).eq('id', deliveryId);
    }

    for (final o in orders) {
      final payload = <String, dynamic>{'updated_at': now};
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        payload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        payload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (driverChanged) {
        payload['driver_id'] = newDriverId;
        payload['driver_name'] = newDriverName;
      }
      if (payload.length > 1) {
        await _client.from('orders').update(payload).eq('id', o.id);
      }

      // Mirror note/SO onto the delivery_stop. lock_delivered_stops trigger
      // blocks updates on already-delivered stops, which is exactly what
      // we want — those rows are immutable.
      final stopPayload = <String, dynamic>{};
      if (driverNoteOverrides != null &&
          driverNoteOverrides.containsKey(o.id)) {
        final v = driverNoteOverrides[o.id];
        stopPayload['driver_note'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (soInvoiceOverrides != null &&
          soInvoiceOverrides.containsKey(o.id)) {
        final v = soInvoiceOverrides[o.id];
        stopPayload['so_invoice_number'] =
            (v == null || v.trim().isEmpty) ? null : v.trim();
      }
      if (stopPayload.isNotEmpty) {
        try {
          await _client
              .from('delivery_stops')
              .update(stopPayload)
              .eq('delivery_id', deliveryId)
              .eq('order_id', o.id);
        } catch (_) {
          // Stop may be locked (already delivered). Skip silently.
        }
        // DO-based stops carry do_id (order_id is null), so mirror there too.
        try {
          await _client
              .from('delivery_stops')
              .update(stopPayload)
              .eq('delivery_id', deliveryId)
              .eq('do_id', o.id);
        } catch (_) {}
      }
    }

    if (driverChanged) {
      try {
        final body = orders.length == 1
            ? 'Delivery for ${orders.first.customerName ?? "a stop"}'
            : '${orders.length} stops assigned';
        await _client.functions.invoke('send-notification', body: {
          'userId': newDriverId,
          'title': 'Delivery reassigned to you',
          'body': body,
          'data': {
            'type': 'delivery_assigned',
            'delivery_id': deliveryId,
          },
        });
      } catch (e, st) {
        // ignore: avoid_print
        print('FCM reassign notify failed: $e\n$st');
      }
    }
  }

  /// Manually mark a delivery as fully delivered. For third-party drivers
  /// who don't run the mobile app — the dispatch manager confirms delivery
  /// verbally / via paperwork and flips the records.
  ///
  /// Flips each non-delivered `delivery_stops.status` to 'delivered'. The
  /// `delivery_stop_to_order_sync` trigger cascades that to `orders.status`
  /// automatically. Then marks the delivery itself completed.
  Future<void> markDeliveryAsDelivered({
    required String deliveryId,
  }) async {
    final now = DateTime.now().toIso8601String();

    await _client
        .from('delivery_stops')
        .update({'status': 'delivered', 'delivered_at': now})
        .eq('delivery_id', deliveryId)
        .neq('status', 'delivered');

    await _client.from('deliveries').update({
      'status': 'completed',
      'completed_at': now,
    }).eq('id', deliveryId);
  }

  // ===================================================================
  // STAGE 2 — DO-based dispatch (replaces the obsolete `orders` pool).
  // The dispatch pool is approved Delivery Orders that haven't yet been
  // assigned to a driver. A DO is "taken" once its id appears as `do_id`
  // on a delivery_stop whose delivery is not cancelled.
  // ===================================================================

  /// Lists Delivery Orders for the dispatch board, mapped into the web
  /// `Order` model. Returns the full lifecycle so the status filter works:
  ///   • approved  = pool (not yet assigned)
  ///   • dispatched = assigned to a driver, in progress
  ///   • delivered = delivered (DO marked delivered, or its stop delivered)
  /// A DO's assignment/driver come from the delivery_stop carrying its do_id
  /// (on a non-cancelled delivery).
  Future<List<Order>> listDeliveryOrdersForDispatch({
    required String orgId,
    String? branchId,
    DateTime? from,
    DateTime? to,
  }) async {
    // 1) Candidate DOs: dispatchable or delivered, not voided, org/branch scoped.
    var q = _client.from('delivery_orders')
        .select('id, voucher_number, customer_id, collect_amount, status, '
            'branch_id, is_voided, created_at, '
            'customers(shop_name, code), sales_orders(voucher_number)')
        .eq('org_id', orgId)
        .inFilter('status',
            const ['saved', 'invoiced', 'partially_delivered', 'delivered']);
    if (branchId != null) q = q.eq('branch_id', branchId);
    if (from != null) q = q.gte('created_at', from.toIso8601String());
    if (to != null) q = q.lte('created_at', to.toIso8601String());
    final dos = await q.order('created_at', ascending: false);

    // 2) Assignment map: do_id -> {delivery, driver, stop status}.
    final assign = <String, Map<String, dynamic>>{};
    try {
      final taken = await _client
          .from('delivery_stops')
          .select('do_id, status, delivery_id, '
              'deliveries(id, driver_id, driver_name, status)')
          .not('do_id', 'is', null);
      for (final s in taken as List) {
        final delStatus = (s['deliveries']?['status']) as String?;
        if (delStatus == 'cancelled') continue;
        final id = s['do_id'] as String?;
        if (id != null) assign[id] = Map<String, dynamic>.from(s as Map);
      }
    } catch (_) {}

    // 3) Map DOs into the Order model with the right lifecycle status.
    final result = <Order>[];
    for (final d in dos as List) {
      final id = d['id'] as String?;
      if (id == null) continue;
      if ((d['is_voided'] as bool?) == true) continue;
      final custId = d['customer_id'] as String?;
      if (custId == null) continue;
      final collect = (d['collect_amount'] as num?);
      final doDelivered = (d['status'] as String?) == 'delivered';

      OrderStatus st;
      String? driverId, driverName, deliveryId;
      final a = assign[id];
      if (a != null) {
        deliveryId = a['delivery_id'] as String?;
        driverId = a['deliveries']?['driver_id'] as String?;
        driverName = a['deliveries']?['driver_name'] as String?;
        final stopDelivered = (a['status'] as String?) == 'delivered';
        st = (stopDelivered || doDelivered)
            ? OrderStatus.delivered
            : OrderStatus.dispatched;
      } else {
        st = doDelivered ? OrderStatus.delivered : OrderStatus.approved;
      }

      result.add(Order(
        id: id,
        orgId: orgId,
        customerId: custId,
        customerName: d['customers']?['shop_name'] as String?,
        customerCode: d['customers']?['code'] as String?,
        status: st,
        driverId: driverId,
        driverName: driverName,
        deliveryId: deliveryId,
        // DO voucher is the dispatch reference shown to the driver.
        soInvoiceNumber: d['voucher_number'] as String?,
        createdAt: DateTime.parse(d['created_at'] as String).toLocal(),
        updatedAt: DateTime.parse(d['created_at'] as String).toLocal(),
        // collect_amount drives cash-collection; null/0 = non-collection (credit).
        paymentType: (collect ?? 0) > 0 ? 'cash' : 'credit',
        amount: (collect ?? 0).round(),
      ));
    }
    return result;
  }

  /// Assigns Delivery Orders to a driver as one multi-stop delivery. Mirrors
  /// assignOrdersToDriver but writes `do_id` on each stop (order_id stays
  /// null) and does NOT write back to the obsolete `orders` table. The DO's
  /// own accounting was already done at approval; pool-exit is tracked by the
  /// do_id on the stop.
  Future<void> assignDeliveryOrdersToDriver({
    required List<Order> orders,
    required String driverId,
    required String driverName,
    required String currentUserId,
    required String currentUserName,
    required String orgId,
    Map<String, String?>? driverNoteOverrides,
    Map<String, String?>? soInvoiceOverrides,
  }) async {
    if (orders.isEmpty) return;
    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;
    final hex = ts.toRadixString(16);
    final deliveryId = 'delivery_${ts}_$hex';

    await _client.from('deliveries').insert({
      'id': deliveryId,
      'driver_id': driverId,
      'driver_name': driverName,
      'driver_role': 'driver',
      'created_by': currentUserId,
      'created_by_name': currentUserName,
      'created_by_role': 'dispatchManager',
      'created_at': now.toIso8601String(),
      'status': 'assigned',
      'org_id': orgId,
      'order_id': null,
    });

    final stopRows = <Map<String, dynamic>>[];
    for (var i = 0; i < orders.length; i++) {
      final o = orders[i];
      final dn = (driverNoteOverrides != null && driverNoteOverrides.containsKey(o.id))
          ? driverNoteOverrides[o.id]
          : o.driverNote;
      final so = (soInvoiceOverrides != null && soInvoiceOverrides.containsKey(o.id))
          ? soInvoiceOverrides[o.id]
          : o.soInvoiceNumber;
      stopRows.add({
        'id': 'stop_${ts}_${i}_$hex',
        'delivery_id': deliveryId,
        'customer_id': o.customerId,
        'customer_name': o.customerName ?? '',
        'customer_code': o.customerCode ?? '',
        'sequence': i + 1,
        'item_description': '',
        'amount': o.amount,
        'payment_type': o.paymentType,
        'status': 'pending',
        'verification': 'none',
        'photo_paths_json': '[]',
        'do_id': o.id,
        'order_id': null,
        'driver_note': (dn == null || dn.trim().isEmpty) ? null : dn.trim(),
        'so_invoice_number': (so == null || so.trim().isEmpty) ? null : so.trim(),
      });
    }
    await _client.from('delivery_stops').insert(stopRows);

    // Fire-and-forget FCM notification to the driver.
    try {
      final firstName = orders.first.customerName ?? 'a stop';
      final body = orders.length == 1
          ? 'New delivery for $firstName'
          : '${orders.length} stops assigned';
      await _client.functions.invoke('send-notification', body: {
        'userId': driverId,
        'title': 'New delivery assigned',
        'body': body,
        'data': {'type': 'delivery_assigned', 'delivery_id': deliveryId},
      });
    } catch (_) {}
  }

  /// DO-based counterpart of listOrdersInDelivery: reads the delivery's stops
  /// (those carrying a do_id) and maps them back into Order objects so the
  /// edit/mark-delivered modal works for DO deliveries.
  Future<List<Order>> listDeliveryOrdersInDelivery(String deliveryId) async {
    final stops = await _client
        .from('delivery_stops')
        .select('do_id, customer_id, customer_name, customer_code, amount, '
            'payment_type, status, driver_note, so_invoice_number')
        .eq('delivery_id', deliveryId)
        .not('do_id', 'is', null)
        .order('sequence');
    final result = <Order>[];
    for (final s in stops as List) {
      final doId = s['do_id'] as String?;
      final custId = s['customer_id'] as String?;
      if (doId == null || custId == null) continue;
      result.add(Order(
        id: doId,
        orgId: '',
        customerId: custId,
        customerName: s['customer_name'] as String?,
        customerCode: s['customer_code'] as String?,
        status: (s['status'] as String?) == 'delivered'
            ? OrderStatus.delivered
            : OrderStatus.dispatched,
        deliveryId: deliveryId,
        driverNote: s['driver_note'] as String?,
        soInvoiceNumber: s['so_invoice_number'] as String?,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        paymentType: s['payment_type'] as String? ?? 'cash',
        amount: (s['amount'] as num?)?.round() ?? 0,
      ));
    }
    return result;
  }
}
