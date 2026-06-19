// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../erp/services/asset_pdf.dart';

/// Public asset page (static, Firebase-hosted). The QR encodes
/// "$_kAssetViewBase?t=<public_token>"; the page fetches the asset-view
/// function (JSON) and renders. Edge Functions can't serve HTML, so the page
/// lives on Firebase, not on the function domain.
const String _kAssetViewBase = 'https://opstation-f06c7.web.app/asset.html';

/// Assets Management — operational register (no GL yet).
/// Master list (left) with search + filters; detail panel (right) with full
/// spec, current placement & custodian, placement/custody history, photos,
/// and the maintenance log. Backed by assets / asset_categories /
/// asset_assignments / asset_files / asset_maintenance and the
/// next_asset_code + asset_reassign RPCs.
class ErpAssetsScreen extends ConsumerStatefulWidget {
  const ErpAssetsScreen({super.key});
  @override
  ConsumerState<ErpAssetsScreen> createState() => _ErpAssetsScreenState();
}

const _bucket = 'asset-files';
const _statuses = [
  'in_use',
  'in_storage',
  'under_repair',
  'retired',
  'lost',
  'disposed'
];
const _conditions = ['new', 'good', 'fair', 'poor'];

String _statusLabel(String? s) =>
    (s ?? '').replaceAll('_', ' ').trim().isEmpty
        ? '—'
        : s!.replaceAll('_', ' ');

Color _statusColor(String? s) {
  switch (s) {
    case 'in_use':
      return AppTheme.success;
    case 'in_storage':
      return AppTheme.primary;
    case 'under_repair':
      return AppTheme.warning;
    case 'lost':
    case 'disposed':
      return AppTheme.danger;
    default:
      return AppTheme.textSecondary;
  }
}

class _ErpAssetsScreenState extends ConsumerState<ErpAssetsScreen> {
  final _money = NumberFormat('#,##0.##');
  bool _loading = true;
  List<Map<String, dynamic>> _assets = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _branches = [];
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _custodians = [];
  final Map<String, String> _catNames = {};
  final Map<String, String> _branchNames = {};
  final Map<String, String> _userNames = {};
  final Map<String, String> _custodianNames = {};

  String? _selectedId;
  final _searchCtrl = TextEditingController();
  String _catFilter = 'all';
  String _branchFilter = 'all';
  String _statusFilter = 'all';
  String _custodianFilter = 'all';
  String _dueFilter = 'all'; // all | due | overdue | soon

