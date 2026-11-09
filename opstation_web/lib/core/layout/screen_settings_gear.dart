import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';
import '../../features/erp/presentation/erp_admin_settings_screen.dart' deferred as adm;

/// Settings shown on a screen's own gear (master admins only). Each entry is a
/// subset of Admin Settings — the same items, saved the same way. Admin
/// Settings itself is unchanged.
class _ScreenSettings {
  final String title;
  final List<String> keys; // Admin Settings toggle keys, in display order
  final List<String> extras; // see ErpAdminSettingsScreen.extras
  final (String, String)? page; // (button label, route) for the screen's own setup page
  const _ScreenSettings(this.title, this.keys, [this.extras = const [], this.page]);
}

const _posPage = ('Open POS Configuration', '/erp/pos-config');
const _pos = _ScreenSettings('POS', ['org.batch_tracking'], ['serious.block_negative_stock'], _posPage);

const _salesPrint = ['org.voucher_dates_editable', 'org.show_org_name_sales'];
const _purchasePrint = ['org.voucher_dates_editable', 'org.show_org_name_purchase'];
const _customerKeys = [
  'org.customer_targets_enabled',
  'org.customer_supervise_flow',
  'org.customer_edit_supervise_flow',
  'org.customer_edit_alert',
  'org.customer_deactivate_access',
  'org.field_location_capture',
  'org.surveyor_location_supervise',
  'org.loc_fix_warning',
];
const _intelKeys = ['org.intel_delete_access', 'org.intel_autopilot', 'org.audit_location_tracking', 'org.auditor_group_scope'];

const Map<String, _ScreenSettings> _screenSettings = {
  // ── Sales ──
  '/erp/quotation': _ScreenSettings('Quotation', ['org.quotation_custom_company']),
  '/erp/sales': _ScreenSettings('Sales Order', [
    'org.foc_enabled', 'org.schemes_enabled', ..._salesPrint,
  ], ['footer.org.footer_note_so', 'footer.org.voucher_footer_note']),
  '/erp/delivery-orders': _ScreenSettings('Delivery Order', [
    'org.credit_limit_alert', 'org.aging_alert', 'org.delivery_flow_enabled',
    'org.do_supervise_flow', 'org.batch_tracking', ..._salesPrint,
  ], ['footer.org.footer_note_do', 'footer.org.voucher_footer_note', 'serious.block_negative_stock']),
  '/erp/sales-invoices': _ScreenSettings('Sales Invoice', [
    'org.si_price_editable', 'org.doc_review_flow_si', 'org.si_supervise_flow',
    'org.schemes_enabled', ..._salesPrint,
  ], ['footer.org.footer_note_si', 'footer.org.voucher_footer_note']),
  '/erp/schemes': _ScreenSettings('Schemes & Offers', ['org.schemes_enabled']),
  '/erp/sales-returns': _ScreenSettings('Sales Return Note', ['org.srn_date_editable']),
  '/erp/sales-return-invoices': _ScreenSettings('Sales Return Invoice', [
    'org.sri_price_edit', 'org.sri_date_editable', 'org.sri_supervise_flow',
  ]),
  '/erp/pos': _pos,
  '/erp/pos-config': _ScreenSettings('POS', ['org.batch_tracking'], ['serious.block_negative_stock']),
  '/erp/pos-catalog': _pos,
  '/erp/pos-customer-history': _pos,
  '/erp/pos-held-bills': _pos,
  '/erp/pos-expense-management': _pos,
  '/customers': _ScreenSettings('Customers', _customerKeys),
  '/crm/customers': _ScreenSettings('Customers', _customerKeys),
  '/operations/retailers': _ScreenSettings('Retailers', [
    'org.retailer_info_enabled', 'org.show_product_images',
  ]),
  '/erp/customer-ledger': _ScreenSettings('Customer Ledger', [], ['ledger.customer']),
  '/erp/customer-balance-report': _ScreenSettings('Customer Balance Report', ['org.cbr_collection_columns']),
  '/reports/receipt-books': _ScreenSettings('Receipt Books', ['org.receipt_books_flow']),

  // ── Purchase ──
  '/erp/purchase': _ScreenSettings('Purchase Order', [
    'org.po_approval_required', 'org.po_reject_notify',
    'org.po_show_stock_consumption', 'org.po_fg_stock', ..._purchasePrint,
  ], ['footer.org.purchase_footer_note']),
  '/erp/grn': _ScreenSettings('Goods Receipt Note', [
    'org.grn_supervise_flow', 'org.batch_tracking', ..._purchasePrint,
  ], ['footer.org.purchase_footer_note', 'serious.block_zero_cost_receipt']),
  '/erp/purchase-invoices': _ScreenSettings('Purchase Invoice', [
    'org.pi_updates_cost_price', 'org.doc_review_flow_pi', 'org.pi_supervise_flow',
    ..._purchasePrint,
  ], ['footer.org.purchase_footer_note']),
  '/erp/purchase-returns': _ScreenSettings('Purchase Return Note', ['org.purchase_return_allow_short_stock']),
  '/erp/purchase-return-vouchers': _ScreenSettings('Purchase Return Invoice', [
    'org.pri_price_editable', 'org.doc_review_flow_pri',
  ]),
  '/erp/supplier-ledger': _ScreenSettings('Supplier Ledger', [], ['ledger.supplier']),

  // ── Inventory ──
  '/erp/products': _ScreenSettings('Products', [
    'org.product_supervise_flow', 'org.consignment_enabled', 'org.batch_tracking',
    'org.hide_main_groups_by_branch',
  ], ['hidden_groups']),
  '/erp/batch-tracking': _ScreenSettings('Batch Tracking', ['org.batch_tracking']),
  '/erp/stock-transfers': _ScreenSettings('Stock Transfers', ['org.transfer_alert_skip_admin']),
  '/erp/processor-tracker': _ScreenSettings('Out for Processing', ['org.processor_overdue_reminder']),
  '/erp/inventory-integrity': _ScreenSettings('Inventory Integrity', [],
      ['serious.block_negative_stock', 'serious.block_zero_cost_receipt']),

  // ── Manufacturing ──
  '/manufacturing/job-card': _ScreenSettings('Job Card', [
    'org.job_card_price_restrict', 'org.job_ack_flow', 'org.job_ack_skip_admin',
    'org.ask_labels_after_production', 'org.production_updates_cost_price',
  ]),
  '/manufacturing/production-voucher': _ScreenSettings('Production Voucher', [
    'org.ask_labels_after_production', 'org.production_updates_cost_price',
  ], ['serious.block_negative_stock']),
  '/manufacturing/product-assembly': _ScreenSettings('Product Assembly (BOM)', ['org.bom_supervise_flow']),
  '/manufacturing/quick-costing': _ScreenSettings('Quick Costing', ['org.quick_costing_cost_access']),
  '/manufacturing/qc-station': _ScreenSettings('QC Station', ['feature.qc_station']),

  // ── Financials ──
  '/financials/journal-vouchers': _ScreenSettings('Journal Voucher', [
    'org.jv_supervise_flow', 'org.jv_approve_flow', 'org.jv_void_flow',
  ]),
  '/financials/payment-advice': _ScreenSettings('Payment Advice', [
    'org.pa_approval_enabled', 'org.pa_signatures', 'org.pa_approval_watermark',
  ]),
  '/financials/duplicate-references': _ScreenSettings('Duplicate References', ['org.dupref_supervise_flow']),
  '/erp/receipt-vouchers': _ScreenSettings('Receipt Voucher', ['org.dupref_supervise_flow']),
  '/erp/payment-vouchers': _ScreenSettings('Payment Voucher', ['org.dupref_supervise_flow']),

  // ── Other ──
  '/assets': _ScreenSettings('Assets', [
    'org.asset_supervise_flow', 'org.asset_suggest_flow',
    'org.asset_maintenance_reminder', 'org.asset_custodian_reminder',
  ]),
  '/intelligence/placement': _ScreenSettings('Placement Audit', _intelKeys),
  '/intelligence/dashboard': _ScreenSettings('Intelligence', ['org.intel_autopilot']),
  '/intelligence/score-distribution': _ScreenSettings('Score Distribution', ['org.intel_autopilot']),
  '/products': _ScreenSettings('Intelligence Products', ['org.intel_autopilot']),
  '/intelligence/competitors': _ScreenSettings('Competitor Spotting', _intelKeys),
  '/hr/payroll': _ScreenSettings('Payroll', [], ['payroll']),
};

