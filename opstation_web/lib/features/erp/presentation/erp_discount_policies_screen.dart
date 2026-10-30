import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/permissions/access_control.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../core/widgets/product_picker.dart';
import '../../auth/auth_controller.dart';

/// Inventory → Discount Policies.
///
/// Two ways to discount a product for a customer:
///   • Customer + SKU — a policy tagged to one customer for one product.
///   • Discount group — product discounts inside a group; the customer profile
///     carries one group.
/// When both match, the customer + SKU policy wins. A policy is % or Rs per
/// unit, with optional start / end dates. Policies made or changed by
/// non-admins wait for an admin's approval; an admin's apply straight away.
/// Applied automatically on Quotations, Sales Invoices and POS.
class ErpDiscountPoliciesScreen extends ConsumerStatefulWidget {
  const ErpDiscountPoliciesScreen({super.key});
  @override
  ConsumerState<ErpDiscountPoliciesScreen> createState() => _ErpDiscountPoliciesScreenState();
}

class _ErpDiscountPoliciesScreenState extends ConsumerState<ErpDiscountPoliciesScreen>
    with SingleTickerProviderStateMixin {
  static const _key = 'discount_policies';

  late final TabController _tabs = TabController(length: 3, vsync: this);
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _policies = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = [];
  final Map<String, Map<String, dynamic>> _prodById = {};
  final Map<String, Map<String, dynamic>> _custById = {};
  final Map<String, String> _userNames = {};

  String _skuSearch = '';
  String? _openGroupId;
  String _groupSearch = '';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  AccessControl? get _access => ref.read(accessSyncProvider);
  bool get _isAdmin => _access?.isAdmin ?? false;
  bool get _canAdd => _isAdmin || (_access?.canAddDoc(_key) ?? false);
  bool get _canEdit => _isAdmin || (_access?.canEditDoc(_key) ?? false);

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() { if (mounted) setState(() {}); });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<List<Map<String, dynamic>>> _all(String table, String select, {String? order}) async {
    final out = <Map<String, dynamic>>[];
    const page = 1000;
    for (var from = 0; ; from += page) {
      var q = Supabase.instance.client.from(table).select(select).eq('org_id', _orgId!);
      final rows = await (order == null ? q : q.order(order)).range(from, from + page - 1);
      out.addAll((rows as List).map((r) => Map<String, dynamic>.from(r as Map)));
      if (rows.length < page) break;
    }
    return out;
  }

  Future<void> _load() async {
    if (_orgId == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Future.wait([
        _all('discount_policies', '*', order: 'updated_at'),
        _all('discount_groups', '*', order: 'name'),
        _all('products', 'id, name, sku, selling_price, base_uom_id, is_active', order: 'name'),
        _all('customers', 'id, shop_name, code, discount_group_id, is_active', order: 'shop_name'),
      ]);
      _policies = res[0].reversed.toList();
      _groups = res[1];
      _products = res[2].where((p) => p['is_active'] != false).toList();
      _customers = res[3].where((c) => c['is_active'] != false).toList();
      _prodById..clear()..addEntries(res[2].map((p) => MapEntry(p['id'] as String, p)));
      _custById..clear()..addEntries(res[3].map((c) => MapEntry(c['id'] as String, c)));
      final uids = <String>{
        for (final p in _policies) ...[
          if (p['created_by'] != null) '${p['created_by']}',
          if (p['updated_by'] != null) '${p['updated_by']}',
          if (p['approved_by'] != null) '${p['approved_by']}',
        ]
      }.toList();
      if (uids.isNotEmpty) {
        final us = await Supabase.instance.client.from('users').select('id, name').inFilter('id', uids);
        for (final u in us as List) {
          _userNames['${u['id']}'] = '${u['name'] ?? ''}';
        }
      }
      if (_openGroupId != null && !_groups.any((g) => g['id'] == _openGroupId)) _openGroupId = null;
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (mounted) {
        setState(() {
          _loading = false;
          _error = s.contains('discount_') && (s.contains('does not exist') || s.contains('schema cache'))
              ? 'Discount policies are not switched on yet. Please run the latest database update.'
              : friendlyError('Could not load discount policies', e);
        });
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _num(num? v) {
    final d = (v ?? 0).toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  String _discText(Map<String, dynamic> p) =>
      p['disc_type'] == 'amount' ? 'Rs ${_num(p['value'] as num?)} / unit' : '${_num(p['value'] as num?)}%';

  String _prodName(String? id) {
    final p = _prodById[id];
    if (p == null) return 'Product';
    final sku = (p['sku'] as String?) ?? '';
    return sku.isEmpty ? '${p['name']}' : '${p['name']} · $sku';
  }

  String _custName(String? id) {
    final c = _custById[id];
    if (c == null) return 'Customer';
    final code = (c['code'] as String?) ?? '';
    return code.isEmpty ? '${c['shop_name']}' : '${c['shop_name']} · $code';
  }

  String _groupName(String? id) {
    for (final g in _groups) {
      if (g['id'] == id) return '${g['name']}';
    }
    return 'Group';
  }

  bool _inDate(Map<String, dynamic> p) {
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    final f = DateTime.tryParse('${p['valid_from'] ?? ''}');
    final to = DateTime.tryParse('${p['valid_to'] ?? ''}');
    if (f != null && t.isBefore(f)) return false;
    if (to != null && t.isAfter(to)) return false;
    return true;
  }

  /// What the policy is doing right now, in plain words.
  (String, Color) _state(Map<String, dynamic> p) {
    final st = '${p['status'] ?? 'pending'}';
    if (st == 'pending') return ('Waiting approval', Colors.orange.shade800);
    if (st == 'rejected') return ('Rejected', AppTheme.danger);
    if (p['is_active'] != true) return ('Switched off', AppTheme.textSecondary);
    final f = DateTime.tryParse('${p['valid_from'] ?? ''}');
    if (f != null && DateTime.now().isBefore(f)) return ('Starts ${DateFormat('d MMM').format(f)}', Colors.blue.shade700);
    if (!_inDate(p)) return ('Expired', AppTheme.textSecondary);
    return ('Active', AppTheme.success);
  }

  String _validity(Map<String, dynamic> p) {
    final f = DateTime.tryParse('${p['valid_from'] ?? ''}');
    final t = DateTime.tryParse('${p['valid_to'] ?? ''}');
    final df = DateFormat('d MMM y');
    if (f == null && t == null) return 'No end date';
    if (f != null && t != null) return '${df.format(f)} – ${df.format(t)}';
    if (f != null) return 'From ${df.format(f)}';
    return 'Until ${df.format(t!)}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pending = _policies.where((p) => p['status'] == 'pending').length;
    final mobile = MediaQuery.of(context).size.width < 700;
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(mobile ? 14 : 24, mobile ? 14 : 20, mobile ? 8 : 24, 0),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Discount Policies', style: TextStyle(fontSize: mobile ? 20 : 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              const Text('Customer + SKU discounts win over discount-group ones. Applied on Quotations, Sales Invoices and POS.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            ])),
            IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          ]),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          indicatorColor: AppTheme.primary,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: 'Customer + SKU'),
            const Tab(text: 'Discount groups'),
            Tab(text: pending > 0 ? 'Waiting approval ($pending)' : 'Waiting approval'),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
                  : TabBarView(controller: _tabs, children: [
                      _skuTab(mobile),
                      _groupsTab(mobile),
                      _approvalTab(mobile),
                    ]),
        ),
      ]),
    );
  }

  // ── Customer + SKU tab ────────────────────────────────────────────────────
  Widget _skuTab(bool mobile) {
    final q = _skuSearch.trim().toLowerCase();
    final list = _policies.where((p) => p['customer_id'] != null).where((p) {
      if (q.isEmpty) return true;
      return '${_custName(p['customer_id'] as String?)} ${_prodName(p['product_id'] as String?)}'.toLowerCase().contains(q);
    }).toList();
    return Column(children: [
      Padding(
        padding: EdgeInsets.fromLTRB(mobile ? 12 : 24, 12, mobile ? 12 : 24, 8),
        child: Row(children: [
          Expanded(child: TextField(
            decoration: const InputDecoration(hintText: 'Search customer or product…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _skuSearch = v),
          )),
          if (_canAdd) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(mobile ? 'Add' : 'Add discount'),
              onPressed: () => _editPolicy(null, customerMode: true),
            ),
          ],
        ]),
      ),
      Expanded(
        child: list.isEmpty
            ? const Center(child: Text('No customer discounts yet.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                padding: EdgeInsets.fromLTRB(mobile ? 12 : 24, 4, mobile ? 12 : 24, 24),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _policyCard(list[i], showCustomer: true),
              ),
      ),
    ]);
  }

  Widget _policyCard(Map<String, dynamic> p, {bool showCustomer = false, bool showGroup = false, bool approval = false}) {
    final (label, color) = _state(p);
    final by = _userNames['${p['updated_by'] ?? p['created_by'] ?? ''}'];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (showCustomer)
            Text(_custName(p['customer_id'] as String?), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          if (showGroup)
            Text('Group: ${_groupName(p['group_id'] as String?)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          Text(_prodName(p['product_id'] as String?),
              style: TextStyle(fontSize: showCustomer || showGroup ? 12.5 : 14, fontWeight: showCustomer || showGroup ? FontWeight.w500 : FontWeight.w700)),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
              child: Text(_discText(p), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppTheme.primary)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(10)),
              child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
            ),
            Text(_validity(p), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
          if ((p['notes'] as String?)?.trim().isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${p['notes']}', style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: AppTheme.textSecondary)),
            ),
          if (p['status'] == 'rejected' && (p['reject_reason'] as String?)?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Why: ${p['reject_reason']}', style: const TextStyle(fontSize: 12, color: AppTheme.danger)),
            ),
          if (by != null && by.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('${p['status'] == 'pending' ? 'Requested' : 'Last changed'} by $by',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ),
          if (approval && _isAdmin)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.success, foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Approve'),
                  onPressed: () => _setStatus(p, 'approved'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger, visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Reject'),
                  onPressed: () => _reject(p),
                ),
              ]),
            ),
        ])),
        if (_canEdit || _isAdmin)
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'edit': _editPolicy(p, customerMode: p['customer_id'] != null); break;
                case 'toggle': _toggleActive(p); break;
                case 'delete': _delete(p); break;
              }
            },
            itemBuilder: (_) => [
              if (_canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit')),
              if (_canEdit) PopupMenuItem(value: 'toggle', child: Text(p['is_active'] == true ? 'Switch off' : 'Switch on')),
              if (_isAdmin) const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: AppTheme.danger))),
            ],
          ),
      ]),
    );
  }

  // ── Groups tab ────────────────────────────────────────────────────────────
  Widget _groupsTab(bool mobile) {
    final groupList = _groupList(mobile);
    final open = _openGroupId == null ? null : _groups.firstWhere((g) => g['id'] == _openGroupId, orElse: () => {});
    if (mobile) {
      if (open == null || open.isEmpty) return groupList;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
          onPressed: () => setState(() => _openGroupId = null),
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('All groups'),
        ),
        Expanded(child: _groupDetail(open, mobile)),
      ]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 320, child: groupList),
      const VerticalDivider(width: 1),
      Expanded(
        child: open == null || open.isEmpty
            ? const Center(child: Text('Pick a group to see its product discounts and customers.', style: TextStyle(color: AppTheme.textSecondary)))
            : _groupDetail(open, mobile),
      ),
    ]);
  }

  Widget _groupList(bool mobile) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          const Expanded(child: Text('Groups', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
          if (_canAdd)
            TextButton.icon(onPressed: () => _editGroup(null), icon: const Icon(Icons.add, size: 18), label: const Text('New group')),
        ]),
      ),
      Expanded(
        child: _groups.isEmpty
            ? const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No discount groups yet.', style: TextStyle(color: AppTheme.textSecondary))))
            : ListView.builder(
                itemCount: _groups.length,
                itemBuilder: (_, i) {
                  final g = _groups[i];
                  final products = _policies.where((p) => p['group_id'] == g['id']).length;
                  final custs = _customers.where((c) => c['discount_group_id'] == g['id']).length;
                  final sel = g['id'] == _openGroupId;
                  return ListTile(
                    selected: sel,
                    selectedTileColor: AppTheme.primary.withOpacity(0.06),
                    title: Text('${g['name']}', style: TextStyle(fontWeight: FontWeight.w700,
                        decoration: g['is_active'] == false ? TextDecoration.lineThrough : null)),
                    subtitle: Text('$products product${products == 1 ? '' : 's'} · $custs customer${custs == 1 ? '' : 's'}'
                        '${g['is_active'] == false ? ' · switched off' : ''}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => setState(() { _openGroupId = g['id'] as String; _groupSearch = ''; }),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _groupDetail(Map<String, dynamic> g, bool mobile) {
    final gid = g['id'] as String;
    final pols = _policies.where((p) => p['group_id'] == gid).toList();
    final q = _groupSearch.trim().toLowerCase();
    final members = _customers.where((c) => c['discount_group_id'] == gid)
        .where((c) => q.isEmpty || '${c['shop_name']} ${c['code'] ?? ''}'.toLowerCase().contains(q)).toList();
    final memberCount = _customers.where((c) => c['discount_group_id'] == gid).length;
    return ListView(
      padding: EdgeInsets.fromLTRB(mobile ? 12 : 20, 12, mobile ? 12 : 20, 24),
      children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${g['name']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if ((g['description'] as String?)?.isNotEmpty == true)
              Text('${g['description']}', style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ])),
          if (_canEdit)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'edit') _editGroup(g);
                if (v == 'toggle') _toggleGroup(g);
                if (v == 'delete') _deleteGroup(g);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Rename / describe')),
                PopupMenuItem(value: 'toggle', child: Text(g['is_active'] == false ? 'Switch on' : 'Switch off')),
                if (_isAdmin) const PopupMenuItem(value: 'delete', child: Text('Delete group', style: TextStyle(color: AppTheme.danger))),
              ],
            ),
        ]),
        if (g['is_active'] == false)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('This group is switched off — its discounts do not apply.', style: TextStyle(fontSize: 12, color: AppTheme.warning)),
          ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('PRODUCT DISCOUNTS · ${pols.length}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppTheme.textSecondary, letterSpacing: 0.5))),
          if (_canAdd)
            TextButton.icon(
              onPressed: () => _editPolicy(null, customerMode: false, groupId: gid),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add product'),
            ),
        ]),
        if (pols.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No product discounts in this group yet.', style: TextStyle(color: AppTheme.textSecondary))),
        for (final p in pols) Padding(padding: const EdgeInsets.only(bottom: 8), child: _policyCard(p)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('CUSTOMERS IN THIS GROUP · $memberCount',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppTheme.textSecondary, letterSpacing: 0.5))),
          if (_canEdit)
            TextButton.icon(
              onPressed: () => _addMembers(gid),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Add customers'),
            ),
        ]),
        if (memberCount > 8)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TextField(
              decoration: const InputDecoration(hintText: 'Search customers in this group…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
              onChanged: (v) => setState(() => _groupSearch = v),
            ),
          ),
        if (memberCount == 0)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No customers yet. Add them here, or pick this group on the customer\'s profile.',
                  style: TextStyle(color: AppTheme.textSecondary))),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            for (final c in members)
              ListTile(
                dense: true,
                title: Text('${c['shop_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: (c['code'] as String?)?.isNotEmpty == true ? Text('${c['code']}') : null,
                trailing: _canEdit
                    ? IconButton(
                        tooltip: 'Remove from group',
                        icon: const Icon(Icons.remove_circle_outline, color: AppTheme.danger, size: 20),
                        onPressed: () => _setCustomerGroup([c['id'] as String], null),
                      )
                    : null,
              ),
          ]),
        ),
      ],
    );
  }

  // ── Approval tab ──────────────────────────────────────────────────────────
  Widget _approvalTab(bool mobile) {
    final list = _policies.where((p) => p['status'] == 'pending').toList();
    return list.isEmpty
        ? const Center(child: Text('Nothing waiting for approval.', style: TextStyle(color: AppTheme.textSecondary)))
        : ListView.separated(
            padding: EdgeInsets.fromLTRB(mobile ? 12 : 24, 12, mobile ? 12 : 24, 24),
            itemCount: list.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              if (i == 0) {
                return Text(_isAdmin
                    ? 'Check each request, then approve or reject. A policy only applies once approved.'
                    : 'These are waiting for an admin to approve. They apply once approved.',
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary));
              }
              final p = list[i - 1];
              return _policyCard(p, showCustomer: p['customer_id'] != null, showGroup: p['group_id'] != null, approval: true);
            },
          );
  }

  // ── Actions ───────────────────────────────────────────────────────────────
  Future<void> _setStatus(Map<String, dynamic> p, String status, {String? reason}) async {
    try {
      await Supabase.instance.client.from('discount_policies').update({
        'status': status,
        if (status == 'rejected') 'reject_reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
      }).eq('id', p['id'] as String);
      _snack(status == 'approved' ? 'Approved — the discount now applies.' : 'Rejected.');
      _load();
    } catch (e) {
      _snack(friendlyError('Could not update', e));
    }
  }

  Future<void> _reject(Map<String, dynamic> p) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reject this discount?'),
      content: TextField(controller: ctrl, autofocus: true, maxLines: 2,
          decoration: const InputDecoration(hintText: 'Reason (optional)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('Reject')),
      ],
    ));
    final reason = ctrl.text;
    ctrl.dispose();
    if (ok == true) await _setStatus(p, 'rejected', reason: reason);
  }

  Future<void> _toggleActive(Map<String, dynamic> p) async {
    try {
      await Supabase.instance.client.from('discount_policies')
          .update({'is_active': p['is_active'] != true}).eq('id', p['id'] as String);
      _snack(p['is_active'] == true
          ? 'Switched off.'
          : (_isAdmin ? 'Switched on.' : 'Switched on — waiting for an admin to approve.'));
      _load();
    } catch (e) {
      _snack(friendlyError('Could not update', e));
    }
  }

  Future<void> _delete(Map<String, dynamic> p) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete this discount?'),
      content: const Text('It stops applying straight away. Documents already made keep their discount.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('discount_policies').delete().eq('id', p['id'] as String);
      _snack('Deleted.');
      _load();
    } catch (e) {
      _snack(friendlyError('Could not delete', e));
    }
  }

  Future<void> _editPolicy(Map<String, dynamic>? p, {required bool customerMode, String? groupId}) async {
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PolicyDialog(
        existing: p,
        customerMode: customerMode,
        groupId: groupId ?? p?['group_id'] as String?,
        groupName: _groupName(groupId ?? p?['group_id'] as String?),
        products: _products,
        customers: _customers,
        prodName: _prodName,
        custName: _custName,
        isAdmin: _isAdmin,
      ),
    );
    if (res == null) return;
    // Same target + product already has a policy? Edit that one instead of
    // adding a second that would compete with it.
    final dup = _policies.where((x) =>
        x['id'] != p?['id'] &&
        x['product_id'] == res['product_id'] &&
        (customerMode ? x['customer_id'] == res['customer_id'] : x['group_id'] == res['group_id'])).toList();
    if (dup.isNotEmpty) {
      final go = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Already has a discount'),
        content: Text('${customerMode ? _custName(res['customer_id'] as String?) : 'This group'} already has '
            '${_discText(dup.first)} on ${_prodName(res['product_id'] as String?)}. Save this one as well? '
            'The most recently changed one applies.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
        ],
      ));
      if (go != true) return;
    }
    try {
      final client = Supabase.instance.client;
      if (p == null) {
        await client.from('discount_policies').insert({...res, 'org_id': _orgId});
      } else {
        await client.from('discount_policies').update(res).eq('id', p['id'] as String);
      }
      _snack(_isAdmin ? 'Saved — the discount applies now.' : 'Saved — waiting for an admin to approve.');
      _load();
    } catch (e) {
      _snack(friendlyError('Could not save the discount', e));
    }
  }

  Future<void> _editGroup(Map<String, dynamic>? g) async {
    final name = TextEditingController(text: g?['name'] as String? ?? '');
    final desc = TextEditingController(text: g?['description'] as String? ?? '');
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(g == null ? 'New discount group' : 'Edit group'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Group name *', hintText: 'e.g. Wholesale A')),
        const SizedBox(height: 10),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ));
    final n = name.text.trim(), d = desc.text.trim();
    name.dispose();
    desc.dispose();
    if (ok != true) return;
    if (n.isEmpty) { _snack('Give the group a name.'); return; }
    try {
      final client = Supabase.instance.client;
      if (g == null) {
        final row = await client.from('discount_groups').insert({
          'org_id': _orgId, 'name': n, 'description': d.isEmpty ? null : d,
          'created_by': ref.read(currentUserProvider)?.id,
        }).select('id').single();
        _openGroupId = row['id'] as String?;
      } else {
        await client.from('discount_groups').update({'name': n, 'description': d.isEmpty ? null : d}).eq('id', g['id'] as String);
      }
      _snack('Group saved.');
      _load();
    } catch (e) {
      final s = e.toString().toLowerCase();
      _snack(s.contains('duplicate') || s.contains('unique') ? 'A group with this name already exists.' : friendlyError('Could not save the group', e));
    }
  }

  Future<void> _toggleGroup(Map<String, dynamic> g) async {
    try {
      await Supabase.instance.client.from('discount_groups').update({'is_active': g['is_active'] == false}).eq('id', g['id'] as String);
      _load();
    } catch (e) {
      _snack(friendlyError('Could not update', e));
    }
  }

  Future<void> _deleteGroup(Map<String, dynamic> g) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Delete "${g['name']}"?'),
      content: const Text('Its product discounts are deleted and its customers are taken out of the group.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      final client = Supabase.instance.client;
      final ids = _customers.where((c) => c['discount_group_id'] == g['id']).map((c) => c['id'] as String).toList();
      if (ids.isNotEmpty) await _setCustomerGroup(ids, null, quiet: true);
      await client.from('discount_groups').delete().eq('id', g['id'] as String);
      _openGroupId = null;
      _snack('Group deleted.');
      _load();
    } catch (e) {
      _snack(friendlyError('Could not delete the group', e));
    }
  }

  Future<void> _setCustomerGroup(List<String> ids, String? groupId, {bool quiet = false}) async {
    try {
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        await Supabase.instance.client.from('customers').update({'discount_group_id': groupId}).inFilter('id', chunk);
      }
      for (final id in ids) {
        _custById[id]?['discount_group_id'] = groupId;
      }
      if (!quiet) {
        setState(() {});
        _snack(groupId == null ? 'Removed from the group.' : 'Added to the group.');
      }
    } catch (e) {
      _snack(friendlyError('Could not update the customers', e));
    }
  }

  Future<void> _addMembers(String gid) async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => _CustomerMultiPicker(customers: _customers, groupId: gid, groupName: _groupName),
    );
    if (picked == null || picked.isEmpty) return;
    final moving = picked.where((id) {
      final g = _custById[id]?['discount_group_id'];
      return g != null && g != gid;
    }).length;
    if (moving > 0) {
      final go = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Move customers?'),
        content: Text('$moving of them are in another discount group. A customer can be in one group only — move them here?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move')),
        ],
      ));
      if (go != true) return;
    }
    await _setCustomerGroup(picked, gid);
  }
}

