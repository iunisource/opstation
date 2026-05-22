import '../../salesperson/models/customer.dart';

/// Categories of compliance anomaly this slice detects.
enum AnomalyType {
  skipped,
  zeroCollection,
  noGps,
  notVisited,
}

extension AnomalyTypeX on AnomalyType {
  String get label {
    switch (this) {
      case AnomalyType.skipped:
        return 'Repeated skips';
      case AnomalyType.zeroCollection:
        return 'Zero collection';
      case AnomalyType.noGps:
        return 'No GPS captured';
      case AnomalyType.notVisited:
        return 'Not visited';
    }
  }

  /// Short one-line hint for admins on what the flag means.
  String get description {
    switch (this) {
      case AnomalyType.skipped:
        return 'Customer skipped on repeated visits';
      case AnomalyType.zeroCollection:
        return 'On-site with Rs 0 collected repeatedly';
      case AnomalyType.noGps:
        return 'No GPS fix captured repeatedly';
      case AnomalyType.notVisited:
        return 'On route but never marked on repeated trips';
    }
  }
}

/// A single customer flagged under a single anomaly type for one
/// salesperson. `count` is the number of occurrences inside the
/// lookback window. `detail` is a short admin-facing explanation
/// pulled from the most recent incident.
class AnomalyFlag {
  final AnomalyType type;
  final Customer customer;
  final int count;
  final String detail;

  const AnomalyFlag({
    required this.type,
    required this.customer,
    required this.count,
    required this.detail,
  });
}

/// All flags for one salesperson, grouped by anomaly type, with the
/// score precomputed.
class SalespersonCompliance {
  final String userId;
  final String userName;

  /// All customers the salesperson serviced in the lookback window.
  /// 'Serviced' = appeared as a stop in any trip in that window.
  final int customersServiced;

  /// Customers flagged under at least one anomaly type.
  final int customersFlagged;

  final Map<AnomalyType, List<AnomalyFlag>> flagsByType;

  const SalespersonCompliance({
    required this.userId,
    required this.userName,
    required this.customersServiced,
    required this.customersFlagged,
    required this.flagsByType,
  });

  /// Ratio: (customers with 0 anomalies / total serviced) * 100, floored
  /// at 0 and capped at 100.
  double get scorePercent {
    if (customersServiced == 0) return 100.0;
    final clean = customersServiced - customersFlagged;
    return (clean / customersServiced) * 100.0;
  }

  int get totalFlagCount => flagsByType.values.fold(0, (s, l) => s + l.length);
}
