import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// Birds-eye audit trail for the whole ERP. Reads `voucher_audit_log`
/// (the shared audit store) joined to the acting user, scoped to the current
/// org via that user. Filterable by date range, user (incl. All), and entity
/// type. Read-only.
class ErpAuditLogScreen extends ConsumerStatefulWidget {
  const ErpAuditLogScreen({super.key});
  @override
  ConsumerState<ErpAuditLogScreen> createState() => _ErpAuditLogScreenState();
}

class _ErpAuditLogScreenState extends ConsumerState<ErpAuditLogScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _orgUsers = [];

  late DateTime _from;
  late DateTime _to;
  String _user = 'all'; // all | <userId>
  String _type = 'all'; // all | <voucher_type>

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 30));
    _load();
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

      // Org users (for the dropdown AND to scope the audit by user-id set —
      // voucher_audit_log has no org_id column, so we scope via its acting
      // users. This is the same embed pattern the per-voucher audit uses.)
      final users = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId)
          .order('name');
      final userList = List<Map<String, dynamic>>.from(users);
      final ids = [for (final u in userList) u['id'] as String];

      final fromIso = DateFormat('yyyy-MM-dd').format(_from);
      final toIso =
          DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));

      var q = client
          .from('voucher_audit_log')
          .select('*, users(name)')
          .gte('performed_at', fromIso)
          .lt('performed_at', toIso);
      if (_user != 'all') {
        q = q.eq('user_id', _user);
      } else {
        q = q.inFilter('user_id', ids);
      }
      final rows =
          await q.order('performed_at', ascending: false).limit(1000);

      if (!mounted) return;
      setState(() {
        _orgUsers = userList;
        _entries = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = [];
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
    _load();
  }

  List<String> get _typeOptions {
    final s = <String>{};
    for (final e in _entries) {
      final t = e['voucher_type'] as String?;
      if (t != null && t.isNotEmpty) s.add(t);
    }
    final list = s.toList()..sort();
    return ['all', ...list];
  }

  List<Map<String, dynamic>> get _filtered {
    if (_type == 'all') return _entries;
    return _entries.where((e) => e['voucher_type'] == _type).toList();
  }

  (IconData, Color) _actionStyle(String action) {
    switch (action) {
      case 'created':
        return (Icons.add_circle_outline, AppTheme.success);
      case 'edited':
        return (Icons.edit_outlined, AppTheme.primary);
      case 'saved':
        return (Icons.save_outlined, AppTheme.primary);
      case 'confirmed':
        return (Icons.check_circle_outline, AppTheme.success);
      case 'locked':
        return (Icons.lock_outline, Colors.orange);
      case 'unlocked':
        return (Icons.lock_open, AppTheme.textSecondary);
      case 'invoiced':
        return (Icons.receipt_long_outlined, AppTheme.primary);
      case 'cancelled':
        return (Icons.cancel_outlined, AppTheme.danger);
      case 'deleted':
        return (Icons.delete_outline, AppTheme.danger);
      default:
        return (Icons.history, AppTheme.textSecondary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Audit Trail',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            if (!_loading)
              Text('${rows.length} events',
                  style: const TextStyle(color: AppTheme.textSecondary)),
            const Spacer(),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
          ]),
          const SizedBox(height: 4),
          const Text('Birds-eye view of all ERP activity',
              style: TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            _dateChip('From', _from, () => _pickDate(isFrom: true)),
            const SizedBox(width: 8),
            _dateChip('To', _to, () => _pickDate(isFrom: false)),
            const SizedBox(width: 16),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                value: _user,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'User', isDense: true),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All users')),
                  for (final u in _orgUsers)
                    DropdownMenuItem(
                        value: u['id'] as String,
                        child: Text('${u['name'] ?? 'Unknown'}')),
                ],
                onChanged: (v) {
                  setState(() => _user = v ?? 'all');
                  _load();
                },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                value: _typeOptions.contains(_type) ? _type : 'all',
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Type', isDense: true),
                items: [
                  for (final t in _typeOptions)
                    DropdownMenuItem(
                        value: t,
                        child: Text(t == 'all' ? 'All types' : t)),
                ],
                onChanged: (v) => setState(() => _type = v ?? 'all'),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _table(rows),
          ),
        ],
      ),
    );
  }

  Widget _dateChip(String label, DateTime date, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label  ',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          Text(DateFormat('d MMM y').format(date),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          const Icon(Icons.calendar_today_outlined,
              size: 14, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }

  Widget _table(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return const Center(
          child: Text('No activity in this range',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
          child: const Row(children: [
            SizedBox(
                width: 150,
                child: Text('Time',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('User',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            SizedBox(
                width: 90,
                child: Text('Type',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            SizedBox(
                width: 110,
                child: Text('Action',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 4,
                child: Text('Details',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _row(rows[i]),
          ),
        ),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final action = e['action'] as String? ?? '-';
    final type = e['voucher_type'] as String? ?? '-';
    final details = e['details'] as String? ?? '';
    final userName = e['users']?['name'] as String? ?? '—';
    final ts = e['performed_at'] != null
        ? DateFormat('d MMM y · HH:mm')
            .format(DateTime.parse(e['performed_at'] as String).toLocal())
        : '';
    final (icon, color) = _actionStyle(action);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 150,
            child: Text(ts,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
            flex: 2,
            child: Text(userName,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600))),
        SizedBox(
            width: 90,
            child: Container(
              alignment: Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(4)),
                child: Text(type,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary)),
              ),
            )),
        SizedBox(
            width: 110,
            child: Row(children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(action,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color),
                    overflow: TextOverflow.ellipsis),
              ),
            ])),
        Expanded(
            flex: 4,
            child: Text(details,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary))),
      ]),
    );
  }
}
