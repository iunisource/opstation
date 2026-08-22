import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../widgets/signature_stamp_settings.dart';

/// An optional numeric parameter attached to a toggle. Shown (and saved) only
/// while the parent toggle is ON. Stored in `app_config` as a string.
class _NumberField {
  final String key; // app_config key, e.g. 'org.aging_alert_days'
  final String label; // e.g. 'Aging threshold'
  final int defaultValue;
  final String suffix; // e.g. 'days'
  const _NumberField(this.key, this.label, this.defaultValue,
      {this.suffix = ''});
}

/// An optional free-text parameter attached to a toggle (e.g. a recipient
/// email list). Shown (and saved) only while the parent toggle is ON. Stored
/// in `app_config` as a string.
class _TextSetting {
  final String key; // app_config key
  final String label;
  final String hint;
  const _TextSetting(this.key, this.label, {this.hint = ''});
}

/// An optional branch selector attached to a toggle (e.g. "which branch's
/// stock to compare"). Shown (and saved) only while the parent toggle is ON.
/// Stored in `app_config` as the branch id string, or 'all' for all branches.
class _BranchField {
  final String key; // app_config key, e.g. 'org.po_fg_branch_id'
  final String label;
  const _BranchField(this.key, this.label);
}

/// An optional USER multi-select attached to a toggle (e.g. "which users may
/// edit prices"). Shown (and saved) only while the parent toggle is ON.
/// Stored in `app_config` as a comma-separated list of user ids.
class _UsersField {
  final String key; // app_config key, e.g. 'org.sri_price_edit_users'
  final String label;
  const _UsersField(this.key, this.label);
}

/// Definition of a single org-level admin toggle.
/// To add a new setting, append one entry to [_toggles] below — the screen
/// renders, loads, and persists it automatically. Boolean values are stored in
/// `app_config` as 'true'/'false' under [key] (org-scoped, branch_id NULL),
/// matching the existing app_config convention.
class _AdminToggle {
  final String key;
  final String title;
  final String subtitle;
  final _NumberField? number; // optional numeric companion
  final _TextSetting? text; // optional free-text companion
  final _BranchField? branch; // optional branch-picker companion
  final _UsersField? users; // optional user multi-select companion
  final bool defaultOn; // value used when no app_config row exists yet
  const _AdminToggle(this.key, this.title, this.subtitle,
      {this.number, this.text, this.branch, this.users, this.defaultOn = false});
}

