import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Superadmin Subscription Dashboard — every org's SaaS billing state, history,
/// and the actions to manage it. Reads via RLS (superAdmin full access); all
/// mutations go through the SECURITY DEFINER sub_admin_* RPCs (168).
class SubscriptionsScreen extends ConsumerStatefulWidget {
  const SubscriptionsScreen({super.key});
  @override
  ConsumerState<SubscriptionsScreen> createState() => _State();
}

class _Row {
  final Map<String, dynamic> sub;
  final Map<String, dynamic>? org;
  final Map<String, dynamic>? card;
  _Row(this.sub, this.org, this.card);
  String get orgId => sub['org_id'] as String;
  String get name => (org?['name'] as String?) ?? orgId;
  String get status => (sub['status'] as String?) ?? 'active';
  bool get orgActive => (org?['is_active'] as bool?) ?? true;
  bool get managed => (sub['billing_managed'] as bool?) ?? false;
  num get amount => (sub['amount'] as num?) ?? 0;
  String? get periodEnd => sub['current_period_end'] as String?;
  // "Paying" = on automated billing OR marked paid (mark-paid flips managed on).
  // Only these show an amount / count toward MRR — everything else is just an org.
  bool get paying => managed && status == 'active';
}

class _State extends ConsumerState<SubscriptionsScreen> {
  bool _loading = true;
  String _search = '';
  String _filter = 'ALL';
  List<_Row> _rows = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  SupabaseClient get _c => Supabase.instance.client;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final subs = List<Map<String, dynamic>>.from(
          await _c.from('org_subscriptions').select('*'));
      final orgs = List<Map<String, dynamic>>.from(
          await _c.from('orgs').select('id, name, is_active, expires_at'));
      final cards = List<Map<String, dynamic>>.from(await _c
          .from('org_payment_methods')
          .select('org_id, brand, last4, exp_month, exp_year, is_default, status')
          .eq('is_default', true)
          .eq('status', 'active'));
      final orgById = {for (final o in orgs) o['id'] as String: o};
      final cardByOrg = {for (final c in cards) c['org_id'] as String: c};
      final rows = subs
          .map((s) => _Row(s, orgById[s['org_id']], cardByOrg[s['org_id']]))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() { _rows = rows; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('Load error: $e');
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _uid() => ref.read(currentUserProvider)?.id ?? 'superadmin';

  String _fmtDate(String? iso) {
    if (iso == null) return '—';
    final d = DateTime.tryParse(iso);
    if (d == null) return '—';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _money(num v) => 'PKR ${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

  Color _statusColor(String s) {
    switch (s) {
      case 'active': return AppTheme.success;
      case 'trialing': return AppTheme.primary;
      case 'past_due': return AppTheme.warning;
      case 'locked': return AppTheme.danger;
      case 'canceled': return AppTheme.textSecondary;
      default: return AppTheme.textSecondary;
    }
  }

  Future<void> _rpc(String fn, Map<String, dynamic> params, String ok) async {
    try {
      await _c.rpc(fn, params: params);
      _toast(ok);
      await _load();
    } catch (e) {
      _toast('Failed: $e');
    }
  }

  Future<void> _extend(_Row r) async {
    final ctrl = TextEditingController(text: '30');
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Extend ${r.name}'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Days to extend'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim()) ?? 0),
              child: const Text('Extend')),
        ],
      ),
    );
    if (days != null && days > 0) {
      await _rpc('sub_admin_extend',
          {'p_org': r.orgId, 'p_days': days, 'p_user': _uid()}, 'Extended $days day(s)');
    }
  }

  Future<void> _recordCard(_Row r) async {
    final brand = TextEditingController(text: r.card?['brand'] as String? ?? '');
    final last4 = TextEditingController(text: r.card?['last4'] as String? ?? '');
    final mm = TextEditingController();
    final yy = TextEditingController();
    final token = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Card on file — ${r.name}'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Tokenized details only — never enter a full card number here.',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: brand, decoration: const InputDecoration(labelText: 'Brand (Visa…)'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: last4, decoration: const InputDecoration(labelText: 'Last 4'))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: mm, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Exp MM'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: yy, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Exp YYYY'))),
            ]),
            const SizedBox(height: 8),
            TextField(controller: token, decoration: const InputDecoration(labelText: 'Gateway token (optional)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      await _rpc('sub_admin_upsert_payment_method', {
        'p_org': r.orgId, 'p_provider': 'manual',
        'p_brand': brand.text.trim(), 'p_last4': last4.text.trim(),
        'p_exp_month': int.tryParse(mm.text.trim()), 'p_exp_year': int.tryParse(yy.text.trim()),
        'p_token': token.text.trim().isEmpty ? null : token.text.trim(), 'p_user': _uid(),
      }, 'Card on file updated');
    }
  }

  Future<void> _history(_Row r) async {
    final events = List<Map<String, dynamic>>.from(await _c
        .from('subscription_events').select('event_type, detail, actor, created_at')
        .eq('org_id', r.orgId).order('created_at', ascending: false).limit(50));
    final invoices = List<Map<String, dynamic>>.from(await _c
        .from('subscription_invoices').select('invoice_number, amount, status, due_date, paid_at')
        .eq('org_id', r.orgId).order('issued_at', ascending: false).limit(50));
    final payments = List<Map<String, dynamic>>.from(await _c
        .from('subscription_payments').select('amount, status, provider, created_at')
        .eq('org_id', r.orgId).order('created_at', ascending: false).limit(50));
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('${r.name} — history'),
        content: SizedBox(
          width: 560,
          child: DefaultTabController(
            length: 3,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const TabBar(labelColor: AppTheme.primary, tabs: [
                Tab(text: 'Events'), Tab(text: 'Invoices'), Tab(text: 'Payments'),
              ]),
              SizedBox(
                height: 320,
                child: TabBarView(children: [
                  _list(events, (e) => '${_fmtDate(e['created_at'] as String?)}  ·  ${e['event_type']}',
                      (e) => '${e['detail'] ?? ''}  (${e['actor'] ?? ''})'),
                  _list(invoices, (e) => '${e['invoice_number'] ?? ''}  ·  ${_money((e['amount'] as num?) ?? 0)}',
                      (e) => 'Due ${_fmtDate(e['due_date'] as String?)}  ·  ${e['status']}'),
                  _list(payments, (e) => '${_money((e['amount'] as num?) ?? 0)}  ·  ${e['status']}',
                      (e) => '${e['provider'] ?? ''}  ·  ${_fmtDate(e['created_at'] as String?)}'),
                ]),
              ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Close'))],
      ),
    );
  }

  Widget _list(List<Map<String, dynamic>> rows, String Function(Map<String, dynamic>) title,
      String Function(Map<String, dynamic>) sub) {
    if (rows.isEmpty) return const Center(child: Text('Nothing yet', style: TextStyle(color: AppTheme.textSecondary)));
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        dense: true,
        title: Text(title(rows[i]), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(sub(rows[i]), style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase();
    var rows = _rows;
    if (_filter != 'ALL') rows = rows.where((r) => r.status == _filter).toList();
    if (q.isNotEmpty) rows = rows.where((r) => matchesQuery(r.name, q)).toList();

    final mrr = _rows.where((r) => r.paying).fold<num>(0, (a, r) => a + r.amount);
    int cnt(String s) => _rows.where((r) => r.status == s).length;
    final mobile = MediaQuery.of(context).size.width < 720;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Column(children: [
        Container(
          color: AppTheme.card,
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Row(children: [
            const Text('Subscription Dashboard',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.textPrimary)),
            const Spacer(),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      _tile('Orgs', '${_rows.length}', AppTheme.textPrimary),
                      _tile('Trialing', '${cnt('trialing')}', AppTheme.primary),
                      _tile('Active', '${cnt('active')}', AppTheme.success),
                      _tile('Past due', '${cnt('past_due')}', AppTheme.warning),
                      _tile('Locked', '${cnt('locked')}', AppTheme.danger),
                      _tile('MRR (active)', _money(mrr), AppTheme.textPrimary),
                    ]),
                    const SizedBox(height: 18),
                    Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      SizedBox(
                        width: mobile ? double.infinity : 320,
                        child: TextField(
                          decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search), hintText: 'Search org', isDense: true),
                          onChanged: (v) => setState(() => _search = v),
                        ),
                      ),
                      DropdownButton<String>(
                        value: _filter,
                        items: const [
                          DropdownMenuItem(value: 'ALL', child: Text('All statuses')),
                          DropdownMenuItem(value: 'trialing', child: Text('Trialing')),
                          DropdownMenuItem(value: 'active', child: Text('Active')),
                          DropdownMenuItem(value: 'past_due', child: Text('Past due')),
                          DropdownMenuItem(value: 'locked', child: Text('Locked')),
                        ],
                        onChanged: (v) => setState(() => _filter = v ?? 'ALL'),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    if (mobile)
                      Column(children: [
                        for (final r in rows) _mobileCard(r),
                        if (rows.isEmpty)
                          const Padding(padding: EdgeInsets.all(24), child: Text('No matching orgs')),
                      ])
                    else
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Column(children: [
                          _headerRow(),
                          for (final r in rows) _dataRow(r),
                          if (rows.isEmpty)
                            const Padding(padding: EdgeInsets.all(24), child: Text('No matching orgs')),
                        ]),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget _tile(String label, String value, Color c) => Container(
        width: 150,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: c)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );

  Widget _headerRow() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppTheme.border)),
        ),
        child: Row(children: const [
          Expanded(flex: 3, child: Text('Organization', style: _th)),
          Expanded(flex: 2, child: Text('Status', style: _th)),
          Expanded(flex: 2, child: Text('Amount', style: _th)),
          Expanded(flex: 2, child: Text('Due', style: _th)),
          Expanded(flex: 2, child: Text('Card', style: _th)),
          Expanded(flex: 2, child: Text('Auto-bill', style: _th)),
          SizedBox(width: 48, child: Text('', style: _th)),
        ]),
      );

  Widget _dataRow(_Row r) {
    final card = r.card == null ? '—' : '${r.card!['brand'] ?? 'Card'} ••${r.card!['last4'] ?? ''}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Row(children: [
        Expanded(flex: 3, child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: _statusChip(r))),
        Expanded(flex: 2, child: Text(r.paying ? _money(r.amount) : '—',
            style: TextStyle(fontSize: 13, color: r.paying ? AppTheme.textPrimary : AppTheme.textSecondary))),
        Expanded(flex: 2, child: Text(
            r.periodEnd == null ? (r.status == 'active' ? 'Never' : '—') : _fmtDate(r.periodEnd),
            style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: Text(card, style: const TextStyle(fontSize: 13))),
        Expanded(flex: 2, child: _autoBillSwitch(r)),
        SizedBox(width: 48, child: _actionsMenu(r)),
      ]),
    );
  }

  Widget _statusChip(_Row r) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: _statusColor(r.status).withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(r.status,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _statusColor(r.status))),
      );

  Widget _autoBillSwitch(_Row r) => Switch(
        value: r.managed,
        onChanged: (v) => _rpc('sub_admin_set_billing_managed',
            {'p_org': r.orgId, 'p_managed': v, 'p_user': _uid()},
            v ? 'Automated billing on' : 'Automated billing off'),
      );

  Widget _actionsMenu(_Row r) => PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'paid': _rpc('sub_admin_mark_paid', {'p_org': r.orgId, 'p_user': _uid()}, 'Marked paid'); break;
            case 'never': _rpc('sub_admin_never_expire', {'p_org': r.orgId, 'p_user': _uid()}, 'Set to never expire'); break;
            case 'extend': _extend(r); break;
            case 'lock': _rpc('sub_admin_set_active', {'p_org': r.orgId, 'p_active': false, 'p_user': _uid()}, 'Locked'); break;
            case 'unlock': _rpc('sub_admin_set_active', {'p_org': r.orgId, 'p_active': true, 'p_user': _uid()}, 'Unlocked'); break;
            case 'card': _recordCard(r); break;
            case 'history': _history(r); break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'paid', child: Text('Mark paid (extend period)')),
          const PopupMenuItem(value: 'extend', child: Text('Extend days…')),
          const PopupMenuItem(value: 'never', child: Text('Set to never expire')),
          if (r.orgActive)
            const PopupMenuItem(value: 'lock', child: Text('Lock org'))
          else
            const PopupMenuItem(value: 'unlock', child: Text('Unlock org')),
          const PopupMenuItem(value: 'card', child: Text('Record card on file')),
          const PopupMenuItem(value: 'history', child: Text('View history')),
        ],
      );

  // Stacked card for narrow screens.
  Widget _mobileCard(_Row r) {
    final card = r.card == null ? '—' : '${r.card!['brand'] ?? 'Card'} ••${r.card!['last4'] ?? ''}';
    final due = r.periodEnd == null ? (r.status == 'active' ? 'Never' : '—') : _fmtDate(r.periodEnd);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      decoration: BoxDecoration(
          color: AppTheme.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
          _statusChip(r),
          _actionsMenu(r),
        ]),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(children: [
            _kv('Amount', r.paying ? _money(r.amount) : '—'),
            _kv('Due', due),
            _kv('Card', card),
            Row(children: [
              const Expanded(child: Text('Auto-bill', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))),
              _autoBillSwitch(r),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 80, child: Text(k, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        ]),
      );
}

const _th = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
