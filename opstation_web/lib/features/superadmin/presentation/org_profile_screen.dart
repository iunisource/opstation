import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/modules/app_modules.dart';
import '../../../core/theme/app_theme.dart';
import 'orgs_screen.dart' show showOrgModulesDialog;
import 'storage_usage_widgets.dart';

/// Super Admin → Organizations → one org's profile.
/// Overview, activity, users (with last sign-in), branches, modules,
/// subscription and Storage (incl. document / kiosk / audit settings).
/// Data: org_profile_summary (SQL 353) + org_storage_usage (SQL 350).
class OrgProfileScreen extends StatefulWidget {
  final String orgId;
  const OrgProfileScreen({super.key, required this.orgId});
  @override
  State<OrgProfileScreen> createState() => _OrgProfileScreenState();
}

class _OrgProfileScreenState extends State<OrgProfileScreen> {
  Map<String, dynamic>? _d;
  String? _err;
  bool _loading = true;
  final _money = NumberFormat('#,##0');
  final _date = DateFormat('d MMM y');
  final _dateTime = DateFormat('d MMM y, h:mm a');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final r = await Supabase.instance.client.rpc('org_profile_summary', params: {'p_org': widget.orgId});
      if (!mounted) return;
      setState(() { _d = r == null ? null : Map<String, dynamic>.from(r as Map); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString().contains('org_profile_summary')
            ? 'Run SQL 353 in Supabase first.'
            : 'Could not load: ${e.toString().split('\n').first}';
      });
    }
  }

  DateTime? _dt(dynamic v) => DateTime.tryParse('${v ?? ''}')?.toLocal();

  String _ago(DateTime? d) {
    if (d == null) return 'never';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    return _date.format(d);
  }

  Widget _card(String title, Widget child, {Widget? action}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(title.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800, color: AppTheme.textSecondary, letterSpacing: 0.6)),
            ),
            if (action != null) action,
          ]),
          const SizedBox(height: 10),
          child,
        ]),
      );

  Widget _kpi(String label, String value, {String? sub, Color? color}) => Container(
        constraints: const BoxConstraints(minWidth: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          if (sub != null) Text(sub, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _chip(String text, Color color, {IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
        ]),
      );

  String _roleLabel(String? r) => switch (r) {
        'masterAdmin' => 'Master admin',
        'admin' => 'Admin',
        'superAdmin' => 'Super admin',
        'erpUser' => 'ERP user',
        'accountant' => 'Accountant',
        'dispatchManager' => 'Dispatch manager',
        'salesperson' => 'Salesperson',
        'driver' => 'Driver',
        'retailer' => 'Retailer',
        null => '—',
        final String other => other,
      };

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 700;
    return Container(
      color: AppTheme.background,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_err!, style: const TextStyle(color: AppTheme.danger)),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                )
              : _d == null
                  ? const Center(child: Text('Organization not found'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: EdgeInsets.all(narrow ? 12 : 28),
                        children: [
                          _header(narrow),
                          const SizedBox(height: 16),
                          _activity(narrow),
                          _usersCard(narrow),
                          if (narrow) ...[
                            _branchesCard(),
                            _modulesCard(),
                            _subscriptionCard(),
                          ] else
                            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: _branchesCard()),
                              const SizedBox(width: 16),
                              Expanded(child: _modulesCard()),
                              const SizedBox(width: 16),
                              Expanded(child: _subscriptionCard()),
                            ]),
                          _card('Storage', OrgStoragePanel(orgId: widget.orgId)),
                        ],
                      ),
                    ),
    );
  }

  Widget _header(bool narrow) {
    final o = Map<String, dynamic>.from((_d!['org'] as Map?) ?? const {});
    final users = ((_d!['users'] as List?) ?? const []).cast<Map>();
    final active = o['is_active'] as bool? ?? true;
    final archived = o['archived'] as bool? ?? false;
    final created = _dt(o['created_at']);
    final expires = _dt(o['expires_at']);
    final expired = expires != null && expires.isBefore(DateTime.now());
    final maxUsers = o['max_users'] as int?;
    final activeUsers = users.where((u) => u['active'] != false).length;
    final master = users.cast<Map?>().firstWhere((u) => u?['id'] == o['master_admin_id'], orElse: () => null);
    final last = _dt(_d!['last_activity']);
    final name = '${o['name'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextButton.icon(
        onPressed: () => context.go('/orgs'),
        icon: const Icon(Icons.arrow_back, size: 16),
        label: const Text('Organizations'),
      ),
      const SizedBox(height: 6),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: narrow ? 48 : 60,
          height: narrow ? 48 : 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(name.isEmpty ? 'O' : name.substring(0, 1).toUpperCase(),
              style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800, fontSize: narrow ? 20 : 26)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(fontSize: narrow ? 20 : 26, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            SelectableText('${o['id']}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _chip(active ? 'Active' : 'Inactive', active ? AppTheme.success : AppTheme.danger),
              if (archived) _chip('Archived', AppTheme.textSecondary, icon: Icons.archive_outlined),
              _chip(
                  expires == null ? 'No expiry' : (expired ? 'Expired ${_date.format(expires)}' : 'Until ${_date.format(expires)}'),
                  expired ? AppTheme.danger : AppTheme.textSecondary,
                  icon: Icons.event_outlined),
              _chip('$activeUsers${maxUsers != null ? '/$maxUsers' : ''} active users',
                  maxUsers != null && activeUsers >= maxUsers ? AppTheme.danger : AppTheme.textSecondary,
                  icon: Icons.people_outline),
              if (created != null) _chip('Since ${_date.format(created)}', AppTheme.textSecondary, icon: Icons.flag_outlined),
              _chip('Last activity ${_ago(last)}', last != null && DateTime.now().difference(last).inDays > 14
                  ? Colors.orange.shade800 : AppTheme.textSecondary, icon: Icons.bolt_outlined),
            ]),
            if (master != null) ...[
              const SizedBox(height: 8),
              Text('Master admin: ${master['name']} · ${master['email']}',
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            ],
          ]),
        ),
        if (!narrow)
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
      ]),
    ]);
  }

  Widget _activity(bool narrow) {
    final m = Map<String, dynamic>.from((_d!['metrics'] as Map?) ?? const {});
    Map g(String k) => (m[k] as Map?) ?? const {};
    num n(Map x, String k) => (x[k] as num?) ?? 0;
    final si = g('sales_invoices'), pi = g('purchase_invoices');
    final order = [
      'sales_invoices', 'purchase_invoices', 'sales_orders', 'delivery_orders', 'purchase_orders', 'purchase_grns',
      'journal_entries', 'customers', 'suppliers', 'products', 'hr_employees', 'hr_attendance', 'assets',
      'voucher_documents',
    ];
    return _card(
      'Activity',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 10, children: [
          _kpi('Sales last 30 days', 'Rs ${_money.format(n(si, 'amount_30d'))}', sub: '${n(si, 'last_30d')} invoices'),
          _kpi('Purchases last 30 days', 'Rs ${_money.format(n(pi, 'amount_30d'))}', sub: '${n(pi, 'last_30d')} invoices'),
          _kpi('Customers', _money.format(n(g('customers'), 'total')), sub: '+${n(g('customers'), 'last_30d')} in 30 days'),
          _kpi('Products', _money.format(n(g('products'), 'total')), sub: '+${n(g('products'), 'last_30d')} in 30 days'),
          _kpi('Employees', _money.format(n(g('hr_employees'), 'total'))),
        ]),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (_, c) {
          final rows = [
            for (final k in order)
              if (m[k] is Map && (m[k] as Map).containsKey('total')) MapEntry(k, Map<String, dynamic>.from(m[k] as Map)),
          ];
          return Column(children: [
            Row(children: const [
              Expanded(flex: 4, child: Text('Record', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              Expanded(flex: 2, child: Text('30 days', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
              Expanded(flex: 3, child: Text('Last added', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
            ]),
            const Divider(height: 12),
            for (final e in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(flex: 4, child: Text('${e.value['label']}', style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 2, child: Text(_money.format(n(e.value, 'total')), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                  Expanded(flex: 2, child: Text(_money.format(n(e.value, 'last_30d')), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 3, child: Text(_ago(_dt(e.value['last_at'])), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                ]),
              ),
          ]);
        }),
      ]),
    );
  }

  Widget _usersCard(bool narrow) {
    final users = ((_d!['users'] as List?) ?? const []).cast<Map>();
    return _card(
      'Users (${users.length})',
      Column(children: [
        for (final u in users)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.6)))),
            child: Row(children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: (u['active'] == false ? AppTheme.textSecondary : AppTheme.primary).withOpacity(0.12),
                child: Text('${u['name'] ?? '?'}'.isEmpty ? '?' : '${u['name']}'.substring(0, 1).toUpperCase(),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                        color: u['active'] == false ? AppTheme.textSecondary : AppTheme.primary)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${u['name'] ?? '—'}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: u['active'] == false ? AppTheme.textSecondary : null,
                          decoration: u['active'] == false ? TextDecoration.lineThrough : null)),
                  Text('${u['email'] ?? ''}', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                      overflow: TextOverflow.ellipsis),
                  if (narrow)
                    Text('${_roleLabel(u['role'] as String?)} · last sign-in ${_ago(_dt(u['last_sign_in']))}',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              ),
              if (!narrow) ...[
                SizedBox(width: 130, child: Text(_roleLabel(u['role'] as String?), style: const TextStyle(fontSize: 12))),
                SizedBox(
                  width: 170,
                  child: Tooltip(
                    message: _dt(u['last_sign_in']) == null ? 'Never signed in' : _dateTime.format(_dt(u['last_sign_in'])!),
                    child: Text('Last sign-in ${_ago(_dt(u['last_sign_in']))}',
                        textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                ),
              ],
            ]),
          ),
      ]),
    );
  }

  Widget _branchesCard() {
    final b = ((_d!['branches'] as List?) ?? const []).cast<Map>();
    final real = b.where((x) => x['is_virtual'] != true).toList();
    final virt = b.length - real.length;
    return _card(
      'Branches (${real.length})',
      real.isEmpty
          ? const Text('No branches', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final x in real)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    Icon(Icons.store_outlined, size: 15,
                        color: x['is_active'] == false ? AppTheme.textSecondary : AppTheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${x['name']}', style: const TextStyle(fontSize: 12.5))),
                    if (x['is_active'] == false)
                      const Text('inactive', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                ),
              if (virt > 0)
                Text('+ $virt processor / off-site location${virt == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ]),
    );
  }

  Widget _modulesCard() {
    final mods = {
      for (final m in ((_d!['modules'] as List?) ?? const []).cast<Map>()) '${m['module']}': m['enabled'] == true,
    };
    final name = '${(_d!['org'] as Map?)?['name'] ?? ''}';
    return _card(
      'Modules',
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final m in kAppModules)
          _chip(m.label, mods[m.key] == true ? AppTheme.success : AppTheme.textSecondary,
              icon: mods[m.key] == true ? Icons.check_circle : Icons.remove_circle_outline),
      ]),
      action: TextButton(
        onPressed: () async {
          await showOrgModulesDialog(context, widget.orgId, name);
          _load();
        },
        child: const Text('Manage'),
      ),
    );
  }

  Widget _subscriptionCard() {
    final s = (_d!['subscription'] as Map?);
    if (s == null) {
      return _card('Subscription', const Text('No subscription record', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)));
    }
    // Show the useful fields that exist, whatever the table's exact columns are.
    const keys = {
      'plan': 'Plan', 'plan_name': 'Plan', 'status': 'Status', 'billing_cycle': 'Billing',
      'amount': 'Amount', 'price': 'Price', 'seats': 'Seats', 'trial_ends_at': 'Trial ends',
      'current_period_end': 'Renews / ends', 'next_billing_date': 'Next billing', 'started_at': 'Started',
    };
    final rows = <Widget>[];
    for (final e in keys.entries) {
      final v = s[e.key];
      if (v == null || '$v'.isEmpty) continue;
      final d = e.key.endsWith('_at') || e.key.endsWith('_end') || e.key.endsWith('_date') ? _dt(v) : null;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 110, child: Text(e.value, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(child: Text(d != null ? _date.format(d) : '$v', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
        ]),
      ));
    }
    return _card(
      'Subscription',
      rows.isEmpty ? const Text('—') : Column(children: rows),
      action: TextButton(onPressed: () => context.go('/subscriptions'), child: const Text('Open')),
    );
  }
}
