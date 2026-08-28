import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/format/money.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/widgets/responsive.dart';

/// Supplier Profile (Supplier 360) — the purchase-side mirror of Customer 360.
///  • Overview   : contact card, outstanding payable, purchase summary
///  • Payables   : aging buckets (0-30 … 120+) + open invoices
///  • Purchases  : recent purchase invoices + totals
///  • Tasks      : customer_activities linked to this supplier (supplier_id)
///  • Complaints : crm_complaints linked to this supplier (supplier_id)
///
/// Opens from the CRM menu (pick a supplier) or is pushed with [initialSupplier]
/// from the Follow-ups screen for a specific supplier.
class ErpSupplier360Screen extends ConsumerStatefulWidget {
  final Map<String, dynamic>? initialSupplier;
  const ErpSupplier360Screen({super.key, this.initialSupplier});

  @override
  ConsumerState<ErpSupplier360Screen> createState() => _ErpSupplier360ScreenState();
}

class _ErpSupplier360ScreenState extends ConsumerState<ErpSupplier360Screen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  final _money = NumberFormat('#,##0');
  final MoneyFmt _money2 = const MoneyFmt();

  // Supplier picker
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loadingList = true;
  bool _showDrop = false;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  Map<String, dynamic>? _supplier;

  // supplier_id -> count of pending items (open/in-progress tasks + open complaints)
  Map<String, int> _pending = {};

  // Payables / aging
  bool _loadingPay = true;
  double _current = 0, _b1 = 0, _b2 = 0, _b3 = 0, _b4 = 0, _payTotal = 0;
  final List<Map<String, dynamic>> _openItems = [];

  // Purchases
  bool _loadingBuy = true;
  double _totalPurchased = 0;
  int _piCount = 0;
  DateTime? _lastPurchase;
  final List<Map<String, dynamic>> _recentPis = [];

  // Tasks
  bool _loadingActs = true;
  List<Map<String, dynamic>> _activities = [];
  List<Map<String, dynamic>> _orgUsers = [];
  Map<String, String> _userNames = {};

  // Complaints
  bool _loadingComplaints = true;
  List<Map<String, dynamic>> _complaints = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _supplierId => _supplier?['id'] as String?;
  String get _name => (_supplier?['name'] as String?) ?? '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    _loadSuppliers();
    _loadPending();
    _searchCtrl.addListener(_onSearch);
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) {
        setState(() { _showDrop = true; if (_searchCtrl.text.isEmpty) _filtered = _suppliers; });
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _showDrop = true;
      _filtered = q.isEmpty
          ? _suppliers
          : _suppliers.where((s) => matchesQuery('${s['name'] ?? ''}', q)).toList();
    });
  }

  Future<void> _loadSuppliers() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loadingList = false); return; }
    try {
      final List<Map<String, dynamic>> all = [];
      int from = 0; const page = 1000;
      while (true) {
        final rows = await Supabase.instance.client
            .from('suppliers')
            .select('id, name, phone, email, address, contact_person, ntn, credit_limit')
            .eq('org_id', orgId)
            .order('name')
            .range(from, from + page - 1);
        final list = List<Map<String, dynamic>>.from(rows);
        all.addAll(list);
        if (list.length < page) break;
        from += page;
        if (from > 100000) break;
      }
      if (!mounted) return;
      setState(() { _suppliers = all; _filtered = all; _loadingList = false; });
      if (widget.initialSupplier != null && _supplier == null) {
        final id = widget.initialSupplier!['id'];
        final m = all.where((s) => s['id'] == id).toList();
        _select(m.isNotEmpty ? m.first : widget.initialSupplier!);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  void _select(Map<String, dynamic> s) {
    setState(() {
      _supplier = s;
      _showDrop = false;
      _searchCtrl.text = s['name'] as String? ?? '';
    });
    _refresh();
  }

  void _refresh() {
    _loadPayables();
    _loadPurchases();
    _loadActivities();
    _loadComplaints();
  }

  /// Per-supplier pending count for the list badges: open/in-progress tasks +
  /// open complaints, grouped by supplier.
  Future<void> _loadPending() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;
    final map = <String, int>{};
    try {
      final t = await client
          .from('customer_activities')
          .select('supplier_id')
          .eq('org_id', orgId)
          .not('supplier_id', 'is', null)
          .inFilter('status', ['open', 'in_progress']);
      for (final r in t as List) {
        final id = r['supplier_id'] as String?;
        if (id != null) map[id] = (map[id] ?? 0) + 1;
      }
    } catch (_) {}
    try {
      final c = await client
          .from('crm_complaints')
          .select('supplier_id')
          .eq('org_id', orgId)
          .not('supplier_id', 'is', null)
          .inFilter('status', ['open', 'in_progress']);
      for (final r in c as List) {
        final id = r['supplier_id'] as String?;
        if (id != null) map[id] = (map[id] ?? 0) + 1;
      }
    } catch (_) {}
    if (mounted) setState(() => _pending = map);
  }

  // ── Payables / aging ──────────────────────────────────────────────
  Future<void> _loadPayables() async {
    final orgId = _orgId;
    final sid = _supplierId;
    if (orgId == null || sid == null) return;
    setState(() { _loadingPay = true; });
    try {
      final client = Supabase.instance.client;
      final asOf = DateTime.now();
      final asOfStr = DateFormat('yyyy-MM-dd').format(asOf);

      // Unpaid purchase invoices (org-wide, ties to the payable balance).
      final List invs = [];
      for (int f = 0; ; f += 1000) {
        final page = List.from(await client.from('purchase_invoices')
            .select('id, voucher_number, voucher_date, grand_total')
            .eq('org_id', orgId).eq('supplier_id', sid)
            .lte('voucher_date', asOfStr).range(f, f + 999));
        invs.addAll(page);
        if (page.length < 1000 || f > 200000) break;
      }

      // Payments to this supplier (CPV lines, account_type = supplier).
      double paid = 0;
      try {
        final List cpvHeaders = [];
        for (int f = 0; ; f += 1000) {
          final page = List.from(await client.from('cpv_vouchers')
              .select('id, voucher_date, created_at')
              .eq('org_id', orgId).eq('status', 'posted').range(f, f + 999));
          cpvHeaders.addAll(page);
          if (page.length < 1000 || f > 200000) break;
        }
        final asOfEnd = DateTime(asOf.year, asOf.month, asOf.day, 23, 59, 59);
        final cpvIds = <String>[];
        for (final v in cpvHeaders) {
          final m = v as Map;
          final ed = DateTime.tryParse((m['voucher_date'] as String?) ?? '') ??
              DateTime.tryParse((m['created_at'] as String?) ?? '');
          if (ed == null || !ed.isAfter(asOfEnd)) cpvIds.add(m['id'] as String);
        }
        for (var i = 0; i < cpvIds.length; i += 100) {
          final end = (i + 100) > cpvIds.length ? cpvIds.length : (i + 100);
          final lines = await client.from('cpv_voucher_lines')
              .select('amount')
              .eq('account_type', 'supplier').eq('account_id', sid)
              .inFilter('voucher_id', cpvIds.sublist(i, end));
          for (final ln in lines as List) {
            paid += ((ln as Map)['amount'] as num?)?.toDouble() ?? 0;
          }
        }
      } catch (_) {}

      final list = List<Map<String, dynamic>>.from(invs)
        ..sort((a, b) => (a['voucher_date'] as String).compareTo(b['voucher_date'] as String));
      double cur = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0;
      final items = <Map<String, dynamic>>[];
      double avail = paid;
      for (final inv in list) {
        final total = (inv['grand_total'] as num?)?.toDouble() ?? 0;
        final applied = avail >= total ? total : avail;
        avail -= applied;
        final outstanding = total - applied;
        if (outstanding <= 0.005) continue;
        final invDate = DateTime.parse(inv['voucher_date'] as String);
        final age = asOf.difference(invDate).inDays;
        if (age <= 30) cur += outstanding;
        else if (age <= 60) b1 += outstanding;
        else if (age <= 90) b2 += outstanding;
        else if (age <= 120) b3 += outstanding;
        else b4 += outstanding;
        items.add({
          'voucher_number': inv['voucher_number'] as String? ?? '-',
          'voucher_date': invDate,
          'outstanding': outstanding,
          'ageDays': age,
        });
      }
      items.sort((a, b) => (a['voucher_date'] as DateTime).compareTo(b['voucher_date'] as DateTime));
      if (!mounted) return;
      setState(() {
        _current = cur; _b1 = b1; _b2 = b2; _b3 = b3; _b4 = b4;
        _payTotal = cur + b1 + b2 + b3 + b4;
        _openItems..clear()..addAll(items);
        _loadingPay = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPay = false);
    }
  }

  // ── Purchases ─────────────────────────────────────────────────────
  Future<void> _loadPurchases() async {
    final orgId = _orgId;
    final sid = _supplierId;
    if (orgId == null || sid == null) return;
    setState(() { _loadingBuy = true; });
    try {
      final rows = await Supabase.instance.client.from('purchase_invoices')
          .select('id, voucher_number, voucher_date, grand_total')
          .eq('org_id', orgId).eq('supplier_id', sid)
          .order('voucher_date', ascending: false);
      final list = List<Map<String, dynamic>>.from(rows);
      double total = 0;
      DateTime? last;
      for (final r in list) {
        total += (r['grand_total'] as num?)?.toDouble() ?? 0;
        final d = DateTime.tryParse('${r['voucher_date']}');
        if (d != null && (last == null || d.isAfter(last))) last = d;
      }
      if (!mounted) return;
      setState(() {
        _totalPurchased = total;
        _piCount = list.length;
        _lastPurchase = last;
        _recentPis..clear()..addAll(list.take(12));
        _loadingBuy = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingBuy = false);
    }
  }

  // ── Tasks (customer_activities.supplier_id) ───────────────────────
  Future<void> _loadActivities() async {
    final orgId = _orgId;
    final sid = _supplierId;
    if (orgId == null || sid == null) return;
    setState(() { _loadingActs = true; });
    try {
      final client = Supabase.instance.client;
      final users = await client.from('users').select('id, name, role').eq('org_id', orgId).order('name');
      final names = <String, String>{};
      for (final u in users) { names[u['id'] as String] = (u['name'] as String?) ?? 'Unknown'; }
      final rows = await client.from('customer_activities')
          .select().eq('supplier_id', sid).order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _orgUsers = List<Map<String, dynamic>>.from(users);
        _userNames = names;
        _activities = List<Map<String, dynamic>>.from(rows);
        _loadingActs = false;
      });
      _loadPending();
    } catch (_) {
      if (mounted) setState(() { _activities = []; _loadingActs = false; });
    }
  }

  Future<void> _toggleDone(Map<String, dynamic> a) async {
    final done = (a['status'] as String?) == 'done';
    try {
      await Supabase.instance.client.from('customer_activities').update({
        'status': done ? 'open' : 'done',
        'completed_at': done ? null : DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', a['id']);
      _loadActivities();
    } catch (_) {}
  }

  Future<void> _deleteActivity(String id) async {
    try {
      await Supabase.instance.client.from('customer_activities').delete().eq('id', id);
      _loadActivities();
    } catch (_) {}
  }

  Future<void> _taskDialog({Map<String, dynamic>? existing}) async {
    final orgId = _orgId;
    final sid = _supplierId;
    if (orgId == null || sid == null) return;
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: (existing?['title'] as String?) ?? '');
    final noteCtrl = TextEditingController(text: (existing?['note'] as String?) ?? '');
    DateTime? due = DateTime.tryParse('${existing?['due_date']}');
    String? assignee = existing?['assigned_to'] as String?;
    String priority = (existing?['priority'] as String?) ?? 'medium';
    String status = (existing?['status'] as String?) ?? 'open';

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: Text(isEdit ? 'Edit task' : 'New task'),
        content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: titleCtrl, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Title *', isDense: true)),
          const SizedBox(height: 12),
          TextField(controller: noteCtrl, maxLines: 3, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Description', isDense: true)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(context: ctx, initialDate: due ?? DateTime.now(),
                    firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (picked != null) setS(() => due = picked);
              },
              child: InputDecorator(decoration: const InputDecoration(labelText: 'Due date', isDense: true),
                  child: Text(due == null ? 'None' : DateFormat('d MMM yyyy').format(due!), style: const TextStyle(fontSize: 14))),
            )),
            if (due != null) IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => setS(() => due = null)),
            const SizedBox(width: 8),
            Expanded(child: DropdownButtonFormField<String>(value: priority,
              decoration: const InputDecoration(labelText: 'Priority', isDense: true),
              items: const [DropdownMenuItem(value: 'low', child: Text('Low')), DropdownMenuItem(value: 'medium', child: Text('Medium')), DropdownMenuItem(value: 'high', child: Text('High'))],
              onChanged: (v) => setS(() => priority = v ?? 'medium'))),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(value: assignee, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Assignee', isDense: true),
            items: [const DropdownMenuItem(value: null, child: Text('Unassigned')),
              for (final u in _orgUsers) DropdownMenuItem(value: u['id'] as String, child: Text('${u['name'] ?? 'Unknown'}'))],
            onChanged: (v) => setS(() => assignee = v)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: status,
            decoration: const InputDecoration(labelText: 'Status', isDense: true),
            items: const [DropdownMenuItem(value: 'open', child: Text('Open')), DropdownMenuItem(value: 'in_progress', child: Text('In progress')), DropdownMenuItem(value: 'done', child: Text('Done'))],
            onChanged: (v) => setS(() => status = v ?? 'open')),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () async {
            if (titleCtrl.text.trim().isEmpty) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Title is required')));
              return;
            }
            final nowIso = DateTime.now().toIso8601String();
            final body = <String, dynamic>{
              'org_id': orgId,
              'supplier_id': sid,
              'customer_id': null,
              'type': 'task',
              'title': titleCtrl.text.trim(),
              'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
              'due_date': due != null ? DateFormat('yyyy-MM-dd').format(due!) : null,
              'assigned_to': assignee,
              'priority': priority,
              'status': status,
              'updated_at': nowIso,
            };
            try {
              final client = Supabase.instance.client;
              if (isEdit) {
                await client.from('customer_activities').update(body).eq('id', existing['id']);
              } else {
                body['id'] = 'act_${DateTime.now().microsecondsSinceEpoch}';
                body['created_by'] = ref.read(currentUserProvider)?.id;
                body['created_at'] = nowIso;
                body['completed_at'] = status == 'done' ? nowIso : null;
                await client.from('customer_activities').insert(body);
              }
              if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
              _loadActivities();
            } catch (e) {
              if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: ${e.toString().split('\n').first}')));
            }
          }, child: Text(isEdit ? 'Save' : 'Create')),
        ],
      )),
    );
  }

  // ── Complaints (crm_complaints.supplier_id) ───────────────────────
  Future<void> _loadComplaints() async {
    final sid = _supplierId;
    if (sid == null) return;
    setState(() { _loadingComplaints = true; });
    try {
      final rows = await Supabase.instance.client.from('crm_complaints')
          .select().eq('supplier_id', sid).order('created_at', ascending: false);
      if (!mounted) return;
      setState(() { _complaints = List<Map<String, dynamic>>.from(rows); _loadingComplaints = false; });
      _loadPending();
    } catch (_) {
      if (mounted) setState(() { _complaints = []; _loadingComplaints = false; });
    }
  }

  int get _openComplaints => _complaints.where((c) {
    final s = c['status'] as String?;
    return s == 'open' || s == 'in_progress';
  }).length;

  int get _openTasks => _activities.where((a) {
    final s = a['status'] as String?;
    return s == 'open' || s == 'in_progress';
  }).length;

  Widget _tabBadge(int n, Color c) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10)),
      child: Text('$n', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700)));

  Future<void> _newComplaint() async {
    final orgId = _orgId;
    final sid = _supplierId;
    if (orgId == null || sid == null) return;
    final subjectCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Log complaint'),
      content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: subjectCtrl, textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Subject *', isDense: true)),
        const SizedBox(height: 12),
        TextField(controller: descCtrl, maxLines: 3, textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Description', isDense: true, alignLabelWithHint: true)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
        ElevatedButton(onPressed: () async {
          if (subjectCtrl.text.trim().isEmpty) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Subject is required')));
            return;
          }
          try {
            await Supabase.instance.client.from('crm_complaints').insert({
              'id': 'cmp_${DateTime.now().microsecondsSinceEpoch}',
              'org_id': orgId,
              'supplier_id': sid,
              'customer_id': null,
              'subject': subjectCtrl.text.trim(),
              'description': descCtrl.text.trim().isEmpty ? null : descCtrl.text.trim(),
              'status': 'open',
              'created_by': ref.read(currentUserProvider)?.id,
              'created_at': DateTime.now().toIso8601String(),
            });
            if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
            _loadComplaints();
          } catch (e) {
            if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: ${e.toString().split('\n').first}')));
          }
        }, child: const Text('Log')),
      ],
    ));
  }

  Future<void> _resolveComplaint(Map<String, dynamic> c) async {
    try {
      await Supabase.instance.client.from('crm_complaints').update({
        'status': 'resolved',
        'resolved_at': DateTime.now().toIso8601String(),
      }).eq('id', c['id']);
      _loadComplaints();
    } catch (_) {}
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating));
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(children: [
        _headerBar(),
        if (_supplier == null)
          Expanded(child: _pickerBody())
        else
          Expanded(child: Column(children: [
            Container(color: Colors.white, child: TabBar(
              controller: _tabs,
              isScrollable: true,
              labelColor: AppTheme.primary,
              unselectedLabelColor: AppTheme.textSecondary,
              indicatorColor: AppTheme.primary,
              labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              tabs: [
                const Tab(text: 'Overview'),
                const Tab(text: 'Payables'),
                const Tab(text: 'Purchases'),
                Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Tasks'),
                  if (_openTasks > 0) _tabBadge(_openTasks, AppTheme.warning),
                ])),
                Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Complaints'),
                  if (_openComplaints > 0) _tabBadge(_openComplaints, AppTheme.danger),
                ])),
              ],
            )),
            const Divider(height: 1),
            Expanded(child: TabBarView(controller: _tabs, children: [
              _overviewTab(), _payablesTab(), _purchasesTab(), _tasksTab(), _complaintsTab(),
            ])),
          ])),
      ]),
    );
  }

  Widget _headerBar() {
    final canPop = Navigator.of(context).canPop();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 24, 14),
      child: Row(children: [
        if (canPop) ...[
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop(), tooltip: 'Back'),
          const SizedBox(width: 4),
        ],
        if (_supplier != null) ...[
          CircleAvatar(radius: 20, backgroundColor: AppTheme.primary.withOpacity(0.12),
            child: Text(_name.isNotEmpty ? _name[0].toUpperCase() : '?', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Supplier', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            Text(_name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
          ])),
          TextButton.icon(onPressed: () => setState(() { _supplier = null; _searchCtrl.clear(); _filtered = _suppliers; }),
              icon: const Icon(Icons.arrow_back, size: 16), label: const Text('All suppliers')),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh, tooltip: 'Refresh'),
        ] else
          const Expanded(child: Text('Suppliers', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
      ]),
    );
  }

  // -------------------------------------------------------------- Picker

  Widget _pickerBody() {
    if (_loadingList) return const Center(child: CircularProgressIndicator());
    final q = _searchCtrl.text.toLowerCase().trim();
    final list = q.isEmpty
        ? _suppliers
        : _suppliers.where((s) => matchesQuery(
            '${s['name'] ?? ''} ${s['contact_person'] ?? ''} ${s['phone'] ?? ''}', q)).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_suppliers.length} suppliers',
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        TextField(
          controller: _searchCtrl,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search by name, contact or phone…',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.border)),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: HScrollOnNarrow(
          minWidth: 650,
          child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            // header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: Row(children: const [
                Expanded(flex: 4, child: Text('Supplier', style: _th)),
                Expanded(flex: 3, child: Text('Contact', style: _th)),
                Expanded(flex: 3, child: Text('Phone', style: _th)),
                Expanded(flex: 3, child: Text('Email', style: _th)),
                SizedBox(width: 70, child: Text('Pending', textAlign: TextAlign.right, style: _th)),
              ]),
            ),
            const Divider(height: 1),
            Expanded(child: list.isEmpty
                ? const Center(child: Text('No suppliers found.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final s = list[i];
                      return InkWell(
                        onTap: () => _select(s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                          child: Row(children: [
                            Expanded(flex: 4, child: Text(s['name'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
                            Expanded(flex: 3, child: Text(_val(s['contact_person']), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 3, child: Text(_val(s['phone']), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary))),
                            Expanded(flex: 3, child: Text(_val(s['email']), style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                            SizedBox(width: 70, child: Align(
                              alignment: Alignment.centerRight,
                              child: (_pending[s['id']] ?? 0) > 0
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(color: AppTheme.danger, borderRadius: BorderRadius.circular(10)),
                                      child: Text('${_pending[s['id']]}',
                                          style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w800)),
                                    )
                                  : const Icon(Icons.local_shipping_outlined, size: 18, color: AppTheme.primary),
                            )),
                          ]),
                        ),
                      );
                    },
                  )),
          ]),
        ))),
      ]),
    );
  }

  // -------------------------------------------------------------- Overview

  Widget _overviewTab() {
    final c = _supplier!;
    final creditLimit = (c['credit_limit'] as num?)?.toDouble();
    return ListView(padding: const EdgeInsets.fromLTRB(32, 20, 32, 32), children: [
      if (_openTasks > 0 || _openComplaints > 0) ...[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.warning.withOpacity(0.10),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.warning.withOpacity(0.35)),
          ),
          child: Row(children: [
            const Icon(Icons.notifications_active_outlined, size: 16, color: AppTheme.warning),
            const SizedBox(width: 8),
            Expanded(child: Text(
              [
                if (_openTasks > 0) '$_openTasks open task${_openTasks == 1 ? '' : 's'}',
                if (_openComplaints > 0) '$_openComplaints open complaint${_openComplaints == 1 ? '' : 's'}',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            )),
            if (_openTasks > 0)
              TextButton(onPressed: () => _tabs.animateTo(3), child: const Text('View tasks')),
            if (_openComplaints > 0)
              TextButton(onPressed: () => _tabs.animateTo(4), child: const Text('View complaints')),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      // Outstanding payable headline
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.account_balance_wallet_outlined, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            const Text('Outstanding payable', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            const Spacer(),
            if (_loadingPay) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 6),
          Text('Rs ${_money2.format(_payTotal)}',
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppTheme.primary)),
          const SizedBox(height: 12),
          Row(children: [
            _miniStat('Open invoices', '${_openItems.length}'),
            const SizedBox(width: 24),
            _miniStat('Credit limit', creditLimit == null || creditLimit == 0 ? 'No limit' : 'Rs ${_money.format(creditLimit)}'),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      // Purchase summary
      _card(title: 'Purchase summary', icon: Icons.shopping_bag_outlined, child: Row(children: [
        _miniStat('Total purchased', 'Rs ${_money.format(_totalPurchased)}'),
        const SizedBox(width: 24),
        _miniStat('Invoices', '$_piCount'),
        const SizedBox(width: 24),
        _miniStat('Last purchase', _lastPurchase == null ? '—' : DateFormat('d MMM y').format(_lastPurchase!)),
      ])),
      const SizedBox(height: 16),
      _card(title: 'Contact', icon: Icons.local_shipping_outlined, child: Column(children: [
        _infoRow(Icons.person_outline, 'Contact', _val(c['contact_person'])),
        _infoRow(Icons.phone_outlined, 'Phone', _val(c['phone']),
            onTap: (c['phone'] as String?)?.trim().isNotEmpty == true ? () => _copy(c['phone'] as String, 'Phone') : null),
        _infoRow(Icons.mail_outline, 'Email', _val(c['email'])),
        _infoRow(Icons.badge_outlined, 'NTN', _val(c['ntn'])),
        _infoRow(Icons.home_outlined, 'Address', _val(c['address'])),
      ])),
    ]);
  }

  String _val(dynamic v) => (v as String?)?.trim().isNotEmpty == true ? v as String : '—';

  // -------------------------------------------------------------- Payables

  Widget _payablesTab() {
    if (_loadingPay) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.fromLTRB(32, 20, 32, 32), children: [
      Row(children: [
        _bucketCard('Current (0-30)', _current, AppTheme.success),
        const SizedBox(width: 10),
        _bucketCard('31-60', _b1, AppTheme.warning),
        const SizedBox(width: 10),
        _bucketCard('61-90', _b2, Colors.orange),
        const SizedBox(width: 10),
        _bucketCard('91-120', _b3, Colors.deepOrange),
        const SizedBox(width: 10),
        _bucketCard('120+', _b4, AppTheme.danger),
        const SizedBox(width: 10),
        _bucketCard('Total', _payTotal, AppTheme.primary, bold: true),
      ]),
      const SizedBox(height: 20),
      const Text('Open invoices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      if (_openItems.isEmpty)
        Container(width: double.infinity, padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: const Center(child: Text('No open invoices — nothing outstanding.', style: TextStyle(color: AppTheme.textSecondary))))
      else
        Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
          child: Column(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), color: AppTheme.background,
              child: Row(children: const [
                Expanded(flex: 3, child: Text('Voucher #', style: _th)),
                Expanded(flex: 3, child: Text('Date', style: _th)),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: Text('Days', style: _th))),
                Expanded(flex: 3, child: Align(alignment: Alignment.center, child: Text('Bucket', style: _th))),
                Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('Outstanding', style: _th))),
              ])),
            const Divider(height: 1),
            ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              itemCount: _openItems.length, separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final inv = _openItems[i];
                final age = inv['ageDays'] as int;
                final (label, color) = _bucketOf(age);
                return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9), child: Row(children: [
                  Expanded(flex: 3, child: Text(inv['voucher_number'] as String, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                  Expanded(flex: 3, child: Text(DateFormat('d MMM yyyy').format(inv['voucher_date'] as DateTime), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: Text('$age', style: const TextStyle(fontSize: 12)))),
                  Expanded(flex: 3, child: Align(alignment: Alignment.center, child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color))))),
                  Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(_money2.format(inv['outstanding'] as double), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary)))),
                ]));
              }),
          ])),
    ]);
  }

  // -------------------------------------------------------------- Purchases

  Widget _purchasesTab() {
    if (_loadingBuy) return const Center(child: CircularProgressIndicator());
    if (_recentPis.isEmpty) {
      return const Center(child: Text('No purchase invoices for this supplier.', style: TextStyle(color: AppTheme.textSecondary)));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(32, 20, 32, 32), children: [
      Row(children: [
        _bucketCard('Total purchased', _totalPurchased, AppTheme.primary, bold: true),
        const SizedBox(width: 10),
        _bucketCard('Invoices', _piCount.toDouble(), AppTheme.textPrimary),
      ]),
      const SizedBox(height: 20),
      const Text('Recent purchase invoices', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
        child: Column(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), color: AppTheme.background,
            child: Row(children: const [
              Expanded(flex: 3, child: Text('Voucher #', style: _th)),
              Expanded(flex: 3, child: Text('Date', style: _th)),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('Amount', style: _th))),
            ])),
          const Divider(height: 1),
          ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
            itemCount: _recentPis.length, separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = _recentPis[i];
              final d = DateTime.tryParse('${p['voucher_date']}');
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9), child: Row(children: [
                Expanded(flex: 3, child: Text(p['voucher_number'] as String? ?? '-', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                Expanded(flex: 3, child: Text(d != null ? DateFormat('d MMM yyyy').format(d) : '-', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(_money2.format((p['grand_total'] as num?)?.toDouble() ?? 0), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)))),
              ]));
            }),
        ])),
    ]);
  }

  // -------------------------------------------------------------- Tasks

  Widget _tasksTab() {
    if (_loadingActs) return const Center(child: CircularProgressIndicator());
    final open = _activities.where((a) => (a['status'] as String?) != 'done').toList()
      ..sort((a, b) => '${a['due_date']}'.compareTo('${b['due_date']}'));
    final done = _activities.where((a) => (a['status'] as String?) == 'done').toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(32, 16, 32, 8), child: Row(children: [
        const Text('Tasks', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const Spacer(),
        ElevatedButton.icon(icon: const Icon(Icons.add_task, size: 16), label: const Text('Add task'), onPressed: () => _taskDialog()),
      ])),
      Expanded(child: (open.isEmpty && done.isEmpty)
          ? const Center(child: Text('No tasks yet — add one for this supplier', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView(padding: const EdgeInsets.fromLTRB(32, 8, 32, 32), children: [
              if (open.isNotEmpty) ...[
                const Text('Open', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                for (final a in open) _taskCard(a, false),
                const SizedBox(height: 20),
              ],
              if (done.isNotEmpty) ...[
                const Text('Done', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                for (final a in done) _taskCard(a, true),
              ],
            ])),
    ]);
  }

  Widget _taskCard(Map<String, dynamic> a, bool done) {
    final due = DateTime.tryParse('${a['due_date']}');
    final now = DateTime.now();
    final overdue = !done && due != null && due.isBefore(DateTime(now.year, now.month, now.day));
    final assignee = a['assigned_to'] as String?;
    final title = (a['title'] as String?)?.trim();
    final note = (a['note'] as String?)?.trim();
    return Container(margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: overdue ? AppTheme.danger.withOpacity(0.5) : AppTheme.border)),
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(onTap: () => _toggleDone(a), child: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, size: 20, color: done ? AppTheme.success : AppTheme.textSecondary)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (due != null) Text(DateFormat('d MMM y').format(due), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: overdue ? AppTheme.danger : AppTheme.textSecondary)),
            if (overdue) const Padding(padding: EdgeInsets.only(left: 6), child: Text('overdue', style: TextStyle(fontSize: 11, color: AppTheme.danger, fontWeight: FontWeight.w700))),
          ]),
          if (due != null) const SizedBox(height: 4),
          Text(title != null && title.isNotEmpty ? title : (note ?? '(untitled)'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, decoration: done ? TextDecoration.lineThrough : null, color: done ? AppTheme.textSecondary : null)),
          if (note != null && note.isNotEmpty && title != null && title.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(note, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.person_outline, size: 13, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(assignee == null ? 'Unassigned' : (_userNames[assignee] ?? 'Unknown'), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
        ])),
        IconButton(icon: const Icon(Icons.edit_outlined, size: 16, color: AppTheme.textSecondary), onPressed: () => _taskDialog(existing: a), tooltip: 'Edit'),
        IconButton(icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.textSecondary), onPressed: () => _deleteActivity(a['id'] as String), tooltip: 'Delete'),
      ]),
    );
  }

  // -------------------------------------------------------------- Complaints

  Widget _complaintsTab() {
    if (_loadingComplaints) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(32, 16, 32, 8), child: Row(children: [
        const Text('Complaints', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const Spacer(),
        ElevatedButton.icon(icon: const Icon(Icons.report_gmailerrorred_outlined, size: 16), label: const Text('Log complaint'), onPressed: _newComplaint),
      ])),
      Expanded(child: _complaints.isEmpty
          ? const Center(child: Text('No complaints logged.', style: TextStyle(color: AppTheme.textSecondary)))
          : ListView.separated(padding: const EdgeInsets.fromLTRB(32, 8, 32, 32), itemCount: _complaints.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final c = _complaints[i];
                final status = (c['status'] as String?) ?? 'open';
                final open = status == 'open' || status == 'in_progress';
                final created = DateTime.tryParse('${c['created_at']}');
                return Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(c['subject'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: (open ? AppTheme.warning : AppTheme.success).withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
                        child: Text(status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: open ? AppTheme.warning : AppTheme.success))),
                    ]),
                    if ((c['description'] as String?)?.isNotEmpty == true) ...[
                      const SizedBox(height: 6),
                      Text(c['description'] as String, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    ],
                    const SizedBox(height: 8),
                    Row(children: [
                      Text(created == null ? '' : DateFormat('d MMM y, h:mm a').format(created.toLocal()), style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      const Spacer(),
                      if (open) TextButton(onPressed: () => _resolveComplaint(c), child: const Text('Mark resolved')),
                    ]),
                  ]));
              })),
    ]);
  }

  // -------------------------------------------------------------- shared bits

  (String, Color) _bucketOf(int age) {
    if (age <= 30) return ('0-30', AppTheme.success);
    if (age <= 60) return ('31-60', AppTheme.warning);
    if (age <= 90) return ('61-90', Colors.orange);
    if (age <= 120) return ('91-120', Colors.deepOrange);
    return ('120+', AppTheme.danger);
  }

  Widget _card({required String title, required IconData icon, required Widget child}) {
    return Container(width: double.infinity, padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, size: 18, color: AppTheme.textSecondary), const SizedBox(width: 8), Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))]),
        const SizedBox(height: 12),
        child,
      ]));
  }

  Widget _infoRow(IconData icon, String label, String value, {VoidCallback? onTap}) {
    final content = Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 15, color: AppTheme.textSecondary),
      const SizedBox(width: 10),
      SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
      Expanded(child: Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: onTap != null ? AppTheme.primary : null))),
      if (onTap != null) const Icon(Icons.copy, size: 13, color: AppTheme.textSecondary),
    ]));
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }

  Widget _miniStat(String label, String value, {Color? color}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color ?? Colors.black87)),
    ]);
  }

  Widget _bucketCard(String label, double v, Color c, {bool bold = false}) {
    return Expanded(child: Container(padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 4),
        Text(_money2.format(v), style: TextStyle(fontSize: bold ? 16 : 14, fontWeight: FontWeight.w800, color: v.abs() > 0.005 ? c : AppTheme.textSecondary)),
      ])));
  }
}

const _th = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
