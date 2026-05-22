import 'dart:convert';

import '../../../core/database/app_database.dart';

/// Status of a delivery as a whole.
enum DeliveryStatus {
  draft,
  assigned,
  inProgress,
  completed,
  cancelled,
}

extension DeliveryStatusX on DeliveryStatus {
  String get wire {
    switch (this) {
      case DeliveryStatus.draft:
        return 'draft';
      case DeliveryStatus.assigned:
        return 'assigned';
      case DeliveryStatus.inProgress:
        return 'in_progress';
      case DeliveryStatus.completed:
        return 'completed';
      case DeliveryStatus.cancelled:
        return 'cancelled';
    }
  }

  String get label {
    switch (this) {
      case DeliveryStatus.draft:
        return 'Draft';
      case DeliveryStatus.assigned:
        return 'Assigned';
      case DeliveryStatus.inProgress:
        return 'In progress';
      case DeliveryStatus.completed:
        return 'Completed';
      case DeliveryStatus.cancelled:
        return 'Cancelled';
    }
  }

  static DeliveryStatus fromWire(String s) {
    switch (s) {
      case 'draft':
        return DeliveryStatus.draft;
      case 'assigned':
        return DeliveryStatus.assigned;
      case 'in_progress':
        return DeliveryStatus.inProgress;
      case 'completed':
        return DeliveryStatus.completed;
      case 'cancelled':
        return DeliveryStatus.cancelled;
      default:
        return DeliveryStatus.draft;
    }
  }
}

/// Status of a single stop within a delivery.
enum DeliveryStopStatus {
  pending,
  delivered,
  failed,
}

extension DeliveryStopStatusX on DeliveryStopStatus {
  String get wire {
    switch (this) {
      case DeliveryStopStatus.pending:
        return 'pending';
      case DeliveryStopStatus.delivered:
        return 'delivered';
      case DeliveryStopStatus.failed:
        return 'failed';
    }
  }

  String get label {
    switch (this) {
      case DeliveryStopStatus.pending:
        return 'Pending';
      case DeliveryStopStatus.delivered:
        return 'Delivered';
      case DeliveryStopStatus.failed:
        return 'Failed';
    }
  }

  static DeliveryStopStatus fromWire(String s) {
    switch (s) {
      case 'pending':
        return DeliveryStopStatus.pending;
      case 'delivered':
        return DeliveryStopStatus.delivered;
      case 'failed':
        return DeliveryStopStatus.failed;
      default:
        return DeliveryStopStatus.pending;
    }
  }
}

/// Payment arrangement for a stop. 'credit' means the customer is on
/// account — driver delivers without collecting at drop; amount is
/// tracked as owed elsewhere.
enum PaymentType { cash, credit }

extension PaymentTypeX on PaymentType {
  String get wire {
    switch (this) {
      case PaymentType.cash:
        return 'cash';
      case PaymentType.credit:
        return 'credit';
    }
  }

  String get label {
    switch (this) {
      case PaymentType.cash:
        return 'Cash';
      case PaymentType.credit:
        return 'Credit';
    }
  }

  static PaymentType fromWire(String s) {
    switch (s) {
      case 'credit':
        return PaymentType.credit;
      case 'cash':
      default:
        return PaymentType.cash;
    }
  }
}

/// Geofence verification outcome, computed at mark time against the
/// org-wide [geofenceRadiusMeters] setting. Mirrors the salesperson
/// visit flow — same semantic meaning, same thresholds, so admins
/// can reason about verification consistently across roles.
///
/// This is a SOFT flag: an outside/noLocation verification never
/// blocks the driver. Admin reports and compliance patterns use it
/// to detect anomalies without penalizing legitimate edge cases
/// (inaccurate customer location data, off-site drops, warehouses
/// without GPS).
enum DeliveryStopVerification { pending, verified, outside, noLocation }

extension DeliveryStopVerificationX on DeliveryStopVerification {
  String get wire {
    switch (this) {
      case DeliveryStopVerification.pending:
        return 'pending';
      case DeliveryStopVerification.verified:
        return 'verified';
      case DeliveryStopVerification.outside:
        return 'outside';
      case DeliveryStopVerification.noLocation:
        return 'no_location';
    }
  }

  String get label {
    switch (this) {
      case DeliveryStopVerification.pending:
        return 'Pending';
      case DeliveryStopVerification.verified:
        return 'Verified';
      case DeliveryStopVerification.outside:
        return 'Outside';
      case DeliveryStopVerification.noLocation:
        return 'No GPS';
    }
  }

  static DeliveryStopVerification fromWire(String s) {
    switch (s) {
      case 'verified':
        return DeliveryStopVerification.verified;
      case 'outside':
        return DeliveryStopVerification.outside;
      case 'no_location':
        return DeliveryStopVerification.noLocation;
      case 'pending':
      default:
        return DeliveryStopVerification.pending;
    }
  }
}

class DeliveryStop {
  final String id;
  final String deliveryId;
  final String customerId;
  final String customerCode;
  final String customerName;
  final int sequence;
  final String itemDescription;
  final int amount;
  final PaymentType paymentType;
  final DeliveryStopStatus status;
  final DateTime? deliveredAt;
  final String? failureReason;
  final int? cashReceived;
  final double? capturedLat;
  final double? capturedLng;
  final int? distanceMeters;
  final DeliveryStopVerification verification;
  final String? driverNote;
  final String? soInvoiceNumber;
  final List<String> photoPaths;