const List<_AdminToggle> _toggles = [
  _AdminToggle(
    'org.credit_limit_alert',
    'Credit limit alert on Delivery Order',
    'When a Delivery Order is created for a customer whose outstanding balance '
        'exceeds their credit limit, show an alert with the limit details. '
        'The user can override and proceed.',
  ),
  _AdminToggle(
    'org.aging_alert',
    'Overdue aging alert on Delivery Order',
    'When a Delivery Order is created for a customer with outstanding invoices '
        'aged at or beyond the threshold below, show an alert. The user can '
        'override and proceed. If both this and the credit limit are exceeded, '
        'the popup lists both.',
    number: _NumberField('org.aging_alert_days', 'Aging threshold', 60,
        suffix: 'days'),
  ),

  // ─── Add more org-level toggles here ─────────────────────────────────────
  _AdminToggle(
    'org.quotation_custom_company',
    'Custom company name on quotations',
    'When ON, quotations can print a custom company name (set below) in the '
        'header instead of the real organization name. The quotation print menu '
        'gets a "Show custom company name" toggle to switch it on per quote; it '
        'is mutually exclusive with "Show company name".',
    text: _TextSetting('org.quotation_custom_company_name', 'Custom company name',
        hint: 'e.g. Alfa Trading Co.'),
  ),

  _AdminToggle(
    'org.cbr_collection_columns',
    'Collection columns on Customer Balance Report',
    'Show blank "Receipt #" and "Amount Collected" columns in the Customer '
        'Balance Report print/PDF — for recording collections during a route run.',
  ),

  _AdminToggle(
    'org.si_price_editable',
    'Editable prices on Sales Invoices',
    'When ON, the unit price on a Sales Invoice can be edited before it is saved/posted '
        '(in addition to the discount). When OFF (default), the price is fixed from the '
        'order and only the discount is adjustable.',
  ),

  _AdminToggle(
    'org.sri_price_edit',
    'Restrict price editing on Sales Return Invoices',
    'When ON, only the users selected below can edit unit prices and discounts '
        'on a draft Sales Return Invoice — everyone else sees them read-only. '
        'Admins and master admins can always edit. When OFF (default), any user '
        'can edit prices on a draft SRI.',
    users: _UsersField('org.sri_price_edit_users', 'Users allowed to edit SRI prices'),
  ),

  _AdminToggle(
    'org.po_approval_required',
    'Require approval for Purchase Orders',
    'When ON, a saved Purchase Order stays "Pending approval" until a user with '
        'the "Approve Purchase Order" permission approves it. Only approved POs '
        'appear in the GRN selection. The approval is recorded in the PO audit '
        'trail and shown on the printed PO.',
  ),
  _AdminToggle(
    'org.po_show_stock_consumption',
    'Show stock & 3-month consumption on Purchase Order',
    'On the Purchase Order screen, show each line item\'s current on-hand stock '
        'for the PO branch and its average monthly consumption (sales/issues) over '
        'the last 3 months — to guide ordering quantities.',
  ),
  _AdminToggle(
    'org.po_fg_stock',
    'Show finished-goods stock on Purchase Order',
    'For factory branches buying raw materials: on each PO line, also show the '
        'on-hand stock of the FINISHED product(s) whose BOM uses that raw item — '
        'so you can assess finished availability before re-ordering raw. The '
        'raw-to-finished link comes from your Product Assemblies (BOMs). Choose '
        'below which branch\'s finished stock to compare (e.g. the central '
        'warehouse), or all branches combined.',
    branch: _BranchField('org.po_fg_branch_id', 'Compare finished-goods stock at'),
  ),
  // _AdminToggle('org.some_flag', 'Title shown to admin', 'What it does.'),

  _AdminToggle(
    'org.job_ack_flow',
    'New job alert & acknowledgement (Job Cards)',
    'When ON, a loud buzzer sounds on open Job Card screens whenever a new job '
        'is created, and repeats every 5 minutes (for ~20 seconds) until someone '
        'acknowledges it. Opening the job shows a "Noted" pop-up; the moment any '
        'user clicks Noted, the alert stops for everyone and who acknowledged it '
        '(and when) is recorded in the job\'s audit trail. Adds a "Note & Print" '
        'button that acknowledges and prints in one step.',
  ),
  _AdminToggle(
    'org.job_ack_skip_admin',
    'Skip admins for the new-job buzzer',
    'When ON, admin and master-admin users are NOT interrupted by the new-job '
        'buzzer and banner — the pendency count still shows on their menu so they '
        'can see pending jobs, but the loud alert is left to the floor/operational '
        'users. Only applies when the new-job alert above is ON.',
  ),
  _AdminToggle(
    'org.job_card_price_restrict',
    'Restrict who can see Job Card prices',
    'When ON, Job Card prices — component costs, labour/overhead, totals, and the '
        'priced "Print / PDF" — are shown only to admins and the specific users you '
        'select below. Everyone else still sees the full Job Card and can print the '
        'internal shop-floor copy, just without any costing. When OFF (default), the '
        'existing production-cost report permission governs who sees prices.',
    users: _UsersField('org.job_card_price_users', 'Users allowed to see Job Card prices'),
  ),
  _AdminToggle(
    'org.transfer_alert_skip_admin',
    'Skip admins for the stock-transfer buzzer',
    'When ON, admin and master-admin users are NOT interrupted by the '
        'stock-transfer acceptance buzzer and banner — the pendency count still '
        'shows on their Inventory menu, but the loud alert is left to the branch '
        'users who accept transfers.',
  ),

  _AdminToggle(
    'org.customer_edit_alert',
    'Email alert when a customer is edited',
    'When an existing customer record is edited (not newly created), email the '
        'recipients below a note of who changed which fields on which customer. '
        'A lightweight event-audit notification. Leave recipients blank to send '
        'to no one.',
    text: _TextSetting('org.customer_edit_alert_emails', 'Alert recipients',
        hint: 'Comma- or newline-separated email addresses'),
  ),

  _AdminToggle(
    'org.asset_maintenance_reminder',
    'Email reminders for due asset maintenance',
    'When ON, a daily digest of assets whose next scheduled maintenance is '
        'overdue or falls within the lead time below is emailed to the '
        'recipients. Servicing an asset (which sets its next due date) clears it '
        'from the reminder automatically. Leave recipients blank to send to no one.',
    number: _NumberField(
        'org.asset_maintenance_reminder_days', 'Remind ahead by', 7,
        suffix: 'days'),
    text: _TextSetting(
        'org.asset_maintenance_reminder_emails', 'Reminder recipients',
        hint: 'Comma- or newline-separated email addresses'),
  ),

  _AdminToggle(
    'org.backup_enabled',
    'Daily data backup by email',
    'When ON, a zipped CSV export of all of this organization\'s data (one file '
        'per table) is emailed to the recipients below every night. Leave '
        'recipients blank to send to no one.',
    text: _TextSetting('org.backup_emails', 'Backup recipients',
        hint: 'Comma- or newline-separated email addresses'),
  ),

  _AdminToggle(
    'org.delivery_flow_enabled',
    'Delivery flow for Delivery Orders',
    'When ON, Delivery Orders track delivery separately from invoicing: a DO '
        'can be dispatched, assigned to a driver, and marked Delivered, and '
        'shows two tags (Delivered + Invoiced / Invoice Pending). When OFF, a '
        'DO is considered complete once invoiced — no dispatch needed — and '
        'shows only its billing status.',
  ),

  _AdminToggle(
    'org.customer_targets_enabled',
    'Customer sales targets',
    'When ON, each customer carries a monthly sales target. The target and '
        'this month\'s achievement (from sales invoices) appear on the customer '
        'profile and in CRM 360, routes show accumulated targets, and the '
        'Performance section becomes available. When OFF, targets are hidden '
        'everywhere.',
  ),

  _AdminToggle(
    'org.pri_price_editable',
    'Editable price on Purchase Return Invoices',
    'When ON, users can type any unit price on a Purchase Return Invoice. When '
        'OFF (default), the price is frozen to each product\'s Cost Price and '
        'the return value is adjusted only through Discount. Either way a zero '
        'price is never allowed — value is reduced via Discount, not a zero '
        'price. Admins and master admins can always edit the price regardless '
        'of this setting.',
  ),

  _AdminToggle(
    'org.pi_updates_cost_price',
    'Update product Cost Price from Purchase Invoices',
    'When ON, saving a Purchase Invoice updates each line item\'s product Cost '
        'Price in the product profile to the invoiced unit cost — keeping costs '
        'current and Purchase Return pricing accurate. Only non-zero costs are '
        'written, and only products on the invoice are touched. When OFF, Cost '
        'Price is left unchanged.',
  ),

  _AdminToggle(
    'org.foc_enabled',
    'Free-of-Cost (FOC) items on Sales Orders',
    'When ON, a separate "Free of Cost Items" section appears on the Sales Order '
        'screen. FOC lines ship to the customer at zero price (they add nothing to '
        'the invoice value — only item and quantity appear on the SO, DO and '
        'Invoice) but are still consumed at cost, so COGS is booked normally. The '
        'same product may appear once in the paid section and once in the FOC '
        'section. When OFF, the FOC section is hidden; any FOC lines already on '
        'existing orders are preserved.',
  ),

  _AdminToggle(
    'org.consignment_enabled',
    'Consignment (client-owned) items',
    'When ON, products can be marked "Client-owned (consignment)" in the product '
        'master. Such items are tracked in stock by quantity only, at zero book '
        'value: purchases post the vendor value to a Consignment Clearing account '
        '(not inventory), they add no cost to production or COGS, and you recover '
        'from the client via a manual journal voucher. When OFF, the consignment '
        'checkbox is hidden; products already flagged keep their behaviour.',
  ),
  _AdminToggle(
    'org.show_product_images',
    'Show product images in the retailer app',
    'When ON, retailers browsing your catalogue see brand logos and product '
        'photos instead of a plain text list. Images are optional per product — '
        'anything without one falls back to the text row, so a partly-filled '
        'catalogue still looks deliberate. Leave this OFF until you have uploaded '
        'enough images to be worth it: switching it on with an empty catalogue '
        'shows a wall of placeholders and makes the app look broken.',
  ),

  _AdminToggle(
    'org.hide_main_groups_by_branch',
    'Hide product groups by branch',
    'When ON, choose per branch which product Main Groups to hide. A product in a '
        'hidden main group does not appear in the Products list while that branch '
        'is selected. Stock, ledgers and reports are unaffected. Set the '
        'branch/group selection in the panel below.',
  ),
  _AdminToggle(
    'org.voucher_dates_editable',
    'Allow editing dates on vouchers',
    'When ON, users can change the document date on Sales Orders, Delivery '
        'Orders, Purchase Orders, GRNs, and Purchase / Sales Invoices instead of '
        'it being fixed to the creation date. Admins can always edit dates.',
  ),

  _AdminToggle(
    'org.srn_date_editable',
    'Allow editing date on Sales Return Notes',
    'When ON, users can change the document date on a Sales Return Note (SRN) '
        'instead of it being fixed to the creation date. Admins can always edit dates.',
  ),
  _AdminToggle(
    'org.show_org_name_sales',
    'Show company name on sale vouchers',
    'When ON (default), your organization name prints in the header of Sales '
        'Orders, Delivery Orders and Sales Invoices. Turn OFF to hide it — e.g. '
        'when printing on pre-printed letterhead. The branch name is unaffected.',
    defaultOn: true,
  ),
  _AdminToggle(
    'org.show_org_name_purchase',
    'Show company name on purchase vouchers',
    'When ON (default), your organization name prints in the header of Purchase '
        'Orders, GRNs and Purchase Invoices. Turn OFF to hide it — e.g. when '
        'printing on pre-printed letterhead. The branch name is unaffected.',
    defaultOn: true,
  ),

  // Support documents & admin review — isolated per invoice type, since each
  // has a different scenario. When ON, that invoice gains a Support Documents
  // panel; saving sends it for review and an admin approves to post (recording
  // signature + stamp). When OFF, that invoice type posts exactly as today.
  _AdminToggle(
    'org.doc_review_flow_si',
    'Support docs & admin review — Sales Invoices',
    'Applies only to Sales Invoices. Independent of the other invoice types.',
  ),
  _AdminToggle(
    'org.doc_review_flow_pi',
    'Support docs & admin review — Purchase Invoices',
    'Applies only to Purchase Invoices. Independent of the other invoice types.',
  ),
  _AdminToggle(
    'org.doc_review_flow_pri',
    'Support docs & admin review — Purchase Return Invoices',
    'Applies only to Purchase Return Invoices. Independent of the other invoice types.',
  ),

  _AdminToggle(
    'feature.qc_station',
    'QC Station — tap-to-print QC labels',
    'When ON, Manufacturing → QC Station becomes available: on a shop-floor tablet an '
        'operator picks a job, taps their RFID card, and taps a QC checkpoint to instantly '
        'print a 2"x1" QC label (checkpoint, spec, job, product, operator, time). Checkpoints '
        'are defined per product/BOM under QC Checkpoints. When OFF, the station shows a '
        'disabled notice and nothing about the job card / batch-post flow changes.',
  ),

  _AdminToggle(
    'org.grn_supervise_flow',
    'Supervision, documents & comments on GRNs',
    'When ON, Goods Receipt Notes gain a Support Documents panel (attach images / '
        'PDFs, e.g. the supplier delivery challan) and an Internal Remarks trail, and '
        'admins get a "Supervise" action as an extra review layer. Supervision is '
        'NON-BLOCKING: a GRN still confirms and moves stock exactly as before whether '
        'or not it has been supervised — it only records that an admin checked it. '
        'GRN files are kept in a separate storage bucket from the invoice documents. '
        'When OFF, GRNs behave exactly as today.',
  ),

  _AdminToggle(
    'org.customer_supervise_flow',
    'Supervision for new customers',
    'When ON, every newly-created customer must be "Supervised" by an admin or '
        'master admin. A pendency counter on the Sales → Customers menu shows how '
        'many customers are still awaiting supervision, and clears as each is '
        'supervised. Existing customers were auto-supervised, so only customers '
        'created from now on appear. Supervision is non-blocking — the customer '
        'can still be used for orders while pending. When OFF, no counter shows.',
  ),

  _AdminToggle(
    'org.product_supervise_flow',
    'Supervision for new products',
    'When ON, every newly-created product must be "Supervised" by an admin or '
        'master admin. A pendency counter on the Inventory → Products menu shows '
        'how many products are still awaiting supervision, and clears as each is '
        'supervised. Existing products were auto-supervised, so only products '
        'created from now on appear. Supervision is non-blocking — the product '
        'can still be used while pending. When OFF, no counter shows.',
  ),

  _AdminToggle(
    'org.station_master_enabled',
    'Station Master assistant',
    'When ON, a "Station Master" helper bubble appears for everyone in this '
        'org. Users can ask plain-language questions about their own data — '
        'stock of a product, a customer\'s balance, today\'s sales or '
        'collection, what\'s pending approval, or where a voucher is. It only '
        'answers from the areas each user is already allowed to see, and only '
        'about system data — nothing general. When OFF, the bubble is hidden.',
  ),
];

