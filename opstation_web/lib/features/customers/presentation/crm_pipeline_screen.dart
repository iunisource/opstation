import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// CRM Pipeline — a Kanban board of opportunities across per-org stages.
/// Columns come from `crm_pipeline_stages` (seeded with defaults on first
/// open; renamable later by master admins). Cards are `crm_opportunities`;
/// a card may be tied to an existing customer or be a bare prospect (lead)
/// that can later be converted into a customer.
class CrmPipelineScreen extends ConsumerStatefulWidget {
  const CrmPipelineScreen({super.key});
  @override
  ConsumerState<CrmPipelineScreen> createState() => _CrmPipelineScreenState();
}

const List<Map<String, dynamic>> _kDefaultStages = [
  {'key': 'new', 'label': 'New', 'position': 1, 'is_won': false, 'is_lost': false},
  {'key': 'contacted', 'label': 'Contacted', 'position': 2, 'is_won': false, 'is_lost': false},
  {'key': 'quoted', 'label': 'Quoted', 'position': 3, 'is_won': false, 'is_lost': false},
  {'key': 'negotiation', 'label': 'Negotiation', 'position': 4, 'is_won': false, 'is_lost': false},
  {'key': 'won', 'label': 'Won', 'position': 5, 'is_won': true, 'is_lost': false},
  {'key': 'lost', 'label': 'Lost', 'position': 6, 'is_won': false, 'is_lost': true},
];

