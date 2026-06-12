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
  const PermItem(this.key, this.label, this.kind, this.route);

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
    PermItem('product_classifications', 'Product Classifications', PermKind.doc, '/erp/product-classifications'),
    PermItem('opening_stock', 'Opening Stock', PermKind.doc, '/erp/opening-stock'),
    PermItem('stock_transfer', 'Stock Transfers', PermKind.doc, '/erp/stock-transfers'),
    PermItem('stock_adjustment', 'Stock Adjustment', PermKind.doc, '/erp/stock-adjustment'),
  ]),
  PermModule('purchase', 'Purchase', Icons.shopping_cart_outlined, [
    PermItem('suppliers', 'Suppliers', PermKind.doc, '/erp/suppliers'),
    PermItem('po', 'Purchase Orders', PermKind.doc, '/erp/purchase'),
    PermItem('grn', 'GRN', PermKind.doc, '/erp/grn'),
    PermItem('pi', 'Purchase Invoices', PermKind.doc, '/erp/purchase-invoices'),
    PermItem('purchase_return', 'Purchase Return Notes', PermKind.doc, '/erp/purchase-returns'),
    PermItem('purchase_return_invoice', 'Purchase Return Invoices', PermKind.doc, '/erp/purchase-return-vouchers'),
  ]),
  PermModule('sales', 'Sales', Icons.receipt_long_outlined, [
    PermItem('so', 'Sales Orders', PermKind.doc, '/erp/sales'),
    PermItem('do', 'Delivery Orders', PermKind.doc, '/erp/delivery-orders'),
    PermItem('si', 'Sales Invoices', PermKind.doc, '/erp/sales-invoices'),
    PermItem('sales_return', 'Sales Return Notes', PermKind.doc, '/erp/sales-returns'),
    PermItem('sales_return_invoice', 'Sales Return Invoices', PermKind.doc, '/erp/sales-return-invoices'),
  ]),
  PermModule('pos', 'POS', Icons.storefront_outlined, [
    PermItem('pos_config', 'Configuration', PermKind.doc, '/erp/pos-config'),
    PermItem('pos', 'POS', PermKind.doc, '/erp/pos'),
    PermItem('pos_catalog', 'POS Catalog', PermKind.doc, '/erp/pos-catalog'),
    PermItem('pos_customer_history', 'Customer History', PermKind.report, '/erp/pos-customer-history'),
    PermItem('pos_held_bills', 'Bills on Hold', PermKind.report, '/erp/pos-held-bills'),
    PermItem('pos_expense', 'Expense Management', PermKind.doc, '/erp/pos-expense-management'),
  ]),
  PermModule('reports', 'Ledgers & Aging', Icons.analytics_outlined, [
    PermItem('supplier_ledger', 'Supplier Ledger', PermKind.report, '/erp/supplier-ledger'),
    PermItem('customer_ledger', 'Customer Ledger', PermKind.report, '/erp/customer-ledger'),
    PermItem('inventory_ledger', 'Inventory Ledger', PermKind.report, '/erp/inventory-ledger'),
    PermItem('customer_aging', 'Customer Aging', PermKind.report, '/erp/customer-aging'),
    PermItem('supplier_aging', 'Supplier Aging', PermKind.report, '/erp/supplier-aging'),
  ], moduleGated: false),
  PermModule('production', 'Manufacturing', Icons.precision_manufacturing_outlined, [
    PermItem('bom', 'Product Assembly (BOM)', PermKind.doc, '/manufacturing/product-assembly'),
    PermItem('production', 'Production Voucher', PermKind.doc, '/manufacturing/production-voucher'),
    PermItem('production_inverse', 'Production Inverse Voucher', PermKind.doc, '/manufacturing/production-inverse-voucher'),
    PermItem('damage_stock', 'Damage Stock Voucher', PermKind.doc, '/manufacturing/damage-stock-voucher'),
    PermItem('claim_processing', 'Claim Processing Voucher', PermKind.doc, '/manufacturing/claim-processing-voucher'),
    PermItem('production_waste', 'Production Waste Report', PermKind.report, '/manufacturing/production-waste-report'),
  ]),
  PermModule('hr', 'HR', Icons.badge_outlined, [
    PermItem('hr_employees', 'Employee Directory', PermKind.doc, '/hr/employees'),
    PermItem('hr_attendance', 'Attendance', PermKind.doc, '/hr/attendance'),
    PermItem('hr_leave', 'Leave', PermKind.doc, '/hr/leave'),
  ], moduleGated: false),
  PermModule('financial_reporting', 'Financials', Icons.account_balance_outlined, [
    PermItem('chart_of_accounts', 'Chart of Accounts', PermKind.doc, '/erp/chart-of-accounts'),
    PermItem('jv', 'Journal Vouchers', PermKind.doc, '/financials/journal-vouchers'),
    PermItem('opening_jv', 'Opening Journal', PermKind.doc, '/financials/opening-journal'),
    PermItem('cpv', 'Payment Vouchers', PermKind.doc, '/erp/payment-vouchers'),
    PermItem('crv', 'Receipt Vouchers', PermKind.doc, '/erp/receipt-vouchers'),
    PermItem('trial_balance', 'Trial Balance', PermKind.report, '/financials/trial-balance'),
    PermItem('account_activity', 'Account Activity', PermKind.report, '/financials/account-activity'),
    PermItem('profit_loss', 'Profit & Loss', PermKind.report, '/financials/profit-loss'),
    PermItem('balance_sheet', 'Balance Sheet', PermKind.report, '/financials/balance-sheet'),
  ]),
];

/// route -> PermItem (for menu + router gating).
final Map<String, PermItem> kRouteToPerm = {
  for (final m in kPermissionRegistry)
    for (final it in m.items) it.route: it,
};

/// route -> owning module key (only for groups that map to a real org module).
final Map<String, String> kRouteToModule = {
  for (final m in kPermissionRegistry)
    if (m.moduleGated)
      for (final it in m.items) it.route: m.key,
};

/// Every valid permission key (used to discard stale legacy keys).
final Set<String> kAllPermKeys = {
  for (final m in kPermissionRegistry) ...m.allKeys,
};
