import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Unified task inbox (Option B): every task assigned across the team, whether
/// linked to a customer, a supplier, or nothing (internal). Backed by
/// `customer_activities` (now nullable customer_id, plus supplier_id + title).
///
/// Default lens: "Assigned to me" + "Active" (open + in_progress). Follow-ups
/// remains the customer-only manager cockpit; this is the personal/coordination
/// superset. `done` = closed; `open` and `in_progress` both count as active.
class ErpTasksScreen extends ConsumerStatefulWidget {
  const ErpTasksScreen({super.key});
  @override
  ConsumerState<ErpTasksScreen> createState() => _ErpTasksScreenState();
}

class _ErpTasksScreenState extends ConsumerState<ErpTasksScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  final Map<String, Map<String, dynamic>> _custById = {};
  final Map<String, Map<String, dynamic>> _suppById = {};
  final Map<String, String> _userNames = {};
  List<Map<String, dynamic>> _orgUsers = [];
  List<Map<String, dynamic>> _suppliers = [];

  String _assignee = 'me'; // me | all | unassigned | <userId>
  String _status = 'active'; // active | open | in_progress | done
  String _link = 'all'; // all | customer | supplier | internal
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

  String? get _myId => ref.read(currentUserProvider)?.id;

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('customer_activities')
          .select()
          .eq('org_id', orgId);
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

      // Resolve customer + supplier display for linked rows.
      final cids = <String>{
        for (final a in list)
          if (a['customer_id'] != null) a['customer_id'] as String
      }.toList();
      final cust = <String, Map<String, dynamic>>{};
      if (cids.isNotEmpty) {
        final cs =
            await client.from('customers').select('id, code, shop_name').inFilter('id', cids);
        for (final c in cs) {
          cust[c['id'] as String] = Map<String, dynamic>.from(c);
        }
      }

      // Active suppliers — small list, loaded up front for the picker + display.
      final supps = await client
          .from('suppliers')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final suppMap = <String, Map<String, dynamic>>{};
      for (final s in supps) {
        suppMap[s['id'] as String] = Map<String, dynamic>.from(s);
      }

      if (!mounted) return;
      setState(() {
        _rows = list;
        _orgUsers = List<Map<String, dynamic>>.from(users);
        _suppliers = List<Map<String, dynamic>>.from(supps);
        _userNames
          ..clear()
          ..addAll(names);
        _custById
          ..clear()
          ..addAll(cust);
        _suppById
          ..clear()
          ..addAll(suppMap);
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
      final patch = <String, dynamic>{
        'status': status,
        'updated_at': DateTime.now().toIso8601String(),
        'completed_at':
            status == 'done' ? DateTime.now().toIso8601String() : null,
      };
      await Supabase.instance.client
          .from('customer_activities')
          .update(patch)
          .eq('id', a['id']);
      _load();
    } catch (_) {/* ignore */}
  }

  // ── date helpers ───────────────────────────────────────────────────────────

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

  bool _active(String? s) => s == 'open' || s == 'in_progress';

  // ── filtering ──────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.toLowerCase();
    final me = _myId;
    final out = _rows.where((a) {
      final status = a['status'] as String?;
      // status filter
      if (_status == 'active' && !_active(status)) return false;
      if (_status == 'open' && status != 'open') return false;
      if (_status == 'in_progress' && status != 'in_progress') return false;
      if (_status == 'done' && status != 'done') return false;

      // assignee filter
      final asg = a['assigned_to'] as String?;
      if (_assignee == 'me' && asg != me) return false;
      if (_assignee == 'unassigned' && asg != null) return false;
      if (_assignee != 'all' &&
          _assignee != 'me' &&
          _assignee != 'unassigned' &&
          asg != _assignee) {
        return false;
      }

      // link-type filter
      final hasCust = a['customer_id'] != null;
      final hasSupp = a['supplier_id'] != null;
      if (_link == 'customer' && !hasCust) return false;
      if (_link == 'supplier' && !hasSupp) return false;
      if (_link == 'internal' && (hasCust || hasSupp)) return false;

      // text search across title / note / link name
      if (q.isNotEmpty) {
        final title = (a['title'] as String? ?? '').toLowerCase();
        final note = (a['note'] as String? ?? '').toLowerCase();
        final linkName = _linkName(a).toLowerCase();
        if (!title.contains(q) &&
            !note.contains(q) &&
            !linkName.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    out.sort((a, b) {
      // active before done
      final aActive = _active(a['status'] as String?) ? 0 : 1;
      final bActive = _active(b['status'] as String?) ? 0 : 1;
      if (aActive != bActive) return aActive - bActive;
      // then by due date, nulls last
      final ad = DateTime.tryParse('${a['due_date']}');
      final bd = DateTime.tryParse('${b['due_date']}');
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });
    return out;
  }

  String _linkName(Map<String, dynamic> a) {
    if (a['customer_id'] != null) {
      final c = _custById[a['customer_id']];
      final code = c?['code'] as String?;
      final shop = c?['shop_name'] as String? ?? '';
      return (code != null && code.isNotEmpty) ? '$code · $shop' : shop;
    }
    if (a['supplier_id'] != null) {
      return _suppById[a['supplier_id']]?['name'] as String? ?? '(supplier)';
    }
    return 'Internal';
  }

  // counts for the stat row (always relative to the current assignee lens)
  int _countWhere(bool Function(Map<String, dynamic>) test) {
    final me = _myId;
    return _rows.where((a) {
      final asg = a['assigned_to'] as String?;
      if (_assignee == 'me' && asg != me) return false;
      if (_assignee == 'unassigned' && asg != null) return false;
      if (_assignee != 'all' &&
          _assignee != 'me' &&
          _assignee != 'unassigned' &&
          asg != _assignee) return false;
      return test(a);
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    final orgId = ref.read(currentUserProvider)?.orgId;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Tasks',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            FilledButton.icon(
              onPressed: orgId == null ? null : () => _openEditor(null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New task'),
            ),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
          ]),
          const SizedBox(height: 4),
          const Text(
              'Coordinate work across the team — customer, supplier, or internal.',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            _stat('Active', _countWhere((a) => _active(a['status'] as String?)),
                AppTheme.primary),
            const SizedBox(width: 12),
            _stat(
                'In progress',
                _countWhere((a) => a['status'] == 'in_progress'),
                AppTheme.warning),
            const SizedBox(width: 12),
            _stat(
                'Overdue',
                _countWhere((a) =>
                    _active(a['status'] as String?) &&
                    _isOverdue(DateTime.tryParse('${a['due_date']}'))),
                AppTheme.danger),
          ]),
          const SizedBox(height: 16),
          _filtersBar(),
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

  Widget _filtersBar() {
    return Wrap(spacing: 12, runSpacing: 12, children: [
      SizedBox(
        width: 240,
        child: TextField(
          controller: _searchCtrl,
          decoration: const InputDecoration(
              hintText: 'Search tasks…',
              prefixIcon: Icon(Icons.search),
              isDense: true),
        ),
      ),
      SizedBox(
        width: 220,
        child: DropdownButtonFormField<String>(
          value: _assignee,
          isExpanded: true,
          decoration:
              const InputDecoration(labelText: 'Assignee', isDense: true),
          items: [
            const DropdownMenuItem(value: 'me', child: Text('Assigned to me')),
            const DropdownMenuItem(value: 'all', child: Text('All assignees')),
            const DropdownMenuItem(
                value: 'unassigned', child: Text('Unassigned')),
            for (final u in _orgUsers)
              DropdownMenuItem(
                  value: u['id'] as String,
                  child: Text('${u['name'] ?? 'Unknown'}')),
          ],
          onChanged: (v) => setState(() => _assignee = v ?? 'me'),
        ),
      ),
      SizedBox(
        width: 170,
        child: DropdownButtonFormField<String>(
          value: _status,
          decoration:
              const InputDecoration(labelText: 'Status', isDense: true),
          items: const [
            DropdownMenuItem(value: 'active', child: Text('Active')),
            DropdownMenuItem(value: 'open', child: Text('Open')),
            DropdownMenuItem(value: 'in_progress', child: Text('In progress')),
            DropdownMenuItem(value: 'done', child: Text('Done')),
          ],
          onChanged: (v) => setState(() => _status = v ?? 'active'),
        ),
      ),
      SizedBox(
        width: 170,
        child: DropdownButtonFormField<String>(
          value: _link,
          decoration: const InputDecoration(labelText: 'Type', isDense: true),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All types')),
            DropdownMenuItem(value: 'customer', child: Text('Customer')),
            DropdownMenuItem(value: 'supplier', child: Text('Supplier')),
            DropdownMenuItem(value: 'internal', child: Text('Internal')),
          ],
          onChanged: (v) => setState(() => _link = v ?? 'all'),
        ),
      ),
    ]);
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
          child: Text('No tasks match',
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
    final status = a['status'] as String? ?? 'open';
    final overdue = _active(status) && _isOverdue(due);
    final title = (a['title'] as String?)?.trim();
    final note = (a['note'] as String?)?.trim();
    final asg = a['assigned_to'] as String?;
    final priority = a['priority'] as String?;

    return InkWell(
      onTap: () => _openEditor(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          _statusControl(a, status),
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
                Text(
                    title != null && title.isNotEmpty
                        ? title
                        : (note != null && note.isNotEmpty
                            ? note
                            : '(untitled task)'),
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        decoration: status == 'done'
                            ? TextDecoration.lineThrough
                            : null,
                        color: status == 'done'
                            ? AppTheme.textSecondary
                            : null),
                    overflow: TextOverflow.ellipsis),
                if (note != null && note.isNotEmpty && title != null && title.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(note,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _linkChip(a),
          const SizedBox(width: 8),
          if (priority != null && priority.isNotEmpty) _priorityChip(priority),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
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

  Widget _statusControl(Map<String, dynamic> a, String status) {
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

  Widget _linkChip(Map<String, dynamic> a) {
    IconData icon;
    String label;
    if (a['customer_id'] != null) {
      icon = Icons.store_outlined;
      label = _linkName(a);
    } else if (a['supplier_id'] != null) {
      icon = Icons.local_shipping_outlined;
      label = _linkName(a);
    } else {
      icon = Icons.lan_outlined;
      label = 'Internal';
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: AppTheme.primary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primary),
              overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }

  Widget _priorityChip(String p) {
    final lower = p.toLowerCase();
    Color c;
    switch (lower) {
      case 'high':
        c = AppTheme.danger;
        break;
      case 'low':
        c = AppTheme.textSecondary;
        break;
      default:
        c = AppTheme.warning; // medium / anything else
    }
    final label = lower.isEmpty ? '' : lower[0].toUpperCase() + lower.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
      child: Text(label,
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Future<void> _openEditor(Map<String, dynamic>? existing) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final userId = ref.read(currentUserProvider)?.id;
    if (orgId == null || userId == null) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TaskDialog(
        orgId: orgId,
        userId: userId,
        orgUsers: _orgUsers,
        suppliers: _suppliers,
        existing: existing,
        existingCustomer: existing != null && existing['customer_id'] != null
            ? _custById[existing['customer_id']]
            : null,
      ),
    );
    if (saved == true) _load();
  }
}

/// Create / edit dialog for a task. Writes to customer_activities with exactly
/// one of customer_id / supplier_id set (or neither = internal).
class _TaskDialog extends StatefulWidget {
  final String orgId;
  final String userId;
  final List<Map<String, dynamic>> orgUsers;
  final List<Map<String, dynamic>> suppliers;
  final Map<String, dynamic>? existing;
  final Map<String, dynamic>? existingCustomer;

  const _TaskDialog({
    required this.orgId,
    required this.userId,
    required this.orgUsers,
    required this.suppliers,
    this.existing,
    this.existingCustomer,
  });

  @override
  State<_TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<_TaskDialog> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  final _custSearchCtrl = TextEditingController();

  String? _assignee;
  DateTime? _due;
  String _priority = 'medium';
  String _status = 'open';
  String _linkType = 'none'; // none | customer | supplier
  Map<String, dynamic>? _customer; // {id, code, shop_name}
  String? _supplierId;

  List<Map<String, dynamic>> _custResults = [];
  bool _searching = false;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: (e?['title'] as String?) ?? '');
    _desc = TextEditingController(text: (e?['note'] as String?) ?? '');
    _assignee = e?['assigned_to'] as String?;
    _due = DateTime.tryParse('${e?['due_date']}');
    _priority = (e?['priority'] as String?) ?? 'medium';
    _status = (e?['status'] as String?) ?? 'open';
    if (e != null && e['customer_id'] != null) {
      _linkType = 'customer';
      _customer = widget.existingCustomer ??
          {'id': e['customer_id'], 'shop_name': '(customer)', 'code': null};
    } else if (e != null && e['supplier_id'] != null) {
      _linkType = 'supplier';
      _supplierId = e['supplier_id'] as String?;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _custSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _searchCustomers(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _custResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await Supabase.instance.client
          .from('customers')
          .select('id, code, shop_name')
          .eq('org_id', widget.orgId)
          .or('shop_name.ilike.%$q%,code.ilike.%$q%')
          .limit(20);
      if (!mounted) return;
      setState(() {
        _custResults = List<Map<String, dynamic>>.from(res);
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Title is required.');
      return;
    }
    if (_linkType == 'customer' && _customer == null) {
      setState(() => _error = 'Pick a customer or change the type.');
      return;
    }
    if (_linkType == 'supplier' && _supplierId == null) {
      setState(() => _error = 'Pick a supplier or change the type.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final nowIso = DateTime.now().toIso8601String();
    final dueStr = _due == null
        ? null
        : '${_due!.year.toString().padLeft(4, '0')}-${_due!.month.toString().padLeft(2, '0')}-${_due!.day.toString().padLeft(2, '0')}';
    final body = <String, dynamic>{
      'org_id': widget.orgId,
      'title': title,
      'note': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      'type': 'task',
      'customer_id': _linkType == 'customer' ? _customer!['id'] : null,
      'supplier_id': _linkType == 'supplier' ? _supplierId : null,
      'assigned_to': _assignee,
      'due_date': dueStr,
      'priority': _priority,
      'status': _status,
      'updated_at': nowIso,
    };
    try {
      final client = Supabase.instance.client;
      if (_isEdit) {
        await client
            .from('customer_activities')
            .update(body)
            .eq('id', widget.existing!['id']);
      } else {
        body['id'] = 'act_${DateTime.now().microsecondsSinceEpoch}';
        body['created_by'] = widget.userId;
        body['created_at'] = nowIso;
        body['completed_at'] = _status == 'done' ? nowIso : null;
        await client.from('customer_activities').insert(body);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit task' : 'New task'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Title *', isDense: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _desc,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Description', isDense: true),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                value: _assignee,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Assignee', isDense: true),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Unassigned')),
                  for (final u in widget.orgUsers)
                    DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text('${u['name'] ?? 'Unknown'}')),
                ],
                onChanged: (v) => setState(() => _assignee = v),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: _pickDue,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                          labelText: 'Due date', isDense: true),
                      child: Text(
                          _due == null
                              ? 'None'
                              : DateFormat('d MMM yyyy').format(_due!),
                          style: const TextStyle(fontSize: 14)),
                    ),
                  ),
                ),
                if (_due != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() => _due = null),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _priority,
                    decoration: const InputDecoration(
                        labelText: 'Priority', isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'low', child: Text('Low')),
                      DropdownMenuItem(
                          value: 'medium', child: Text('Medium')),
                      DropdownMenuItem(value: 'high', child: Text('High')),
                    ],
                    onChanged: (v) =>
                        setState(() => _priority = v ?? 'medium'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(
                    labelText: 'Status', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'open', child: Text('Open')),
                  DropdownMenuItem(
                      value: 'in_progress', child: Text('In progress')),
                  DropdownMenuItem(value: 'done', child: Text('Done')),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'open'),
              ),
              const SizedBox(height: 16),
              const Text('Link to',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'none', label: Text('Internal')),
                  ButtonSegment(value: 'customer', label: Text('Customer')),
                  ButtonSegment(value: 'supplier', label: Text('Supplier')),
                ],
                selected: {_linkType},
                onSelectionChanged: (s) =>
                    setState(() => _linkType = s.first),
              ),
              const SizedBox(height: 10),
              if (_linkType == 'customer') _customerPicker(),
              if (_linkType == 'supplier') _supplierPicker(),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(
                        color: AppTheme.danger, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }

  Widget _customerPicker() {
    if (_customer != null) {
      final code = _customer!['code'] as String?;
      final shop = _customer!['shop_name'] as String? ?? '';
      final label =
          (code != null && code.isNotEmpty) ? '$code · $shop' : shop;
      return Row(children: [
        const Icon(Icons.store_outlined, size: 16, color: AppTheme.primary),
        const SizedBox(width: 6),
        Expanded(
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600))),
        TextButton(
          onPressed: () => setState(() {
            _customer = null;
            _custResults = [];
            _custSearchCtrl.clear();
          }),
          child: const Text('Change'),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _custSearchCtrl,
        decoration: InputDecoration(
          hintText: 'Search customer by name or code…',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          suffixIcon: _searching
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : null,
        ),
        onChanged: _searchCustomers,
      ),
      if (_custResults.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final c in _custResults)
                ListTile(
                  dense: true,
                  title: Text(c['shop_name'] as String? ?? ''),
                  subtitle: (c['code'] as String?)?.isNotEmpty == true
                      ? Text(c['code'] as String)
                      : null,
                  onTap: () => setState(() {
                    _customer = Map<String, dynamic>.from(c);
                    _custResults = [];
                  }),
                ),
            ],
          ),
        ),
    ]);
  }

  Widget _supplierPicker() {
    return DropdownButtonFormField<String>(
      value: _supplierId,
      isExpanded: true,
      decoration:
          const InputDecoration(labelText: 'Supplier', isDense: true),
      items: [
        for (final s in widget.suppliers)
          DropdownMenuItem(
              value: s['id'] as String,
              child: Text('${s['name'] ?? '(supplier)'}')),
      ],
      onChanged: (v) => setState(() => _supplierId = v),
    );
  }

  Future<void> _pickDue() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _due = picked);
  }
}