/// A module-wise grouping of the flat [_toggles] list, so Admin Settings reads
/// as organised sections instead of one long wall of switches. Each toggle key
/// appears in exactly one group; any key not listed here falls into "Other".
class _ToggleGroup {
  final String title;
  final IconData icon;
  final List<String> keys;
  const _ToggleGroup(this.title, this.icon, this.keys);
}

const List<_ToggleGroup> _toggleGroupsOrder = [
  _ToggleGroup('Sales & Customers', Icons.storefront_outlined, [
    'org.credit_limit_alert',
    'org.aging_alert',
    'org.si_price_editable',
    'org.delivery_flow_enabled',
    'org.foc_enabled',
    'org.customer_targets_enabled',
    'org.srn_date_editable',
    'org.doc_review_flow_si',
    'org.customer_supervise_flow',
    'org.customer_edit_alert',
    'org.quotation_custom_company',
    'org.cbr_collection_columns',
    'org.show_product_images',
  ]),
  _ToggleGroup('Purchase & GRN', Icons.shopping_cart_outlined, [
    'org.po_approval_required',
    'org.po_show_stock_consumption',
    'org.po_fg_stock',
    'org.pi_updates_cost_price',
    'org.pri_price_editable',
    'org.doc_review_flow_pi',
    'org.doc_review_flow_pri',
    'org.grn_supervise_flow',
  ]),
  _ToggleGroup('Manufacturing', Icons.precision_manufacturing_outlined, [
    'org.job_card_price_restrict',
    'org.job_ack_flow',
    'org.job_ack_skip_admin',
    'feature.qc_station',
  ]),
  _ToggleGroup('Inventory & Products', Icons.inventory_2_outlined, [
    'org.transfer_alert_skip_admin',
    'org.consignment_enabled',
    'org.hide_main_groups_by_branch',
    'org.product_supervise_flow',
  ]),
  _ToggleGroup('Documents & Printing', Icons.description_outlined, [
    'org.show_org_name_sales',
    'org.show_org_name_purchase',
    'org.voucher_dates_editable',
  ]),
  _ToggleGroup('Alerts, Data & Assets', Icons.notifications_active_outlined, [
    'org.asset_maintenance_reminder',
    'org.backup_enabled',
  ]),
  _ToggleGroup('Assistant', Icons.hub_outlined, [
    'org.station_master_enabled',
  ]),
];

class ErpAdminSettingsScreen extends ConsumerStatefulWidget {
  const ErpAdminSettingsScreen({super.key});

  @override
  ConsumerState<ErpAdminSettingsScreen> createState() =>
      _ErpAdminSettingsScreenState();
}

