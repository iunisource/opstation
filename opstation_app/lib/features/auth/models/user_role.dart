/// All user roles supported in Opstation.
/// A single user account maps to exactly one role.
/// Salesperson and Driver are mutually exclusive at the business level.
enum UserRole {
  superAdmin,
  masterAdmin,
  admin,
  salesperson,
  surveyor,
  dispatchManager,
  driver,
  accountant,
}

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.superAdmin:
        return 'Super Admin';
      case UserRole.masterAdmin:
        return 'Master Admin';
      case UserRole.admin:
        return 'Admin';
      case UserRole.salesperson:
        return 'Salesperson';
      case UserRole.surveyor:
        return 'Surveyor';
      case UserRole.dispatchManager:
        return 'Dispatch Manager';
      case UserRole.driver:
        return 'Driver';
      case UserRole.accountant:
        return 'Accountant';
    }
  }

  /// Initial landing route for each role after login.
  String get homeRoute {
    switch (this) {
      case UserRole.superAdmin:
        return '/super-admin';
      case UserRole.masterAdmin:
        return '/master-admin';
      case UserRole.admin:
        return '/admin';
      case UserRole.salesperson:
        return '/salesperson';
      case UserRole.surveyor:
        return '/surveyor';
      case UserRole.dispatchManager:
        return '/dispatch';
      case UserRole.driver:
        return '/driver';
      case UserRole.accountant:
        return '/accountant';
    }
  }

  static UserRole? fromKey(String key) {
    for (final r in UserRole.values) {
      if (r.name == key) return r;
    }
    return null;
  }
}
