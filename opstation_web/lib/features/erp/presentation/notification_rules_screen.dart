import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Admin Settings → Notifications (master admin only).
///
/// For every event that can notify, the master admin picks the recipients and,
/// per recipient, the channel (Push = browser push + bell, Email) and the
/// branches. Nobody is included by default. Stored in notification_rules and
/// dispatched server-side by notify_event() (SQL 296).

class NotifEvent {
  final String key, group, title, desc;
  final String? perm; // permission-registry key used for the access warning
  final bool branchScoped, creator;
  const NotifEvent(this.key, this.group, this.title, this.desc,
      {this.perm, this.branchScoped = true, this.creator = false});
}

const kNotifEvents = <NotifEvent>[
  NotifEvent('po_submitted', 'Purchase', 'PO submitted for approval',
      'A Purchase Order is locked and waiting for approval. Email is the rich PO email with Approve / Reject.',
      perm: 'po'),
  NotifEvent('po_approved', 'Purchase', 'PO approved', 'A Purchase Order was approved.', perm: 'po', creator: true),
  NotifEvent('po_rejected', 'Purchase', 'PO rejected', 'A Purchase Order was rejected (with the reason).',
      perm: 'po', creator: true),
  NotifEvent('grn_supervise', 'Purchase', 'GRN needs supervision',
      'A GRN was received and is waiting for supervision (when the GRN supervise flow is on).', perm: 'grn'),
  NotifEvent('grn_ready_invoice', 'Purchase', 'GRN received — ready to invoice',
      'Goods were received on a GRN; a Purchase Invoice can now be raised.', perm: 'grn'),
  NotifEvent('pi_review', 'Purchase', 'Purchase Invoice needs review', 'Sent for review (review flow on).', perm: 'pi'),
  NotifEvent('pi_review_rejected', 'Purchase', 'Purchase Invoice review rejected', 'The reviewer rejected it.',
      perm: 'pi', creator: true),
  NotifEvent('pi_supervise', 'Purchase', 'Purchase Invoice needs supervision', 'Posted and waiting for supervision.',
      perm: 'pi'),
  NotifEvent('pri_review', 'Purchase', 'Purchase Return Invoice needs review', 'Sent for review (review flow on).',
      perm: 'purchase_return_invoice'),
  NotifEvent('pri_review_rejected', 'Purchase', 'Purchase Return Invoice review rejected', 'The reviewer rejected it.',
      perm: 'purchase_return_invoice', creator: true),
  NotifEvent('pa_pending', 'Finance', 'Payment Advice pending approval',
      'A new Payment Advice needs approval. Email is the rich PA email with Approve / Reject.',
      perm: 'payment_advice', branchScoped: false),
  NotifEvent('pa_approved', 'Finance', 'Payment Advice approved', 'A Payment Advice was approved.',
      perm: 'payment_advice', branchScoped: false, creator: true),
  NotifEvent('pa_rejected', 'Finance', 'Payment Advice rejected', 'A Payment Advice was rejected (with the reason).',
      perm: 'payment_advice', branchScoped: false, creator: true),
  NotifEvent('jv_approval', 'Finance', 'Journal Voucher needs approval', 'Submitted for approval (JV approval flow on).',
      perm: 'jv'),
  NotifEvent('jv_supervise', 'Finance', 'Journal Voucher needs supervision', 'Posted and waiting for supervision.',
      perm: 'jv'),
  NotifEvent('si_review', 'Sales', 'Sales Invoice needs review', 'Sent for review (review flow on).', perm: 'si'),
  NotifEvent('si_review_rejected', 'Sales', 'Sales Invoice review rejected', 'The reviewer rejected it.',
      perm: 'si', creator: true),
  NotifEvent('si_supervise', 'Sales', 'Sales Invoice needs supervision', 'Posted and waiting for supervision.',
      perm: 'si'),
  NotifEvent('sri_supervise', 'Sales', 'Sales Return Invoice needs supervision', 'Posted and waiting for supervision.',
      perm: 'sales_return_invoice'),
  NotifEvent('do_supervise', 'Sales', 'Delivery Order needs supervision', 'Saved and waiting for supervision.',
      perm: 'do'),
  NotifEvent('field_order', 'Sales', 'Field order submitted', 'A salesperson submitted an order from the field app.',
      perm: 'field_orders'),
  NotifEvent('retailer_order', 'Sales', 'Retailer order received', 'A shop placed an order in the retailer portal.',
      perm: 'retailer_orders'),
  NotifEvent('transfer_dispatch', 'Inventory', 'Stock transfer to receive',
      'A transfer was dispatched. Branch = the RECEIVING branch.', perm: 'stock_transfer'),
  NotifEvent('customer_supervise', 'Masters', 'New customer needs supervision', 'Customer supervise flow on.',
      perm: 'customers', branchScoped: false),
  NotifEvent('product_supervise', 'Masters', 'New product needs supervision', 'Product supervise flow on.',
      perm: 'products', branchScoped: false),
  NotifEvent('hr_leave_pending', 'HR', 'Leave request waiting for approval',
      'A leave request was saved. Branch = the employee\'s branch.', perm: 'hr_leave'),
  NotifEvent('hr_leave_approved', 'HR', 'Leave approved', 'A leave request was approved.',
      perm: 'hr_leave', creator: true),
  NotifEvent('hr_leave_rejected', 'HR', 'Leave rejected', 'A leave request was rejected.',
      perm: 'hr_leave', creator: true),
  NotifEvent('hr_employee_pending', 'HR', 'New employee waiting for approval',
      'An employee was added by a non-admin and needs approval.', perm: 'hr_employees'),
  NotifEvent('payroll_finalized', 'HR', 'Payroll finalized — ready for payment',
      'Someone pressed Finalize on a payroll run.', perm: 'hr_payroll', branchScoped: false),
  NotifEvent('payroll_paid', 'HR', 'Payroll marked paid', 'A payroll run was marked paid.',
      perm: 'hr_payroll', branchScoped: false),
];

