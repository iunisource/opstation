import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

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
  const _AdminToggle(this.key, this.title, this.subtitle, {this.number, this.text});
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
    'org.cbr_collection_columns',
    'Collection columns on Customer Balance Report',
    'Show blank "Receipt #" and "Amount Collected" columns in the Customer '
        'Balance Report print/PDF — for recording collections during a route run.',
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
  // _AdminToggle('org.some_flag', 'Title shown to admin', 'What it does.'),

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
    'org.kiosk_capture_photo',
    'Capture punch photo at Attendance Kiosk',
    'When ON, the Attendance Kiosk takes a webcam snapshot at each check-in '
        'and check-out and stores it with the attendance record (kept for 30 '
        'days, then overwritten). Helps verify who actually punched and deters '
        'buddy-punching. Requires the kiosk camera to be active; if a kiosk '
        'uses only a hardware scanner with no camera, the punch still works '
        'but no photo is captured. When OFF, no photos are taken.',
  ),
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
      setState(() {
        for (final t in _toggles) {
          _values[t.key] = cfg[t.key] == 'true';
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
                  Container(
                    constraints: const BoxConstraints(maxWidth: 760),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < _toggles.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, color: AppTheme.border),
                          SwitchListTile(
                            activeColor: AppTheme.primary,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(_toggles[i].title,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                ),
                                if (_saving.contains(_toggles[i].key)) ...[
                                  const SizedBox(width: 10),
                                  const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                ],
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_toggles[i].subtitle,
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.textSecondary,
                                      height: 1.35)),
                            ),
                            value: _values[_toggles[i].key] ?? false,
                            onChanged: (v) => _setToggle(_toggles[i].key, v),
                          ),
                          if (_toggles[i].number != null &&
                              (_values[_toggles[i].key] ?? false))
                            _numberRow(_toggles[i].number!),
                          if (_toggles[i].text != null &&
                              (_values[_toggles[i].key] ?? false))
                            _textRow(_toggles[i].text!),
                        ],
                      ],
                    ),
                  ),
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