class _ErpAdminSettingsScreenState
    extends ConsumerState<ErpAdminSettingsScreen> {
  final Map<String, bool> _values = {};
  final Map<String, TextEditingController> _numCtrls = {};
  final Map<String, TextEditingController> _textCtrls = {};
  final Map<String, String> _branchValues = {}; // branch-picker companions ('all' or branch id)
  final Map<String, Set<String>> _userValues = {}; // user multi-select companions
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _orgUsers = [];
  final Set<String> _saving = {};
  bool _loading = true;
  bool _backupRunning = false;
  // UI: search + collapsible sections.
  final TextEditingController _searchCtrl = TextEditingController();
  String _search = '';
  final Set<String> _collapsedGroups = {}; // section titles currently collapsed
  bool _blockNegStock = false; // inventory_settings.block_negative_stock (Serious Zone)
  bool _blockZeroCostReceipt = false; // inventory_settings.block_zero_cost_receipt (Serious Zone)
  bool _savingSerious = false;
  bool _savingSerious2 = false;

  @override
  void initState() {
    super.initState();
    for (final t in _toggles) {
      if (t.number != null) {
        _numCtrls[t.number!.key] =
            TextEditingController(text: t.number!.defaultValue.toString());
      }
      if (t.text != null) {
        _textCtrls[t.text!.key] = TextEditingController();
      }
    }
    // Start with every section collapsed — a clean overview the admin can
    // expand into, instead of one long wall of switches.
    _collapsedGroups.addAll([for (final g in _toggleGroupsOrder) g.title]);
    _collapsedGroups.add('Other');
    _load();
  }

  @override
  void dispose() {
    for (final c in _numCtrls.values) {
      c.dispose();
    }
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId);
      final cfg = <String, String>{};
      for (final r in rows as List) {
        cfg[r['key'] as String] = r['value'] as String? ?? '';
      }
      // Branch roster for any branch-picker companions.
      List<Map<String, dynamic>> branches = [];
      try {
        branches = List<Map<String, dynamic>>.from(await Supabase.instance.client
            .from('branches')
            .select('id, name')
            .eq('org_id', orgId)
            .order('name'));
      } catch (_) {}
      // User roster for any user multi-select companions.
      List<Map<String, dynamic>> orgUsers = [];
      try {
        orgUsers = List<Map<String, dynamic>>.from(await Supabase.instance.client
            .from('users')
            .select('id, name, role')
            .eq('org_id', orgId)
            .order('name'));
      } catch (_) {}
      // Serious Zone: negative-stock guard lives on inventory_settings.
      bool blockNeg = false;
      bool blockZeroCost = false;
      try {
        final invs = await Supabase.instance.client
            .from('inventory_settings')
            .select('block_negative_stock, block_zero_cost_receipt')
            .eq('org_id', orgId)
            .maybeSingle();
        blockNeg = (invs?['block_negative_stock'] as bool?) ?? false;
        blockZeroCost = (invs?['block_zero_cost_receipt'] as bool?) ?? false;
      } catch (_) {}
      setState(() {
        _branches = branches;
        _orgUsers = orgUsers;
        _blockNegStock = blockNeg;
        _blockZeroCostReceipt = blockZeroCost;
        for (final t in _toggles) {
          _values[t.key] =
              cfg.containsKey(t.key) ? cfg[t.key] == 'true' : t.defaultOn;
          final n = t.number;
          if (n != null) {
            final stored = cfg[n.key];
            if (stored != null && stored.trim().isNotEmpty) {
              _numCtrls[n.key]!.text = stored.trim();
            }
          }
          final tx = t.text;
          if (tx != null) {
            final storedT = cfg[tx.key];
            if (storedT != null) {
              _textCtrls[tx.key]!.text = storedT;
            }
          }
          final b = t.branch;
          if (b != null) {
            final storedB = cfg[b.key]?.trim();
            // Fall back to 'all' if unset or the stored branch no longer exists.
            final valid = storedB != null &&
                (storedB == 'all' ||
                    branches.any((br) => br['id'] == storedB));
            _branchValues[b.key] = valid ? storedB : 'all';
          }
          final u = t.users;
          if (u != null) {
            final storedU = cfg[u.key]?.trim() ?? '';
            _userValues[u.key] = storedU.isEmpty
                ? <String>{}
                : storedU
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toSet();
          }
        }
        _loading = false;
      });
    } catch (_) {
      setState(() {
        for (final t in _toggles) {
          _values[t.key] = false;
        }
        _loading = false;
      });
    }
  }

  Future<void> _persist(String key, String value) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    await Supabase.instance.client.from('app_config').upsert({
      'key': key,
      'value': value,
      'org_id': orgId,
    }, onConflict: 'key,org_id,branch_id');
  }

  Future<void> _setSeriousFlag(String column, bool v) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final neg = column == 'block_negative_stock';
    setState(() {
      if (neg) { _blockNegStock = v; _savingSerious = true; }
      else { _blockZeroCostReceipt = v; _savingSerious2 = true; }
    });
    try {
      await Supabase.instance.client
          .from('inventory_settings')
          .update({column: v}).eq('org_id', orgId);
    } catch (e) {
      if (!mounted) return;
      setState(() { if (neg) _blockNegStock = !v; else _blockZeroCostReceipt = !v; });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() { if (neg) _savingSerious = false; else _savingSerious2 = false; });
    }
  }

  Widget _seriousToggle(String title, String subtitle, bool value, bool saving,
      ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(subtitle,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
            const SizedBox(height: 8),
          ]),
        ),
        const SizedBox(width: 16),
        if (saving)
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Switch(value: value, activeColor: AppTheme.danger, onChanged: onChanged),
      ]),
    );
  }

  Widget _seriousZone() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: AppTheme.danger),
            const SizedBox(width: 8),
            Text('SERIOUS ZONE',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800,
                    color: AppTheme.danger, letterSpacing: 0.6)),
          ]),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.danger.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.danger.withOpacity(0.35)),
          ),
          child: Column(children: [
            _seriousToggle(
              'Block negative stock',
              'When ON, the system refuses any sale, issue, or production that would '
              'drive a product below zero stock at a branch — it asks you to post the '
              'receipt first. This prevents the negative cost layers that corrupt '
              'inventory valuation. Turn this on only AFTER cleaning up existing '
              'negative stock (Inventory Integrity), otherwise day-to-day postings '
              'that rely on overselling will be blocked.',
              _blockNegStock, _savingSerious,
              (v) => _setSeriousFlag('block_negative_stock', v),
            ),
            const Divider(height: 1, color: AppTheme.border),
            _seriousToggle(
              'Block zero-cost receipts (GRN)',
              'When ON, a Goods Receipt refuses any non-consignment line that has no '
              'unit cost on the purchase order or the product — the buyer must enter a '
              'cost before receiving. This stops zero-cost inventory layers at the '
              'source, which are what corrupt product valuation and production costing. '
              'Consignment items are exempt.',
              _blockZeroCostReceipt, _savingSerious2,
              (v) => _setSeriousFlag('block_zero_cost_receipt', v),
            ),
          ]),
        ),
        const SizedBox(height: 18),
      ]),
    );
  }

  Future<void> _backupNow() async {
    setState(() => _backupRunning = true);
    try {
      final res = await Supabase.instance.client.functions.invoke('daily-backup');
      final data = res.data;
      final ok = res.status == 200 && data is Map && data['ok'] == true;
      String msg;
      if (ok) {
        final results = (data['results'] as List?) ?? [];
        if (results.isEmpty) {
          msg = 'No recipients set — add a backup email above and try again.';
        } else {
          final r = results.first as Map;
          switch (r['status']) {
            case 'sent':
              msg = 'Backup emailed — ${r['tables']} tables, ${r['mb']} MB, to ${r['recipients']} recipient(s).';
              break;
            case 'too_large':
              msg = 'Backup built but too large to email (${r['mb']} MB).';
              break;
            default:
              msg = 'Backup skipped — check the recipients above.';
          }
        }
      } else {
        final err = (data is Map ? data['error'] : null) ?? 'status ${res.status}';
        msg = 'Backup failed: $err';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _backupRunning = false);
    }
  }

  Future<void> _setToggle(String key, bool val) async {
    setState(() {
      _values[key] = val;
      _saving.add(key);
    });
    try {
      await _persist(key, val.toString());
    } catch (e) {
      if (mounted) {
        setState(() => _values[key] = !val); // revert on failure
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  Future<void> _saveNumber(_NumberField n) async {
    final raw = _numCtrls[n.key]!.text.trim();
    final parsed = int.tryParse(raw);
    final clean = (parsed == null || parsed < 0) ? n.defaultValue : parsed;
    // Normalize the field to the cleaned value.
    if (_numCtrls[n.key]!.text != clean.toString()) {
      _numCtrls[n.key]!.text = clean.toString();
    }
    setState(() => _saving.add(n.key));
    try {
      await _persist(n.key, clean.toString());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(n.key));
    }
  }

  Widget _numberRow(_NumberField n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Row(
        children: [
          Text(n.label,
              style: const TextStyle(
                  fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(width: 12),
          SizedBox(
            width: 90,
            child: TextField(
              controller: _numCtrls[n.key],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _saveNumber(n),
              onTapOutside: (_) {
                FocusManager.instance.primaryFocus?.unfocus();
                _saveNumber(n);
              },
            ),
          ),
          if (n.suffix.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(n.suffix,
                style: const TextStyle(
                    fontSize: 12.5, color: AppTheme.textSecondary)),
          ],
          if (_saving.contains(n.key)) ...[
            const SizedBox(width: 10),
            const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ],
      ),
    );
  }

  Future<void> _saveText(_TextSetting t) async {
    final val = _textCtrls[t.key]!.text.trim();
    setState(() => _saving.add(t.key));
    try {
      await _persist(t.key, val);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(t.key));
    }
  }

  Widget _textRow(_TextSetting t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(t.label,
                style: const TextStyle(
                    fontSize: 12.5, color: AppTheme.textSecondary)),
            if (_saving.contains(t.key)) ...[
              const SizedBox(width: 10),
              const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          const SizedBox(height: 6),
          TextField(
            controller: _textCtrls[t.key],
            maxLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: t.hint,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _saveText(t),
            onTapOutside: (_) {
              FocusManager.instance.primaryFocus?.unfocus();
              _saveText(t);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _saveBranch(_BranchField b, String value) async {
    final old = _branchValues[b.key] ?? 'all';
    setState(() {
      _branchValues[b.key] = value;
      _saving.add(b.key);
    });
    try {
      await _persist(b.key, value);
    } catch (e) {
      if (mounted) {
        setState(() => _branchValues[b.key] = old); // revert on failure
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(b.key));
    }
  }

  Widget _branchRow(_BranchField b) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(
              child: Text(b.label,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppTheme.textSecondary)),
            ),
            if (_saving.contains(b.key)) ...[
              const SizedBox(width: 10),
              const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _branchValues[b.key] ?? 'all',
            isExpanded: true,
            style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(
                  value: 'all', child: Text('All branches (combined)')),
              for (final br in _branches)
                DropdownMenuItem(
                    value: br['id'] as String, child: Text('${br['name']}')),
            ],
            onChanged: (v) {
              if (v != null) _saveBranch(b, v);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _saveUsers(_UsersField u, Set<String> ids) async {
    final old = Set<String>.from(_userValues[u.key] ?? {});
    setState(() {
      _userValues[u.key] = ids;
      _saving.add(u.key);
    });
    try {
      await _persist(u.key, ids.join(','));
    } catch (e) {
      if (mounted) {
        setState(() => _userValues[u.key] = old);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(u.key));
    }
  }

  Future<void> _pickUsers(_UsersField u) async {
    final sel = Set<String>.from(_userValues[u.key] ?? {});
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) {
        final searchCtrl = TextEditingController();
        return StatefulBuilder(builder: (ctx, setD) {
          final q = searchCtrl.text.trim().toLowerCase();
          final matches = q.isEmpty
              ? _orgUsers
              : _orgUsers
                  .where((us) =>
                      ((us['name'] as String? ?? '').toLowerCase().contains(q)))
                  .toList();
          return AlertDialog(
            title: Text(u.label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            content: SizedBox(
              width: 380,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: searchCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                          hintText: 'Search user...',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          border: OutlineInputBorder()),
                      onChanged: (_) => setD(() {}),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView(shrinkWrap: true, children: [
                          for (final us in matches)
                            CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(us['name'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13.5)),
                              subtitle: Text('${us['role'] ?? ''}',
                                  style: const TextStyle(fontSize: 11)),
                              value: sel.contains(us['id']),
                              onChanged: (v) => setD(() {
                                if (v == true) {
                                  sel.add(us['id'] as String);
                                } else {
                                  sel.remove(us['id']);
                                }
                              }),
                            ),
                          if (matches.isEmpty)
                            const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text('No matches.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 13, color: Colors.grey))),
                        ]),
                      ),
                    ),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, sel),
                  child: Text('Apply (${sel.length})')),
            ],
          );
        });
      },
    );
    if (picked != null) _saveUsers(u, picked);
  }

  Widget _usersRow(_UsersField u) {
    final sel = _userValues[u.key] ?? <String>{};
    final names = [
      for (final us in _orgUsers)
        if (sel.contains(us['id'])) (us['name'] as String? ?? '-')
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Flexible(
            child: Text(u.label,
                style: const TextStyle(
                    fontSize: 12.5, color: AppTheme.textSecondary)),
          ),
          if (_saving.contains(u.key)) ...[
            const SizedBox(width: 10),
            const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Text(
            names.isEmpty ? 'No users selected — nobody can edit' : names.join(', '),
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: names.isEmpty ? Colors.orange : AppTheme.textPrimary),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          icon: const Icon(Icons.group_outlined, size: 16),
          label: Text(sel.isEmpty ? 'Select users' : 'Edit (${sel.length})'),
          onPressed: () => _pickUsers(u),
        ),
        ]),
      ],
    ));
  }

  // A single toggle rendered as a self-contained card (for the grid layout).
  // Header: title + description on the left, switch on the right. When ON, any
  // companion field (number / text / branch / users) drops in below a divider.
  Widget _toggleCard(_AdminToggle t) {
    final on = _values[t.key] ?? false;
    final hasCompanion =
        on && (t.number != null || t.text != null || t.branch != null || t.users != null);
    return Container(
      decoration: BoxDecoration(
        color: on ? AppTheme.primary.withOpacity(0.045) : Colors.white,
        border: Border.all(
            color: on ? AppTheme.primary.withOpacity(0.35) : AppTheme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              height: 1.25)),
                      const SizedBox(height: 5),
                      Text(t.subtitle,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.textSecondary,
                              height: 1.35)),
                    ]),
              ),
              const SizedBox(width: 4),
              if (_saving.contains(t.key))
                const Padding(
                  padding: EdgeInsets.only(top: 4, right: 8, left: 4),
                  child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                Transform.scale(
                  scale: 0.9,
                  child: Switch(
                    value: on,
                    activeColor: AppTheme.primary,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => _setToggle(t.key, v),
                  ),
                ),
            ]),
          ),
          if (hasCompanion) ...[
            const Divider(height: 1, color: AppTheme.border),
            const SizedBox(height: 12),
            if (t.number != null) _numberRow(t.number!),
            if (t.text != null) _textRow(t.text!),
            if (t.branch != null) _branchRow(t.branch!),
            if (t.users != null) _usersRow(t.users!),
          ],
        ],
      ),
    );
  }

  // The full set of toggles, rendered as module-wise sections. Each section is
  // a collapsible card with an icon, a count of enabled settings, and a chevron.
  // A search box filters toggles by title/description across all sections and
  // auto-expands the matches. Order follows [_toggleGroupsOrder]; any toggle not
  // assigned to a group is collected into a trailing "Other" card.
  List<Widget> _buildGroupedToggles() {
    final byKey = {for (final t in _toggles) t.key: t};
    final assigned = <String>{};
    final q = _search.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final out = <Widget>[];

    bool matches(_AdminToggle t) =>
        q.isEmpty ||
        t.title.toLowerCase().contains(q) ||
        t.subtitle.toLowerCase().contains(q);

    void section(String title, IconData icon, List<_AdminToggle> allItems) {
      final items = allItems.where(matches).toList();
      if (items.isEmpty) return;
      final enabled = items.where((t) => _values[t.key] ?? false).length;
      // While searching, everything is force-expanded to reveal matches.
      final collapsed = !searching && _collapsedGroups.contains(title);
      out.add(_sectionCard(title, icon, items, enabled, collapsed));
      out.add(const SizedBox(height: 14));
    }

    for (final g in _toggleGroupsOrder) {
      final items = <_AdminToggle>[];
      for (final k in g.keys) {
        final t = byKey[k];
        if (t != null) {
          items.add(t);
          assigned.add(k);
        }
      }
      section(g.title, g.icon, items);
    }
    final leftover = [
      for (final t in _toggles)
        if (!assigned.contains(t.key)) t
    ];
    section('Other', Icons.tune, leftover);

    if (out.isEmpty && searching) {
      out.add(Container(
        constraints: const BoxConstraints(maxWidth: 1040),
        padding: const EdgeInsets.symmetric(vertical: 48),
        alignment: Alignment.center,
        child: Column(children: [
          Icon(Icons.search_off,
              size: 40, color: AppTheme.textSecondary.withOpacity(0.4)),
          const SizedBox(height: 10),
          Text('No settings match "$_search"',
              style: const TextStyle(
                  fontSize: 13.5, color: AppTheme.textSecondary)),
        ]),
      ));
    }
    return out;
  }

  // A single collapsible section card.
  Widget _sectionCard(String title, IconData icon, List<_AdminToggle> items,
      int enabled, bool collapsed) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 1040),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() {
            if (_collapsedGroups.contains(title)) {
              _collapsedGroups.remove(title);
            } else {
              _collapsedGroups.add(title);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
            child: Row(children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 20, color: AppTheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                          '${items.length} setting${items.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppTheme.textSecondary)),
                    ]),
              ),
              if (enabled > 0)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('$enabled on',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primary)),
                ),
              AnimatedRotation(
                turns: collapsed ? 0 : 0.5,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more,
                    color: AppTheme.textSecondary),
              ),
            ]),
          ),
        ),
        if (!collapsed) ...[
          const Divider(height: 1, color: AppTheme.border),
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(builder: (ctx, c) {
              const spacing = 12.0;
              final cols = c.maxWidth >= 640 ? 2 : 1;
              final itemW = cols == 1
                  ? c.maxWidth
                  : ((c.maxWidth - spacing * (cols - 1)) / cols) - 0.5;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final t in items)
                    SizedBox(width: itemW, child: _toggleCard(t)),
                ],
              );
            }),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppTheme.primary,
                            AppTheme.primary.withOpacity(0.68)
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.tune, color: Colors.white, size: 24),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Admin Settings',
                                style: TextStyle(
                                    fontSize: 24, fontWeight: FontWeight.w800)),
                            SizedBox(height: 2),
                            Text(
                                'Organization-wide controls. Changes apply to all branches and save immediately.',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: AppTheme.textSecondary)),
                          ]),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  // Search
                  Container(
                    constraints: const BoxConstraints(maxWidth: 1040),
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        hintText: 'Search settings…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _search = '');
                                },
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 14),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: AppTheme.border)),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                const BorderSide(color: AppTheme.border)),
                        focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                                color: AppTheme.primary, width: 1.5)),
                      ),
                    ),
                  ),
                  if (_search.isEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      constraints: const BoxConstraints(maxWidth: 1040),
                      child: Row(children: [
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _collapsedGroups.clear()),
                          icon: const Icon(Icons.unfold_more, size: 16),
                          label: const Text('Expand all',
                              style: TextStyle(fontSize: 12.5)),
                          style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap),
                        ),
                        const SizedBox(width: 6),
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _collapsedGroups.addAll(
                                [for (final g in _toggleGroupsOrder) g.title]);
                            _collapsedGroups.add('Other');
                          }),
                          icon: const Icon(Icons.unfold_less, size: 16),
                          label: const Text('Collapse all',
                              style: TextStyle(fontSize: 12.5)),
                          style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap),
                        ),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ..._buildGroupedToggles(),
                  // The panels below are not part of the toggle list — hide them
                  // while a search is active so results stay focused.
                  if (_search.isEmpty) ...[
                  if (ref.read(currentUserProvider)?.role ==
                          WebUserRole.masterAdmin ||
                      ref.read(currentUserProvider)?.role ==
                          WebUserRole.superAdmin) ...[
                    const SizedBox(height: 16),
                    _FiscalYearPanel(
                        orgId: ref.read(currentUserProvider)?.orgId ?? ''),
                    const SizedBox(height: 16),
                    _DashboardPasswordPanel(
                        orgId: ref.read(currentUserProvider)?.orgId ?? ''),
                  ],
                  const SizedBox(height: 16),
                  SignatureStampSettings(
                    orgId: ref.read(currentUserProvider)?.orgId ?? '',
                    userId: ref.read(currentUserProvider)?.id,
                  ),
                  const SizedBox(height: 16),
                  _FooterNotesPanel(
                      orgId: ref.read(currentUserProvider)?.orgId ?? ''),
                  if (_values['org.hide_main_groups_by_branch'] ?? false) ...[
                    const SizedBox(height: 16),
                    _HiddenGroupsPanel(
                        orgId: ref.read(currentUserProvider)?.orgId ?? ''),
                  ],
                  if (_values['org.backup_enabled'] ?? false) ...[
                    const SizedBox(height: 16),
                    Container(
                      constraints: const BoxConstraints(maxWidth: 760),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Run a backup now',
                                    style: TextStyle(
                                        fontSize: 14, fontWeight: FontWeight.w600)),
                                SizedBox(height: 4),
                                Text(
                                    'Email a zipped CSV export of all data to the recipients above, right now.',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: AppTheme.textSecondary,
                                        height: 1.35)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          ElevatedButton.icon(
                            onPressed: _backupRunning ? null : _backupNow,
                            icon: _backupRunning
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.backup_outlined, size: 18),
                            label: Text(_backupRunning ? 'Sending…' : 'Back up now'),
                            style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _seriousZone(),
                  ], // end: panels hidden while searching
                ],
              ),
            ),
    );
  }
}


