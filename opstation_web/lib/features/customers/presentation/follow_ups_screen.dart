import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'erp_customer_360_screen.dart';

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
      final rows = await client
          .from('customer_activities')
          .select()
          .eq('org_id', orgId)
          .inFilter('status', ['open', 'done'])
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

      final cids = list.map((e) => e['customer_id'] as String).toSet().toList();
      final cust = <String, Map<String, dynamic>>{};
      if (cids.isNotEmpty) {
        final cs =
            await client.from('customers').select().inFilter('id', cids);
        for (final c in cs) {
          cust[c['id'] as String] = Map<String, dynamic>.from(c);
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

  Future<void> _markDone(Map<String, dynamic> a) async {
    try {
      await Supabase.instance.client.from('customer_activities').update({
        'status': 'done',
        'completed_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', a['id']);
      _load();
    } catch (_) {/* ignore */}
  }

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
        if (status != 'open') return false;
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
        final name = (c?['shop_name'] as String? ?? '').toLowerCase();
        final code = (c?['code'] as String? ?? '').toLowerCase();
        if (!name.contains(q) && !code.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  int get _overdueCount => _rows
      .where((a) =>
          a['status'] == 'open' &&
          _isOverdue(DateTime.tryParse('${a['due_date']}')))
      .length;
  int get _todayCount => _rows
      .where((a) =>
          a['status'] == 'open' &&
          _isToday(DateTime.tryParse('${a['due_date']}')))
      .length;
  int get _upcomingCount => _rows.where((a) {
        if (a['status'] != 'open') return false;
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
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
          ]),
          const SizedBox(height: 4),
          const Text('Open tasks across all shops',
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
    final shop = c?['shop_name'] as String? ?? '(unknown shop)';
    final code = c?['code'] as String?;
    final asg = a['assigned_to'] as String?;
    final type = (a['type'] as String?) ?? 'note';
    return InkWell(
      onTap: c == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => Customer360Screen(customer: c))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          (a['status'] == 'done')
              ? const Icon(Icons.check_circle, size: 20, color: Colors.green)
              : InkWell(
                  onTap: () => _markDone(a),
                  child: const Icon(Icons.radio_button_unchecked,
                      size: 20, color: AppTheme.textSecondary),
                ),
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
                    code != null && code.isNotEmpty ? '$code · $shop' : shop,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(a['note'] as String? ?? '',
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
}
