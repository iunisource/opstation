import 'package:flutter/material.dart';

/// A permission item is either a "doc" (voucher / editable entity — has Add &
/// Edit toggles; Delete is role-gated to admins) or a "report" (has a single
/// Show toggle).
enum PermKind { doc, report }

class PermItem {
  final String key;
  final String label;
  final PermKind kind;
  final String route;

  /// Optional owning module, for items that sit in an ungated group but still
  /// belong to a licensable module. A customer ledger is a Sales artefact and
  /// an inventory ledger an Inventory one, even though both live under
  /// "Reports & Ledgers" — without this they showed for every org regardless
  /// of which modules were switched on.
  final String? module;

  const PermItem(this.key, this.label, this.kind, this.route, {this.module});

  String get addKey => 'doc.$key.add';
  String get editKey => 'doc.$key.edit';
  String get viewKey => 'report.$key.view';

  /// Permission keys this item owns (2 for docs, 1 for reports).
  List<String> get keys =>
      kind == PermKind.doc ? [addKey, editKey] : [viewKey];
}

class PermModule {
  final String key; // matches org_modules.module for module-level gating
  final String label;
  final IconData icon;
  final List<PermItem> items;
  // Whether this group maps to a real org_modules toggle. Ledgers/Aging are
  // derived reports with no dedicated org module, so they are NOT module-gated
  // (the menu still gates them via the underlying purchase/sales/inventory
  // modules; here we gate by permission only).
  final bool moduleGated;
  const PermModule(this.key, this.label, this.icon, this.items,
      {this.moduleGated = true});

  List<String> get allKeys => [for (final it in items) ...it.keys];
}