/// Master-admin-only Fiscal Year card. Lets you set the org's fiscal-year start
/// month (app_config org.fiscal_year_start_month) and close / reopen the books
/// through a date (calls close_fiscal_year / reopen_books, which are themselves
/// server-side gated to master admins). Once closed, no journal entry can be
/// posted or edited with a date inside the locked period. Old records stay fully
/// reportable — this only prevents back-posting into a finalised year.
class _FiscalYearPanel extends StatefulWidget {
  final String orgId;
  const _FiscalYearPanel({required this.orgId});
  @override
  State<_FiscalYearPanel> createState() => _FiscalYearPanelState();
}

class _FiscalYearPanelState extends State<_FiscalYearPanel> {
  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  int _startMonth = 1; // 1..12
  DateTime? _closedThrough; // null = nothing closed
  bool _loading = true;
  bool _savingMonth = false;
  bool _busy = false; // close/reopen in flight

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.orgId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', widget.orgId)
          .inFilter('key',
              ['org.fiscal_year_start_month', 'org.books_closed_through']);
      int month = 1;
      DateTime? closed;
      for (final r in rows as List) {
        final k = r['key'] as String;
        final v = (r['value'] as String?)?.trim() ?? '';
        if (k == 'org.fiscal_year_start_month') {
          final m = int.tryParse(v);
          if (m != null && m >= 1 && m <= 12) month = m;
        } else if (k == 'org.books_closed_through') {
          closed = DateTime.tryParse(v);
        }
      }
      if (mounted) {
        setState(() {
          _startMonth = month;
          _closedThrough = closed;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Fiscal-year window that contains "today", per the start month.
  ({DateTime start, DateTime end}) _currentFy() {
    final now = DateTime.now();
    final startYear =
        now.month >= _startMonth ? now.year : now.year - 1;
    final start = DateTime(startYear, _startMonth, 1);
    final end = DateTime(startYear + 1, _startMonth, 1)
        .subtract(const Duration(days: 1));
    return (start: start, end: end);
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1].substring(0, 3)} ${d.year}';

  Future<void> _saveMonth(int m) async {
    setState(() {
      _startMonth = m;
      _savingMonth = true;
    });
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': 'org.fiscal_year_start_month',
        'value': m.toString(),
        'org_id': widget.orgId,
      }, onConflict: 'key,org_id,branch_id');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingMonth = false);
    }
  }

  Future<void> _closeYear() async {
    final fy = _currentFy();
    // Default the picker to this fiscal year's last day.
    final picked = await showDatePicker(
      context: context,
      initialDate: fy.end,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Close the books through this date',
    );
    if (picked == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close the books?'),
        content: Text(
            'No journal entry dated on or before ${_fmt(picked)} will be postable or editable after this. '
            'You can reopen the period later if you need to. Old records stay fully reportable.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white),
              child: const Text('Close year')),
        ],
      ),
    );
    if (ok != true) return;
    await _runRpc('close_fiscal_year', {
      'p_org': widget.orgId,
      'p_through':
          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}',
    });
  }

  Future<void> _reopen() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reopen the books?'),
        content: const Text(
            'This clears the period lock, allowing entries to be posted into the previously closed period again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Reopen')),
        ],
      ),
    );
    if (ok != true) return;
    // p_through omitted / null -> clears the lock entirely.
    await _runRpc('reopen_books', {'p_org': widget.orgId});
  }

  Future<void> _runRpc(String fn, Map<String, dynamic> params) async {
    setState(() => _busy = true);
    try {
      final res =
          await Supabase.instance.client.rpc(fn, params: params);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(res?.toString() ?? 'Done')));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fy = _currentFy();
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: _loading
          ? const Center(
              child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.event_available_outlined,
                      size: 18, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  const Text('Fiscal Year',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(5)),
                    child: const Text('Master admin',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary)),
                  ),
                ]),
                const SizedBox(height: 4),
                const Text(
                    'Set when your financial year begins, and close a year to lock it against back-posting. '
                    'Closing keeps all old records fully reportable.',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.textSecondary,
                        height: 1.35)),
                const SizedBox(height: 16),

                // Start month
                Row(children: [
                  const SizedBox(
                      width: 150,
                      child: Text('Financial year starts',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600))),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: _startMonth,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (int m = 1; m <= 12; m++)
                        DropdownMenuItem(
                            value: m,
                            child: Text(_months[m - 1],
                                style: const TextStyle(fontSize: 13))),
                    ],
                    onChanged: _savingMonth
                        ? null
                        : (v) {
                            if (v != null) _saveMonth(v);
                          },
                  ),
                  if (_savingMonth) ...[
                    const SizedBox(width: 10),
                    const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ]),
                const SizedBox(height: 6),
                Text(
                    'Current fiscal year: ${_fmt(fy.start)} → ${_fmt(fy.end)}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),

                const Divider(height: 28, color: AppTheme.border),

                // Close status + actions
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Books closed through',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Row(children: [
                            Icon(
                                _closedThrough == null
                                    ? Icons.lock_open_outlined
                                    : Icons.lock_outline,
                                size: 15,
                                color: _closedThrough == null
                                    ? AppTheme.textSecondary
                                    : AppTheme.danger),
                            const SizedBox(width: 6),
                            Text(
                                _closedThrough == null
                                    ? 'Open — nothing locked'
                                    : _fmt(_closedThrough!),
                                style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: _closedThrough == null
                                        ? AppTheme.textSecondary
                                        : AppTheme.danger)),
                          ]),
                        ],
                      ),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    if (_closedThrough != null) ...[
                      OutlinedButton(
                          onPressed: _busy ? null : _reopen,
                          child: const Text('Reopen')),
                      const SizedBox(width: 8),
                    ],
                    ElevatedButton.icon(
                      onPressed: _busy ? null : _closeYear,
                      icon: const Icon(Icons.lock_outline, size: 16),
                      label: const Text('Close year…'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// Custom panel for the 'org.hide_main_groups_by_branch' toggle: pick a branch,
/// tick the Main Groups to hide for it. Rows are stored in
/// branch_hidden_main_groups (org_id, branch_id, main_group).
class _HiddenGroupsPanel extends StatefulWidget {
  final String orgId;
  const _HiddenGroupsPanel({required this.orgId});
  @override
  State<_HiddenGroupsPanel> createState() => _HiddenGroupsPanelState();
}

class _HiddenGroupsPanelState extends State<_HiddenGroupsPanel> {
  List<Map<String, dynamic>> _branches = [];
  List<String> _groups = [];
  final Map<String, Set<String>> _hidden = {}; // branchId -> hidden main_groups
  String? _branchId;
  bool _loading = true;
  final Set<String> _busy = {}; // "branchId|group" keys currently saving

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.orgId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final client = Supabase.instance.client;
    try {
      final branches = await client
          .from('branches')
          .select('id, name')
          .eq('org_id', widget.orgId)
          .eq('is_active', true)
          .order('name');
      final prods = await client
          .from('products')
          .select('product_main_group')
          .eq('org_id', widget.orgId);
      final hidden = await client
          .from('branch_hidden_main_groups')
          .select('branch_id, main_group')
          .eq('org_id', widget.orgId);
      final groups = <String>{};
      for (final pr in prods as List) {
        final g = (pr['product_main_group'] as String?)?.trim();
        if (g != null && g.isNotEmpty) groups.add(g);
      }
      _hidden.clear();
      for (final h in hidden as List) {
        (_hidden[h['branch_id'] as String] ??= <String>{})
            .add(h['main_group'] as String);
      }
      if (!mounted) return;
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
        _groups = groups.toList()..sort();
        _branchId =
            _branches.isNotEmpty ? _branches.first['id'] as String : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _setHidden(String branchId, String group, bool hide) async {
    final k = '$branchId|$group';
    setState(() {
      _busy.add(k);
      if (hide) {
        (_hidden[branchId] ??= <String>{}).add(group);
      } else {
        _hidden[branchId]?.remove(group);
      }
    });
    final client = Supabase.instance.client;
    try {
      if (hide) {
        await client.from('branch_hidden_main_groups').upsert({
          'org_id': widget.orgId,
          'branch_id': branchId,
          'main_group': group,
        }, onConflict: 'org_id,branch_id,main_group');
      } else {
        await client
            .from('branch_hidden_main_groups')
            .delete()
            .eq('org_id', widget.orgId)
            .eq('branch_id', branchId)
            .eq('main_group', group);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (hide) {
            _hidden[branchId]?.remove(group);
          } else {
            (_hidden[branchId] ??= <String>{}).add(group);
          }
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(k));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = _branchId == null
        ? const <String>{}
        : (_hidden[_branchId] ?? const <String>{});
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Hidden product groups by branch',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'Pick a branch, then tick the Main Groups to hide from the Products '
            'list while that branch is selected.',
            style: TextStyle(
                fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_branches.isEmpty)
            const Text('No branches found.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))
          else if (_groups.isEmpty)
            const Text('No product main groups found.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))
          else ...[
            Row(
              children: [
                const Text('Branch',
                    style: TextStyle(
                        fontSize: 12.5, color: AppTheme.textSecondary)),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _branchId,
                  onChanged: (v) => setState(() => _branchId = v),
                  items: [
                    for (final b in _branches)
                      DropdownMenuItem(
                        value: b['id'] as String,
                        child: Text(b['name'] as String? ?? '-',
                            style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final g in _groups)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                activeColor: AppTheme.primary,
                title: Text(g, style: const TextStyle(fontSize: 13)),
                secondary: _busy.contains('$_branchId|$g')
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : null,
                value: hidden.contains(g),
                onChanged: _branchId == null
                    ? null
                    : (v) => _setHidden(_branchId!, g, v ?? false),
              ),
          ],
        ],
      ),
    );
  }
}


/// Footer notes for vouchers, moved here from Operations → Settings and split
/// per voucher type. Each field is stored in app_config (org-scoped):
///   Sales Order            → org.footer_note_so
///   Delivery Order         → org.footer_note_do
///   Sales Invoice          → org.footer_note_si
///   Purchase (PO/GRN/PI)   → org.purchase_footer_note
///   Default (fallback)     → org.voucher_footer_note
/// A sales voucher with its own field left blank falls back to the Default
/// note, so existing orgs keep their current footer until they set a specific
/// one. Each field saves on blur / submit.
class _FooterNoteDef {
  final String key;
  final String label;
  final String help;
  const _FooterNoteDef(this.key, this.label, this.help);
}

const List<_FooterNoteDef> _footerNoteDefs = [
  _FooterNoteDef('org.footer_note_so', 'Sales Order footer note',
      'Printed at the bottom of Sales Order PDFs. Leave blank to use the default note below.'),
  _FooterNoteDef('org.footer_note_do', 'Delivery Order footer note',
      'Printed at the bottom of Delivery Order PDFs. Leave blank to use the default note below.'),
  _FooterNoteDef('org.footer_note_si', 'Sales Invoice footer note',
      'Printed at the bottom of Sales Invoice PDFs. Leave blank to use the default note below.'),
  _FooterNoteDef('org.purchase_footer_note', 'Purchase footer note (PO, GRN, PI)',
      'Printed at the bottom of Purchase Order, GRN and Purchase Invoice PDFs.'),
  _FooterNoteDef('org.voucher_footer_note', 'Default footer note',
      'Used for any sales voucher above whose own note is left blank.'),
];

class _FooterNotesPanel extends StatefulWidget {
  final String orgId;
  const _FooterNotesPanel({required this.orgId});
  @override
  State<_FooterNotesPanel> createState() => _FooterNotesPanelState();
}

class _FooterNotesPanelState extends State<_FooterNotesPanel> {
  final Map<String, TextEditingController> _ctrls = {};
  final Set<String> _saving = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    for (final d in _footerNoteDefs) {
      _ctrls[d.key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.orgId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', widget.orgId);
      final cfg = <String, String>{};
      for (final r in rows as List) {
        cfg[r['key'] as String] = r['value'] as String? ?? '';
      }
      if (!mounted) return;
      setState(() {
        for (final d in _footerNoteDefs) {
          _ctrls[d.key]!.text = cfg[d.key] ?? '';
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(_FooterNoteDef d) async {
    if (widget.orgId.isEmpty) return;
    final val = _ctrls[d.key]!.text.trim();
    setState(() => _saving.add(d.key));
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': d.key,
        'value': val,
        'org_id': widget.orgId,
      }, onConflict: 'key,org_id,branch_id');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(d.key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Voucher footer notes',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'Set a footer note per voucher type. Each prints at the bottom of '
            'that voucher\'s PDF. Changes save when you tap outside the box.',
            style: TextStyle(
                fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            for (final d in _footerNoteDefs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(d.label,
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary)),
                      if (_saving.contains(d.key)) ...[
                        const SizedBox(width: 10),
                        const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(d.help,
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textSecondary,
                            height: 1.3)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _ctrls[d.key],
                      maxLines: 2,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _save(d),
                      onTapOutside: (_) {
                        FocusManager.instance.primaryFocus?.unfocus();
                        _save(d);
                      },
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}


/// Dashboard privacy: master admin sets a password that non-master users must
/// enter before dashboard numbers are shown. Deliberately SUBTLE — one quiet
/// row, no big buttons.
class _DashboardPasswordPanel extends StatefulWidget {
  final String orgId;
  const _DashboardPasswordPanel({required this.orgId});
  @override
  State<_DashboardPasswordPanel> createState() => _DashboardPasswordPanelState();
}

class _DashboardPasswordPanelState extends State<_DashboardPasswordPanel> {
  bool _isSet = false;
  bool _loaded = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client.from('app_config')
          .select('value').eq('org_id', widget.orgId)
          .eq('key', 'org.dashboard_password').maybeSingle();
      if (mounted) setState(() { _isSet = ((row?['value'] as String?) ?? '').isNotEmpty; _loaded = true; });
    } catch (_) { if (mounted) setState(() => _loaded = true); }
  }

  Future<void> _edit() async {
    final p1 = TextEditingController();
    final p2 = TextEditingController();
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Text(_isSet ? 'Change dashboard password' : 'Set dashboard password',
            style: const TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Admins and other users will need this password to view the dashboard numbers. You (master admin) always see them.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          TextField(controller: p1, obscureText: true, autofocus: true,
              decoration: const InputDecoration(labelText: 'New password', isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: p2, obscureText: true,
              decoration: InputDecoration(labelText: 'Confirm password', isDense: true,
                  border: const OutlineInputBorder(), errorText: error)),
        ]),
        actions: [
          if (_isSet)
            TextButton(
              onPressed: () => Navigator.pop(ctx, ''),
              child: const Text('Remove protection', style: TextStyle(color: AppTheme.danger, fontSize: 12.5)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (p1.text.length < 4) { setS(() => error = 'At least 4 characters'); return; }
              if (p1.text != p2.text) { setS(() => error = 'Passwords do not match'); return; }
              Navigator.pop(ctx, p1.text);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            child: const Text('Save'),
          ),
        ],
      )),
    );
    if (result == null) return;
    try {
      if (result.isEmpty) {
        await Supabase.instance.client.from('app_config').delete()
            .eq('org_id', widget.orgId).eq('key', 'org.dashboard_password');
      } else {
        final hash = sha256.convert(utf8.encode(result)).toString();
        await Supabase.instance.client.from('app_config').upsert({
          'org_id': widget.orgId, 'key': 'org.dashboard_password', 'value': hash,
        }, onConflict: 'key,org_id,branch_id');
      }
      if (mounted) {
        setState(() => _isSet = result.isNotEmpty);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result.isEmpty ? 'Dashboard protection removed' : 'Dashboard password saved'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save: ' + e.toString().split('\n').first),
          behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Icon(Icons.lock_outline, size: 16, color: AppTheme.textSecondary.withOpacity(0.8)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Dashboard privacy', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              _isSet
                  ? 'Protected — non-master users must enter the password to see dashboard numbers.'
                  : 'Optionally require a password before non-master users can see dashboard numbers.',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: _edit,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(_isSet ? 'Change' : 'Set password',
              style: const TextStyle(fontSize: 12.5, color: AppTheme.primary, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}