  const DeliveryStop({
    required this.id,
    required this.deliveryId,
    required this.customerId,
    required this.customerCode,
    required this.customerName,
    required this.sequence,
    required this.itemDescription,
    required this.amount,
    required this.paymentType,
    required this.status,
    this.deliveredAt,
    this.failureReason,
    this.cashReceived,
    this.capturedLat,
    this.capturedLng,
    this.distanceMeters,
    this.verification = DeliveryStopVerification.pending,
    this.driverNote,
    this.soInvoiceNumber,
    this.photoPaths = const [],
  });

  factory DeliveryStop.fromRow(DeliveryStopsData r) {
    List<String> paths;
    try {
      final decoded = jsonDecode(r.photoPathsJson);
      paths = (decoded is List)
          ? decoded.whereType<String>().toList()
          : const <String>[];
    } catch (_) {
      paths = const <String>[];
    }
    return DeliveryStop(
      id: r.id,
      deliveryId: r.deliveryId,
      customerId: r.customerId,
      customerCode: r.customerCode,
      customerName: r.customerName,
      sequence: r.sequence,
      itemDescription: r.itemDescription,
      amount: r.amount,
      paymentType: PaymentTypeX.fromWire(r.paymentType),
      status: DeliveryStopStatusX.fromWire(r.status),
      deliveredAt: r.deliveredAt,
      failureReason: r.failureReason,
      cashReceived: r.cashReceived,
      capturedLat: r.capturedLat,
      capturedLng: r.capturedLng,
      distanceMeters: r.distanceMeters,
      verification: DeliveryStopVerificationX.fromWire(r.verification),
      driverNote: r.driverNote,
      soInvoiceNumber: r.soInvoiceNumber,
      photoPaths: paths,
    );
  }
}

class Delivery {
  final String id;
  final String? driverId;
  final String? driverName;
  final String? driverRole;
  final String createdBy;
  final String createdByName;
  final String createdByRole;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DeliveryStatus status;
  final String? notes;
  final List<DeliveryStop> stops;

  const Delivery({
    required this.id,
    required this.driverId,
    required this.driverName,
    required this.driverRole,
    required this.createdBy,
    required this.createdByName,
    required this.createdByRole,
    required this.createdAt,
    required this.startedAt,
    required this.completedAt,
    required this.status,
    required this.notes,
    required this.stops,
  });

  factory Delivery.fromRow(DeliveriesData r, List<DeliveryStop> stops) {
    return Delivery(
      id: r.id,
      driverId: r.driverId,
      driverName: r.driverName,
      driverRole: r.driverRole,
      createdBy: r.createdBy,
      createdByName: r.createdByName,
      createdByRole: r.createdByRole,
      createdAt: r.createdAt,
      startedAt: r.startedAt,
      completedAt: r.completedAt,
      status: DeliveryStatusX.fromWire(r.status),
      notes: r.notes,
      stops: stops,
    );
  }

  /// Convenience: sum of all stop amounts.
  int get totalAmount =>
      stops.fold<int>(0, (s, x) => s + x.amount);

  /// Convenience: sum of only cash-type amounts.
  int get cashAmount => stops
      .where((s) => s.paymentType == PaymentType.cash)
      .fold<int>(0, (s, x) => s + x.amount);

  /// Convenience: sum of only credit-type amounts.
  int get creditAmount => stops
      .where((s) => s.paymentType == PaymentType.credit)
      .fold<int>(0, (s, x) => s + x.amount);

  int get deliveredCount =>
      stops.where((s) => s.status == DeliveryStopStatus.delivered).length;
  int get failedCount =>
      stops.where((s) => s.status == DeliveryStopStatus.failed).length;
  int get pendingCount =>
      stops.where((s) => s.status == DeliveryStopStatus.pending).length;

  /// Actual cash the driver has collected so far, summed across all
  /// delivered stops (credit stops don't contribute — customer is on
  /// account). Uses [cashReceived] which may differ from the dispatched
  /// [amount] if the customer short-paid.
  int get cashCollected => stops
      .where((s) =>
          s.status == DeliveryStopStatus.delivered &&
          s.paymentType == PaymentType.cash &&
          s.cashReceived != null)
      .fold<int>(0, (sum, s) => sum + (s.cashReceived ?? 0));

  /// Number of settled stops (delivered or failed) that were marked
  /// outside the geofence. Used for admin dashboards and compliance
  /// pattern detection. Pending stops don't count toward this.
  int get outsideGeofenceCount => stops
      .where((s) =>
          s.status != DeliveryStopStatus.pending &&
          s.verification == DeliveryStopVerification.outside)
      .length;

  /// Settled stops that had no GPS fix at mark-time (either permission
  /// denied, fix timed out, or the customer has no saved location).
  int get noLocationCount => stops
      .where((s) =>
          s.status != DeliveryStopStatus.pending &&
          s.verification == DeliveryStopVerification.noLocation)
      .length;
}