/// The single source of truth for every gated voucher & report in the ERP.
/// Mirrors the menu in main_layout.dart.
const List<PermModule> kPermissionRegistry = [
  PermModule('inventory', 'Inventory', Icons.inventory_2_outlined, [
    PermItem('products', 'Products', PermKind.doc, '/erp/products'),
    PermItem('branches', 'Branches', PermKind.doc, '/erp/branches'),
    PermItem('uoms', 'Units of Measure', PermKind.doc, '/erp/uoms'),
    PermItem('stock_levels', 'Stock Levels', PermKind.report, '/erp/stock'),
    PermItem('low_stock_report', 'Low Stock Report', PermKind.report, '/erp/low-stock-report'),
    PermItem('stock_value_report', 'Stock Value Report', PermKind.report, '/erp/stock-value-report'),
    PermItem('stock_balance_report', 'Stock Balance Report', PermKind.report, '/erp/stock-balance-report'),
    PermItem('stock_aging_report', 'Stock Aging Report', PermKind.report, '/erp/stock-aging-report'),
    PermItem('inventory_integrity', 'Inventory Integrity', PermKind.report, '/erp/inventory-integrity'),
    PermItem('product_classifications', 'Product Classifications', PermKind.doc, '/erp/product-classifications'),
    PermItem('opening_stock', 'Opening Stock', PermKind.doc, '/erp/opening-stock'),
    PermItem('stock_transfer', 'Stock Transfers', PermKind.doc, '/erp/stock-transfers'),
    PermItem('stock_adjustment', 'Stock Adjustment', PermKind.doc, '/erp/stock-adjustment'),
    PermItem('demand_plan', 'Demand Planner', PermKind.report, '/erp/demand-plan'),
    PermItem('price_list', 'Price List Generator', PermKind.report, '/erp/price-list'),
  ]),
  PermModule('purchase', 'Purchase', Icons.shopping_cart_outlined, [
    PermItem('purchase_dashboard', 'Purchase Dashboard', PermKind.report, '/erp/purchase-dashboard'),
    PermItem('purchase_report', 'Purchase Report', PermKind.report, '/erp/purchase-report'),
    PermItem('suppliers', 'Suppliers', PermKind.doc, '/erp/suppliers'),
    PermItem('po', 'Purchase Orders', PermKind.doc, '/erp/purchase'),
    PermItem('grn', 'GRN', PermKind.doc, '/erp/grn'),
    PermItem('pi', 'Purchase Invoices', PermKind.doc, '/erp/purchase-invoices'),
    PermItem('purchase_return', 'Purchase Return Notes', PermKind.doc, '/erp/purchase-returns'),
    PermItem('purchase_return_invoice', 'Purchase Return Invoices', PermKind.doc, '/erp/purchase-return-vouchers'),
  ]),
  PermModule('sales', 'Sales', Icons.receipt_long_outlined, [
    PermItem('sales_dashboard', 'Sales Dashboard', PermKind.report, '/erp/sales-dashboard'),
    PermItem('customers', 'Customers', PermKind.doc, '/customers'),
    PermItem('quotation', 'Quotation', PermKind.doc, '/erp/quotation'),
    PermItem('so', 'Sales Orders', PermKind.doc, '/erp/sales'),
    PermItem('field_orders', 'Field Orders', PermKind.doc, '/erp/field-orders'),
    PermItem('retailer_orders', 'Retailer Orders', PermKind.doc, '/erp/retailer-orders'),
    PermItem('do', 'Delivery Orders', PermKind.doc, '/erp/delivery-orders'),
    PermItem('si', 'Sales Invoices', PermKind.doc, '/erp/sales-invoices'),
    PermItem('sales_return', 'Sales Return Notes', PermKind.doc, '/erp/sales-returns'),
    PermItem('sales_return_invoice', 'Sales Return Invoices', PermKind.doc, '/erp/sales-return-invoices'),
    PermItem('sales_report', 'Sales Report', PermKind.report, '/erp/sales-report'),
    PermItem('sales_return_report', 'Sales Return Report', PermKind.report, '/erp/sales-return-report'),
    PermItem('dispatch_summary', 'Dispatch Summary', PermKind.report, '/erp/dispatch-summary'),
    PermItem('schemes', 'Schemes & Offers', PermKind.doc, '/erp/schemes'),
    PermItem('schemes_report', 'Scheme Performance', PermKind.report, '/erp/schemes-report'),
  ]),
  PermModule('pos', 'POS', Icons.storefront_outlined, [
    PermItem('pos_config', 'Configuration', PermKind.doc, '/erp/pos-config'),
    PermItem('pos', 'POS', PermKind.doc, '/erp/pos'),
    PermItem('pos_catalog', 'POS Catalog', PermKind.doc, '/erp/pos-catalog'),
    PermItem('pos_customer_history', 'Customer History', PermKind.report, '/erp/pos-customer-history'),
    PermItem('pos_held_bills', 'Bills on Hold', PermKind.report, '/erp/pos-held-bills'),
    PermItem('pos_expense', 'Expense Management', PermKind.doc, '/erp/pos-expense-management'),
  ]),
  PermModule('reports', 'Reports & Ledgers', Icons.analytics_outlined, [
    PermItem('supplier_ledger', 'Supplier Ledger', PermKind.report, '/erp/supplier-ledger', module: 'purchase'),
    PermItem('customer_ledger', 'Customer Ledger', PermKind.report, '/erp/customer-ledger', module: 'sales'),
    PermItem('inventory_ledger', 'Inventory Ledger', PermKind.report, '/erp/inventory-ledger', module: 'inventory'),
    PermItem('customer_aging', 'Customer Aging', PermKind.report, '/erp/customer-aging', module: 'sales'),
    PermItem('supplier_aging', 'Supplier Aging', PermKind.report, '/erp/supplier-aging', module: 'purchase'),
    PermItem('margin_report', 'Margin Report', PermKind.report, '/reports/margin', module: 'sales'),
    PermItem('customer_balance_report', 'Customer Balance Report', PermKind.report, '/reports/customer-balance', module: 'sales'),
    PermItem('supplier_balance_report', 'Supplier Balance Report', PermKind.report, '/reports/supplier-balance', module: 'purchase'),
    PermItem('skipped_receipts_report', 'Skipped Receipts Report', PermKind.report, '/reports/skipped-receipts', module: 'sales'),
    // Report Builder and Files are cross-cutting tools, not tied to a single
    // licensable module — left permission-gated only.
    // Reports Center is the browsable gallery landing; grant it to let a user
    // open the Center. Individual cards inside are still gated by each report's
    // own permission, and saved custom reports by their share audience.
    PermItem('reports_center', 'Reports Center', PermKind.report, '/reports/center'),
    PermItem('report_builder', 'Report Builder', PermKind.report, '/intelligence/report-builder'),
    PermItem('shared_files', 'Files', PermKind.report, '/erp/files'),
  ], moduleGated: false),
  PermModule('production', 'Manufacturing', Icons.precision_manufacturing_outlined, [
    PermItem('production_floor', 'Production Floor', PermKind.report, '/manufacturing/production-floor'),
    PermItem('production_plan', 'Production Material Planner', PermKind.report, '/manufacturing/production-plan'),
    PermItem('bom', 'Product Assembly (BOM)', PermKind.doc, '/manufacturing/product-assembly'),
    PermItem('production', 'Production Voucher', PermKind.doc, '/manufacturing/production-voucher'),
    PermItem('job_card', 'Job Card', PermKind.doc, '/manufacturing/job-card'),
    PermItem('qc_checkpoints', 'QC Checkpoints', PermKind.doc, '/manufacturing/qc-checkpoints'),
    PermItem('qc_station', 'QC Station', PermKind.report, '/manufacturing/qc-station'),
    PermItem('job_kiosk', 'Job Kiosk', PermKind.report, '/manufacturing/job-kiosk'),
    PermItem('production_inverse', 'Production Inverse Voucher', PermKind.doc, '/manufacturing/production-inverse-voucher'),
    PermItem('damage_stock', 'Damage Stock Voucher', PermKind.doc, '/manufacturing/damage-stock-voucher'),
    PermItem('claim_processing', 'Claim Processing Voucher', PermKind.doc, '/manufacturing/claim-processing-voucher'),
    PermItem('production_waste', 'Production Waste Report', PermKind.report, '/manufacturing/production-waste-report'),
    PermItem('overheads_summary', 'Overheads Summary', PermKind.report, '/manufacturing/overheads-summary'),
    PermItem('fg_without_bom', 'Goods without BOM', PermKind.report, '/erp/fg-without-bom'),
    // Capability (not a navigable screen): who may SEE costing on the Production
    // Voucher & Job Card. Admins always can; grant this to specific users.
    // Editing/adding cost is separately restricted to master admins in-screen.
    PermItem('production_cost', 'View Production & Job Costs', PermKind.report, '/manufacturing/cost-view'),
  ]),
  PermModule('hr', 'HR', Icons.badge_outlined, [
    PermItem('hr_employees', 'Employee Directory', PermKind.doc, '/hr/employees'),
    PermItem('hr_attendance', 'Attendance', PermKind.doc, '/hr/attendance'),
    PermItem('hr_attendance_kiosk', 'Attendance Kiosk', PermKind.report, '/hr/attendance-kiosk'),
    PermItem('hr_attendance_board', 'Attendance Board', PermKind.report, '/hr/attendance-board'),
    PermItem('hr_leave', 'Leave', PermKind.doc, '/hr/leave'),
  ]),
  PermModule('financial_reporting', 'Financials', Icons.account_balance_outlined, [
    PermItem('chart_of_accounts', 'Chart of Accounts', PermKind.doc, '/erp/chart-of-accounts'),
    PermItem('jv', 'Journal Vouchers', PermKind.doc, '/financials/journal-vouchers'),
    PermItem('opening_journal', 'Opening Journal', PermKind.doc, '/financials/opening-journal'),
    PermItem('cpv', 'Payment Vouchers', PermKind.doc, '/erp/payment-vouchers'),
    PermItem('crv', 'Receipt Vouchers', PermKind.doc, '/erp/receipt-vouchers'),
    PermItem('pdc', 'PDC Voucher', PermKind.doc, '/erp/pdc-voucher'),
    PermItem('trial_balance', 'Trial Balance', PermKind.report, '/financials/trial-balance'),
    PermItem('account_activity', 'Account Activity', PermKind.report, '/financials/account-activity'),
    PermItem('cash_book', 'Cash Book Report', PermKind.report, '/financials/cash-book'),
    PermItem('profit_loss', 'Profit & Loss', PermKind.report, '/financials/profit-loss'),
    PermItem('balance_sheet', 'Balance Sheet', PermKind.report, '/financials/balance-sheet'),
  ]),
  PermModule('assets', 'Assets', Icons.chair_outlined, [
    PermItem('assets', 'Asset Register', PermKind.doc, '/assets'),
  ]),
  PermModule('facility', 'Facility', Icons.cleaning_services_outlined, [
    PermItem('facility', 'Facility Maintenance', PermKind.doc, '/facility'),
  ]),
  // CRM is licensable in app_modules.dart but had no registry entry, so none
  // of its routes appeared in kRouteToModule and the menu showed for every
  // org whether or not the module was switched on.
  PermModule('crm', 'CRM', Icons.contacts_outlined, [
    PermItem('crm_customers', 'CRM Customers', PermKind.doc, '/crm/customers'),
    PermItem('crm_pipeline', 'Pipeline', PermKind.doc, '/crm/pipeline'),
    PermItem('crm_follow_ups', 'Follow-ups', PermKind.doc, '/crm/follow-ups'),
    PermItem('crm_supplier_profile', 'Suppliers', PermKind.doc, '/crm/supplier-profile'),
  ]),
];

/// route -> PermItem (for menu + router gating).
final Map<String, PermItem> kRouteToPerm = {
  for (final m in kPermissionRegistry)
    for (final it in m.items) it.route: it,
};

/// route -> owning module key (only for groups that map to a real org module).
///
/// Built in two passes: the group's own module first, then any per-item
/// override. Later entries win, so an item that names its own module takes
/// precedence — which is how reports inside the ungated "Reports & Ledgers"
/// group still get gated by Sales, Purchase or Inventory.
final Map<String, String> kRouteToModule = {
  for (final m in kPermissionRegistry)
    if (m.moduleGated)
      for (final it in m.items) it.route: m.key,
  for (final m in kPermissionRegistry)
    for (final it in m.items)
      if (it.module != null) it.route: it.module!,
};

/// Every valid permission key (used to discard stale legacy keys).
final Set<String> kAllPermKeys = {
  for (final m in kPermissionRegistry) ...m.allKeys,
};