const _creator = '__creator__';

class NotificationRulesScreen extends StatefulWidget {
  final String orgId;
  const NotificationRulesScreen({super.key, required this.orgId});
  @override
  State<NotificationRulesScreen> createState() => _NotificationRulesScreenState();
}

class _NotificationRulesScreenState extends State<NotificationRulesScreen> {
  SupabaseClient get _db => Supabase.instance.client;
  bool _loading = true;
  String? _error;
  bool _byUser = false;
  String _q = '';
  final Set<String> _testing = {};
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _branches = [];
  final Map<String, Set<String>> _userBranches = {}; // user -> allocated branches
  final Map<String, Set<String>> _userPerms = {}; // user -> permission keys
  List<Map<String, dynamic>> _rules = [];
  final Map<String, bool> _enabled = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  static bool _isAdminRole(String? r) => r == 'admin' || r == 'masterAdmin' || r == 'superAdmin';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final org = widget.orgId;
      final res = await Future.wait([
        _db.from('users').select('id, name, email, role, is_active').eq('org_id', org).order('name'),
        _db.from('branches').select('id, name').eq('org_id', org).order('name'),
        _db.from('notification_rules').select().eq('org_id', org),
        _db.from('notification_event_state').select().eq('org_id', org),
      ]);
      _users = List<Map<String, dynamic>>.from(res[0] as List)
          .where((u) => u['is_active'] != false && u['role'] != 'retailer')
          .toList();
      _branches = List<Map<String, dynamic>>.from(res[1] as List);
      _rules = List<Map<String, dynamic>>.from(res[2] as List);
      _enabled
        ..clear()
        ..addAll({for (final r in res[3] as List) r['event_key'] as String: r['enabled'] == true});
      final ids = _users.map((u) => u['id'] as String).toList();
      if (ids.isNotEmpty) {
        try {
          final ub = await _db.from('erp_user_branches').select('user_id, branch_id').inFilter('user_id', ids);
          _userBranches.clear();
          for (final r in ub as List) {
            (_userBranches[r['user_id'] as String] ??= {}).add(r['branch_id'] as String);
          }
        } catch (_) {}
        try {
          final up = await _db.from('user_permissions').select('user_id, permission').inFilter('user_id', ids);
          _userPerms.clear();
          for (final r in up as List) {
            (_userPerms[r['user_id'] as String] ??= {}).add('${r['permission']}');
          }
        } catch (_) {}
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Map<String, dynamic>? _user(String? id) {
    for (final u in _users) {
      if (u['id'] == id) return u;
    }
    return null;
  }

  String _branchName(String id) {
    for (final b in _branches) {
      if (b['id'] == id) return '${b['name']}';
    }
    return id;
  }

  bool _canAccess(String? userId, String? perm) {
    if (userId == null || userId == _creator || perm == null) return true;
    final u = _user(userId);
    if (u == null) return false;
    if (_isAdminRole(u['role'] as String?)) return true;
    final p = _userPerms[userId] ?? const {};
    return p.contains('doc.$perm.add') || p.contains('doc.$perm.edit') || p.contains('report.$perm.view');
  }

  List<Map<String, dynamic>> _rulesFor(String event) =>
      _rules.where((r) => r['event_key'] == event).toList();

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  // ── writes ────────────────────────────────────────────────────────────────
  Future<void> _update(Map<String, dynamic> rule, Map<String, dynamic> patch) async {
    final old = Map<String, dynamic>.from(rule);
    setState(() => rule.addAll(patch));
    try {
      await _db.from('notification_rules')
          .update({...patch, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', rule['id']);
    } catch (e) {
      setState(() => rule
        ..clear()
        ..addAll(old));
      _snack('Could not save: $e');
    }
  }

  Future<void> _remove(Map<String, dynamic> rule) async {
    setState(() => _rules.remove(rule));
    try {
      await _db.from('notification_rules').delete().eq('id', rule['id']);
    } catch (e) {
      setState(() => _rules.add(rule));
      _snack('Could not remove: $e');
    }
  }

  Future<void> _setEnabled(String event, bool on) async {
    setState(() => _enabled[event] = on);
    try {
      await _db.from('notification_event_state')
          .upsert({'org_id': widget.orgId, 'event_key': event, 'enabled': on}, onConflict: 'org_id,event_key');
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  List<String>? _defaultBranches(NotifEvent ev, String? userId) {
    if (!ev.branchScoped || userId == null || userId == _creator) return null;
    final u = _user(userId);
    if (u == null || _isAdminRole(u['role'] as String?)) return null;
    final b = _userBranches[userId];
    return (b == null || b.isEmpty) ? null : b.toList();
  }

  Future<void> _addRecipients(NotifEvent ev) async {
    final existingUsers = _rulesFor(ev.key).map((r) => r['user_id']).whereType<String>().toSet();
    final picked = <String>{};
    final emailCtrl = TextEditingController();
    String q = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => StatefulBuilder(builder: (dlg, setD) {
        final list = _users
            .where((u) => !existingUsers.contains(u['id']))
            .where((u) => q.isEmpty || '${u['name']} ${u['email']}'.toLowerCase().contains(q.toLowerCase()))
            .toList();
        return AlertDialog(
          title: Text('Add recipients — ${ev.title}'),
          content: SizedBox(
            width: 460,
            height: 460,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (ev.creator && !existingUsers.contains(_creator))
                CheckboxListTile(
                  dense: true,
                  value: picked.contains(_creator),
                  onChanged: (v) => setD(() => v == true ? picked.add(_creator) : picked.remove(_creator)),
                  title: const Text('Document creator', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Whoever created that document'),
                ),
              TextField(
                decoration: const InputDecoration(
                    isDense: true, prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search users'),
                onChanged: (v) => setD(() => q = v),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: ListView(children: [
                  for (final u in list)
                    CheckboxListTile(
                      dense: true,
                      value: picked.contains(u['id']),
                      onChanged: (v) =>
                          setD(() => v == true ? picked.add(u['id'] as String) : picked.remove(u['id'])),
                      title: Text('${u['name'] ?? ''}'),
                      subtitle: Text('${u['role'] ?? ''}${(u['email'] ?? '').toString().isNotEmpty ? ' · ${u['email']}' : ''}',
                          style: const TextStyle(fontSize: 11.5)),
                      secondary: _canAccess(u['id'] as String, ev.perm)
                          ? null
                          : const Tooltip(
                              message: 'This user cannot open this screen',
                              child: Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18)),
                    ),
                ]),
              ),
              const Divider(),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Outside email addresses (email only)',
                    hintText: 'owner@example.com, accounts@example.com'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(false), child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(true), child: const Text('Add')),
          ],
        );
      }),
    );
    if (ok != true) return;
    final rows = <Map<String, dynamic>>[
      for (final id in picked)
        {
          'org_id': widget.orgId,
          'event_key': ev.key,
          'user_id': id,
          'push': true,
          'email_on': false,
          'branch_ids': _defaultBranches(ev, id),
        },
      for (final e in emailCtrl.text.split(RegExp(r'[,;\s]+')).map((s) => s.trim().toLowerCase()))
        if (e.contains('@') && !_rulesFor(ev.key).any((r) => (r['email'] ?? '') == e))
          {'org_id': widget.orgId, 'event_key': ev.key, 'email': e, 'push': false, 'email_on': true, 'branch_ids': null},
    ];
    if (rows.isEmpty) return;
    try {
      final ins = await _db.from('notification_rules').insert(rows).select();
      setState(() => _rules.addAll(List<Map<String, dynamic>>.from(ins as List)));
    } catch (e) {
      _snack('Could not add: $e');
    }
  }

  Future<void> _pickBranches(Map<String, dynamic> rule) async {
    final cur = ((rule['branch_ids'] as List?)?.cast<String>() ?? const <String>[]).toSet();
    bool all = rule['branch_ids'] == null;
    final sel = {...cur};
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => StatefulBuilder(
        builder: (dlg, setD) => AlertDialog(
          title: const Text('Branches'),
          content: SizedBox(
            width: 360,
            child: ListView(shrinkWrap: true, children: [
              CheckboxListTile(
                dense: true,
                value: all,
                onChanged: (v) => setD(() => all = v == true),
                title: const Text('All branches', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              for (final b in _branches)
                CheckboxListTile(
                  dense: true,
                  value: !all && sel.contains(b['id']),
                  onChanged: all
                      ? null
                      : (v) => setD(() => v == true ? sel.add(b['id'] as String) : sel.remove(b['id'])),
                  title: Text('${b['name']}'),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(false), child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _update(rule, {'branch_ids': all || sel.isEmpty ? null : sel.toList()});
  }

  // ── UI ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final empty = kNotifEvents.where((e) => _rulesFor(e.key).isEmpty).length;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('By event'), icon: Icon(Icons.event_note, size: 16)),
                ButtonSegment(value: true, label: Text('By user'), icon: Icon(Icons.person_outline, size: 16)),
              ],
              selected: {_byUser},
              onSelectionChanged: (s) => setState(() => _byUser = s.first),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 980),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.primary.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.primary.withOpacity(0.25)),
                            ),
                            child: Text(
                              'Choose who is told about each event. Push = browser notification on their devices '
                              '+ the bell in the app. Email = to their email address. Nobody gets anything unless '
                              'added here.${empty > 0 ? '\n$empty of ${kNotifEvents.length} events have no recipients.' : ''}',
                              style: const TextStyle(fontSize: 12.5, height: 1.45),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                              prefixIcon: const Icon(Icons.search, size: 20),
                              hintText: _byUser
                                  ? 'Search people or notifications…'
                                  : 'Search notifications, groups or recipients…',
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: AppTheme.border)),
                              enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: AppTheme.border)),
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (_byUser) ..._buildByUser() else ..._buildByEvent(),
                        ]),
                      ),
                    ),
                  ],
                ),
    );
  }

  String _recipientLabel(Map<String, dynamic> r) {
    final uid = r['user_id'] as String?;
    if (uid == _creator) return 'document creator';
    if (uid == null) return '${r['email'] ?? ''}';
    final u = _user(uid);
    return '${u?['name'] ?? ''} ${u?['email'] ?? ''} ${u?['role'] ?? ''}';
  }

  bool _matchesEvent(NotifEvent ev) {
    if (_q.isEmpty) return true;
    final hay = '${ev.title} ${ev.desc} ${ev.group} '
            '${_rulesFor(ev.key).map(_recipientLabel).join(' ')}'
        .toLowerCase();
    return _q.split(RegExp(r'\s+')).every(hay.contains);
  }

  Future<void> _sendTest(NotifEvent ev) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: const Text('Send a test?'),
        content: Text('A test notification for "${ev.title}" will go to everyone added here, on the channels ticked '
            '(push and/or email), ignoring branch limits. "Document creator" gets it as you.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(true), child: const Text('Send test')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _testing.add(ev.key));
    try {
      final res = await _db.rpc('notify_test_event',
          params: {'p_org': widget.orgId, 'p_event': ev.key, 'p_title': ev.title});
      final m = res is Map ? res : const {};
      if (m['ok'] == true) {
        _snack('Test sent — push to ${m['push'] ?? 0} user(s), email to ${m['email'] ?? 0} address(es).');
      } else {
        _snack('${m['message'] ?? 'Test could not be sent.'}');
      }
    } catch (e) {
      _snack('Test failed: $e');
    } finally {
      if (mounted) setState(() => _testing.remove(ev.key));
    }
  }

  List<Widget> _buildByEvent() {
    final out = <Widget>[];
    String? group;
    for (final ev in kNotifEvents.where(_matchesEvent)) {
      if (ev.group != group) {
        group = ev.group;
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(group.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: AppTheme.textSecondary)),
        ));
      }
      out.add(_eventCard(ev));
    }
    out.add(const Padding(
      padding: EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Text('MANAGED ELSEWHERE',
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: AppTheme.textSecondary)),
    ));
    out.add(_infoCard(Icons.summarize_outlined, 'Daily attendance summary (email)',
        'Scheduled morning / evening summary. On/off and recipients are set on the Attendance screen.',
        'Open Attendance', '/hr/attendance'));
    out.add(_infoCard(Icons.badge_outlined, 'Employee punch alerts (email)',
        'Per-employee alerts to the email saved on each employee\'s profile (Notify on punch).',
        'Open Employees', '/hr/employees'));
    return out;
  }

  Widget _infoCard(IconData icon, String title, String desc, String action, String route) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              const SizedBox(height: 2),
              Text(desc, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            ]),
          ),
          TextButton(
            onPressed: () {
              final router = GoRouter.of(context);
              Navigator.of(context).pop();
              router.go(route);
            },
            child: Text(action),
          ),
        ]),
      );

  Widget _eventCard(NotifEvent ev) {
    final rules = _rulesFor(ev.key);
    final on = _enabled[ev.key] ?? true;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                    child: Text(ev.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
                const SizedBox(width: 8),
                if (rules.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                    child: const Text('No recipients',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.orange)),
                  ),
              ]),
              const SizedBox(height: 2),
              Text(ev.desc, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            ]),
          ),
          if (rules.isNotEmpty)
            Tooltip(
              message: on ? 'Sending — switch off to pause' : 'Paused',
              child: Switch(value: on, onChanged: (v) => _setEnabled(ev.key, v)),
            ),
        ]),
        if (rules.isNotEmpty) const Divider(height: 14),
        for (final r in rules) _ruleRow(ev, r),
        Row(children: [
          TextButton.icon(
            onPressed: () => _addRecipients(ev),
            icon: const Icon(Icons.person_add_alt, size: 16),
            label: const Text('Add recipient'),
          ),
          const Spacer(),
          if (rules.isNotEmpty)
            TextButton.icon(
              onPressed: _testing.contains(ev.key) ? null : () => _sendTest(ev),
              icon: _testing.contains(ev.key)
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_outlined, size: 16),
              label: const Text('Send test'),
            ),
        ]),
      ]),
    );
  }

  Widget _chip(String label, bool on, VoidCallback? tap, {IconData? icon}) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: on ? AppTheme.primary.withOpacity(0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? AppTheme.primary.withOpacity(0.5) : AppTheme.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: on ? AppTheme.primary : AppTheme.textSecondary),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: tap == null ? AppTheme.border : (on ? AppTheme.primary : AppTheme.textSecondary))),
          ]),
        ),
      );

  Widget _ruleRow(NotifEvent ev, Map<String, dynamic> r) {
    final uid = r['user_id'] as String?;
    final isCreator = uid == _creator;
    final ext = uid == null;
    final u = _user(uid);
    final name = isCreator ? 'Document creator' : ext ? '${r['email']}' : '${u?['name'] ?? 'Removed user'}';
    final sub = isCreator ? 'whoever created it' : ext ? 'outside email' : '${u?['role'] ?? ''}';
    final push = r['push'] == true, mail = r['email_on'] == true;
    final br = (r['branch_ids'] as List?)?.cast<String>();
    final noAccess = !ext && !_canAccess(uid, ev.perm);
    final hasEmail = isCreator || ext || ((u?['email'] ?? '').toString().contains('@'));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 6, children: [
        SizedBox(
          width: 220,
          child: Row(children: [
            Icon(isCreator ? Icons.edit_note : ext ? Icons.alternate_email : Icons.person_outline,
                size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text(sub, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              ]),
            ),
            if (noAccess)
              const Tooltip(
                message: 'This user cannot open this screen — they will be told but cannot act on it.',
                child: Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
              ),
          ]),
        ),
        _chip('Push', push, ext ? null : () => _update(r, {'push': !push}), icon: Icons.notifications_none),
        _chip('Email', mail, hasEmail ? () => _update(r, {'email_on': !mail}) : null, icon: Icons.mail_outline),
        if (ev.branchScoped && !ext)
          _chip(br == null ? 'All branches' : br.map(_branchName).join(', '), br != null, () => _pickBranches(r),
              icon: Icons.store_mall_directory_outlined),
        IconButton(
          tooltip: 'Remove',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16, color: AppTheme.textSecondary),
          onPressed: () => _remove(r),
        ),
        if (!push && !mail)
          const Text('(no channel ticked — nothing sent)', style: TextStyle(fontSize: 10.5, color: Colors.orange)),
      ]),
    );
  }

  List<Widget> _buildByUser() {
    final byKey = {for (final e in kNotifEvents) e.key: e};
    final entries = <String, List<Map<String, dynamic>>>{};
    for (final r in _rules) {
      final who = (r['user_id'] as String?) ?? 'mail:${r['email']}';
      (entries[who] ??= []).add(r);
    }
    if (entries.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('Nobody receives any notifications yet.')),
        )
      ];
    }
    final byKeyTitle = {for (final e in kNotifEvents) e.key: e.title};
    if (_q.isNotEmpty) {
      entries.removeWhere((k, rs) {
        final who = k == _creator
            ? 'document creator'
            : k.startsWith('mail:')
                ? k.substring(5)
                : '${_user(k)?['name'] ?? ''} ${_user(k)?['email'] ?? ''}';
        final hay = '$who ${rs.map((r) => byKeyTitle[r['event_key']] ?? '').join(' ')}'.toLowerCase();
        return !_q.split(RegExp(r'\s+')).every(hay.contains);
      });
    }
    final keys = entries.keys.toList()
      ..sort((a, b) {
        String n(String k) => k == _creator ? '0' : k.startsWith('mail:') ? 'zz$k' : '${_user(k)?['name'] ?? k}';
        return n(a).toLowerCase().compareTo(n(b).toLowerCase());
      });
    return [
      for (final k in keys)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                k == _creator
                    ? 'Document creator'
                    : k.startsWith('mail:')
                        ? k.substring(5)
                        : '${_user(k)?['name'] ?? 'Removed user'}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 6),
            for (final r in entries[k]!)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '• ${byKey[r['event_key']]?.title ?? r['event_key']} — '
                  '${[if (r['push'] == true) 'Push', if (r['email_on'] == true) 'Email'].join(' + ').ifEmpty('nothing ticked')}'
                  '${r['branch_ids'] == null ? '' : ' · ${(r['branch_ids'] as List).cast<String>().map(_branchName).join(', ')}'}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ]),
        ),
    ];
  }
}

extension on String {
  String ifEmpty(String alt) => isEmpty ? alt : this;
}