  // detail sub-data
  bool _detailLoading = false;
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _files = [];
  List<Map<String, dynamic>> _maint = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final assets = await client
          .from('assets')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('asset_code');
      final cats = await client
          .from('asset_categories')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final branches = await client
          .from('branches')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      final users = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId)
          .order('name');
      final custodians = await client
          .from('asset_custodians')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');

      if (!mounted) return;
      setState(() {
        _assets = List<Map<String, dynamic>>.from(assets);
        _categories = List<Map<String, dynamic>>.from(cats);
        _branches = List<Map<String, dynamic>>.from(branches);
        _users = List<Map<String, dynamic>>.from(users);
        _custodians = List<Map<String, dynamic>>.from(custodians);
        _catNames
          ..clear()
          ..addEntries(_categories.map((c) =>
              MapEntry(c['id'] as String, (c['name'] as String?) ?? '—')));
        _branchNames
          ..clear()
          ..addEntries(_branches.map((b) =>
              MapEntry(b['id'] as String, (b['name'] as String?) ?? '—')));
        _userNames
          ..clear()
          ..addEntries(_users.map((u) =>
              MapEntry(u['id'] as String, (u['name'] as String?) ?? '—')));
        _custodianNames
          ..clear()
          ..addEntries(_custodians.map((c) =>
              MapEntry(c['id'] as String, (c['name'] as String?) ?? '—')));
        _loading = false;
        if (_selectedId != null &&
            !_assets.any((a) => a['id'] == _selectedId)) {
          _selectedId = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack('Could not load assets: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _loadDetail(String assetId) async {
    setState(() {
      _detailLoading = true;
      _history = [];
      _files = [];
      _maint = [];
    });
    try {
      final client = Supabase.instance.client;
      final hist = await client
          .from('asset_assignments')
          .select()
          .eq('asset_id', assetId)
          .order('performed_at', ascending: false);
      final files = await client
          .from('asset_files')
          .select()
          .eq('asset_id', assetId)
          .order('created_at', ascending: false);
      final maint = await client
          .from('asset_maintenance')
          .select()
          .eq('asset_id', assetId)
          .order('service_date', ascending: false);
      if (!mounted) return;
      setState(() {
        _history = List<Map<String, dynamic>>.from(hist);
        _files = List<Map<String, dynamic>>.from(files);
        _maint = List<Map<String, dynamic>>.from(maint);
        _detailLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _detailLoading = false);
    }
  }

  void _select(String id) {
    setState(() => _selectedId = id);
    _loadDetail(id);
  }

  Map<String, dynamic>? get _selected =>
      _selectedId == null ? null : _assets.firstWhere(
          (a) => a['id'] == _selectedId,
          orElse: () => <String, dynamic>{});

  List<Map<String, dynamic>> get _filtered {
    final q = _searchCtrl.text.toLowerCase();
    return _assets.where((a) {
      if (_catFilter != 'all' && a['category_id'] != _catFilter) return false;
      if (_branchFilter != 'all' && a['branch_id'] != _branchFilter) {
        return false;
      }
      if (_statusFilter != 'all' && a['status'] != _statusFilter) return false;
      if (_custodianFilter != 'all') {
        if (_custodianFilter == 'unassigned') {
          if (a['assigned_to'] != null) return false;
        } else if (a['assigned_to'] != _custodianFilter) {
          return false;
        }
      }
      if (_dueFilter != 'all') {
        final st = _dueState(a);
        if (_dueFilter == 'due' && st == null) return false;
        if (_dueFilter == 'overdue' && st != 'overdue') return false;
        if (_dueFilter == 'soon' && st != 'soon') return false;
      }
      if (q.isNotEmpty) {
        final hay = [
          a['asset_code'],
          a['name'],
          a['serial_no'],
          a['model'],
          a['manufacturer'],
        ].map((e) => '${e ?? ''}'.toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// 'overdue' if next maintenance date has passed, 'soon' if within 14 days.
  String? _dueState(Map<String, dynamic> a) {
    final d = DateTime.tryParse('${a['next_maintenance_due']}');
    if (d == null) return null;
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    if (!d.isAfter(day)) return 'overdue';
    if (d.isBefore(day.add(const Duration(days: 14)))) return 'soon';
    return null;
  }

  int get _dueCount => _assets.where((a) => _dueState(a) != null).length;

  Widget _dueBadgeButton() {
    final on = _dueFilter != 'all';
    return InkWell(
      onTap: () => setState(() => _dueFilter = on ? 'all' : 'due'),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? AppTheme.danger : AppTheme.danger.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: AppTheme.danger.withOpacity(on ? 1 : 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.build_outlined,
              size: 14, color: on ? Colors.white : AppTheme.danger),
          const SizedBox(width: 6),
          Text('$_dueCount due',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : AppTheme.danger)),
          if (on) ...[
            const SizedBox(width: 6),
            const Icon(Icons.close, size: 13, color: Colors.white),
          ],
        ]),
      ),
    );
  }

  Widget _nextDueBanner(Map<String, dynamic> a) {
    final st = _dueState(a);
    final due = _fmtDate(a['next_maintenance_due']);
    final color = st == 'overdue'
        ? AppTheme.danger
        : (st == 'soon' ? AppTheme.warning : AppTheme.textSecondary);
    final tail =
        st == 'overdue' ? '  ·  overdue' : (st == 'soon' ? '  ·  due soon' : '');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(children: [
        Icon(Icons.event_outlined, size: 15, color: color),
        const SizedBox(width: 8),
        Text('Next due: ${due ?? '—'}$tail',
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  Future<void> _printSheet(Map<String, dynamic> a) async {
    final orgName = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final hist = _history.map((h) {
      final when = DateTime.tryParse('${h['performed_at']}');
      final parts = <String>[
        if (h['branch_id'] != null) '→ ${_branchNames[h['branch_id']] ?? '—'}',
        if (h['location_text'] != null) '${h['location_text']}',
        if (h['assigned_to'] != null)
          '@ ${_custodianNames[h['assigned_to']] ?? '—'}',
        if (h['status'] != null) _statusLabel(h['status'] as String?),
      ];
      final text =
          '${_capitalize((h['action'] as String?)?.replaceAll('_', ' '))}'
          '${parts.isEmpty ? '' : '  ·  ${parts.join('  ·  ')}'}'
          '${(h['note'] as String?)?.isNotEmpty == true ? '  —  ${h['note']}' : ''}';
      final whenStr = [
        if (when != null) DateFormat('d MMM y, h:mm a').format(when),
        if (h['performed_by'] != null)
          'by ${_userNames[h['performed_by']] ?? '—'}',
      ].join('  ·  ');
      return {'text': text, 'when': whenStr};
    }).toList();

    final maint = _maint.map((m) {
      final text = '${_capitalize(m['type'] as String?)}'
          '${m['cost'] == null ? '' : '  ·  Rs ${_money.format(m['cost'])}'}'
          '${m['vendor'] != null ? '  ·  ${m['vendor']}' : ''}'
          '${(m['note'] as String?)?.isNotEmpty == true ? '  —  ${m['note']}' : ''}';
      return {
        'text': text,
        'date': _fmtDate(m['service_date']) ?? '',
        'next': _fmtDate(m['next_due']) ?? '',
      };
    }).toList();

    final cond = _capitalize(a['condition'] as String?);

    Uint8List? imgBytes;
    final imgFile = _files.firstWhere(
        (f) => (f['file_type'] as String?) == 'image',
        orElse: () => <String, dynamic>{});
    final imgPath =
        (a['image_path'] as String?) ?? (imgFile['storage_path'] as String?);
    if (imgPath != null && imgPath.isNotEmpty) {
      try {
        imgBytes =
            await Supabase.instance.client.storage.from(_bucket).download(imgPath);
      } catch (_) {/* skip image if it can't be fetched */}
    }

    await AssetPdf.printSheet(
      orgName: orgName,
      code: a['asset_code'] as String? ?? '-',
      name: a['name'] as String? ?? '-',
      imageBytes: imgBytes,
      status: _statusLabel(a['status'] as String?),
      condition: cond == '—' ? null : cond,
      category: a['category_id'] == null ? null : _catNames[a['category_id']],
      branch: a['branch_id'] == null ? null : _branchNames[a['branch_id']],
      location: a['location_text'] as String?,
      custodian: a['assigned_to'] == null
          ? null
          : _custodianNames[a['assigned_to']],
      serial: a['serial_no'] as String?,
      model: a['model'] as String?,
      manufacturer: a['manufacturer'] as String?,
      supplier: a['supplier_id'] as String?,
      purchased: _fmtDate(a['purchase_date']),
      cost: a['purchase_cost'] == null
          ? null
          : 'Rs ${_money.format(a['purchase_cost'])}',
      warranty: _fmtDate(a['warranty_expiry']),
      description: a['description'] as String?,
      notes: a['notes'] as String?,
      nextDue: _fmtDate(a['next_maintenance_due']),
      nextDueOverdue: _dueState(a) == 'overdue',
      nextDueSoon: _dueState(a) == 'soon',
      qrData: _assetUrl(a),
      history: List<Map<String, String>>.from(hist),
      maintenance: List<Map<String, String>>.from(maint),
    );
  }

  String? _assetUrl(Map<String, dynamic> a) {
    final t = a['public_token'] as String?;
    if (t == null || t.isEmpty) return null;
    return '$_kAssetViewBase?t=$t';
  }

  Future<void> _printLabel(Map<String, dynamic> a) async {
    final url = _assetUrl(a);
    if (url == null) {
      _snack('This asset has no QR token yet — reload after the migration.');
      return;
    }
    await AssetPdf.printLabel(
      code: a['asset_code'] as String? ?? '-',
      name: a['name'] as String? ?? '-',
      url: url,
      orgName: ref.read(currentUserProvider)?.orgName,
    );
  }

  Future<void> _printLabelsDialog() async {
    final source = _filtered.isNotEmpty ? _filtered : _assets;
    if (source.isEmpty) {
      _snack('No assets to print.');
      return;
    }
    final selected = <String>{...source.map((a) => a['id'] as String)};
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final allOn = selected.length == source.length;
        return AlertDialog(
          title: const Text('Print QR labels'),
          content: SizedBox(
            width: 440,
            height: 480,
            child: Column(children: [
              Row(children: [
                Text('${selected.length} of ${source.length} selected',
                    style: const TextStyle(color: AppTheme.textSecondary)),
                const Spacer(),
                TextButton(
                  onPressed: () => setLocal(() {
                    if (allOn) {
                      selected.clear();
                    } else {
                      selected
                        ..clear()
                        ..addAll(source.map((a) => a['id'] as String));
                    }
                  }),
                  child: Text(allOn ? 'Clear all' : 'Select all'),
                ),
              ]),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    for (final a in source)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: selected.contains(a['id']),
                        onChanged: (v) => setLocal(() {
                          if (v == true) {
                            selected.add(a['id'] as String);
                          } else {
                            selected.remove(a['id']);
                          }
                        }),
                        title: Text(
                            '${a['asset_code'] ?? ''}   ${a['name'] ?? ''}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton.icon(
              icon: const Icon(Icons.print, size: 18),
              label: Text('Print ${selected.length}'),
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      final labels = <Map<String, String>>[];
                      for (final a in source) {
                        if (!selected.contains(a['id'])) continue;
                        final url = _assetUrl(a);
                        if (url == null) continue;
                        labels.add({
                          'code': a['asset_code'] as String? ?? '-',
                          'name': a['name'] as String? ?? '-',
                          'url': url,
                        });
                      }
                      Navigator.pop(ctx);
                      if (labels.isEmpty) {
                        _snack('Selected assets have no QR token yet.');
                        return;
                      }
                      AssetPdf.printLabelSheet(
                        labels: labels,
                        orgName: ref.read(currentUserProvider)?.orgName,
                      );
                    },
            ),
          ],
        );
      }),
    );
  }

  // ───────────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Assets',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            if (!_loading)
              Text('${_assets.length} total',
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
            if (!_loading && (_dueCount > 0 || _dueFilter != 'all')) ...[
              const SizedBox(width: 10),
              _dueBadgeButton(),
            ],
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.category_outlined, size: 18),
              label: const Text('Categories'),
              onPressed: _categoriesDialog,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: const Text('QR labels'),
              onPressed: _printLabelsDialog,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.badge_outlined, size: 18),
              label: const Text('Custodians'),
              onPressed: _custodiansDialog,
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New asset'),
              onPressed: () => _assetDialog(),
            ),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh'),
          ]),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 360, child: _listPane()),
                      const SizedBox(width: 16),
                      Expanded(child: _detailPane()),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────── list pane
  Widget _listPane() {
    final rows = _filtered;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                    hintText: 'Search code, name, serial…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: _filterDropdown(
                    value: _catFilter,
                    hint: 'Category',
                    items: {
                      'all': 'All categories',
                      for (final c in _categories)
                        c['id'] as String: c['name'] as String? ?? '—',
                    },
                    onChanged: (v) => setState(() => _catFilter = v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _filterDropdown(
                    value: _statusFilter,
                    hint: 'Status',
                    items: {
                      'all': 'All statuses',
                      for (final s in _statuses) s: _statusLabel(s),
                    },
                    onChanged: (v) => setState(() => _statusFilter = v),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              _filterDropdown(
                value: _branchFilter,
                hint: 'Branch',
                items: {
                  'all': 'All branches',
                  for (final b in _branches)
                    b['id'] as String: b['name'] as String? ?? '—',
                },
                onChanged: (v) => setState(() => _branchFilter = v),
              ),
              const SizedBox(height: 8),
              _filterDropdown(
                value: _custodianFilter,
                hint: 'Custodian',
                items: {
                  'all': 'All custodians',
                  'unassigned': 'Unassigned',
                  for (final c in _custodians)
                    c['id'] as String: c['name'] as String? ?? '—',
                },
                onChanged: (v) => setState(() => _custodianFilter = v),
              ),
              const SizedBox(height: 8),
              _filterDropdown(
                value: _dueFilter,
                hint: 'Maintenance',
                items: const {
                  'all': 'All',
                  'due': 'Due (overdue + soon)',
                  'overdue': 'Overdue only',
                  'soon': 'Due soon',
                },
                onChanged: (v) => setState(() => _dueFilter = v),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? const Center(
                    child: Text('No assets match',
                        style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final a = rows[i];
                      final selected = a['id'] == _selectedId;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: AppTheme.primary.withOpacity(0.06),
                        onTap: () => _select(a['id'] as String),
                        title: Text(a['name'] as String? ?? '—',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            a['asset_code'],
                            if (a['category_id'] != null)
                              _catNames[a['category_id']],
                          ].where((e) => e != null).join('  ·  '),
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (_dueState(a) != null) ...[
                            Icon(Icons.build_circle,
                                size: 16,
                                color: _dueState(a) == 'overdue'
                                    ? AppTheme.danger
                                    : AppTheme.warning),
                            const SizedBox(width: 6),
                          ],
                          _statusChip(a['status'] as String?),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterDropdown({
    required String value,
    required String hint,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: hint, isDense: true),
      items: items.entries
          .map((e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: (v) => onChanged(v ?? 'all'),
    );
  }

  Widget _statusChip(String? s) {
    final c = _statusColor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(_statusLabel(s),
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }

  // ───────────────────────────────────────────────────── detail pane
  Widget _detailPane() {
    final a = _selected;
    if (a == null || a.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: const Center(
          child: Text('Select an asset to see its details',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a['name'] as String? ?? '—',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(a['asset_code'] as String? ?? '',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              _statusChip(a['status'] as String?),
              const SizedBox(width: 8),
              IconButton(
                  onPressed: () => _printSheet(a),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  tooltip: 'Print / PDF'),
              IconButton(
                  onPressed: () => _printLabel(a),
                  icon: const Icon(Icons.qr_code_2),
                  tooltip: 'QR label (print & stick on asset)'),
              IconButton(
                  onPressed: () => _assetDialog(existing: a),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit'),
              IconButton(
                  onPressed: () => _reassignDialog(a),
                  icon: const Icon(Icons.swap_horiz),
                  tooltip: 'Reassign / move'),
            ]),
            const SizedBox(height: 16),
            // placement
            _section('Current placement', [
              _kv('Branch',
                  a['branch_id'] == null ? '—' : _branchNames[a['branch_id']]),
              _kv('Location', a['location_text'] as String?),
              _kv(
                  'Custodian',
                  a['assigned_to'] == null
                      ? 'Unassigned'
                      : _custodianNames[a['assigned_to']]),
              _kv('Condition', _capitalize(a['condition'] as String?)),
            ]),
            const SizedBox(height: 16),
            _section('Specification', [
              _kv('Category',
                  a['category_id'] == null ? '—' : _catNames[a['category_id']]),
              _kv('Serial no.', a['serial_no'] as String?),
              _kv('Model', a['model'] as String?),
              _kv('Manufacturer', a['manufacturer'] as String?),
              _kv('Supplier', a['supplier_id'] as String?),
              _kv('Purchased', _fmtDate(a['purchase_date'])),
              _kv(
                  'Purchase cost',
                  a['purchase_cost'] == null
                      ? null
                      : 'Rs ${_money.format(a['purchase_cost'])}'),
              _kv('Warranty till', _fmtDate(a['warranty_expiry'])),
            ]),
            if ((a['description'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              _kv('Description', a['description'] as String?),
            ],
            if ((a['notes'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              _kv('Notes', a['notes'] as String?),
            ],
            const SizedBox(height: 20),
            _photosSection(a),
            const SizedBox(height: 20),
            _historySection(),
            const SizedBox(height: 20),
            _maintSection(a),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          Wrap(runSpacing: 8, spacing: 28, children: rows),
        ],
      ),
    );
  }

  Widget _kv(String k, String? v) {
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k,
              style:
                  const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          const SizedBox(height: 2),
          Text(v == null || v.isEmpty ? '—' : v,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────── photos
  Widget _photosSection(Map<String, dynamic> a) {
    final imgs =
        _files.where((f) => (f['file_type'] as String?) == 'image').toList();
    final docs =
        _files.where((f) => (f['file_type'] as String?) != 'image').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Photos & documents',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.upload_file, size: 16),
            label: const Text('Upload'),
            onPressed: _detailLoading ? null : () => _uploadFile(a),
          ),
        ]),
        const SizedBox(height: 8),
        if (_detailLoading)
          const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)))
        else if (_files.isEmpty)
          const Text('No files yet.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
        else ...[
          if (imgs.isNotEmpty)
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: imgs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _thumb(imgs[i]),
              ),
            ),
          for (final d in docs)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined, size: 20),
              title: Text(d['title'] as String? ?? 'Document',
                  style: const TextStyle(fontSize: 13)),
              trailing: IconButton(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  onPressed: () => _openFile(d)),
            ),
        ],
      ],
    );
  }

  Widget _thumb(Map<String, dynamic> f) {
    return FutureBuilder<String>(
      future: Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(f['storage_path'] as String, 3600),
      builder: (_, snap) {
        final url = snap.data;
        return InkWell(
          onTap: () => _openFile(f),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 96,
              height: 96,
              color: AppTheme.background,
              child: url == null
                  ? const Center(
                      child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : Image.network(url, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined)),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openFile(Map<String, dynamic> f) async {
    try {
      final url = await Supabase.instance.client.storage
          .from(_bucket)
          .createSignedUrl(f['storage_path'] as String, 3600);
      html.window.open(url, '_blank');
    } catch (e) {
      _snack('Could not open file');
    }
  }

  Future<void> _uploadFile(Map<String, dynamic> a) async {
    final input = html.FileUploadInputElement()
      ..accept = 'image/png,image/jpeg,image/webp,application/pdf';
    input.click();
    input.onChange.listen((_) {
      final files = input.files;
      if (files == null || files.isEmpty) return;
      final f = files[0];
      if (f.size > 10 * 1024 * 1024) {
        _snack('File too large — max 10 MB');
        return;
      }
      final reader = html.FileReader();
      reader.readAsArrayBuffer(f);
      reader.onLoad.listen((_) async {
        final r = reader.result;
        final bytes = r is ByteBuffer ? r.asUint8List() : r as Uint8List;
        try {
          final client = Supabase.instance.client;
          final orgId = _orgId ?? 'org';
          final safe = f.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
          final path =
              '$orgId/${a['id']}/${DateTime.now().millisecondsSinceEpoch}_$safe';
          final isImg = (f.type).startsWith('image/');
          await client.storage.from(_bucket).uploadBinary(path, bytes,
              fileOptions: FileOptions(
                  contentType: f.type.isEmpty ? null : f.type, upsert: false));
          await client.from('asset_files').insert({
            'id': 'afil_${DateTime.now().millisecondsSinceEpoch}',
            'org_id': orgId,
            'asset_id': a['id'],
            'file_type': isImg ? 'image' : 'pdf',
            'storage_path': path,
            'title': f.name,
            'uploaded_by': client.auth.currentUser?.id,
          });
          // first image becomes the primary thumbnail
          if (isImg && (a['image_path'] == null)) {
            await client
                .from('assets')
                .update({'image_path': path}).eq('id', a['id']);
          }
          _loadDetail(a['id'] as String);
          _load();
        } catch (e) {
          _snack('Upload failed: ${e.toString().split('\n').first}');
        }
      });
    });
  }

  // ───────────────────────────────────────────────────── history
  Widget _historySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Placement & custody history',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (_history.isEmpty)
          const Text('No movements logged yet.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
        else
          for (final h in _history) _historyRow(h),
      ],
    );
  }

  Widget _historyRow(Map<String, dynamic> h) {
    final when = DateTime.tryParse('${h['performed_at']}');
    final parts = <String>[
      if (h['branch_id'] != null) '→ ${_branchNames[h['branch_id']] ?? '—'}',
      if (h['location_text'] != null) '${h['location_text']}',
      if (h['assigned_to'] != null) '@ ${_custodianNames[h['assigned_to']] ?? '—'}',
      if (h['status'] != null) _statusLabel(h['status'] as String?),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 8),
          child: Icon(Icons.history, size: 15, color: AppTheme.textSecondary),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_capitalize((h['action'] as String?)?.replaceAll('_', ' '))}'
                '${parts.isEmpty ? '' : '  ·  ${parts.join('  ·  ')}'}',
                style: const TextStyle(fontSize: 12.5),
              ),
              if ((h['note'] as String?)?.isNotEmpty == true)
                Text(h['note'] as String,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              Text(
                [
                  if (when != null) DateFormat('d MMM y, h:mm a').format(when),
                  if (h['performed_by'] != null)
                    'by ${_userNames[h['performed_by']] ?? '—'}',
                ].join('  ·  '),
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ───────────────────────────────────────────────────── maintenance
  Widget _maintSection(Map<String, dynamic> a) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Maintenance log',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add'),
            onPressed: () => _maintDialog(a),
          ),
        ]),
        const SizedBox(height: 4),
        if (a['next_maintenance_due'] != null) _nextDueBanner(a),
        if (_maint.isEmpty)
          const Text('No maintenance recorded.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
        else
          for (final m in _maint)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 8),
                  child: Icon(Icons.build_outlined,
                      size: 15, color: AppTheme.textSecondary),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_capitalize(m['type'] as String?)}'
                        '${m['cost'] == null ? '' : '  ·  Rs ${_money.format(m['cost'])}'}'
                        '${m['vendor'] != null ? '  ·  ${m['vendor']}' : ''}',
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                      if ((m['note'] as String?)?.isNotEmpty == true)
                        Text(m['note'] as String,
                            style: const TextStyle(fontSize: 12)),
                      Text(
                        [
                          _fmtDate(m['service_date']),
                          if (m['next_due'] != null)
                            'next: ${_fmtDate(m['next_due'])}',
                        ].where((e) => e != null && e.isNotEmpty).join('  ·  '),
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ]),
            ),
      ],
    );
  }

  // ───────────────────────────────────────────────────── dialogs
  Future<void> _assetDialog({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    final orgId = _orgId;
    if (orgId == null) return;

    String code = existing?['asset_code'] as String? ?? '';
    if (!isEdit) {
      try {
        final res = await Supabase.instance.client
            .rpc('next_asset_code', params: {'p_org_id': orgId});
        code = res as String? ?? 'AST-0001';
      } catch (_) {
        code = 'AST-0001';
      }
    }

    final nameCtrl =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final descCtrl =
        TextEditingController(text: existing?['description'] as String? ?? '');
    final serialCtrl =
        TextEditingController(text: existing?['serial_no'] as String? ?? '');
    final modelCtrl =
        TextEditingController(text: existing?['model'] as String? ?? '');
    final mfgCtrl = TextEditingController(
        text: existing?['manufacturer'] as String? ?? '');
    final supplierCtrl =
        TextEditingController(text: existing?['supplier_id'] as String? ?? '');
    final costCtrl = TextEditingController(
        text: existing?['purchase_cost']?.toString() ?? '');
    final locCtrl = TextEditingController(
        text: existing?['location_text'] as String? ?? '');
    final notesCtrl =
        TextEditingController(text: existing?['notes'] as String? ?? '');

    String? categoryId = existing?['category_id'] as String?;
    String status = existing?['status'] as String? ?? 'in_use';
    String? condition = existing?['condition'] as String?;
    String? branchId = existing?['branch_id'] as String?;
    String? custodian = existing?['assigned_to'] as String?;
    DateTime? purchaseDate = _parseDate(existing?['purchase_date']);
    DateTime? warranty = _parseDate(existing?['warranty_expiry']);
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> save() async {
          if (nameCtrl.text.trim().isEmpty) {
            ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Name is required')));
            return;
          }
          setS(() => saving = true);
          try {
            final client = Supabase.instance.client;
            final payload = {
              'name': nameCtrl.text.trim(),
              'description': _nz(descCtrl.text),
              'category_id': categoryId,
              'status': status,
              'condition': condition,
              'branch_id': branchId,
              'location_text': _nz(locCtrl.text),
              'assigned_to': custodian,
              'serial_no': _nz(serialCtrl.text),
              'model': _nz(modelCtrl.text),
              'manufacturer': _nz(mfgCtrl.text),
              'supplier_id': _nz(supplierCtrl.text),
              'purchase_cost': double.tryParse(costCtrl.text.trim()),
              'purchase_date': purchaseDate == null
                  ? null
                  : DateFormat('yyyy-MM-dd').format(purchaseDate!),
              'warranty_expiry': warranty == null
                  ? null
                  : DateFormat('yyyy-MM-dd').format(warranty!),
              'notes': _nz(notesCtrl.text),
            };
            if (isEdit) {
              await client
                  .from('assets')
                  .update(payload)
                  .eq('id', existing['id']);
            } else {
              final id = 'asset_${DateTime.now().millisecondsSinceEpoch}';
              await client.from('assets').insert({
                'id': id,
                'org_id': orgId,
                'asset_code': code,
                'created_by': client.auth.currentUser?.id,
                ...payload,
              });
              // log creation in history with the actor resolved server-side
              await client.rpc('asset_reassign', params: {
                'p_asset_id': id,
                'p_branch_id': branchId,
                'p_location_text': _nz(locCtrl.text),
                'p_assigned_to': custodian,
                'p_status': status,
                'p_action': 'created',
                'p_note': 'Asset created',
              });
            }
            if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
            await _load();
            if (!isEdit) {
              // select the new one
              final created = _assets.firstWhere(
                  (x) => x['asset_code'] == code,
                  orElse: () => <String, dynamic>{});
              if (created.isNotEmpty) _select(created['id'] as String);
            } else {
              _loadDetail(existing['id'] as String);
            }
          } catch (e) {
            setS(() => saving = false);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                  content:
                      Text('Failed: ${e.toString().split('\n').first}')));
            }
          }
        }

        return AlertDialog(
          title: Text(isEdit ? 'Edit asset · $code' : 'New asset · $code'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name *')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: categoryId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Category'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('—')),
                        for (final c in _categories)
                          DropdownMenuItem<String?>(
                              value: c['id'] as String,
                              child: Text(c['name'] as String? ?? '—')),
                      ],
                      onChanged: (v) => setS(() => categoryId = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: _statuses
                          .map((s) => DropdownMenuItem(
                              value: s, child: Text(_statusLabel(s))))
                          .toList(),
                      onChanged: (v) => setS(() => status = v ?? status),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: branchId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Branch'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('—')),
                        for (final b in _branches)
                          DropdownMenuItem<String?>(
                              value: b['id'] as String,
                              child: Text(b['name'] as String? ?? '—')),
                      ],
                      onChanged: (v) => setS(() => branchId = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: custodian,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Custodian'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('Unassigned')),
                        for (final cu in _custodians)
                          DropdownMenuItem<String?>(
                              value: cu['id'] as String,
                              child: Text(cu['name'] as String? ?? '—')),
                      ],
                      onChanged: (v) => setS(() => custodian = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(
                    controller: locCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Location (sub-location / desk / rack)')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: serialCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Serial no.'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: DropdownButtonFormField<String?>(
                    value: condition,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Condition'),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('—')),
                      for (final c in _conditions)
                        DropdownMenuItem<String?>(
                            value: c, child: Text(_capitalize(c))),
                    ],
                    onChanged: (v) => setS(() => condition = v),
                  )),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: modelCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Model'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextField(
                          controller: mfgCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Manufacturer'))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: supplierCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Supplier'))),
                  const SizedBox(width: 10),
                  Expanded(
                      child: TextField(
                          controller: costCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Purchase cost (Rs)'))),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: _dateField('Purchase date', purchaseDate,
                          (d) => setS(() => purchaseDate = d), ctx)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: _dateField('Warranty expiry', warranty,
                          (d) => setS(() => warranty = d), ctx)),
                ]),
                const SizedBox(height: 10),
                TextField(
                    controller: descCtrl,
                    maxLines: 2,
                    decoration:
                        const InputDecoration(labelText: 'Description')),
                const SizedBox(height: 10),
                TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Notes')),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: saving
                    ? null
                    : () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving ? null : save,
              child: saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(isEdit ? 'Save' : 'Create'),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _reassignDialog(Map<String, dynamic> a) async {
    String? branchId = a['branch_id'] as String?;
    String? custodian = a['assigned_to'] as String?;
    String status = a['status'] as String? ?? 'in_use';
    final locCtrl =
        TextEditingController(text: a['location_text'] as String? ?? '');
    final noteCtrl = TextEditingController();
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> save() async {
          setS(() => saving = true);
          try {
            await Supabase.instance.client.rpc('asset_reassign', params: {
              'p_asset_id': a['id'],
              'p_branch_id': branchId,
              'p_location_text': _nz(locCtrl.text),
              'p_assigned_to': custodian ?? '',
              'p_status': status,
              'p_action': 'transferred',
              'p_note': _nz(noteCtrl.text),
            });
            if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
            await _load();
            _loadDetail(a['id'] as String);
          } catch (e) {
            setS(() => saving = false);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                  content:
                      Text('Failed: ${e.toString().split('\n').first}')));
            }
          }
        }

        return AlertDialog(
          title: const Text('Reassign / move'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String?>(
                value: branchId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Branch'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('—')),
                  for (final b in _branches)
                    DropdownMenuItem<String?>(
                        value: b['id'] as String,
                        child: Text(b['name'] as String? ?? '—')),
                ],
                onChanged: (v) => setS(() => branchId = v),
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: locCtrl,
                  decoration: const InputDecoration(labelText: 'Location')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                value: custodian,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Custodian'),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Unassigned')),
                  for (final cu in _custodians)
                    DropdownMenuItem<String?>(
                        value: cu['id'] as String,
                        child: Text(cu['name'] as String? ?? '—')),
                ],
                onChanged: (v) => setS(() => custodian = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: status,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Status'),
                items: _statuses
                    .map((s) => DropdownMenuItem(
                        value: s, child: Text(_statusLabel(s))))
                    .toList(),
                onChanged: (v) => setS(() => status = v ?? status),
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: noteCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Note (optional)')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: saving
                    ? null
                    : () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: saving ? null : save,
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Apply')),
          ],
        );
      }),
    );
  }

  Future<void> _maintDialog(Map<String, dynamic> a) async {
    String type = 'service';
    final costCtrl = TextEditingController();
    final vendorCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    DateTime date = DateTime.now();
    DateTime? nextDue;
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> save() async {
          setS(() => saving = true);
          try {
            await Supabase.instance.client.from('asset_maintenance').insert({
              'id': 'amnt_${DateTime.now().millisecondsSinceEpoch}',
              'org_id': _orgId,
              'asset_id': a['id'],
              'service_date': DateFormat('yyyy-MM-dd').format(date),
              'type': type,
              'cost': double.tryParse(costCtrl.text.trim()),
              'vendor': _nz(vendorCtrl.text),
              'note': _nz(noteCtrl.text),
              'next_due': nextDue == null
                  ? null
                  : DateFormat('yyyy-MM-dd').format(nextDue!),
              'performed_by': Supabase.instance.client.auth.currentUser?.id,
            });
            if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
            _loadDetail(a['id'] as String);
          } catch (e) {
            setS(() => saving = false);
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                  content:
                      Text('Failed: ${e.toString().split('\n').first}')));
            }
          }
        }

        return AlertDialog(
          title: const Text('Add maintenance'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'service', child: Text('Service')),
                  DropdownMenuItem(value: 'repair', child: Text('Repair')),
                  DropdownMenuItem(
                      value: 'inspection', child: Text('Inspection')),
                  DropdownMenuItem(
                      value: 'calibration', child: Text('Calibration')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) => setS(() => type = v ?? type),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: _dateField('Service date', date,
                        (d) => setS(() => date = d ?? date), ctx)),
                const SizedBox(width: 10),
                Expanded(
                    child: _dateField('Next due', nextDue,
                        (d) => setS(() => nextDue = d), ctx)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: costCtrl,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Cost (Rs)'))),
                const SizedBox(width: 10),
                Expanded(
                    child: TextField(
                        controller: vendorCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Vendor'))),
              ]),
              const SizedBox(height: 10),
              TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(labelText: 'Note')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: saving
                    ? null
                    : () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: saving ? null : save,
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save')),
          ],
        );
      }),
    );
  }

  Future<void> _custodiansDialog() async {
    final orgId = _orgId;
    if (orgId == null) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> addOrEdit({Map<String, dynamic>? existing}) async {
          final nameCtrl =
              TextEditingController(text: existing?['name'] as String? ?? '');
          final phoneCtrl =
              TextEditingController(text: existing?['phone'] as String? ?? '');
          final desigCtrl = TextEditingController(
              text: existing?['designation'] as String? ?? '');
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (c2) => AlertDialog(
              title:
                  Text(existing == null ? 'New custodian' : 'Edit custodian'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name *')),
                const SizedBox(height: 10),
                TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 10),
                TextField(
                    controller: desigCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Designation')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c2, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(c2, true),
                    child: const Text('Save')),
              ],
            ),
          );
          if (ok == true && nameCtrl.text.trim().isNotEmpty) {
            final client = Supabase.instance.client;
            if (existing == null) {
              await client.from('asset_custodians').insert({
                'id': 'acus_${DateTime.now().millisecondsSinceEpoch}',
                'org_id': orgId,
                'name': nameCtrl.text.trim(),
                'phone': _nz(phoneCtrl.text),
                'designation': _nz(desigCtrl.text),
              });
            } else {
              await client.from('asset_custodians').update({
                'name': nameCtrl.text.trim(),
                'phone': _nz(phoneCtrl.text),
                'designation': _nz(desigCtrl.text),
              }).eq('id', existing['id']);
            }
            await _load();
            setS(() {});
          }
        }

        int countFor(String id) =>
            _assets.where((a) => a['assigned_to'] == id).length;

        return AlertDialog(
          title: const Text('Custodians'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Tap a custodian to see the assets currently with them.',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ),
              const SizedBox(height: 8),
              if (_custodians.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No custodians yet.',
                        style: TextStyle(color: AppTheme.textSecondary)))
              else
                ..._custodians.map((c) {
                  final n = countFor(c['id'] as String);
                  final sub = [c['designation'], c['phone']]
                      .whereType<String>()
                      .where((s) => s.trim().isNotEmpty)
                      .join('  ·  ');
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onTap: () {
                      setState(() => _custodianFilter = c['id'] as String);
                      Navigator.of(ctx, rootNavigator: true).pop();
                    },
                    title: Text(c['name'] as String? ?? '—'),
                    subtitle: sub.isEmpty
                        ? null
                        : Text(sub, style: const TextStyle(fontSize: 12)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: AppTheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10)),
                        child: Text('$n assets',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primary)),
                      ),
                      IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          onPressed: () => addOrEdit(existing: c)),
                    ]),
                  );
                }),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Close')),
            ElevatedButton.icon(
                onPressed: () => addOrEdit(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add custodian')),
          ],
        );
      }),
    );
  }

  Future<void> _categoriesDialog() async {
    final orgId = _orgId;
    if (orgId == null) return;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Future<void> add() async {
          final nameCtrl = TextEditingController();
          final codeCtrl = TextEditingController();
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (c2) => AlertDialog(
              title: const Text('New category'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name *')),
                const SizedBox(height: 10),
                TextField(
                    controller: codeCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Code (optional)')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c2, false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    onPressed: () => Navigator.pop(c2, true),
                    child: const Text('Add')),
              ],
            ),
          );
          if (ok == true && nameCtrl.text.trim().isNotEmpty) {
            await Supabase.instance.client.from('asset_categories').insert({
              'id': 'acat_${DateTime.now().millisecondsSinceEpoch}',
              'org_id': orgId,
              'name': nameCtrl.text.trim(),
              'code': _nz(codeCtrl.text),
            });
            await _load();
            setS(() {});
          }
        }

        return AlertDialog(
          title: const Text('Asset categories'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ..._categories.map((c) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(c['name'] as String? ?? '—'),
                    subtitle: (c['code'] as String?)?.isNotEmpty == true
                        ? Text(c['code'] as String)
                        : null,
                  )),
              if (_categories.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('No categories yet.',
                      style: TextStyle(color: AppTheme.textSecondary)),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Close')),
            ElevatedButton.icon(
                onPressed: add,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add category')),
          ],
        );
      }),
    );
  }

  // ───────────────────────────────────────────────────── small helpers
  Widget _dateField(String label, DateTime? value,
      ValueChanged<DateTime?> onPick, BuildContext ctx) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: ctx,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onPick(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true),
        child: Text(value == null ? 'Pick a date' : DateFormat('d MMM y').format(value)),
      ),
    );
  }

  String? _nz(String s) => s.trim().isEmpty ? null : s.trim();

  String _capitalize(String? s) =>
      (s == null || s.isEmpty) ? '—' : s[0].toUpperCase() + s.substring(1);

  DateTime? _parseDate(dynamic v) =>
      v == null ? null : DateTime.tryParse('$v');

  String? _fmtDate(dynamic v) {
    final d = _parseDate(v);
    return d == null ? null : DateFormat('d MMM y').format(d);
  }
}
