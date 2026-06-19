import 'package:flutter/material.dart';

/// Single source of truth for which modules EXIST in Opstation and can be
/// enabled per organization (the super-admin "Modules — <org>" toggles write
/// these keys into `org_modules.module`).
///
/// This is intentionally separate from `kPermissionRegistry`
/// (permission_registry.dart):
///   • This list = what can be sold / licensed / toggled. It is a SUPERSET and
///     may include modules that have no screens yet (`live: false`).
///   • kPermissionRegistry = the routes & permissions each LIVE module gates.
///     Its module-gated `PermModule.key`s must all appear here.
///
/// To add a new module, append one line below — it will automatically show in
/// the super-admin modal. Once its screens exist, add a matching `PermModule`
/// in permission_registry.dart (with `moduleGated: true`) and flip `live: true`
/// here.
class AppModule {
  /// Must equal the `org_modules.module` string the backend stores.
  final String key;

  /// Display label shown in the super-admin Modules modal.
  final String label;

  final IconData icon;

  /// false = licensable / toggleable but no screens wired yet (shows "Soon").
  final bool live;

  const AppModule(this.key, this.label, this.icon, {this.live = true});
}

const List<AppModule> kAppModules = [
  AppModule('inventory', 'Inventory', Icons.inventory_2_outlined),
  AppModule('purchase', 'Purchase', Icons.shopping_cart_outlined),
  AppModule('sales', 'Sales', Icons.receipt_long_outlined),
  AppModule('pos', 'POS', Icons.storefront_outlined),
  AppModule('hr', 'HR', Icons.badge_outlined),
  AppModule('production', 'Production', Icons.precision_manufacturing_outlined),
  AppModule('financial_reporting', 'Financial Reporting', Icons.account_balance_outlined),
  AppModule('assets', 'Asset Management', Icons.chair_outlined),
  AppModule('facility', 'Facility Management', Icons.cleaning_services_outlined),

  // ─── Pending modules — add more here as needed ───────────────────────────
  // The `key` MUST match the org_modules.module string the backend expects.
  // Example:
  // AppModule('facility', 'Facility Management', Icons.apartment_outlined, live: false),
];
