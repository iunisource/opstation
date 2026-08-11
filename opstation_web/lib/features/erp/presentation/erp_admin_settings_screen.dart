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
  final bool defaultOn; // value used when no app_config row exists yet
  const _AdminToggle(this.key, this.title, this.subtitle,
      {this.number, this.text, this.branch, this.defaultOn = false});
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
    'org.job_ack_flow',
    'org.job_ack_skip_admin',
    'feature.qc_station',
  ]),
  _ToggleGroup('Inventory & Products', Icons.inventory_2_outlined, [
    'org.transfer_alert_skip_admin',
    'org.consignment_enabled',
    'org.hide_main_groups_by_branch',
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
  List<Map<String, dynamic>> _branches = [];
  final Set<String> _saving = {};
  bool _loading = true;
  bool _backupRunning = false;

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
      setState(() {
        _branches = branches;
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
      child: Row(children: [
        Text(b.label,
            style:
                const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(width: 12),
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<String>(
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
        ),
        if (_saving.contains(b.key)) ...[
          const SizedBox(width: 10),
          const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ],
      ]),
    );
  }

  // One switch row (+ its optional number/text companion when ON).
  Widget _toggleTile(_AdminToggle t) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SwitchListTile(
        activeColor: AppTheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        title: Row(children: [
          Flexible(
            child: Text(t.title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          if (_saving.contains(t.key)) ...[
            const SizedBox(width: 10),
            const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ]),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.subtitle,
              style: const TextStyle(
                  fontSize: 12.5, color: AppTheme.textSecondary, height: 1.35)),
        ),
        value: _values[t.key] ?? false,
        onChanged: (v) => _setToggle(t.key, v),
      ),
      if (t.number != null && (_values[t.key] ?? false)) _numberRow(t.number!),
      if (t.text != null && (_values[t.key] ?? false)) _textRow(t.text!),
      if (t.branch != null && (_values[t.key] ?? false)) _branchRow(t.branch!),
    ]);
  }

  // The full set of toggles, rendered as module-wise sections (a titled header
  // + a card of switches per group). Order follows [_toggleGroupsOrder]; any
  // toggle not assigned to a group is collected into a trailing "Other" card.
  List<Widget> _buildGroupedToggles() {
    final byKey = {for (final t in _toggles) t.key: t};
    final assigned = <String>{};
    final out = <Widget>[];

    void section(String title, IconData icon, List<_AdminToggle> items) {
      if (items.isEmpty) return;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 8),
        child: Row(children: [
          Icon(icon, size: 16, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text(title.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.primary,
                  letterSpacing: 0.6)),
        ]),
      ));
      out.add(Container(
        constraints: const BoxConstraints(maxWidth: 760),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppTheme.border),
            _toggleTile(items[i]),
          ],
        ]),
      ));
      out.add(const SizedBox(height: 18));
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
    return out;
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
                  const Text('Admin Settings',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(
                    'Organization-wide toggles. Changes apply to all branches and save immediately.',
                    style:
                        TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 20),
                  ..._buildGroupedToggles(),
                  if (ref.read(currentUserProvider)?.role ==
                          WebUserRole.masterAdmin ||
                      ref.read(currentUserProvider)?.role ==
                          WebUserRole.superAdmin) ...[
                    const SizedBox(height: 16),
                    _FiscalYearPanel(
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
