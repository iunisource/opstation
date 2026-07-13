// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/responsive.dart';
import '../../../core/widgets/adaptive_master_detail.dart';
import '../../auth/auth_controller.dart';
import '../../erp/services/asset_pdf.dart';

const _kAreaViewBase = 'https://opstation-f06c7.web.app/area.html';

const _bucket = 'facility-files';
const _categories = ['cleaning', 'inspection', 'servicing', 'safety', 'pest', 'other'];
const _frequencies = ['daily', 'weekly', 'monthly', 'quarterly', 'custom'];
const _areaTypes = ['floor', 'washroom', 'office', 'warehouse', 'exterior', 'equipment', 'other'];

/// Facility maintenance: recurring upkeep so offices/factory stay visit-ready
/// without a scramble. Tasks board + schedules + areas + a readiness band.
class ErpFacilityScreen extends ConsumerStatefulWidget {
  const ErpFacilityScreen({super.key});
  @override
  ConsumerState<ErpFacilityScreen> createState() => _ErpFacilityScreenState();
}

class _ErpFacilityScreenState extends ConsumerState<ErpFacilityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  bool _loading = true;
  String? _orgId;

  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _assignees = [];
  List<Map<String, dynamic>> _areas = [];
  List<Map<String, dynamic>> _schedules = [];
  List<Map<String, dynamic>> _tasks = [];
  Map<String, dynamic> _dash = {};

  final Map<String, String> _userNames = {};
  final Map<String, String> _assigneeNames = {};
  final Map<String, String> _areaNames = {};
  final Map<String, String> _branchNames = {};

  String _branch = 'all';
  String _taskFilter = 'today'; // today | open | overdue | done

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  String _today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _load() async {
    setState(() => _loading = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    _orgId = orgId;
    try {
      final c = Supabase.instance.client;
      final branches = await c
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final users =
          await c.from('users').select('id, name').eq('org_id', orgId).order('name');
      final assignees = await c
          .from('facility_assignees')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final areas = await c
          .from('facility_areas')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final schedules = await c
          .from('facility_schedules')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: false);
      final open = await c
          .from('facility_tasks')
          .select()
          .eq('org_id', orgId)
          .eq('status', 'open')
          .order('due_date');
      final cutoff = DateFormat('yyyy-MM-dd')
          .format(DateTime.now().subtract(const Duration(days: 30)));
      final done = await c
          .from('facility_tasks')
          .select()
          .eq('org_id', orgId)
          .eq('status', 'done')
          .gte('completed_at', cutoff)
          .order('completed_at', ascending: false)
          .limit(300);

      final dash = await c.rpc('rpc_facility_dashboard', params: {
        'p_org_id': orgId,
        'p_branch_id': _branch == 'all' ? null : _branch,
      });

      if (!mounted) return;
      setState(() {
        _branches = List<Map<String, dynamic>>.from(branches);
        _users = List<Map<String, dynamic>>.from(users);
        _assignees = List<Map<String, dynamic>>.from(assignees);
        _areas = List<Map<String, dynamic>>.from(areas);
        _schedules = List<Map<String, dynamic>>.from(schedules);
        _tasks = [
          ...List<Map<String, dynamic>>.from(open),
          ...List<Map<String, dynamic>>.from(done),
        ];
        _dash = Map<String, dynamic>.from(dash as Map);
        _branchNames
          ..clear()
          ..addEntries(_branches.map((b) => MapEntry(b['id'] as String, '${b['name']}')));
        _userNames
          ..clear()
          ..addEntries(_users.map((u) => MapEntry(u['id'] as String, '${u['name']}')));
        _assigneeNames
          ..clear()
          ..addEntries(_assignees.map((u) => MapEntry(u['id'] as String, '${u['name']}')));
        _areaNames
          ..clear()
          ..addEntries(_areas.map((a) => MapEntry(a['id'] as String, '${a['name']}')));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  Future<void> _refreshDash() async {
    if (_orgId == null) return;
    try {
      final dash = await Supabase.instance.client.rpc('rpc_facility_dashboard',
          params: {'p_org_id': _orgId, 'p_branch_id': _branch == 'all' ? null : _branch});
      if (mounted) setState(() => _dash = Map<String, dynamic>.from(dash as Map));
    } catch (_) {}
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ───────────────────────────────────────────────── helpers
  bool _inBranch(Map<String, dynamic> r) =>
      _branch == 'all' || r['branch_id'] == _branch;

  String _fmtDate(dynamic d) {
    if (d == null || '$d'.isEmpty) return '—';
    try {
      return DateFormat('d MMM y').format(DateTime.parse('$d').toLocal());
    } catch (_) {
      return '$d';
    }
  }

  Color _catColor(String? cat) {
    switch (cat) {
      case 'safety':
        return AppTheme.danger;
      case 'inspection':
        return Colors.indigo;
      case 'servicing':
        return Colors.teal;
      case 'pest':
        return Colors.brown;
      case 'cleaning':
        return AppTheme.primary;
      default:
        return AppTheme.textSecondary;
    }
  }

  List<Map<String, dynamic>> get _filteredTasks {
    final today = _today();
    return _tasks.where((t) {
      if (!_inBranch(t)) return false;
      switch (_taskFilter) {
        case 'open':
          return t['status'] == 'open';
        case 'overdue':
          return t['status'] == 'open' && '${t['due_date']}'.compareTo(today) < 0;
        case 'today':
          // Everything scheduled for today — open and done — for a focused
          // daily status check. Done ones render with a tick.
          return '${t['due_date']}' == today;
        case 'done':
          return t['status'] == 'done';
      }
      return true;
    }).toList();
  }

  // ───────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: context.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title + branch picker in one Row overflowed the right edge on a phone.
        // Wrap lets the picker drop to its own line.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text('Facility Maintenance',
                style: TextStyle(fontSize: context.isMobile ? 22 : 28, fontWeight: FontWeight.w800)),
            SizedBox(
              width: 200,
              child: DropdownButtonFormField<String>(
                value: _branch,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Branch', isDense: true),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All branches')),
                  for (final b in _branches)
                    DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}')),
                ],
                onChanged: (v) {
                  setState(() => _branch = v ?? 'all');
                  _refreshDash();
                },
              ),
            ),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          ],
        ),
        if (!context.isMobile) ...[
          const SizedBox(height: 4),
          const Text('Recurring upkeep so the place stays visit-ready',
              style: TextStyle(color: AppTheme.textSecondary)),
        ],
        SizedBox(height: context.isMobile ? 10 : 16),
        _statsBand(),
        SizedBox(height: context.isMobile ? 10 : 16),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border),
          ),
          child: TabBar(
            controller: _tab,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
            indicatorColor: AppTheme.primary,
            tabs: const [
              Tab(text: 'Tasks'),
              Tab(text: 'Schedules'),
              Tab(text: 'Areas'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tab,
                  children: [_tasksTab(), _schedulesTab(), _areasTab()],
                ),
        ),
      ]),
    );
  }

  // ───────────────────────────────────────────────── stats band
  Widget _statsBand() {
    final open = _dash['open'] ?? 0;
    final overdue = _dash['overdue'] ?? 0;
    final today = _dash['due_today'] ?? 0;
    final done7 = _dash['done_7d'] ?? 0;
    final rate = _dash['on_time_rate'];
    return AdaptiveKpiRow(children: [
      _stat('Open', '$open', AppTheme.primary),
      _stat('Overdue', '$overdue', AppTheme.danger),
      _stat('Due today', '$today', Colors.orange),
      _stat('Done (7d)', '$done7', AppTheme.success),
      _stat('On-time', rate == null ? '—' : '$rate%', Colors.teal),
    ]);
  }

  /// No Expanded here: AdaptiveKpiRow decides the width (Expanded on desktop,
  /// half-width on a phone). Hard-coding Expanded made the card a 70px sliver
  /// that stacked its label one letter per line.
  /// Compact on a phone. At desktop scale these five cards run to three rows
  /// (~450px), which starved the Expanded task list below them of height — the
  /// list rendered as a grey slab a few pixels tall.
  Widget _stat(String label, String value, Color color) {
    final mob = context.isMobile;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: mob ? 10 : 16, vertical: mob ? 8 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: TextStyle(fontSize: mob ? 17 : 24, fontWeight: FontWeight.w800, color: color)),
        SizedBox(height: mob ? 0 : 2),
        Text(label,
            style: TextStyle(fontSize: mob ? 10 : 12, color: AppTheme.textSecondary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  // ───────────────────────────────────────────────── TASKS tab
  Widget _tasksTab() {
    final rows = _filteredTasks;
    final doneToday =
        _taskFilter == 'today' ? rows.where((t) => t['status'] == 'done').length : 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: context.isMobile ? 6 : 8, runSpacing: 6, children: [
        for (final f in const ['today', 'open', 'overdue', 'done'])
          Padding(
            padding: EdgeInsets.zero,
            child: ChoiceChip(
              visualDensity: context.isMobile ? VisualDensity.compact : VisualDensity.standard,
              labelStyle: TextStyle(fontSize: context.isMobile ? 11 : 13),
              label: Text({
                'today': 'Today',
                'open': 'All open',
                'overdue': 'Overdue',
                'done': 'Done (30d)',
              }[f]!),
              selected: _taskFilter == f,
              onSelected: (_) => setState(() => _taskFilter = f),
            ),
          ),
        const Spacer(),
        Text(
          _taskFilter == 'today'
              ? '$doneToday / ${rows.length} done'
              : '${rows.length} task${rows.length == 1 ? '' : 's'}',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: rows.isEmpty
            ? Center(
                child: Text(
                    _taskFilter == 'today'
                        ? 'Nothing scheduled for today.'
                        : 'Nothing here.',
                    style: const TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _taskCard(rows[i]),
              ),
      ),
    ]);
  }

  Widget _taskCard(Map<String, dynamic> t) {
    final done = t['status'] == 'done';
    final overdue =
        !done && '${t['due_date']}'.compareTo(_today()) < 0;
    final cat = t['category'] as String?;
    final area = _areaNames[t['area_id']];
    final photoCount = _photoList(t).length;
    return InkWell(
      onTap: () => done ? _taskDetailDialog(t) : _completeDialog(t),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: overdue ? AppTheme.danger : AppTheme.border),
        ),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20, color: done ? AppTheme.success : AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${t['title']}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 3),
              Row(children: [
                _pill(cat ?? 'other', _catColor(cat)),
                if (area != null) ...[
                  const SizedBox(width: 8),
                  Text(area, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ],
                if (_branch == 'all' && _branchNames[t['branch_id']] != null) ...[
                  const SizedBox(width: 8),
                  Text(_branchNames[t['branch_id']]!,
                      style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ]),
            ]),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(done ? 'Done ${_fmtDate(t['completed_at'])}' : 'Due ${_fmtDate(t['due_date'])}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: overdue ? AppTheme.danger : AppTheme.textSecondary)),
            if ((t['checklist'] as List?)?.isNotEmpty == true)
              Text('${(t['checklist'] as List).length} checks',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            if (done && photoCount > 0)
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.photo_outlined, size: 12, color: AppTheme.textSecondary),
                const SizedBox(width: 3),
                Text('$photoCount',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ]),
          ]),
        ]),
      ),
    );
  }

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
            color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(4)),
        child: Text(text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
      );

  // ───────────────────────────────────────────────── completion dialog
  Future<void> _completeDialog(Map<String, dynamic> t) async {
    final checklist = List<String>.from((t['checklist'] as List?)?.cast<String>() ?? []);
    final checks = {for (final item in checklist) item: false};
    final noteCtrl = TextEditingController();
    final requiresPhoto = t['requires_photo'] == true;
    final photos = <String>[];
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text('${t['title']}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (checklist.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Mark this task complete.',
                        style: TextStyle(color: AppTheme.textSecondary)),
                  ),
                for (final item in checklist)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: checks[item],
                    onChanged: (v) => setLocal(() => checks[item] = v ?? false),
                    title: Text(item, style: const TextStyle(fontSize: 14)),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: noteCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                      labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_camera_outlined, size: 18),
                    label: Text(photos.isEmpty ? 'Attach photo' : 'Add another'),
                    onPressed: saving
                        ? null
                        : () async {
                            final p = await _pickAndUploadPhoto(t['id'] as String);
                            if (p != null) setLocal(() => photos.add(p));
                          },
                  ),
                  const SizedBox(width: 10),
                  Text(
                    photos.isEmpty
                        ? (requiresPhoto ? 'required' : 'none yet')
                        : '${photos.length} photo${photos.length == 1 ? '' : 's'} attached',
                    style: TextStyle(
                        fontSize: 12,
                        color: photos.isEmpty && requiresPhoto
                            ? AppTheme.danger
                            : AppTheme.textSecondary),
                  ),
                ]),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (requiresPhoto && photos.isEmpty) {
                        _snack('A photo is required for this task.');
                        return;
                      }
                      setLocal(() => saving = true);
                      final ok = await _markDone(t, checks, noteCtrl.text.trim(), photos);
                      if (ok && ctx.mounted) Navigator.pop(ctx);
                      if (!ok) setLocal(() => saving = false);
                    },
              child: Text(saving ? 'Saving…' : 'Mark done'),
            ),
          ],
        );
      }),
    );
  }

  Future<bool> _markDone(Map<String, dynamic> t, Map<String, bool> checks,
      String note, List<String> photos) async {
    try {
      await Supabase.instance.client.from('facility_tasks').update({
        'status': 'done',
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'completed_by': ref.read(currentUserProvider)?.id,
        'checklist_result': checks,
        'note': note.isEmpty ? null : note,
        'photos': photos,
        'photo_path': photos.isEmpty ? null : photos.first,
      }).eq('id', t['id']);
      await _load();
      return true;
    } catch (e) {
      _snack('Could not save: $e');
      return false;
    }
  }

  List<String> _photoList(Map<String, dynamic> t) {
    final raw = t['photos'];
    if (raw is List && raw.isNotEmpty) return raw.map((e) => '$e').toList();
    final p = t['photo_path'];
    if (p is String && p.isNotEmpty) return [p];
    return [];
  }

  Future<String?> _signedUrl(String path) async {
    try {
      return await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  Widget _photoThumb(String path) {
    return FutureBuilder<String?>(
      future: _signedUrl(path),
      builder: (c, snap) {
        final url = snap.data;
        return InkWell(
          onTap: url == null ? null : () => html.window.open(url, '_blank'),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 76,
            height: 76,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.border),
            ),
            child: snap.connectionState != ConnectionState.done
                ? const Center(
                    child: SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : url == null
                    ? const Center(
                        child: Icon(Icons.image_outlined, size: 20, color: AppTheme.textSecondary))
                    : Image.network(url,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.broken_image_outlined, size: 20))),
          ),
        );
      },
    );
  }

  Future<void> _taskDetailDialog(Map<String, dynamic> t) async {
    final result = (t['checklist_result'] as Map?) ?? {};
    final checklist = List<String>.from((t['checklist'] as List?)?.cast<String>() ?? []);
    final photos = _photoList(t);
    final by = t['completed_by'] == null ? '' : (_userNames[t['completed_by']] ?? '');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${t['title']}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Done ${_fmtDate(t['completed_at'])}${by.isEmpty ? '' : ' · $by'}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  if (checklist.isNotEmpty) ...[
                    for (final item in checklist)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(children: [
                          Icon(
                              result[item] == true
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: result[item] == true
                                  ? AppTheme.success
                                  : AppTheme.textSecondary),
                          const SizedBox(width: 6),
                          Expanded(child: Text(item, style: const TextStyle(fontSize: 13))),
                        ]),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if ((t['note'] as String?)?.isNotEmpty == true) ...[
                    const Text('Note',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    const SizedBox(height: 2),
                    Text('${t['note']}', style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    photos.isEmpty
                        ? 'No photos attached'
                        : '${photos.length} photo${photos.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [for (final p in photos) _photoThumb(p)],
                    ),
                    const SizedBox(height: 4),
                    const Text('Tap a photo to open full size',
                        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  ],
                ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────── assignee roster
  Future<void> _assigneesDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: const Text('Assignees'),
          content: SizedBox(
            width: 420,
            height: 440,
            child: Column(children: [
              Align(
                alignment: Alignment.centerLeft,
                child: const Text(
                    'People who carry out facility tasks (cleaners, maintenance). '
                    'They need not be app users.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _assignees.isEmpty
                    ? const Center(
                        child: Text('No assignees yet.',
                            style: TextStyle(color: AppTheme.textSecondary)))
                    : ListView.separated(
                        itemCount: _assignees.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final a = _assignees[i];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${a['name']}'),
                            subtitle: (a['phone'] as String?)?.isNotEmpty == true
                                ? Text('${a['phone']}')
                                : null,
                            trailing: IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () async {
                                await _assigneeEditDialog(existing: a);
                                setLocal(() {});
                              },
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await _assigneeEditDialog();
                setLocal(() {});
              },
              child: const Text('Add assignee'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        );
      }),
    );
  }

  Future<void> _assigneeEditDialog({Map<String, dynamic>? existing}) async {
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    final phoneCtrl = TextEditingController(text: existing?['phone'] as String? ?? '');
    bool saving = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(existing == null ? 'New assignee' : 'Edit assignee'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Name', isDense: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneCtrl,
                decoration: const InputDecoration(labelText: 'Phone (optional)', isDense: true),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (nameCtrl.text.trim().isEmpty) {
                        _snack('Name is required.');
                        return;
                      }
                      setLocal(() => saving = true);
                      try {
                        final c = Supabase.instance.client;
                        final data = {
                          'org_id': _orgId,
                          'name': nameCtrl.text.trim(),
                          'phone': phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                        };
                        if (existing == null) {
                          await c.from('facility_assignees').insert(data);
                        } else {
                          await c
                              .from('facility_assignees')
                              .update(data)
                              .eq('id', existing['id']);
                        }
                        await _load();
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setLocal(() => saving = false);
                        _snack('Save failed: $e');
                      }
                    },
              child: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        );
      }),
    );
  }

  Future<String?> _pickAndUploadPhoto(String taskId) async {
    try {
      final input = html.FileUploadInputElement()..accept = 'image/*';
      input.click();
      await input.onChange.first;
      if (input.files == null || input.files!.isEmpty) return null;
      final file = input.files!.first;
      final reader = html.FileReader()..readAsArrayBuffer(file);
      await reader.onLoad.first;
      final bytes = reader.result as Uint8List;
      final ext = file.name.contains('.') ? file.name.split('.').last : 'jpg';
      final path =
          '$_orgId/$taskId/${DateTime.now().millisecondsSinceEpoch}.$ext';
      await Supabase.instance.client.storage.from(_bucket).uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      return path;
    } catch (e) {
      _snack('Upload failed: $e');
      return null;
    }
  }

  // ───────────────────────────────────────────────── SCHEDULES tab
  Widget _schedulesTab() {
    final rows = _schedules.where(_inBranch).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('${rows.length} schedule${rows.length == 1 ? '' : 's'}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const Spacer(),
        OutlinedButton.icon(
          icon: const Icon(Icons.groups_outlined, size: 18),
          label: const Text('Assignees'),
          onPressed: _assigneesDialog,
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New schedule'),
          onPressed: () => _scheduleDialog(),
        ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No schedules yet. Add one to start recurring upkeep.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _scheduleCard(rows[i]),
              ),
      ),
    ]);
  }

  Widget _scheduleCard(Map<String, dynamic> s) {
    final active = s['is_active'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s['title']}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 3),
            Row(children: [
              _pill(s['category'] ?? 'other', _catColor(s['category'])),
              const SizedBox(width: 8),
              Text('${s['frequency']}${s['frequency'] == 'custom' ? ' (${s['interval_days']}d)' : ''}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              if (_areaNames[s['area_id']] != null) ...[
                const SizedBox(width: 8),
                Text(_areaNames[s['area_id']]!,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ],
              const SizedBox(width: 8),
              Text('next ${_fmtDate(s['next_due'])}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ]),
        ),
        Switch(
          value: active,
          onChanged: (v) => _toggleSchedule(s, v),
        ),
        IconButton(
            onPressed: () => _scheduleDialog(existing: s),
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit'),
      ]),
    );
  }

  Future<void> _toggleSchedule(Map<String, dynamic> s, bool active) async {
    try {
      await Supabase.instance.client
          .from('facility_schedules')
          .update({'is_active': active}).eq('id', s['id']);
      await _load();
    } catch (e) {
      _snack('Update failed: $e');
    }
  }

  Future<void> _scheduleDialog({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    final titleCtrl = TextEditingController(text: existing?['title'] as String? ?? '');
    final intervalCtrl =
        TextEditingController(text: '${existing?['interval_days'] ?? 7}');
    final checklistCtrl = TextEditingController(
        text: ((existing?['checklist'] as List?)?.cast<String>() ?? []).join('\n'));
    String cat = existing?['category'] as String? ?? 'cleaning';
    String freq = existing?['frequency'] as String? ?? 'daily';
    String? areaId = existing?['area_id'] as String?;
    String? assignee = existing?['assigned_to'] as String?;
    String branchId = existing?['branch_id'] as String? ??
        (_branch != 'all' ? _branch : (_branches.isNotEmpty ? _branches.first['id'] as String : ''));
    bool requiresPhoto = existing?['requires_photo'] == true;
    bool saving = false;

    final branchAreas = () => _areas.where((a) => a['branch_id'] == branchId).toList();

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit schedule' : 'New schedule'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Title (e.g. Mop factory floor)', isDense: true),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: branchId.isEmpty ? null : branchId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Branch', isDense: true),
                      items: [
                        for (final b in _branches)
                          DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}')),
                      ],
                      onChanged: (v) => setLocal(() {
                        branchId = v ?? branchId;
                        areaId = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: cat,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Category', isDense: true),
                      items: [
                        for (final x in _categories)
                          DropdownMenuItem(value: x, child: Text(x)),
                      ],
                      onChanged: (v) => setLocal(() => cat = v ?? cat),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: freq,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Frequency', isDense: true),
                      items: [
                        for (final x in _frequencies)
                          DropdownMenuItem(value: x, child: Text(x)),
                      ],
                      onChanged: (v) => setLocal(() => freq = v ?? freq),
                    ),
                  ),
                  if (freq == 'custom') ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: intervalCtrl,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Every N days', isDense: true),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: areaId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Area (optional)', isDense: true),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final a in branchAreas())
                          DropdownMenuItem(value: a['id'] as String, child: Text('${a['name']}')),
                      ],
                      onChanged: (v) => setLocal(() => areaId = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: assignee,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Assignee (optional)', isDense: true),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final u in _assignees)
                          DropdownMenuItem(value: u['id'] as String, child: Text('${u['name']}')),
                      ],
                      onChanged: (v) => setLocal(() => assignee = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: checklistCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Checklist — one item per line',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Require a photo on completion'),
                  value: requiresPhoto,
                  onChanged: (v) => setLocal(() => requiresPhoto = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (titleCtrl.text.trim().isEmpty) {
                        _snack('Title is required.');
                        return;
                      }
                      if (branchId.isEmpty) {
                        _snack('Pick a branch.');
                        return;
                      }
                      setLocal(() => saving = true);
                      final ok = await _saveSchedule(
                        existing: existing,
                        title: titleCtrl.text.trim(),
                        branchId: branchId,
                        cat: cat,
                        freq: freq,
                        intervalDays: int.tryParse(intervalCtrl.text.trim()),
                        areaId: areaId,
                        assignee: assignee,
                        checklist: checklistCtrl.text
                            .split('\n')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList(),
                        requiresPhoto: requiresPhoto,
                      );
                      if (ok && ctx.mounted) Navigator.pop(ctx);
                      if (!ok) setLocal(() => saving = false);
                    },
              child: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        );
      }),
    );
  }

  Future<bool> _saveSchedule({
    Map<String, dynamic>? existing,
    required String title,
    required String branchId,
    required String cat,
    required String freq,
    int? intervalDays,
    String? areaId,
    String? assignee,
    required List<String> checklist,
    required bool requiresPhoto,
  }) async {
    try {
      final c = Supabase.instance.client;
      final data = {
        'org_id': _orgId,
        'branch_id': branchId,
        'title': title,
        'category': cat,
        'frequency': freq,
        'interval_days': freq == 'custom' ? (intervalDays ?? 1) : null,
        'area_id': areaId,
        'assigned_to': assignee,
        'checklist': checklist,
        'requires_photo': requiresPhoto,
      };
      if (existing != null) {
        await c.from('facility_schedules').update(data).eq('id', existing['id']);
      } else {
        data['created_by'] = ref.read(currentUserProvider)?.id;
        data['start_date'] = _today();
        data['next_due'] = _today();
        await c.from('facility_schedules').insert(data);
        // generate today's task immediately so it shows without waiting for cron
        try {
          await c.rpc('fn_generate_facility_tasks');
        } catch (_) {}
      }
      await _load();
      return true;
    } catch (e) {
      _snack('Save failed: $e');
      return false;
    }
  }

  // ───────────────────────────────────────────────── AREAS tab
  Widget _areasTab() {
    final rows = _areas.where(_inBranch).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('${rows.length} area${rows.length == 1 ? '' : 's'}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const Spacer(),
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code_2, size: 18),
          label: const Text('QR labels'),
          onPressed: _printAreaLabels,
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New area'),
          onPressed: () => _areaDialog(),
        ),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: rows.isEmpty
            ? const Center(
                child: Text('No areas yet. Add zones like Floor, Washroom, Office.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _areaCard(rows[i]),
              ),
      ),
    ]);
  }

  Widget _areaCard(Map<String, dynamic> a) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        const Icon(Icons.place_outlined, size: 20, color: AppTheme.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${a['name']}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 2),
            Row(children: [
              if (a['area_type'] != null) _pill(a['area_type'], AppTheme.textSecondary),
              const SizedBox(width: 8),
              Text(_branchNames[a['branch_id']] ?? '',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ]),
        ),
        IconButton(
            onPressed: () => _printAreaLabel(a),
            icon: const Icon(Icons.qr_code_2, size: 18),
            tooltip: 'QR label (print & stick in the area)'),
        IconButton(
            onPressed: () => _areaDialog(existing: a),
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit'),
      ]),
    );
  }

  String? _areaUrl(Map<String, dynamic> a) {
    final tkn = a['public_token'] as String?;
    if (tkn == null || tkn.isEmpty) return null;
    return '$_kAreaViewBase?t=$tkn';
  }

  String _areaSub(Map<String, dynamic> a) => [
        a['area_type'],
        _branchNames[a['branch_id']],
      ].where((x) => x != null && '$x'.isNotEmpty).join(' · ');

  Future<void> _printAreaLabel(Map<String, dynamic> a) async {
    final url = _areaUrl(a);
    if (url == null) {
      _snack('No QR token yet — refresh and try again.');
      return;
    }
    await AssetPdf.printLabel(
      code: a['name'] as String? ?? 'Area',
      name: _areaSub(a),
      url: url,
      orgName: ref.read(currentUserProvider)?.orgName,
      caption: 'Scan for area status',
    );
  }

  Future<void> _printAreaLabels() async {
    final src = _areas.where(_inBranch).toList();
    final labels = <Map<String, String>>[];
    for (final a in src) {
      final url = _areaUrl(a);
      if (url == null) continue;
      labels.add({
        'code': a['name'] as String? ?? 'Area',
        'name': _areaSub(a),
        'url': url,
      });
    }
    if (labels.isEmpty) {
      _snack('No areas to print.');
      return;
    }
    await AssetPdf.printLabelSheet(
      labels: labels,
      orgName: ref.read(currentUserProvider)?.orgName,
      caption: 'Scan for area status',
    );
  }

  Future<void> _areaDialog({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?['name'] as String? ?? '');
    String type = existing?['area_type'] as String? ?? 'floor';
    String branchId = existing?['branch_id'] as String? ??
        (_branch != 'all' ? _branch : (_branches.isNotEmpty ? _branches.first['id'] as String : ''));
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(isEdit ? 'Edit area' : 'New area'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: nameCtrl,
                decoration:
                    const InputDecoration(labelText: 'Area name', isDense: true),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: branchId.isEmpty ? null : branchId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Branch', isDense: true),
                    items: [
                      for (final b in _branches)
                        DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}')),
                    ],
                    onChanged: (v) => setLocal(() => branchId = v ?? branchId),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: type,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Type', isDense: true),
                    items: [
                      for (final x in _areaTypes)
                        DropdownMenuItem(value: x, child: Text(x)),
                    ],
                    onChanged: (v) => setLocal(() => type = v ?? type),
                  ),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (nameCtrl.text.trim().isEmpty) {
                        _snack('Name is required.');
                        return;
                      }
                      if (branchId.isEmpty) {
                        _snack('Pick a branch.');
                        return;
                      }
                      setLocal(() => saving = true);
                      try {
                        final c = Supabase.instance.client;
                        final data = {
                          'org_id': _orgId,
                          'branch_id': branchId,
                          'name': nameCtrl.text.trim(),
                          'area_type': type,
                        };
                        if (isEdit) {
                          await c.from('facility_areas').update(data).eq('id', existing['id']);
                        } else {
                          await c.from('facility_areas').insert(data);
                        }
                        await _load();
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setLocal(() => saving = false);
                        _snack('Save failed: $e');
                      }
                    },
              child: Text(saving ? 'Saving…' : 'Save'),
            ),
          ],
        );
      }),
    );
  }
}