class _CrmPipelineScreenState extends ConsumerState<CrmPipelineScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _stages = [];
  List<Map<String, dynamic>> _opps = [];
  final List<Map<String, dynamic>> _allCustomers = [];
  final Map<String, Map<String, dynamic>> _custById = {};
  final Map<String, String> _userNames = {};
  List<Map<String, dynamic>> _orgUsers = [];

  final _money = NumberFormat('#,##0');

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;

      // Stages (seed defaults on first open).
      var stages = List<Map<String, dynamic>>.from(await client
          .from('crm_pipeline_stages')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('position'));
      if (stages.isEmpty) {
        final rows = [
          for (final s in _kDefaultStages)
            {
              'id': 'stg_${orgId}_${s['key']}',
              'org_id': orgId,
              'key': s['key'],
              'label': s['label'],
              'position': s['position'],
              'is_won': s['is_won'],
              'is_lost': s['is_lost'],
              'is_active': true,
            }
        ];
        try {
          await client.from('crm_pipeline_stages').insert(rows);
        } catch (_) {/* may already exist from a race */}
        stages = List<Map<String, dynamic>>.from(await client
            .from('crm_pipeline_stages')
            .select()
            .eq('org_id', orgId)
            .eq('is_active', true)
            .order('position'));
      }

      final opps = List<Map<String, dynamic>>.from(await client
          .from('crm_opportunities')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: true));

      // Customers (paginate past PostgREST 1000 cap) for names + picker.
      final custs = <Map<String, dynamic>>[];
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client
            .from('customers')
            .select('id, shop_name, code, phone')
            .eq('org_id', orgId)
            .order('shop_name')
            .range(offset, offset + pageSize - 1);
        custs.addAll(List<Map<String, dynamic>>.from(page));
        if (page.length < pageSize) break;
        offset += pageSize;
      }
      final custMap = <String, Map<String, dynamic>>{};
      for (final c in custs) {
        custMap[c['id'] as String] = c;
      }

      final users = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId)
          .order('name');
      final names = <String, String>{};
      for (final u in users) {
        names[u['id'] as String] = (u['name'] as String?) ?? 'Unknown';
      }

      if (!mounted) return;
      setState(() {
        _stages = stages;
        _opps = opps;
        _allCustomers
          ..clear()
          ..addAll(custs);
        _custById
          ..clear()
          ..addAll(custMap);
        _orgUsers = List<Map<String, dynamic>>.from(users);
        _userNames
          ..clear()
          ..addAll(names);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _stageByKey(String key) {
    for (final s in _stages) {
      if (s['key'] == key) return s;
    }
    return null;
  }

  Future<void> _moveOpp(Map<String, dynamic> opp, String stageKey) async {
    if (opp['stage'] == stageKey) return;
    final stage = _stageByKey(stageKey);
    final won = stage?['is_won'] == true;
    final lost = stage?['is_lost'] == true;
    final status = won ? 'won' : (lost ? 'lost' : 'open');
    final nowIso = DateTime.now().toIso8601String();

    // Optimistic local update for snappy drag.
    setState(() {
      opp['stage'] = stageKey;
      opp['status'] = status;
      opp['closed_at'] = (won || lost) ? nowIso : null;
    });

    try {
      await Supabase.instance.client.from('crm_opportunities').update({
        'stage': stageKey,
        'status': status,
        'closed_at': (won || lost) ? nowIso : null,
        'updated_at': nowIso,
      }).eq('id', opp['id']);
    } catch (_) {
      _load(); // resync on failure
    }
  }

  Future<void> _deleteOpp(String id) async {
    try {
      await Supabase.instance.client
          .from('crm_opportunities')
          .delete()
          .eq('id', id);
      _load();
    } catch (_) {/* ignore */}
  }

  Future<Map<String, dynamic>?> _pickCustomer() async {
    final searchCtrl = TextEditingController();
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = searchCtrl.text.toLowerCase();
          final filtered = (q.isEmpty
                  ? _allCustomers.take(30)
                  : _allCustomers.where((c) =>
                      (c['shop_name'] as String? ?? '')
                          .toLowerCase()
                          .contains(q) ||
                      (c['code'] as String? ?? '').toLowerCase().contains(q)))
              .toList();
          return AlertDialog(
            title: const Text('Select customer'),
            content: SizedBox(
              width: 440,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                        hintText: 'Search name or code…',
                        prefixIcon: Icon(Icons.search),
                        isDense: true),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        return ListTile(
                          dense: true,
                          title: Text(c['shop_name'] as String? ?? '',
                              style: const TextStyle(fontSize: 13)),
                          subtitle: (c['code'] as String?)?.isNotEmpty == true
                              ? Text(c['code'] as String,
                                  style: const TextStyle(fontSize: 11))
                              : null,
                          onTap: () =>
                              Navigator.of(ctx, rootNavigator: true).pop(c),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _convertProspect(Map<String, dynamic> opp) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final name = (opp['prospect_name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return;
    try {
      final id = 'cust_${DateTime.now().millisecondsSinceEpoch}';
      final code = 'L${DateTime.now().millisecondsSinceEpoch % 1000000}';
      await Supabase.instance.client.from('customers').insert({
        'id': id,
        'org_id': orgId,
        'shop_name': name,
        'code': code,
        'phone': opp['prospect_phone'],
        'is_active': true,
        'updated_at': DateTime.now().toIso8601String(),
      });
      await Supabase.instance.client.from('crm_opportunities').update({
        'customer_id': id,
        'prospect_name': null,
        'prospect_phone': null,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', opp['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Converted "$name" to a customer')),
        );
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Convert failed: ${e.toString().split('\n').first}')),
        );
      }
    }
  }

  Future<void> _oppDialog({Map<String, dynamic>? existing}) async {
    final orgId = _orgId;
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: existing?['title'] ?? '');
    final valueCtrl = TextEditingController(
        text: existing?['value'] == null ? '' : '${existing!['value']}');
    final notesCtrl = TextEditingController(text: existing?['notes'] ?? '');
    final pNameCtrl =
        TextEditingController(text: existing?['prospect_name'] ?? '');
    final pPhoneCtrl =
        TextEditingController(text: existing?['prospect_phone'] ?? '');
    bool prospect = isEdit ? (existing!['customer_id'] == null && (existing['prospect_name'] != null)) : false;
    Map<String, dynamic>? selectedCustomer;
    if (isEdit && existing!['customer_id'] != null) {
      final c = _custById[existing['customer_id']];
      if (c != null) selectedCustomer = c;
    }
    String stage = (existing?['stage'] as String?) ??
        (_stages.isNotEmpty ? _stages.first['key'] as String : 'new');
    String? assignee = existing?['assigned_to'] as String?;
    DateTime? close = existing?['expected_close'] == null
        ? null
        : DateTime.tryParse('${existing!['expected_close']}');

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isEdit ? 'Edit opportunity' : 'New opportunity'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(labelText: 'Title *'),
                  ),
                  const SizedBox(height: 12),
                  // Attach: existing customer vs prospect/lead
                  Row(children: [
                    ChoiceChip(
                      label: const Text('Existing customer'),
                      selected: !prospect,
                      onSelected: (_) => setS(() => prospect = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('New prospect'),
                      selected: prospect,
                      onSelected: (_) => setS(() => prospect = true),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (!prospect)
                    InkWell(
                      onTap: () async {
                        final c = await _pickCustomer();
                        if (c != null) setS(() => selectedCustomer = c);
                      },
                      child: InputDecorator(
                        decoration:
                            const InputDecoration(labelText: 'Customer'),
                        child: Text(
                          selectedCustomer == null
                              ? 'Choose a customer'
                              : (selectedCustomer!['shop_name'] as String? ??
                                  ''),
                        ),
                      ),
                    )
                  else ...[
                    TextField(
                      controller: pNameCtrl,
                      decoration: const InputDecoration(
                          labelText: 'Prospect shop name *'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: pPhoneCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Phone'),
                      keyboardType: TextInputType.phone,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: valueCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Value (PKR)', prefixText: 'Rs '),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'))
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: stage,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Stage'),
                        items: [
                          for (final s in _stages)
                            DropdownMenuItem(
                                value: s['key'] as String,
                                child: Text(s['label'] as String)),
                        ],
                        onChanged: (v) => setS(() => stage = v ?? stage),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: close ?? DateTime.now(),
                            firstDate: DateTime.now()
                                .subtract(const Duration(days: 1)),
                            lastDate: DateTime.now()
                                .add(const Duration(days: 730)),
                          );
                          if (picked != null) setS(() => close = picked);
                        },
                        child: InputDecorator(
                          decoration: const InputDecoration(
                              labelText: 'Expected close'),
                          child: Text(close == null
                              ? 'Pick a date'
                              : DateFormat('d MMM y').format(close!)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        value: assignee,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Owner'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('Unassigned')),
                          for (final u in _orgUsers)
                            DropdownMenuItem<String?>(
                                value: u['id'] as String,
                                child: Text('${u['name'] ?? 'Unknown'}')),
                        ],
                        onChanged: (v) => setS(() => assignee = v),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  if (isEdit &&
                      existing!['customer_id'] == null &&
                      (existing['prospect_name'] as String?)?.trim().isNotEmpty ==
                          true) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.person_add_alt, size: 16),
                        label: const Text('Convert prospect to customer'),
                        onPressed: () async {
                          Navigator.of(ctx, rootNavigator: true).pop();
                          await _convertProspect(existing);
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (isEdit)
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx, rootNavigator: true).pop();
                  await _deleteOpp(existing!['id'] as String);
                },
                child: const Text('Delete',
                    style: TextStyle(color: AppTheme.danger)),
              ),
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (titleCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Title is required')));
                  return;
                }
                if (!prospect && selectedCustomer == null) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Choose a customer or switch to prospect')));
                  return;
                }
                if (prospect && pNameCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('Prospect shop name is required')));
                  return;
                }
                final st = _stageByKey(stage);
                final status = st?['is_won'] == true
                    ? 'won'
                    : (st?['is_lost'] == true ? 'lost' : 'open');
                final nowIso = DateTime.now().toIso8601String();
                final data = {
                  'org_id': orgId,
                  'title': titleCtrl.text.trim(),
                  'value': valueCtrl.text.trim().isEmpty
                      ? null
                      : double.tryParse(valueCtrl.text.trim()),
                  'stage': stage,
                  'status': status,
                  'expected_close': close == null
                      ? null
                      : DateFormat('yyyy-MM-dd').format(close!),
                  'assigned_to': assignee,
                  'notes': notesCtrl.text.trim().isEmpty
                      ? null
                      : notesCtrl.text.trim(),
                  'customer_id': prospect ? null : selectedCustomer!['id'],
                  'prospect_name':
                      prospect ? pNameCtrl.text.trim() : null,
                  'prospect_phone': prospect
                      ? (pPhoneCtrl.text.trim().isEmpty
                          ? null
                          : pPhoneCtrl.text.trim())
                      : null,
                  'updated_at': nowIso,
                };
                try {
                  final client = Supabase.instance.client;
                  if (isEdit) {
                    await client
                        .from('crm_opportunities')
                        .update(data)
                        .eq('id', existing!['id']);
                  } else {
                    data['id'] =
                        'opp_${DateTime.now().millisecondsSinceEpoch}';
                    data['created_by'] =
                        Supabase.instance.client.auth.currentUser?.id;
                    data['created_at'] = nowIso;
                    await client.from('crm_opportunities').insert(data);
                  }
                  if (ctx.mounted) {
                    Navigator.of(ctx, rootNavigator: true).pop();
                  }
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            'Failed: ${e.toString().split('\n').first}')));
                  }
                }
              },
              child: Text(isEdit ? 'Save' : 'Create'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Pipeline',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            if (!_loading)
              Text('${_opps.where((o) => o['status'] == 'open').length} open',
                  style: const TextStyle(color: AppTheme.textSecondary)),
            const Spacer(),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New opportunity'),
              onPressed: () => _oppDialog(),
            ),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _stages.isEmpty
                    ? const Center(child: Text('No stages configured'))
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final s in _stages) _column(s),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _column(Map<String, dynamic> stage) {
    final key = stage['key'] as String;
    final cards =
        _opps.where((o) => (o['stage'] as String?) == key).toList();
    final total = cards.fold<double>(
        0, (s, o) => s + ((o['value'] as num?)?.toDouble() ?? 0));
    final accent = stage['is_won'] == true
        ? AppTheme.success
        : stage['is_lost'] == true
            ? AppTheme.danger
            : AppTheme.primary;

    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _moveOpp(d.data, key),
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        return Container(
          width: 300,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: hovering
                ? accent.withOpacity(0.06)
                : AppTheme.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: hovering ? accent : AppTheme.border,
                width: hovering ? 1.4 : 1),
          ),
          child: Column(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(stage['label'] as String,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border)),
                    child: Text('${cards.length}',
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: Text('Rs ${_money.format(total)}',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: cards.isEmpty
                    ? const SizedBox.expand()
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: cards.length,
                        itemBuilder: (_, i) => _draggableCard(cards[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _draggableCard(Map<String, dynamic> opp) {
    final card = _card(opp);
    return Draggable<Map<String, dynamic>>(
      data: opp,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: 268, child: _card(opp, dragging: true)),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }

  Widget _card(Map<String, dynamic> opp, {bool dragging = false}) {
    final cid = opp['customer_id'] as String?;
    final who = cid != null
        ? (_custById[cid]?['shop_name'] as String? ?? '(customer)')
        : (opp['prospect_name'] as String? ?? 'Prospect');
    final isProspect = cid == null;
    final value = (opp['value'] as num?)?.toDouble() ?? 0;
    final asg = opp['assigned_to'] as String?;
    final close = DateTime.tryParse('${opp['expected_close']}');
    final open = (opp['status'] as String?) == 'open';
    final overdue = open &&
        close != null &&
        close.isBefore(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: dragging ? AppTheme.primary : AppTheme.border),
        boxShadow: dragging
            ? [
                BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4))
              ]
            : null,
      ),
      child: InkWell(
        onTap: () => _oppDialog(existing: opp),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(opp['title'] as String? ?? '',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Row(children: [
                Icon(isProspect ? Icons.person_search : Icons.store_outlined,
                    size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(who,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                      overflow: TextOverflow.ellipsis),
                ),
                if (isProspect)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                        color: AppTheme.warning.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4)),
                    child: const Text('lead',
                        style: TextStyle(
                            fontSize: 9,
                            color: AppTheme.warning,
                            fontWeight: FontWeight.w700)),
                  ),
              ]),
              if (value > 0) ...[
                const SizedBox(height: 6),
                Text('Rs ${_money.format(value)}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primary)),
              ],
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(
                      asg == null
                          ? 'Unassigned'
                          : (_userNames[asg] ?? 'Unknown'),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary),
                      overflow: TextOverflow.ellipsis),
                ),
                if (close != null)
                  Text(DateFormat('d MMM').format(close),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: overdue
                              ? AppTheme.danger
                              : AppTheme.textSecondary)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