// ── Policy add / edit dialog ────────────────────────────────────────────────
class _PolicyDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final bool customerMode;
  final String? groupId;
  final String groupName;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> customers;
  final String Function(String?) prodName;
  final String Function(String?) custName;
  final bool isAdmin;
  const _PolicyDialog({
    required this.existing,
    required this.customerMode,
    required this.groupId,
    required this.groupName,
    required this.products,
    required this.customers,
    required this.prodName,
    required this.custName,
    required this.isAdmin,
  });
  @override
  State<_PolicyDialog> createState() => _PolicyDialogState();
}

class _PolicyDialogState extends State<_PolicyDialog> {
  String? _customerId;
  String? _productId;
  String _type = 'percent';
  final _value = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  String? _err;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _customerId = e['customer_id'] as String?;
      _productId = e['product_id'] as String?;
      _type = (e['disc_type'] as String?) ?? 'percent';
      final v = (e['value'] as num?)?.toDouble() ?? 0;
      _value.text = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
      _notes.text = (e['notes'] as String?) ?? '';
      _from = DateTime.tryParse('${e['valid_from'] ?? ''}');
      _to = DateTime.tryParse('${e['valid_to'] ?? ''}');
    }
  }

  @override
  void dispose() {
    _value.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickCustomer() async {
    final id = await showDialog<String>(
      context: context,
      builder: (_) => _CustomerSinglePicker(customers: widget.customers),
    );
    if (id != null) setState(() => _customerId = id);
  }

  Future<void> _pickProd() async {
    final p = await pickProduct(context, widget.products, title: 'Pick product');
    if (p != null && p.isNotEmpty) setState(() => _productId = p['id'] as String?);
  }

  Future<void> _pickDate(bool from) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: (from ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null) return;
    setState(() {
      if (from) {
        _from = d;
      } else {
        _to = d;
      }
    });
  }

  double? get _price {
    for (final p in widget.products) {
      if (p['id'] == _productId) return (p['selling_price'] as num?)?.toDouble();
    }
    return null;
  }

  void _save() {
    final v = double.tryParse(_value.text.trim()) ?? 0;
    String? err;
    if (widget.customerMode && _customerId == null) err = 'Choose the customer.';
    if (_productId == null) err ??= 'Choose the product.';
    if (v <= 0) err ??= 'Enter the discount.';
    if (_type == 'percent' && v > 100) err ??= 'A % discount can\'t be more than 100.';
    final price = _price;
    if (_type == 'amount' && price != null && price > 0 && v >= price) {
      err ??= 'The discount is more than the selling price (Rs ${price.toStringAsFixed(0)}).';
    }
    if (_from != null && _to != null && _to!.isBefore(_from!)) err ??= 'The end date is before the start date.';
    if (err != null) { setState(() => _err = err); return; }
    String? ymd(DateTime? d) => d == null ? null : DateFormat('yyyy-MM-dd').format(d);
    Navigator.pop(context, <String, dynamic>{
      'customer_id': widget.customerMode ? _customerId : null,
      'group_id': widget.customerMode ? null : widget.groupId,
      'product_id': _productId,
      'disc_type': _type,
      'value': v,
      'valid_from': ymd(_from),
      'valid_to': ymd(_to),
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM y');
    final price = _price;
    final v = double.tryParse(_value.text.trim()) ?? 0;
    String? preview;
    if (price != null && price > 0 && v > 0) {
      final off = _type == 'percent' ? price * v / 100 : v;
      preview = 'Selling price Rs ${price.toStringAsFixed(2)} → Rs ${(price - off).clamp(0, price).toStringAsFixed(2)} per unit';
    }
    Widget pickerField(String label, String? value, VoidCallback? onTap) => InkWell(
          onTap: onTap,
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, isDense: true, suffixIcon: onTap == null ? null : const Icon(Icons.arrow_drop_down)),
            child: Text(value ?? 'Choose…', style: TextStyle(color: value == null ? AppTheme.textSecondary : null)),
          ),
        );
    return AlertDialog(
      title: Text(widget.existing == null
          ? (widget.customerMode ? 'Customer discount' : 'Product discount · ${widget.groupName}')
          : 'Edit discount'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.customerMode) ...[
            pickerField('Customer *', _customerId == null ? null : widget.custName(_customerId), _pickCustomer),
            const SizedBox(height: 10),
          ],
          pickerField('Product (SKU) *', _productId == null ? null : widget.prodName(_productId), _pickProd),
          const SizedBox(height: 12),
          Row(children: [
            ChoiceChip(label: const Text('% off'), selected: _type == 'percent', onSelected: (_) => setState(() => _type = 'percent')),
            const SizedBox(width: 8),
            ChoiceChip(label: const Text('Rs off per unit'), selected: _type == 'amount', onSelected: (_) => setState(() => _type = 'amount')),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _value,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(labelText: _type == 'percent' ? 'Discount % *' : 'Discount Rs per unit *', isDense: true),
            onChanged: (_) => setState(() {}),
          ),
          if (preview != null)
            Padding(padding: const EdgeInsets.only(top: 6),
                child: Text(preview, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          const SizedBox(height: 14),
          const Text('Valid (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.event, size: 16),
              label: Text(_from == null ? 'Start date' : 'From ${df.format(_from!)}'),
              onPressed: () => _pickDate(true),
            ),
            if (_from != null) IconButton(tooltip: 'Clear', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _from = null)),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_busy, size: 16),
              label: Text(_to == null ? 'End date' : 'Until ${df.format(_to!)}'),
              onPressed: () => _pickDate(false),
            ),
            if (_to != null) IconButton(tooltip: 'Clear', visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16), onPressed: () => setState(() => _to = null)),
          ]),
          const SizedBox(height: 10),
          TextField(controller: _notes, maxLines: 2, minLines: 1,
              decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true)),
          const SizedBox(height: 10),
          Text(widget.isAdmin
              ? 'You are an admin, so this applies as soon as you save.'
              : 'An admin has to approve this before it applies.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          if (_err != null)
            Padding(padding: const EdgeInsets.only(top: 8),
                child: Text(_err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5, fontWeight: FontWeight.w600))),
        ])),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

