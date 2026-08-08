// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'erp_customer_360_screen.dart';
import 'erp_supplier_360_screen.dart';

/// CRM Follow-ups cockpit — every open follow-up across all shops, with
/// assignee + due filters. Reads `customer_activities` (due_date not null,
/// status='open'). This is the managers' "overdue by rep" view; rows click
/// through to the relevant Customer 360.
class FollowUpsScreen extends ConsumerStatefulWidget {
  const FollowUpsScreen({super.key});
  @override
  ConsumerState<FollowUpsScreen> createState() => _FollowUpsScreenState();
}

class _FollowUpsScreenState extends ConsumerState<FollowUpsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  final Map<String, Map<String, dynamic>> _custById = {};
  final Map<String, Map<String, dynamic>> _suppById = {};
  final Map<String, String> _userNames = {};
  List<Map<String, dynamic>> _orgUsers = [];

  String _assignee = 'all'; // all | unassigned | <userId>
  String _due = 'all'; // all | overdue | today | week
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      // Both customer- AND supplier-linked follow-ups (either party set).
      final rows = await client
          .from('customer_activities')
          .select()
          .eq('org_id', orgId)
          .or('customer_id.not.is.null,supplier_id.not.is.null')
          .inFilter('status', ['open', 'in_progress', 'done'])
          .not('due_date', 'is', null)
          .order('due_date', ascending: true);
      final list = List<Map<String, dynamic>>.from(rows);

      final users = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId)
          .order('name');
      final names = <String, String>{};
      for (final u in users) {
        names[u['id'] as String] = (u['name'] as String?) ?? 'Unknown';
      }

      final cids = list
          .map((e) => e['customer_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final cust = <String, Map<String, dynamic>>{};
      if (cids.isNotEmpty) {
        final cs =
            await client.from('customers').select().inFilter('id', cids);
        for (final c in cs) {
          cust[c['id'] as String] = Map<String, dynamic>.from(c);
        }
      }

      final sids = list
          .map((e) => e['supplier_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final supp = <String, Map<String, dynamic>>{};
      if (sids.isNotEmpty) {
        final ss = await client
            .from('suppliers')
            .select('id, name, phone, email, address, contact_person, ntn, credit_limit')
            .inFilter('id', sids);
        for (final s in ss) {
          supp[s['id'] as String] = Map<String, dynamic>.from(s);
        }
      }

      if (!mounted) return;
      setState(() {
        _rows = list;
        _orgUsers = List<Map<String, dynamic>>.from(users);
        _userNames
          ..clear()
          ..addAll(names);
        _custById
          ..clear()
          ..addAll(cust);
        _suppById
          ..clear()
          ..addAll(supp);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _rows = [];
        _loading = false;
      });
    }
  }

  Future<void> _setStatus(Map<String, dynamic> a, String status) async {
    try {
      await Supabase.instance.client.from('customer_activities').update({
        'status': status,
        'completed_at':
            status == 'done' ? DateTime.now().toIso8601String() : null,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', a['id']);
      _load();
    } catch (_) {/* ignore */}
  }

  // done = closed; open + in_progress both count as active.
  bool _active(String? s) => s == 'open' || s == 'in_progress';

  bool _isOverdue(DateTime? d) {
    if (d == null) return false;
    final now = DateTime.now();
    return d.isBefore(DateTime(now.year, now.month, now.day));
  }

  bool _isToday(DateTime? d) {
    if (d == null) return false;
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  bool _isWithin7(DateTime? d) {
    if (d == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = today.add(const Duration(days: 7));
    return !d.isBefore(today) && d.isBefore(end);
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.toLowerCase();
    final showCompleted = _due == 'completed';
    return _rows.where((a) {
      final status = a['status'] as String?;
      if (showCompleted) {
        if (status != 'done') return false;
      } else {
        if (!_active(status)) return false;
        final due = DateTime.tryParse('${a['due_date']}');
        if (_due == 'overdue' && !_isOverdue(due)) return false;
        if (_due == 'today' && !_isToday(due)) return false;
        if (_due == 'week' && !_isWithin7(due)) return false;
      }
      final asg = a['assigned_to'] as String?;
      if (_assignee == 'unassigned' && asg != null) return false;
      if (_assignee != 'all' && _assignee != 'unassigned' && asg != _assignee) {
        return false;
      }
      if (q.isNotEmpty) {
        final c = _custById[a['customer_id']];
        final s = _suppById[a['supplier_id']];
        final name = (c?['shop_name'] as String? ?? s?['name'] as String? ?? '').toLowerCase();
        final code = (c?['code'] as String? ?? '').toLowerCase();
        final note = (a['note'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !code.contains(q) && !note.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  int get _overdueCount => _rows
      .where((a) =>
          _active(a['status'] as String?) &&
          _isOverdue(DateTime.tryParse('${a['due_date']}')))
      .length;
  int get _todayCount => _rows
      .where((a) =>
          _active(a['status'] as String?) &&
          _isToday(DateTime.tryParse('${a['due_date']}')))
      .length;
  int get _upcomingCount => _rows.where((a) {
        if (!_active(a['status'] as String?)) return false;
        final d = DateTime.tryParse('${a['due_date']}');
        return d != null && !_isOverdue(d) && !_isToday(d);
      }).length;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Follow-ups',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.print_outlined, size: 16),
              label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
              onPressed: _print,
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
          ]),
          const SizedBox(height: 4),
          const Text('Open tasks across customers & suppliers',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            _stat('Overdue', _overdueCount, AppTheme.danger),
            const SizedBox(width: 12),
            _stat('Due today', _todayCount, AppTheme.warning),
            const SizedBox(width: 12),
            _stat('Upcoming', _upcomingCount, AppTheme.primary),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            SizedBox(
              width: 240,
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                    hintText: 'Search shop…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: _assignee,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Assignee', isDense: true),
                items: [
                  const DropdownMenuItem(
                      value: 'all', child: Text('All assignees')),
                  const DropdownMenuItem(
                      value: 'unassigned', child: Text('Unassigned')),
                  for (final u in _orgUsers)
                    DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text('${u['name'] ?? 'Unknown'}')),
                ],
                onChanged: (v) => setState(() => _assignee = v ?? 'all'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                value: _due,
                decoration:
                    const InputDecoration(labelText: 'Due', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All open')),
                  DropdownMenuItem(value: 'overdue', child: Text('Overdue')),
                  DropdownMenuItem(value: 'today', child: Text('Due today')),
                  DropdownMenuItem(value: 'week', child: Text('Next 7 days')),
                  DropdownMenuItem(
                      value: 'completed', child: Text('Completed')),
                ],
                onChanged: (v) => setState(() => _due = v ?? 'all'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _list(),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, int v, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text('$v',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800, color: c)),
        const SizedBox(width: 6),
        Text(label,
            style:
                const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ]),
    );
  }

  Widget _list() {
    final rows = _filtered;
    if (rows.isEmpty) {
      return const Center(
          child: Text('No follow-ups match',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: ListView.separated(
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => _row(rows[i]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> a) {
    final due = DateTime.tryParse('${a['due_date']}');
    final overdue = _isOverdue(due);
    final c = _custById[a['customer_id']];
    final s = _suppById[a['supplier_id']];
    final isSupplier = a['supplier_id'] != null && s != null;
    final code = c?['code'] as String?;
    // Title line: customer "code · shop", or supplier name.
    final title = isSupplier
        ? (s['name'] as String? ?? '(unknown supplier)')
        : (c == null
            ? '(unknown shop)'
            : (code != null && code.isNotEmpty
                ? '$code · ${c['shop_name'] ?? ''}'
                : (c['shop_name'] as String? ?? '')));
    final asg = a['assigned_to'] as String?;
    final type = (a['type'] as String?) ?? 'note';
    return InkWell(
      onTap: () => _editDialog(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          _statusControl(a),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: Text(due == null ? '—' : DateFormat('d MMM').format(due),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color:
                        overdue ? AppTheme.danger : AppTheme.textSecondary)),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Party name opens the profile; the rest of the row opens the editor.
                GestureDetector(
                  onTap: () => _openProfile(c, s, isSupplier),
                  child: Row(children: [
                    Icon(isSupplier ? Icons.local_shipping_outlined : Icons.store_outlined,
                        size: 13, color: AppTheme.primary),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary,
                              decoration: TextDecoration.underline),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ),
                const SizedBox(height: 2),
                Text(
                    ((a['title'] as String?)?.trim().isNotEmpty == true
                        ? a['title'] as String
                        : a['note'] as String? ?? ''),
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _chip(type),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Row(children: [
              const Icon(Icons.person_outline,
                  size: 13, color: AppTheme.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    asg == null
                        ? 'Unassigned'
                        : (_userNames[asg] ?? 'Unknown'),
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('View', style: TextStyle(fontSize: 12)),
            onPressed: () => _editDialog(a),
            style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
          ),
          if (overdue)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: AppTheme.danger.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(4)),
              child: const Text('overdue',
                  style: TextStyle(
                      fontSize: 10,
                      color: AppTheme.danger,
                      fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
    );
  }

  Widget _statusControl(Map<String, dynamic> a) {
    final status = a['status'] as String? ?? 'open';
    IconData icon;
    Color color;
    switch (status) {
      case 'done':
        icon = Icons.check_circle;
        color = AppTheme.success;
        break;
      case 'in_progress':
        icon = Icons.timelapse;
        color = AppTheme.warning;
        break;
      default:
        icon = Icons.radio_button_unchecked;
        color = AppTheme.textSecondary;
    }
    return PopupMenuButton<String>(
      tooltip: 'Set status',
      onSelected: (v) => _setStatus(a, v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'open', child: Text('Open')),
        PopupMenuItem(value: 'in_progress', child: Text('In progress')),
        PopupMenuItem(value: 'done', child: Text('Done')),
      ],
      child: Icon(icon, size: 20, color: color),
    );
  }

  void _openProfile(Map<String, dynamic>? c, Map<String, dynamic>? s, bool isSupplier) {
    if (isSupplier && s != null) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Scaffold(body: ErpSupplier360Screen(initialSupplier: s))));
    } else if (c != null) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => Customer360Screen(customer: c)));
    }
  }

  Future<void> _editDialog(Map<String, dynamic> a) async {
    final titleCtrl = TextEditingController(text: (a['title'] as String?) ?? '');
    final noteCtrl = TextEditingController(text: (a['note'] as String?) ?? '');
    String type = (a['type'] as String?) ?? 'call';
    const types = ['note', 'call', 'visit', 'collection', 'task', 'other'];
    if (!types.contains(type)) type = 'other';
    DateTime? due = DateTime.tryParse('${a['due_date']}');
    String? assignee = a['assigned_to'] as String?;
    String status = (a['status'] as String?) ?? 'open';
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
        title: const Text('Edit follow-up'),
        content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: titleCtrl, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Title', isDense: true)),
          const SizedBox(height: 12),
          TextField(controller: noteCtrl, maxLines: 3, textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Note', isDense: true, alignLabelWithHint: true)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: InkWell(
              onTap: () async {
                final p = await showDatePicker(context: ctx, initialDate: due ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (p != null) setS(() => due = p);
              },
              child: InputDecorator(decoration: const InputDecoration(labelText: 'Due date', isDense: true),
                  child: Text(due == null ? 'None' : DateFormat('d MMM yyyy').format(due!), style: const TextStyle(fontSize: 14))),
            )),
            if (due != null) IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () => setS(() => due = null)),
            const SizedBox(width: 8),
            Expanded(child: DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: 'Type', isDense: true),
              items: const [
                DropdownMenuItem(value: 'note', child: Text('Note')),
                DropdownMenuItem(value: 'call', child: Text('Call')),
                DropdownMenuItem(value: 'visit', child: Text('Visit')),
                DropdownMenuItem(value: 'collection', child: Text('Collection')),
                DropdownMenuItem(value: 'task', child: Text('Task')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ], onChanged: (v) => setS(() => type = v ?? type))),
          ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(value: assignee, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Assignee', isDense: true),
            items: [const DropdownMenuItem(value: null, child: Text('Unassigned')),
              for (final u in _orgUsers) DropdownMenuItem(value: u['id'] as String, child: Text('${u['name'] ?? 'Unknown'}'))],
            onChanged: (v) => setS(() => assignee = v)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: status, decoration: const InputDecoration(labelText: 'Status', isDense: true),
            items: const [DropdownMenuItem(value: 'open', child: Text('Open')), DropdownMenuItem(value: 'in_progress', child: Text('In progress')), DropdownMenuItem(value: 'done', child: Text('Done'))],
            onChanged: (v) => setS(() => status = v ?? 'open')),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () async {
            try {
              await Supabase.instance.client.from('customer_activities').update({
                'title': titleCtrl.text.trim().isEmpty ? null : titleCtrl.text.trim(),
                'note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                'type': type,
                'due_date': due != null ? DateFormat('yyyy-MM-dd').format(due!) : null,
                'assigned_to': assignee,
                'status': status,
                'completed_at': status == 'done' ? DateTime.now().toIso8601String() : null,
                'updated_at': DateTime.now().toIso8601String(),
              }).eq('id', a['id']);
              if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
              _load();
            } catch (e) {
              if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Failed: ${e.toString().split('\n').first}')));
            }
          }, child: const Text('Save')),
        ],
      )),
    );
  }

  Widget _chip(String type) {
    final t = type.isEmpty ? 'note' : type;
    final label = t[0].toUpperCase() + t.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.primary)),
    );
  }

  // Party label for a row: "code · shop" (customer) or supplier name.
  String _partyLabel(Map<String, dynamic> a) {
    if (a['supplier_id'] != null) {
      return _suppById[a['supplier_id']]?['name'] as String? ?? '(supplier)';
    }
    final c = _custById[a['customer_id']];
    final shop = c?['shop_name'] as String? ?? '(unknown)';
    final code = c?['code'] as String?;
    return (code != null && code.isNotEmpty) ? '$code · $shop' : shop;
  }

  void _print() {
    try {
      final rows = _filtered;
      final assigneeLabel = _assignee == 'all'
          ? 'All assignees'
          : _assignee == 'unassigned'
              ? 'Unassigned'
              : (_userNames[_assignee] ?? 'Unknown');
      const dueLabels = {
        'all': 'All open',
        'overdue': 'Overdue',
        'today': 'Due today',
        'week': 'Next 7 days',
        'completed': 'Completed',
      };
      final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
      String esc(String s) => s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');

      final body = StringBuffer();
      for (final a in rows) {
        final due = DateTime.tryParse('${a['due_date']}');
        final overdue = _active(a['status'] as String?) && _isOverdue(due);
        final dateStr = due == null ? '-' : DateFormat('d MMM yy').format(due);
        final isSupp = a['supplier_id'] != null;
        final party = esc(_partyLabel(a));
        // Description: show both the title and the note so nothing is hidden.
        final titleTxt = (a['title'] as String?)?.trim() ?? '';
        final noteTxt = (a['note'] as String?)?.trim() ?? '';
        final desc = esc([
          if (titleTxt.isNotEmpty) titleTxt,
          if (noteTxt.isNotEmpty) noteTxt,
        ].join(' — '));
        final asg = a['assigned_to'] as String?;
        final asgName = esc(asg == null ? 'Unassigned' : (_userNames[asg] ?? 'Unknown'));
        final status = esc((a['status'] as String? ?? 'open'));
        body.write('<tr' + (overdue ? ' class="od"' : '') + '><td>' + dateStr +
            '</td><td>' + (isSupp ? 'Supplier' : 'Customer') + '</td><td>' + party +
            '</td><td>' + desc + '</td><td>' + asgName + '</td><td>' + status + '</td></tr>');
      }

      final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Follow-ups</title><style>'
          '@page { margin: 0.6cm; } '
          'body { font-family: Arial, sans-serif; padding: 16px; font-size: 11px; color: #000; margin: 0; } '
          'h1 { font-size: 18px; margin: 0 0 4px 0; } '
          '.info { font-size: 10px; color: #555; margin: 2px 0; } '
          'table { width: 100%; border-collapse: collapse; margin-top: 10px; } '
          'th, td { padding: 5px 7px; border-bottom: 1px solid #ddd; text-align: left; font-size: 10px; } '
          'th { background: #f5f5f5; font-weight: 700; border-bottom: 1.5px solid #000; } '
          'tr.od td { color: #c62828; } '
          '</style></head><body>'
          '<h1>Follow-ups</h1>'
          '<div class="info"><strong>Assignee:</strong> ' + esc(assigneeLabel) + '</div>'
          '<div class="info"><strong>Filter:</strong> ' + (dueLabels[_due] ?? _due) + '</div>'
          '<div class="info"><strong>Overdue:</strong> ' + _overdueCount.toString() +
          '  ·  <strong>Due today:</strong> ' + _todayCount.toString() +
          '  ·  <strong>Upcoming:</strong> ' + _upcomingCount.toString() + '</div>'
          '<div class="info">Generated: ' + gen + '  ·  ' + rows.length.toString() + ' item(s)</div>'
          '<table><thead><tr><th>Due</th><th>Type</th><th>Party</th><th>Task / Note</th><th>Assignee</th><th>Status</th></tr></thead>'
          '<tbody>' + body.toString() + '</tbody></table></body></html>';

      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.window.open(url, '_blank');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Print error: $e')));
      }
    }
  }
}
