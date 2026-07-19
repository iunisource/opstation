import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../data/audit_repository.dart';
import '../models/audit_log_entry.dart';

/// Admin read-only audit log viewer.
///
/// Filters: date range (default last 7 days), entity type, actor.
/// Rows expand inline to show the diff map if one is attached.
class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  DateTimeRange? _range;
  String? _entityType;
  String? _actorId;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(
      start: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 6)),
      end: now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final from = _range?.start;
    // Include the entire 'to' day by bumping to end-of-day.
    final to = _range == null
        ? null
        : DateTime(
            _range!.end.year,
            _range!.end.month,
            _range!.end.day,
            23,
            59,
            59,
          );

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Audit log',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          if (_entityType != null ||
              _actorId != null ||
              _range == null ||
              _range!.duration.inDays != 6)
            IconButton(
              icon: const Icon(Icons.filter_alt_off_outlined),
              tooltip: 'Reset filters',
              onPressed: () {
                final now = DateTime.now();
                setState(() {
                  _entityType = null;
                  _actorId = null;
                  _range = DateTimeRange(
                    start: DateTime(now.year, now.month, now.day)
                        .subtract(const Duration(days: 6)),
                    end: now,
                  );
                });
              },
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(_range == null
                          ? 'All dates'
                          : '${DateFormat('d MMM').format(_range!.start)} – ${DateFormat('d MMM').format(_range!.end)}'),
                      onPressed: _pickRange,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _entityDropdown()),
                    const SizedBox(width: 8),
                    Expanded(child: _actorDropdown()),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<AuditLogEntry>>(
              future: ref.watch(auditRepositoryProvider).query(
                    from: from,
                    to: to,
                    entityType: _entityType,
                    actorId: _actorId,
                  ),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                final items = snap.data ?? const <AuditLogEntry>[];
                if (items.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No events match your filters.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _AuditTile(entry: items[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _entityDropdown() {
    return DropdownButtonFormField<String?>(
      value: _entityType,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Entity type',
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        prefixIcon: const Icon(Icons.category_outlined, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      items: const [
        DropdownMenuItem(value: null, child: Text('All types')),
        DropdownMenuItem(value: 'customer', child: Text('Customer')),
        DropdownMenuItem(value: 'route', child: Text('Route')),
        DropdownMenuItem(value: 'user', child: Text('User')),
        DropdownMenuItem(value: 'assignment', child: Text('Assignment')),
      ],
      onChanged: (v) => setState(() => _entityType = v),
    );
  }

  Widget _actorDropdown() {
    final teamRepo = ref.watch(scopedTeamRepositoryProvider);
    return FutureBuilder<List<TeamUser>>(
      future: teamRepo.all(includeInactive: true),
      builder: (context, snap) {
        final users = snap.data ?? const <TeamUser>[];
        return DropdownButtonFormField<String?>(
          value: _actorId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Actor',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.person_outline, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All actors'),
            ),
            for (final u in users)
              DropdownMenuItem<String?>(
                value: u.id,
                child: Text(u.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _actorId = v),
        );
      },
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }
}

class _AuditTile extends StatelessWidget {
  final AuditLogEntry entry;
  const _AuditTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? diff;
    try {
      final decoded = jsonDecode(entry.diffJson);
      if (decoded is Map) {
        diff = decoded.cast<String, dynamic>();
      }
    } catch (_) {}
    final hasDiff = diff != null && diff.isNotEmpty;

    final ts = DateFormat('d MMM · HH:mm:ss').format(entry.timestamp);
    final actorLine = entry.actorName.isEmpty
        ? 'System'
        : '${entry.actorName}${entry.actorRole.isEmpty ? '' : ' (${entry.actorRole})'}';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          leading: _actionBadge(entry.action),
          title: Text(
            entry.summary.isEmpty
                ? '${entry.entityType}.${entry.action}'
                : entry.summary,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$ts · $actorLine',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondaryLight,
              ),
            ),
          ),
          trailing: hasDiff
              ? const Icon(Icons.expand_more, size: 20)
              : const SizedBox.shrink(),
          children: [
            if (hasDiff) _DiffTable(diff: diff!),
          ],
        ),
      ),
    );
  }

  Widget _actionBadge(String action) {
    late IconData icon;
    late Color color;
    switch (action) {
      case 'create':
      case 'assign':
        icon = Icons.add_circle_outline;
        color = AppColors.success;
        break;
      case 'delete':
      case 'unassign':
        icon = Icons.remove_circle_outline;
        color = AppColors.danger;
        break;
      case 'setLocation':
        icon = Icons.place_outlined;
        color = AppColors.primary;
        break;
      case 'update':
      default:
        icon = Icons.edit_outlined;
        color = AppColors.warningDark;
        break;
    }
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: 18),
    );
  }
}

class _DiffTable extends StatelessWidget {
  final Map<String, dynamic> diff;
  const _DiffTable({required this.diff});

  @override
  Widget build(BuildContext context) {
    final keys = diff.keys.toList();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.borderLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final k in keys) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: _row(k, diff[k]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String field, Object? value) {
    if (value is Map) {
      final old = value['old'];
      final next = value['new'];
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              field,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryLight,
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                if (old != null)
                  Text(
                    _fmt(old),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.danger,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                if (old != null && next != null)
                  const Icon(Icons.arrow_right_alt, size: 14),
                if (next != null)
                  Text(
                    _fmt(next),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.success,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    // Lists (e.g. assignment added/removed arrays)
    if (value is List) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              field,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondaryLight,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value.join(', '),
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      );
    }
    return Text('$field: ${_fmt(value)}',
        style: const TextStyle(fontSize: 11));
  }

  String _fmt(Object? v) {
    if (v == null) return '—';
    if (v is String) return v.isEmpty ? '—' : v;
    return v.toString();
  }
}