// ── Customer pickers ────────────────────────────────────────────────────────
class _CustomerSinglePicker extends StatefulWidget {
  final List<Map<String, dynamic>> customers;
  const _CustomerSinglePicker({required this.customers});
  @override
  State<_CustomerSinglePicker> createState() => _CustomerSinglePickerState();
}

class _CustomerSinglePickerState extends State<_CustomerSinglePicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.customers.where((c) => q.isEmpty || '${c['shop_name']} ${c['code'] ?? ''}'.toLowerCase().contains(q)).take(200).toList();
    return AlertDialog(
      title: const Text('Choose customer'),
      content: SizedBox(width: 440, height: 480, child: Column(children: [
        TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search name or code…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v)),
        const SizedBox(height: 8),
        Expanded(child: ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final c = list[i];
            return ListTile(
              dense: true,
              title: Text('${c['shop_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: (c['code'] as String?)?.isNotEmpty == true ? Text('${c['code']}') : null,
              onTap: () => Navigator.pop(context, c['id'] as String),
            );
          },
        )),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

class _CustomerMultiPicker extends StatefulWidget {
  final List<Map<String, dynamic>> customers;
  final String groupId;
  final String Function(String?) groupName;
  const _CustomerMultiPicker({required this.customers, required this.groupId, required this.groupName});
  @override
  State<_CustomerMultiPicker> createState() => _CustomerMultiPickerState();
}

class _CustomerMultiPickerState extends State<_CustomerMultiPicker> {
  String _q = '';
  final Set<String> _sel = {};
  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = widget.customers
        .where((c) => c['discount_group_id'] != widget.groupId)
        .where((c) => q.isEmpty || '${c['shop_name']} ${c['code'] ?? ''}'.toLowerCase().contains(q))
        .take(300)
        .toList();
    return AlertDialog(
      title: const Text('Add customers to the group'),
      content: SizedBox(width: 460, height: 500, child: Column(children: [
        TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search name or code…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
            onChanged: (v) => setState(() => _q = v)),
        const SizedBox(height: 8),
        Expanded(child: ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) {
            final c = list[i];
            final id = c['id'] as String;
            final other = c['discount_group_id'] as String?;
            return CheckboxListTile(
              dense: true,
              value: _sel.contains(id),
              onChanged: (v) => setState(() => v == true ? _sel.add(id) : _sel.remove(id)),
              title: Text('${c['shop_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                if ((c['code'] as String?)?.isNotEmpty == true) '${c['code']}',
                if (other != null) 'now in ${widget.groupName(other)}',
              ].join(' · ')),
            );
          },
        )),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel.toList()),
          child: Text(_sel.isEmpty ? 'Add' : 'Add ${_sel.length}'),
        ),
      ],
    );
  }
}
