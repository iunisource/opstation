import '../../../core/database/app_database.dart';

/// A tenant / organization in the system. All app-level users (admins,
/// master admins, salespersons, drivers, etc.) belong to exactly one
/// org. Super admins live outside this boundary — they manage orgs.
class Org {
  final String id;
  final String name;

  /// The user responsible for the org. Null only in the rare window
  /// between creating an org and assigning a master admin.
  final String? masterAdminId;

  /// When false, users in this org cannot log in. Data is preserved
  /// so re-enabling restores everything.
  final bool isActive;

  final DateTime createdAt;
  final DateTime? updatedAt;

  const Org({
    required this.id,
    required this.name,
    this.masterAdminId,
    required this.isActive,
    required this.createdAt,
    this.updatedAt,
  });

  factory Org.fromRow(OrgsData r) {
    return Org(
      id: r.id,
      name: r.name,
      masterAdminId: r.masterAdminId,
      isActive: r.isActive,
      createdAt: r.createdAt,
      updatedAt: r.updatedAt,
    );
  }

  Org copyWith({
    String? name,
    String? masterAdminId,
    bool setMasterAdminNull = false,
    bool? isActive,
    DateTime? updatedAt,
  }) {
    return Org(
      id: id,
      name: name ?? this.name,
      masterAdminId:
          setMasterAdminNull ? null : (masterAdminId ?? this.masterAdminId),
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