/// Floating gear on the screen (bottom-left): opens this screen's settings. Shown to master
/// admins and admins (who can open Admin Settings), only on screens that have settings.
class ScreenSettingsGear extends ConsumerWidget {
  const ScreenSettingsGear({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same people who can open Admin Settings.
    final role = ref.watch(currentUserProvider)?.role;
    if (role != WebUserRole.masterAdmin && role != WebUserRole.admin && role != WebUserRole.superAdmin) {
      return const SizedBox.shrink();
    }
    String loc;
    try {
      loc = GoRouterState.of(context).matchedLocation;
    } catch (_) {
      return const SizedBox.shrink();
    }
    final cfg = _screenSettings[loc];
    if (cfg == null) return const SizedBox.shrink();
    return Tooltip(
      message: '${cfg.title} settings',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(side: BorderSide(color: AppTheme.border)),
        elevation: 3,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _open(context, cfg),
          child: const SizedBox(
            width: 42,
            height: 42,
            child: Icon(Icons.settings_outlined, color: AppTheme.primary, size: 21),
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, _ScreenSettings cfg) async {
    try {
      await adm.loadLibrary();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open settings. Please try again.')));
      }
      return;
    }
    if (!context.mounted) return;
    final before = adm.adminSettingsChangeTick.value;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: AppTheme.background,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 900, maxHeight: size.height * 0.88),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.settings_outlined, size: 20, color: AppTheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text('${cfg.title} settings',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
                      const SizedBox(height: 2),
                      const Text('The same settings as in Admin Settings. Changes save straight away.',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ]),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ]),
              ),
              if (cfg.page != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Material(
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: const BorderSide(color: AppTheme.border),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.tune, color: AppTheme.primary),
                      title: Text(cfg.page!.$1, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: const Text('Payment methods, print size, receipt and more'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        GoRouter.of(context).go(cfg.page!.$2);
                      },
                    ),
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: adm.ErpAdminSettingsScreen(onlyKeys: cfg.keys, extras: cfg.extras),
                ),
              ),
            ]),
          ),
        );
      },
    );
    if (!context.mounted) return;
    if (adm.adminSettingsChangeTick.value != before) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Settings saved. Reload this screen to apply them here.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: 'Reload', onPressed: () => html.window.location.reload()),
      ));
    }
  }
}
