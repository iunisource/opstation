import 'dart:convert';

enum OrderStatus {
  inReview, approved, declined, dispatched, onHold, cancelled, delivered,
}

extension OrderStatusX on OrderStatus {
  String get key {
    switch (this) {
      case OrderStatus.inReview: return 'in_review';
      case OrderStatus.approved: return 'approved';
      case OrderStatus.declined: return 'declined';
      case OrderStatus.dispatched: return 'dispatched';
      case OrderStatus.onHold: return 'on_hold';
      case OrderStatus.cancelled: return 'cancelled';
      case OrderStatus.delivered: return 'delivered';
    }
  }

  String get label {
    switch (this) {
      case OrderStatus.inReview: return 'In review';
      case OrderStatus.approved: return 'Approved';
      case OrderStatus.declined: return 'Declined';
      case OrderStatus.dispatched: return 'Dispatched';
      case OrderStatus.onHold: return 'On hold';
      case OrderStatus.cancelled: return 'Cancelled';
      case OrderStatus.delivered: return 'Delivered';
    }
  }

  /// Status is terminal/locked for the accountant.
  bool get accountantLocked =>
      this == OrderStatus.dispatched || this == OrderStatus.delivered;

  /// Status transition requires a reason (note).
  bool get requiresNote =>
      this == OrderStatus.declined ||
      this == OrderStatus.onHold ||
      this == OrderStatus.cancelled;

  static OrderStatus? fromKey(String? k) {
    if (k == null) return null;
    for (final s in OrderStatus.values) {
      if (s.key == k) return s;
    }
    return null;
  }
}

class Order {
  final String id;
  final String orgId;
  final String customerId;
  final String? customerName;
  final String? customerCode;
  final String? salespersonId;
  final String? salespersonName;
  final String? notes;
  final List<String> photoPaths;
  final OrderStatus status;
  final String? statusNote;
  final String? driverId;
  final String? driverName;
  final String? deliveryId;
  final String? driverNote;
  final String? soInvoiceNumber;
  final DateTime? approvedAt;
  final String? approvedBy;
  final DateTime? dispatchedAt;
  final String? dispatchedBy;
  final DateTime? deliveredAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  /// 'cash' or 'credit'. Set by the accountant at approval time; copied
  /// onto the resulting delivery_stop at dispatch. Default 'cash' is a
  /// safety net for pre-feature rows — new orders force a choice.
  final String paymentType;
  /// PKR amount the driver should collect from the customer. Relevant
  /// for cash orders; 0 for credit (recorded as owed on the stop instead).
  final int amount;

  Order({
    required this.id,
    required this.orgId,
    required this.customerId,
    this.customerName,
    this.customerCode,
    this.salespersonId,
    this.salespersonName,
    this.notes,
    this.photoPaths = const [],
    required this.status,
    this.statusNote,
    this.driverId,
    this.driverName,
    this.deliveryId,
    this.driverNote,
    this.soInvoiceNumber,
    this.approvedAt,
    this.approvedBy,
    this.dispatchedAt,
    this.dispatchedBy,
    this.deliveredAt,
    required this.createdAt,
    required this.updatedAt,
    this.paymentType = 'cash',
    this.amount = 0,
  });

  factory Order.fromRow(Map<String, dynamic> r) {
    final pj = r['photo_paths_json'] as String?;
    final paths = (pj != null && pj.isNotEmpty)
        ? List<String>.from(jsonDecode(pj) as List)
        : const <String>[];
    DateTime? p(String k) =>
        r[k] != null ? DateTime.parse(r[k] as String).toLocal() : null;
    return Order(
      id: r['id'] as String,
      orgId: r['org_id'] as String,
      customerId: r['customer_id'] as String,
      customerName: r['customer_name'] as String?,
      customerCode: r['customer_code'] as String?,
      salespersonId: r['salesperson_id'] as String?,
      salespersonName: r['salesperson_name'] as String?,
      notes: r['notes'] as String?,
      photoPaths: paths,
      status: OrderStatusX.fromKey(r['status'] as String?) ?? OrderStatus.inReview,
      statusNote: r['status_note'] as String?,
      driverId: r['driver_id'] as String?,
      driverName: r['driver_name'] as String?,
      deliveryId: r['delivery_id'] as String?,
      driverNote: r['driver_note'] as String?,
      soInvoiceNumber: r['so_invoice_number'] as String?,
      approvedAt: p('approved_at'),
      approvedBy: r['approved_by'] as String?,
      dispatchedAt: p('dispatched_at'),
      dispatchedBy: r['dispatched_by'] as String?,
      deliveredAt: p('delivered_at'),
      createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
      updatedAt: DateTime.parse(r['updated_at'] as String).toLocal(),
      paymentType: r['payment_type'] as String? ?? 'cash',
      amount: (r['amount'] as int?) ?? 0,
    );
  }
}
