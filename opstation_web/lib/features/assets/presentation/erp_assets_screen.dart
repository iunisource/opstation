// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../../core/widgets/camera_capture.dart';
import '../../../core/storage/image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../../core/layout/main_layout.dart' show assetsDueCountProvider, assetSupervisePendingProvider, assetSuggestionCountProvider;
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
  /// Opens this asset on load (notification links: /assets?focus=<id>).
  final String? focusId;
  const ErpAssetsScreen({super.key, this.focusId});
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

/// Colours a status can be given (Manage list ▸ colour dot).
const Map<String, Color> _kStatusPalette = {
  'green': Color(0xFF16A34A),
  'blue': Color(0xFF2563EB),
  'orange': Color(0xFFEA580C),
  'red': Color(0xFFDC2626),
  'purple': Color(0xFF7C3AED),
  'teal': Color(0xFF0D9488),
  'grey': Color(0xFF6B7280),
};

/// Default colour when none is configured: built-ins keep their colours and
/// custom names are guessed from their words (operative → green, non-operative → red…).
String _defaultStatusColorKey(String? s) {
  final v = (s ?? '').toLowerCase();
  if (v.isEmpty) return 'grey';
  if (v.contains('non') || v.contains('not_') || v.contains('lost') || v.contains('dispos') ||
      v.contains('broken') || v.contains('scrap') || v.contains('dead') || v.contains('faulty')) return 'red';
  if (v.contains('repair') || v.contains('service') || v.contains('maint') || v.contains('pending')) return 'orange';
  if (v.contains('storage') || v.contains('store') || v.contains('spare')) return 'blue';
  if (v.contains('retired') || v.contains('idle')) return 'grey';
  if (v.contains('operative') || v.contains('in_use') || v.contains('working') || v.contains('active') ||
      v.contains('ok') || v.contains('running') || v.contains('good')) return 'green';
  return 'grey';
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

  // ── Supervision (org.asset_supervise_flow, SQL 348) — non-blocking check on
  // every new asset and every change. Only users in org.asset_supervisor_users.
  bool _supFlow = false;
  bool _canSupervise = false;
  bool _supBusy = false;
  String _supFilter = 'all'; // all | pending | rejected | supervised
  bool _focusDone = false;

  // ── Asset suggestions (SQL 366): new additions to watched accounts. ──
  List<Map<String, dynamic>> _suggestions = [];

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

  /// Branch choices for a picker: real branches, plus the asset's current one
  /// if it happens to be a processor location (so the picker never breaks).
  List<Map<String, dynamic>> _branchOptions(String? current) {
    if (current == null || _branches.any((b) => b['id'] == current)) return _branches;
    return [..._branches, {'id': current, 'name': _branchNames[current] ?? current}];
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
          .eq('org_id', orgId).or('role.is.null,role.neq.retailer')
          .order('name');
      await _loadOptionLists(orgId);
      var supFlow = false, canSup = false;
      try {
        final cfg = await client.from('app_config').select('key,value').eq('org_id', orgId)
            .inFilter('key', ['org.asset_supervise_flow', 'org.asset_supervisor_users']);
        final m = {for (final r in cfg as List) r['key'] as String: '${r['value'] ?? ''}'};
        supFlow = m['org.asset_supervise_flow'] == 'true';
        final me = ref.read(currentUserProvider)?.id;
        canSup = me != null &&
            (m['org.asset_supervisor_users'] ?? '').split(',').map((e) => e.trim()).contains(me);
      } catch (_) {}
      final custodians = await client
          .from('asset_custodians')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');

      var suggestions = <Map<String, dynamic>>[];
      try {
        suggestions = List<Map<String, dynamic>>.from(await client
            .from('asset_suggestions')
            .select()
            .eq('org_id', orgId)
            .eq('status', 'pending')
            .order('entry_date', ascending: false)
            .order('created_at', ascending: false));
      } catch (_) {/* not set up yet — no suggestions */}

      if (!mounted) return;
      setState(() {
        _suggestions = suggestions;
        _assets = List<Map<String, dynamic>>.from(assets);
        _categories = List<Map<String, dynamic>>.from(cats);
        // Real branches only for picking — processor / off-site (virtual)
        // locations don't hold company assets. Names keep every branch so an
        // older asset still shows where it was.
        final allBranches = List<Map<String, dynamic>>.from(branches);
        _branches = allBranches.where((b) => b['is_virtual'] != true).toList();
        _users = List<Map<String, dynamic>>.from(users);
        _custodians = List<Map<String, dynamic>>.from(custodians);
        _catNames
          ..clear()
          ..addEntries(_categories.map((c) =>
              MapEntry(c['id'] as String, (c['name'] as String?) ?? '—')));
        _branchNames
          ..clear()
          ..addEntries(allBranches.map((b) =>
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
        _supFlow = supFlow;
        _canSupervise = canSup;
        if (!_supFlow) _supFilter = 'all';
        if (_selectedId != null &&
            !_assets.any((a) => a['id'] == _selectedId)) {
          _selectedId = null;
        }
      });
      ref.invalidate(assetSupervisePendingProvider);
      ref.invalidate(assetSuggestionCountProvider);
      // Opened from a notification: jump straight to that asset.
      final f = widget.focusId;
      if (!_focusDone && f != null && _assets.any((a) => a['id'] == f)) {
        _focusDone = true;
        _select(f);
      }
      // Keep the menu's maintenance-due counter in step with what's on screen
      // (servicing an asset or changing its due date updates it right away).
      ref.invalidate(assetsDueCountProvider);
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
      if (_supFlow && _supFilter != 'all' && _supState(a) != _supFilter) return false;
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

  // ───────────────────────────────────────────────────── supervision
  /// supervised · rejected (back with whoever changed it) · pending.
  String _supState(Map<String, dynamic> a) {
    if (a['supervised_at'] != null) return 'supervised';
    if (a['rejected_at'] != null) return 'rejected';
    // Before SQL 348 the column doesn't exist — treat as checked.
    if (!a.containsKey('supervised_at')) return 'supervised';
    return 'pending';
  }

  int _supCount(String st) => _assets.where((a) => _supState(a) == st).length;

  static const _supFieldLabels = {
    'asset_code': 'Asset code', 'name': 'Name', 'description': 'Description',
    'category_id': 'Category', 'status': 'Status', 'condition': 'Condition',
    'branch_id': 'Branch', 'location_text': 'Location', 'assigned_to': 'Custodian',
    'serial_no': 'Serial no.', 'model': 'Model', 'manufacturer': 'Manufacturer',
    'supplier_id': 'Supplier', 'purchase_cost': 'Purchase cost',
    'purchase_date': 'Purchase date', 'warranty_expiry': 'Warranty till', 'notes': 'Notes',
  };

  String _supValue(String field, dynamic v) {
    if (v == null || '$v'.trim().isEmpty) return '—';
    final s = '$v';
    switch (field) {
      case 'branch_id': return _branchNames[s] ?? s;
      case 'category_id': return _catNames[s] ?? s;
      case 'assigned_to': return _custodianNames[s] ?? s;
      case 'status':
      case 'condition': return _optLabel(s);
      case 'purchase_cost': final n = num.tryParse(s); return n == null ? s : 'Rs ${_money.format(n)}';
      case 'purchase_date':
      case 'warranty_expiry': return _fmtDate(s) ?? s;
    }
    return s;
  }

  String _when(dynamic ts) {
    final d = DateTime.tryParse('${ts ?? ''}');
    return d == null ? '' : DateFormat('d MMM y, h:mm a').format(d.toLocal());
  }

  Future<void> _supervise(List<String> ids) async {
    if (ids.isEmpty || !_canSupervise) return;
    final user = ref.read(currentUserProvider);
    setState(() => _supBusy = true);
    try {
      await Supabase.instance.client.from('assets').update({
        'supervised_at': DateTime.now().toUtc().toIso8601String(),
        'supervised_by': user?.id,
        'supervised_by_name': user?.name,
      }).inFilter('id', ids).filter('supervised_at', 'is', null).filter('rejected_at', 'is', null);
      _snack(ids.length == 1 ? 'Asset supervised' : '${ids.length} assets supervised');
      await _load();
    } catch (e) {
      _snack(e.toString().contains('supervised_at')
          ? 'This feature isn\'t set up yet — please contact Opstation support.'
          : 'Could not supervise: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _supBusy = false);
    }
  }

  Future<void> _confirmSupervise(List<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ids.length == 1 ? 'Supervise this asset?' : 'Supervise ${ids.length} assets?'),
        content: const Text('Marks the asset (and the changes shown) as checked.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.verified_outlined, size: 16),
              label: const Text('Supervise')),
        ],
      ),
    );
    if (ok == true) await _supervise(ids);
  }

  Future<void> _rejectAsset(Map<String, dynamic> a) async {
    if (!_canSupervise) return;
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject asset change'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('It goes back to ${a['sup_changed_by_name'] ?? 'the person who changed it'} to fix and resend.',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Reason *', border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, ctrl.text.trim());
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (reason == null || reason.isEmpty) return;
    final user = ref.read(currentUserProvider);
    setState(() => _supBusy = true);
    try {
      await Supabase.instance.client.from('assets').update({
        'rejected_at': DateTime.now().toUtc().toIso8601String(),
        'rejected_by': user?.id,
        'rejected_by_name': user?.name,
        'reject_reason': reason,
      }).eq('id', a['id']).filter('supervised_at', 'is', null);
      _snack('Rejected — sent back');
      await _load();
    } catch (e) {
      _snack('Could not reject: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _supBusy = false);
    }
  }

  /// Resend a rejected asset without further changes.
  Future<void> _resendAsset(Map<String, dynamic> a) async {
    setState(() => _supBusy = true);
    try {
      await Supabase.instance.client.from('assets').update({'rejected_at': null}).eq('id', a['id']);
      _snack('Resent for supervision');
      await _load();
    } catch (e) {
      _snack('Could not resend: ${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _supBusy = false);
    }
  }

  Widget _supervisionPanel(Map<String, dynamic> a) {
    final st = _supState(a);
    if (st == 'supervised') {
      final by = a['supervised_by_name'];
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          Icon(Icons.verified, size: 16, color: Colors.green.shade700),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Supervised${by == null ? '' : ' by $by'}${_when(a['supervised_at']).isEmpty ? '' : ' · ${_when(a['supervised_at'])}'}',
              style: TextStyle(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      );
    }
    final rejected = st == 'rejected';
    final color = rejected ? AppTheme.danger : Colors.orange.shade800;
    final diff = (a['sup_diff'] is Map) ? Map<String, dynamic>.from(a['sup_diff'] as Map) : <String, dynamic>{};
    final reason = '${a['sup_reason'] ?? ''}';
    final what = reason == 'created'
        ? 'New asset'
        : reason == 'resubmitted'
            ? 'Resent after rejection'
            : 'Edited';
    final me = ref.read(currentUserProvider)?.id;
    final mine = a['sup_changed_by'] != null && a['sup_changed_by'] == me;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(rejected ? Icons.undo : Icons.hourglass_top, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(rejected ? 'Rejected by supervisor' : 'Awaiting supervision',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          '$what${a['sup_changed_by_name'] == null ? '' : ' by ${a['sup_changed_by_name']}'}'
          '${_when(a['sup_changed_at']).isEmpty ? '' : ' · ${_when(a['sup_changed_at'])}'}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        if (rejected) ...[
          const SizedBox(height: 6),
          Text(
            '${a['rejected_by_name'] ?? 'Supervisor'}${_when(a['rejected_at']).isEmpty ? '' : ' · ${_when(a['rejected_at'])}'}: '
            '${a['reject_reason'] ?? ''}',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.danger),
          ),
          const SizedBox(height: 2),
          const Text('Fix it with Edit and save — or Resend as is. It goes back to the supervisor.',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ],
        if (diff.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('CHANGED SINCE LAST CHECK',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: AppTheme.textSecondary)),
          const SizedBox(height: 4),
          for (final e in diff.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text.rich(TextSpan(style: const TextStyle(fontSize: 12), children: [
                TextSpan(text: '${_supFieldLabels[e.key] ?? e.key}: ',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(
                    text: _supValue(e.key, (e.value is Map) ? (e.value as Map)['from'] : null),
                    style: const TextStyle(color: AppTheme.textSecondary, decoration: TextDecoration.lineThrough)),
                const TextSpan(text: '  →  '),
                TextSpan(text: _supValue(e.key, (e.value is Map) ? (e.value as Map)['to'] : null),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ])),
            ),
        ],
        if ((_canSupervise && !rejected) || (rejected && (mine || _canSupervise))) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (_canSupervise && !rejected) ...[
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
                onPressed: _supBusy ? null : () => _confirmSupervise([a['id'] as String]),
                icon: const Icon(Icons.verified_outlined, size: 16),
                label: const Text('Supervise'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                onPressed: _supBusy ? null : () => _rejectAsset(a),
                icon: const Icon(Icons.undo, size: 16),
                label: const Text('Reject'),
              ),
            ],
            if (rejected)
              OutlinedButton.icon(
                onPressed: _supBusy ? null : () => _resendAsset(a),
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('Resend as is'),
              ),
          ]),
        ],
      ]),
    );
  }

  Widget _supIcon(Map<String, dynamic> a) {
    switch (_supState(a)) {
      case 'pending':
        return const Tooltip(message: 'Awaiting supervision',
            child: Icon(Icons.hourglass_top, size: 15, color: Colors.orange));
      case 'rejected':
        return const Tooltip(message: 'Rejected by supervisor',
            child: Icon(Icons.undo, size: 15, color: AppTheme.danger));
    }
    return const SizedBox.shrink();
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

    final cond = _optLabel(a['condition'] as String?);

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

  // ───────────────────────────────────────────────────── status / condition lists
  // Both lists are per organization (app_config org.asset_statuses /
  // org.asset_conditions, JSON arrays of slugs). Managed straight from the
  // dropdowns: "+ Add new…" and "Manage list…".
  List<String> _statusList = [..._statuses];
  List<String> _condList = [..._conditions];
  Map<String, String> _statusColors = {}; // slug -> palette key (org.asset_status_colors)
  int _optTick = 0;

  static String _slug(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  static String _optLabel(String? s) {
    final t = (s ?? '').replaceAll('_', ' ').trim();
    return t.isEmpty ? '—' : t[0].toUpperCase() + t.substring(1);
  }

  Future<void> _loadOptionLists(String orgId) async {
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId)
          .inFilter('key', ['org.asset_statuses', 'org.asset_conditions', 'org.asset_status_colors']);
      for (final r in rows as List) {
        if (r['key'] == 'org.asset_status_colors') {
          try {
            _statusColors = Map<String, String>.from(jsonDecode('${r['value']}') as Map);
          } catch (_) {}
          continue;
        }
        try {
          final list = List<String>.from(jsonDecode('${r['value']}') as List)
              .map(_slug)
              .where((x) => x.isNotEmpty)
              .toList();
          if (list.isEmpty) continue;
          if (r['key'] == 'org.asset_statuses') _statusList = list;
          if (r['key'] == 'org.asset_conditions') _condList = list;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _saveOptionList(String kind, List<String> list) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final key = kind == 'status' ? 'org.asset_statuses' : 'org.asset_conditions';
    final client = Supabase.instance.client;
    final val = jsonEncode(list);
    final upd = await client
        .from('app_config')
        .update({'value': val})
        .eq('org_id', orgId)
        .eq('key', key)
        .select('key');
    if ((upd as List).isEmpty) {
      await client.from('app_config').insert({'org_id': orgId, 'key': key, 'value': val});
    }
    setState(() {
      if (kind == 'status') {
        _statusList = list;
      } else {
        _condList = list;
      }
      _optTick++;
    });
  }

  Future<void> _saveStatusColor(String slug, String colorKey) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final next = {..._statusColors, slug: colorKey};
    final client = Supabase.instance.client;
    final val = jsonEncode(next);
    final upd = await client.from('app_config').update({'value': val})
        .eq('org_id', orgId).eq('key', 'org.asset_status_colors').select('key');
    if ((upd as List).isEmpty) {
      await client.from('app_config').insert({'org_id': orgId, 'key': 'org.asset_status_colors', 'value': val});
    }
    setState(() => _statusColors = next);
  }

  int _optUsage(String kind, String slug) => _assets
      .where((a) => (kind == 'status' ? a['status'] : a['condition']) == slug)
      .length;

  Future<String?> _askOptionName(BuildContext ctx, String title, {String initial = ''}) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (c2) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => Navigator.pop(c2, true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(c2, true), child: const Text('Save')),
        ],
      ),
    );
    final s = _slug(c.text);
    return ok == true && s.isNotEmpty ? s : null;
  }

  /// Adds a new option and returns its slug (or null if cancelled / duplicate).
  Future<String?> _addOption(BuildContext ctx, String kind) async {
    final list = kind == 'status' ? _statusList : _condList;
    final s = await _askOptionName(ctx, kind == 'status' ? 'New status' : 'New condition');
    if (s == null) return null;
    if (list.contains(s)) return s;
    try {
      await _saveOptionList(kind, [...list, s]);
      return s;
    } catch (e) {
      _snack('Could not save: ${e.toString().split('\n').first}');
      return null;
    }
  }

  Future<void> _manageOptions(BuildContext ctx, String kind) async {
    final isStatus = kind == 'status';
    await showDialog(
      context: ctx,
      builder: (c2) => StatefulBuilder(builder: (c2, setD) {
        final list = isStatus ? _statusList : _condList;
        Future<void> save(List<String> next) async {
          try {
            await _saveOptionList(kind, next);
          } catch (e) {
            _snack('Could not save: ${e.toString().split('\n').first}');
          }
          setD(() {});
        }

        Future<void> rename(String old) async {
          final s = await _askOptionName(c2, 'Rename', initial: _optLabel(old));
          if (s == null || s == old) return;
          if (list.contains(s)) {
            _snack('“${_optLabel(s)}” already exists.');
            return;
          }
          final orgId = _orgId;
          try {
            // move every asset that uses the old value to the new one
            await Supabase.instance.client
                .from('assets')
                .update({isStatus ? 'status' : 'condition': s})
                .eq('org_id', orgId!)
                .eq(isStatus ? 'status' : 'condition', old);
          } catch (e) {
            _snack('Could not rename on assets: ${e.toString().split('\n').first}');
            return;
          }
          await save([for (final x in list) x == old ? s : x]);
          if (isStatus && _statusColors[old] != null) {
            try { await _saveStatusColor(s, _statusColors[old]!); } catch (_) {}
          }
          await _load();
          setD(() {});
        }

        Future<void> remove(String s) async {
          final n = _optUsage(kind, s);
          if (n > 0) {
            _snack('“${_optLabel(s)}” is used by $n asset${n == 1 ? '' : 's'}. Change them first.');
            return;
          }
          if (list.length <= 1) {
            _snack('Keep at least one option.');
            return;
          }
          await save([for (final x in list) if (x != s) x]);
        }

        void move(int i, int d) {
          final j = i + d;
          if (j < 0 || j >= list.length) return;
          final next = [...list];
          final t = next[i];
          next[i] = next[j];
          next[j] = t;
          save(next);
        }

        return AlertDialog(
          title: Text(isStatus ? 'Asset statuses' : 'Asset conditions'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (var i = 0; i < list.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: !isStatus
                        ? null
                        : PopupMenuButton<String>(
                            tooltip: 'Colour',
                            onSelected: (k) async {
                              try {
                                await _saveStatusColor(list[i], k);
                              } catch (e) {
                                _snack('Could not save colour: ${e.toString().split('\n').first}');
                              }
                              setD(() {});
                            },
                            itemBuilder: (_) => [
                              for (final e in _kStatusPalette.entries)
                                PopupMenuItem(
                                    value: e.key,
                                    child: Row(children: [
                                      CircleAvatar(radius: 7, backgroundColor: e.value),
                                      const SizedBox(width: 8),
                                      Text(e.key[0].toUpperCase() + e.key.substring(1)),
                                    ])),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: CircleAvatar(radius: 9, backgroundColor: _statusColor(list[i])),
                            ),
                          ),
                    title: isStatus ? _statusChipFor(list[i]) : Text(_optLabel(list[i])),
                    subtitle: Text('${_optUsage(kind, list[i])} asset(s)', style: const TextStyle(fontSize: 11)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: 'Up',
                          icon: const Icon(Icons.arrow_upward, size: 16),
                          onPressed: i == 0 ? null : () => move(i, -1)),
                      IconButton(
                          tooltip: 'Down',
                          icon: const Icon(Icons.arrow_downward, size: 16),
                          onPressed: i == list.length - 1 ? null : () => move(i, 1)),
                      IconButton(
                          tooltip: 'Rename',
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          onPressed: () => rename(list[i])),
                      if (_isMaster)
                        IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                            onPressed: () => remove(list[i])),
                    ]),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c2), child: const Text('Close')),
            ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
                onPressed: () async {
                  await _addOption(c2, kind);
                  setD(() {});
                }),
          ],
        );
      }),
    );
  }

  /// Status / Condition dropdown with "+ Add new…" and "Manage list…" built in.
  Widget _optionDropdown({
    required BuildContext ctx,
    required String kind,
    required String label,
    required String? value,
    required bool allowNone,
    required void Function(String?) onChanged,
    required VoidCallback rebuild,
  }) {
    final list = kind == 'status' ? _statusList : _condList;
    final opts = [...list, if (value != null && !list.contains(value)) value];
    return DropdownButtonFormField<String?>(
      key: ValueKey('$kind-$_optTick-$value'),
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (allowNone) const DropdownMenuItem<String?>(value: null, child: Text('—')),
        for (final o in opts)
          DropdownMenuItem<String?>(
              value: o,
              child: kind == 'status'
                  ? Row(children: [
                      CircleAvatar(radius: 5, backgroundColor: _statusColor(o)),
                      const SizedBox(width: 8),
                      Text(_optLabel(o)),
                    ])
                  : Text(_optLabel(o))),
        const DropdownMenuItem<String?>(
            value: '__add__',
            child: Row(children: [
              Icon(Icons.add, size: 16, color: AppTheme.primary),
              SizedBox(width: 6),
              Text('Add new…', style: TextStyle(color: AppTheme.primary)),
            ])),
        const DropdownMenuItem<String?>(
            value: '__manage__',
            child: Row(children: [
              Icon(Icons.tune, size: 16, color: AppTheme.textSecondary),
              SizedBox(width: 6),
              Text('Manage list…', style: TextStyle(color: AppTheme.textSecondary)),
            ])),
      ],
      onChanged: (v) async {
        if (v == '__add__') {
          final s = await _addOption(ctx, kind);
          if (s != null) onChanged(s);
          _optTick++;
          rebuild();
        } else if (v == '__manage__') {
          await _manageOptions(ctx, kind);
          _optTick++;
          rebuild();
        } else {
          onChanged(v);
        }
      },
    );
  }

  // ───────────────────────────────────────────────────── CSV import / export
  bool get _canBulk {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  static const _csvCols = [
    'asset_code', 'name', 'category', 'branch', 'status', 'condition',
    'custodian', 'location', 'serial_no', 'model', 'manufacturer',
    'purchase_date', 'purchase_cost', 'warranty_expiry', 'description', 'notes',
  ];

  void _downloadCsv(String fileName, List<List<dynamic>> rows) {
    final csv = const ListToCsvConverter().convert(rows);
    final bytes = utf8.encode('﻿$csv'); // BOM so Excel keeps Urdu / symbols
    final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  void _exportCsv({bool templateOnly = false}) {
    final rows = <List<dynamic>>[_csvCols];
    if (!templateOnly) {
      for (final a in _assets) {
        String d(dynamic v) => v == null ? '' : '$v'.split('T').first;
        rows.add([
          a['asset_code'] ?? '',
          a['name'] ?? '',
          _catNames[a['category_id']] ?? '',
          _branchNames[a['branch_id']] ?? '',
          a['status'] ?? '',
          a['condition'] ?? '',
          _custodianNames[a['assigned_to']] ?? '',
          a['location_text'] ?? '',
          a['serial_no'] ?? '',
          a['model'] ?? '',
          a['manufacturer'] ?? '',
          d(a['purchase_date']),
          a['purchase_cost'] ?? '',
          d(a['warranty_expiry']),
          a['description'] ?? '',
          a['notes'] ?? '',
        ]);
      }
    } else {
      rows.add(['', 'Tablet Lenovo M10', 'IT Equipment', _branches.isNotEmpty ? _branches.first['name'] ?? '' : '',
        'in_use', 'good', 'Ali Raza', 'Front office', 'SN12345', 'M10', 'Lenovo',
        '2026-01-15', '45000', '2027-01-15', '', 'Leave asset_code blank to auto-number']);
    }
    final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
    _downloadCsv(templateOnly ? 'assets_template.csv' : 'assets_$stamp.csv', rows);
  }

  static DateTime? _parseAnyDate(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    final iso = DateTime.tryParse(t);
    if (iso != null) return iso;
    for (final f in ['dd/MM/yyyy', 'd/M/yyyy', 'dd-MM-yyyy', 'd-M-yyyy', 'd MMM yyyy', 'dd MMM yyyy', 'd-MMM-yyyy', 'd-MMM-yy']) {
      try {
        return DateFormat(f).parseStrict(t);
      } catch (_) {}
    }
    return null;
  }

  Future<void> _importCsv() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final res = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['csv'], withData: true);
    if (res == null || res.files.isEmpty || res.files.single.bytes == null) return;
    List<List<String>> rows;
    try {
      var text = utf8.decode(res.files.single.bytes!, allowMalformed: true);
      if (text.startsWith('﻿')) text = text.substring(1);
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      rows = [
        for (final r in const CsvToListConverter(shouldParseNumbers: false, eol: '\n').convert(text))
          [for (final c in r) (c?.toString() ?? '').trim()]
      ].where((r) => r.any((c) => c.isNotEmpty)).toList();
    } catch (e) {
      _snack('Could not read the file: $e');
      return;
    }
    if (rows.length < 2) {
      _snack('The file has no data rows.');
      return;
    }
    final head = [for (final h in rows.first) h.toLowerCase().replaceAll(' ', '_')];
    int col(String k) => head.indexOf(k);
    if (col('name') < 0 && col('asset_code') < 0) {
      _snack('Header must include at least “name” (download the template to see the columns).');
      return;
    }
    String cell(List<String> r, String k) {
      final i = col(k);
      return i >= 0 && i < r.length ? r[i].trim() : '';
    }

    final byCode = {for (final a in _assets) '${a['asset_code']}'.toLowerCase(): a};
    final catBy = <String, String>{};
    for (final c in _categories) {
      catBy['${c['name']}'.toLowerCase()] = c['id'] as String;
      if ((c['code'] as String?)?.isNotEmpty == true) catBy['${c['code']}'.toLowerCase()] = c['id'] as String;
    }
    final branchBy = {for (final b in _branches) '${b['name']}'.toLowerCase(): b['id'] as String};
    final custBy = {for (final c in _custodians) '${c['name']}'.toLowerCase(): c['id'] as String};

    final creates = <Map<String, dynamic>>[];
    final updates = <Map<String, dynamic>>[];
    final errors = <String>[];
    final newCats = <String>{};
    final newCusts = <String>{};
    final seenCodes = <String>{};

    for (var i = 1; i < rows.length; i++) {
      final r = rows[i];
      final line = i + 1;
      final code = cell(r, 'asset_code');
      final existing = code.isEmpty ? null : byCode[code.toLowerCase()];
      final f = <String, dynamic>{};
      final rowErr = <String>[];

      if (code.isNotEmpty) {
        if (seenCodes.contains(code.toLowerCase())) rowErr.add('duplicate asset_code $code in file');
        seenCodes.add(code.toLowerCase());
      }
      final name = cell(r, 'name');
      if (name.isNotEmpty) f['name'] = name;
      if (existing == null && name.isEmpty) rowErr.add('name is required for a new asset');

      final st = cell(r, 'status').toLowerCase().replaceAll(' ', '_');
      if (st.isNotEmpty) {
        if (_statusList.contains(_slug(st))) { f['status'] = _slug(st); } else { rowErr.add('status “$st” — use ${_statusList.map(_optLabel).join(', ')}'); }
      }
      final cond = cell(r, 'condition').toLowerCase();
      if (cond.isNotEmpty) {
        if (_condList.contains(_slug(cond))) { f['condition'] = _slug(cond); } else { rowErr.add('condition “$cond” — use ${_condList.map(_optLabel).join(', ')}'); }
      }
      final br = cell(r, 'branch');
      if (br.isNotEmpty) {
        final id = branchBy[br.toLowerCase()];
        if (id == null) { rowErr.add('branch “$br” not found'); } else { f['branch_id'] = id; }
      }
      final cat = cell(r, 'category');
      if (cat.isNotEmpty) {
        final id = catBy[cat.toLowerCase()];
        if (id != null) { f['category_id'] = id; } else { newCats.add(cat); f['_cat'] = cat; }
      }
      final cu = cell(r, 'custodian');
      if (cu.isNotEmpty) {
        final id = custBy[cu.toLowerCase()];
        if (id != null) { f['assigned_to'] = id; } else { newCusts.add(cu); f['_cust'] = cu; }
      }
      for (final k in ['purchase_date', 'warranty_expiry']) {
        final v = cell(r, k);
        if (v.isEmpty) continue;
        final d = _parseAnyDate(v);
        if (d == null) { rowErr.add('$k “$v” is not a date (use 2026-01-31)'); } else { f[k] = DateFormat('yyyy-MM-dd').format(d); }
      }
      final cost = cell(r, 'purchase_cost').replaceAll(',', '');
      if (cost.isNotEmpty) {
        final n = double.tryParse(cost);
        if (n == null) { rowErr.add('purchase_cost “$cost” is not a number'); } else { f['purchase_cost'] = n; }
      }
      for (final k in ['serial_no', 'model', 'manufacturer', 'description', 'notes']) {
        final v = cell(r, k);
        if (v.isNotEmpty) f[k] = v;
      }
      final loc = cell(r, 'location');
      if (loc.isNotEmpty) f['location_text'] = loc;

      if (rowErr.isNotEmpty) {
        errors.add('Row $line${code.isNotEmpty ? ' ($code)' : ''}: ${rowErr.join('; ')}');
        continue;
      }
      if (existing != null) {
        updates.add({'_id': existing['id'], '_code': existing['asset_code'], ...f});
      } else {
        creates.add({'_code': code, ...f});
      }
    }

    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import assets'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${res.files.single.name} · ${rows.length - 1} rows', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 10),
              Text('• ${creates.length} new asset${creates.length == 1 ? '' : 's'} will be created'),
              Text('• ${updates.length} existing asset${updates.length == 1 ? '' : 's'} will be updated (matched by asset_code; blank cells leave a field unchanged)'),
              if (newCats.isNotEmpty) Text('• New categories: ${newCats.join(', ')}'),
              if (newCusts.isNotEmpty) Text('• New custodians: ${newCusts.join(', ')}'),
              if (errors.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('${errors.length} row${errors.length == 1 ? '' : 's'} skipped:',
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                for (final e in errors.take(50)) Text(e, style: const TextStyle(fontSize: 12, color: Colors.red)),
                if (errors.length > 50) Text('…and ${errors.length - 50} more', style: const TextStyle(fontSize: 12)),
              ],
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: creates.isEmpty && updates.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: Text('Import ${creates.length + updates.length}')),
        ],
      ),
    );
    if (go != true) return;

    final client = Supabase.instance.client;
    final progress = ValueNotifier<String>('Starting…');
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 14),
          Expanded(child: ValueListenableBuilder<String>(valueListenable: progress, builder: (_, v, __) => Text(v))),
        ]),
      ),
    );
    var done = 0;
    final fails = <String>[];
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      var k = 0;
      final catIds = <String, String>{};
      for (final c in newCats) {
        final id = 'acat_${stamp}_${k++}';
        await client.from('asset_categories').insert({'id': id, 'org_id': orgId, 'name': c});
        catIds[c] = id;
      }
      final custIds = <String, String>{};
      for (final c in newCusts) {
        final id = 'acus_${stamp}_${k++}';
        await client.from('asset_custodians').insert({'id': id, 'org_id': orgId, 'name': c});
        custIds[c] = id;
      }
      Map<String, dynamic> clean(Map<String, dynamic> m) {
        final out = <String, dynamic>{};
        m.forEach((key, v) {
          if (!key.startsWith('_')) out[key] = v;
        });
        if (m['_cat'] != null) out['category_id'] = catIds[m['_cat']];
        if (m['_cust'] != null) out['assigned_to'] = custIds[m['_cust']];
        return out;
      }

      for (final u in updates) {
        progress.value = 'Updating ${u['_code']}… (${++done}/${creates.length + updates.length})';
        try {
          await client.from('assets').update(clean(u)).eq('id', u['_id']);
        } catch (e) {
          fails.add('${u['_code']}: ${e.toString().split('\n').first}');
        }
      }
      for (final c in creates) {
        var code = (c['_code'] as String?) ?? '';
        try {
          if (code.isEmpty) {
            code = (await client.rpc('next_asset_code', params: {'p_org_id': orgId})) as String? ?? '';
          }
          progress.value = 'Creating $code… (${++done}/${creates.length + updates.length})';
          final id = 'asset_${DateTime.now().millisecondsSinceEpoch}_${k++}';
          final payload = clean(c);
          payload.putIfAbsent('status', () => 'in_use');
          await client.from('assets').insert({
            'id': id, 'org_id': orgId, 'asset_code': code,
            'created_by': client.auth.currentUser?.id, ...payload,
          });
          try {
            await client.rpc('asset_reassign', params: {
              'p_asset_id': id,
              'p_branch_id': payload['branch_id'],
              'p_location_text': payload['location_text'],
              'p_assigned_to': payload['assigned_to'],
              'p_status': payload['status'],
              'p_action': 'created',
              'p_note': 'Imported from CSV',
            });
          } catch (_) {}
        } catch (e) {
          fails.add('${code.isEmpty ? c['name'] : code}: ${e.toString().split('\n').first}');
        }
      }
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    await _load();
    if (!mounted) return;
    if (fails.isEmpty) {
      _snack('Imported: ${creates.length} new, ${updates.length} updated${errors.isNotEmpty ? ', ${errors.length} rows skipped' : ''}.');
    } else {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${fails.length} row${fails.length == 1 ? '' : 's'} failed'),
          content: SizedBox(width: 480, child: SingleChildScrollView(child: Text(fails.join('\n')))),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
  }

  // ───────────────────────────────────────────────────── build
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 800;
    final sel = _selected;
    final showDetail = narrow && sel != null && sel.isNotEmpty;
    // Phone: title row + one "more" menu; list OR detail (with back), never
    // both squeezed side by side (that hid the detail, so taps "did nothing").
    final mobileHeader = Row(children: [
      if (showDetail)
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to list',
          onPressed: () => setState(() => _selectedId = null),
        ),
      Expanded(
        child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(showDetail ? 'Asset' : 'Assets', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          if (!_loading && !showDetail)
            Text('${_assets.length} total', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          if (!_loading && !showDetail && (_dueCount > 0 || _dueFilter != 'all')) _dueBadgeButton(),
        ]),
      ),
      if (!showDetail)
        IconButton.filled(
          icon: const Icon(Icons.add),
          tooltip: 'New asset',
          onPressed: () => _assetDialog(),
        ),
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (v) {
          switch (v) {
            case 'cat': _categoriesDialog(); break;
            case 'qr': _printLabelsDialog(); break;
            case 'cust': _custodiansDialog(); break;
            case 'export': _exportCsv(); break;
            case 'import': _importCsv(); break;
            case 'template': _exportCsv(templateOnly: true); break;
            case 'refresh': _load(); break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'cat', child: ListTile(dense: true, leading: Icon(Icons.category_outlined), title: Text('Categories'))),
          const PopupMenuItem(value: 'qr', child: ListTile(dense: true, leading: Icon(Icons.qr_code_2), title: Text('QR labels'))),
          const PopupMenuItem(value: 'cust', child: ListTile(dense: true, leading: Icon(Icons.badge_outlined), title: Text('Custodians'))),
          if (_canBulk) ...const [
            PopupMenuItem(value: 'export', child: ListTile(dense: true, leading: Icon(Icons.download_outlined), title: Text('Export CSV'))),
            PopupMenuItem(value: 'import', child: ListTile(dense: true, leading: Icon(Icons.upload_file_outlined), title: Text('Import CSV'))),
            PopupMenuItem(value: 'template', child: ListTile(dense: true, leading: Icon(Icons.description_outlined), title: Text('Download template'))),
          ],
          const PopupMenuItem(value: 'refresh', child: ListTile(dense: true, leading: Icon(Icons.refresh), title: Text('Refresh'))),
        ],
      ),
    ]);
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (narrow) mobileHeader else
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
            if (_canBulk) ...[
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: 'Import / export (CSV)',
                onSelected: (v) {
                  if (v == 'export') _exportCsv();
                  if (v == 'template') _exportCsv(templateOnly: true);
                  if (v == 'import') _importCsv();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'export', child: ListTile(dense: true, leading: Icon(Icons.download_outlined), title: Text('Export CSV'))),
                  PopupMenuItem(value: 'import', child: ListTile(dense: true, leading: Icon(Icons.upload_file_outlined), title: Text('Import CSV'))),
                  PopupMenuItem(value: 'template', child: ListTile(dense: true, leading: Icon(Icons.description_outlined), title: Text('Download template'))),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Chip(
                    avatar: Icon(Icons.import_export, size: 18),
                    label: Text('Import / Export'),
                  ),
                ),
              ),
            ],
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
          SizedBox(height: narrow ? 10 : 16),
          if (!_loading && _suggestions.isNotEmpty && !showDetail) ...[
            _suggestionsBanner(),
            SizedBox(height: narrow ? 10 : 14),
          ],
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : narrow
                    ? (showDetail ? _detailPane() : _listPane())
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
                      for (final s in _statusList) s: _optLabel(s),
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
              if (_supFlow) ...[
                const SizedBox(height: 8),
                _filterDropdown(
                  value: _supFilter,
                  hint: 'Supervision',
                  items: {
                    'all': 'All',
                    'pending': 'Awaiting supervision (${_supCount('pending')})',
                    'rejected': 'Rejected (${_supCount('rejected')})',
                    'supervised': 'Supervised',
                  },
                  onChanged: (v) => setState(() => _supFilter = v),
                ),
                if (_canSupervise && _supFilter == 'pending' && rows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.green.shade800),
                      onPressed: _supBusy ? null : () => _confirmSupervise([for (final a in rows) a['id'] as String]),
                      icon: const Icon(Icons.done_all, size: 16),
                      label: Text('Supervise all ${rows.length} shown'),
                    ),
                  ),
                ],
              ],
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
                          if (_supFlow && _supState(a) != 'supervised') ...[
                            _supIcon(a),
                            const SizedBox(width: 6),
                          ],
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

  Widget _statusChipFor(String s) => Align(alignment: Alignment.centerLeft, child: _statusChip(s));

  Color _statusColor(String? s) =>
      _kStatusPalette[_statusColors[s] ?? _defaultStatusColorKey(s)] ?? AppTheme.textSecondary;

  Widget _statusChip(String? s) {
    final c = _statusColor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(6)),
      child: Text(_optLabel(s),
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _flexName(Map<String, dynamic> a, bool narrow) {
    final col = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a['name'] as String? ?? '—', style: TextStyle(fontSize: narrow ? 18 : 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(a['asset_code'] as String? ?? '', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      ],
    );
    return narrow ? Padding(padding: const EdgeInsets.only(bottom: 6), child: col) : Expanded(child: col);
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
        padding: EdgeInsets.all(MediaQuery.of(context).size.width < 800 ? 14 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flex(
              direction: MediaQuery.of(context).size.width < 800 ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              _flexName(a, MediaQuery.of(context).size.width < 800),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
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
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onSelected: (v) {
                  if (v == 'void') _voidAsset(a);
                  if (v == 'delete') _deleteAsset(a);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'void', child: ListTile(dense: true,
                      leading: Icon(Icons.block, color: AppTheme.danger),
                      title: Text('Void asset'),
                      subtitle: Text('Remove from the list with a reason'))),
                  if (_isSuperAdmin)
                    const PopupMenuItem(value: 'delete', child: ListTile(dense: true,
                        leading: Icon(Icons.delete_forever_outlined, color: AppTheme.danger),
                        title: Text('Delete permanently'),
                        subtitle: Text('Super Admin only'))),
                ],
              ),
              ]),
            ]),
            const SizedBox(height: 16),
            if (_supFlow) _supervisionPanel(a),
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
              _kv('Condition', _optLabel(a['condition'] as String?)),
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
      width: MediaQuery.of(context).size.width < 800 ? 140 : 200,
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
            icon: const Icon(Icons.photo_camera_outlined, size: 16),
            label: const Text('Camera'),
            onPressed: _detailLoading ? null : () => _cameraFile(a),
          ),
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
        if (f.type.startsWith('image/')) {
          // Shrink photos (≤1600 px, JPEG 82%) before storing.
          final (cb, cm, ce) = await compressImageBytes(bytes, mime: f.type);
          final base = f.name.contains('.') ? f.name.substring(0, f.name.lastIndexOf('.')) : f.name;
          await _storeAssetFile(a, cb, '$base.$ce', cm);
        } else {
          await _storeAssetFile(a, bytes, f.name, f.type);
        }
      });
    });
  }

  /// Live camera photo → stored like an uploaded image.
  Future<void> _cameraFile(Map<String, dynamic> a) async {
    final bytes = await showCameraCapture(context, title: 'Asset photo');
    if (bytes == null || bytes.isEmpty) return;
    final name = 'photo_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.jpg';
    await _storeAssetFile(a, bytes, name, 'image/jpeg');
  }

  Future<void> _storeAssetFile(Map<String, dynamic> a, Uint8List bytes, String name, String type) async {
    try {
      final client = Supabase.instance.client;
      final orgId = _orgId ?? 'org';
      final safe = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final path = '$orgId/${a['id']}/${DateTime.now().millisecondsSinceEpoch}_$safe';
      final isImg = type.startsWith('image/');
      await client.storage.from(_bucket).uploadBinary(path, bytes,
          fileOptions: FileOptions(contentType: type.isEmpty ? null : type, upsert: false));
      await client.from('asset_files').insert({
        'id': 'afil_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId,
        'asset_id': a['id'],
        'file_type': isImg ? 'image' : 'pdf',
        'storage_path': path,
        'title': name,
        'uploaded_by': client.auth.currentUser?.id,
      });
      // first image becomes the primary thumbnail
      if (isImg && (a['image_path'] == null)) {
        await client.from('assets').update({'image_path': path}).eq('id', a['id']);
      }
      _loadDetail(a['id'] as String);
      _load();
    } catch (e) {
      _snack('Upload failed: ${e.toString().split('\n').first}');
    }
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
  // ── Asset suggestions (SQL 366) ─────────────────────────────────────────
  String _suggAmt(dynamic v) => 'Rs ${_money.format((v as num?) ?? 0)}';

  Widget _suggestionsBanner() {
    final n = _suggestions.length;
    final total = _suggestions.fold<double>(0, (a, s) =>
        a + (((s['amount'] as num?) ?? 0) - ((s['assets_cost'] as num?) ?? 0)).clamp(0, double.infinity).toDouble());
    return Material(
      color: Colors.amber.shade50,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _suggestionsDialog,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.shade700.withOpacity(0.6))),
          child: Row(children: [
            Icon(Icons.lightbulb_outline, color: Colors.amber.shade900, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$n asset suggestion${n == 1 ? '' : 's'} · ${_suggAmt(total)} added to asset accounts '
                'with no asset recorded yet',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.amber.shade900),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _suggestionsDialog, child: const Text('Review')),
          ]),
        ),
      ),
    );
  }

  Future<void> _suggestionsDialog() async {
    await showDialog(
      context: context,
      builder: (dlg) => StatefulBuilder(builder: (dlg, setD) {
        final rows = _suggestions;
        return AlertDialog(
          title: Row(children: [
            Icon(Icons.lightbulb_outline, color: Colors.amber.shade900),
            const SizedBox(width: 8),
            Expanded(child: Text('Asset suggestions (${rows.length})')),
          ]),
          content: SizedBox(
            width: 620,
            child: rows.isEmpty
                ? const Padding(padding: EdgeInsets.all(24),
                    child: Text('All done — nothing waiting.', textAlign: TextAlign.center))
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _suggestionCard(rows[i], dlg, () => setD(() {})),
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(), child: const Text('Close')),
          ],
        );
      }),
    );
  }

  Widget _suggestionCard(Map<String, dynamic> s, BuildContext dlg, VoidCallback rebuild) {
    final amount = (s['amount'] as num?)?.toDouble() ?? 0;
    final covered = (s['assets_cost'] as num?)?.toDouble() ?? 0;
    final made = (s['asset_ids'] as List?)?.length ?? 0;
    final remaining = (amount - covered).clamp(0, double.infinity).toDouble();
    final date = _parseDate(s['entry_date']);
    final branch = _branchNames[s['branch_id']];
    final meta = [
      if (s['source_number'] != null) '${s['source_number']}',
      if (date != null) DateFormat('d MMM yyyy').format(date),
      if (branch != null) branch,
      if (s['party_name'] != null) '${s['party_name']}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50.withOpacity(0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_suggAmt(amount), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('to ${s['account_name'] ?? 'asset account'}',
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            ]),
          ),
          if (made > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
              child: Text('$made asset${made == 1 ? '' : 's'} · ${_suggAmt(covered)}',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.green.shade800)),
            ),
        ]),
        const SizedBox(height: 6),
        if (meta.isNotEmpty) Text(meta, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        if ((s['line_desc'] as String?)?.trim().isNotEmpty ?? false)
          Padding(padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.notes, size: 15, color: AppTheme.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text('${s['line_desc']}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              ])),
        if ((s['narration'] as String?)?.isNotEmpty ?? false)
          Padding(padding: const EdgeInsets.only(top: 3),
              child: Text('${s['narration']}', style: const TextStyle(fontSize: 12.5))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.end, children: [
          TextButton(
            onPressed: () => _dismissSuggestion(s, rebuild),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Dismiss'),
          ),
          if (made > 0)
            OutlinedButton(onPressed: () => _finishSuggestion(s, rebuild), child: const Text('Mark done')),
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: Text(made > 0 ? 'Create another' : 'Create asset'),
            onPressed: () async {
              Navigator.of(dlg, rootNavigator: true).pop();
              final narr = (s['narration'] as String?)?.trim() ?? '';
              // Name: only the line's own description (first item). The narration is
              // usually system text like "Cash Payment: CPV-…", so it never becomes
              // the name — the field stays empty for the user to type instead.
              final lineDesc = (s['line_desc'] as String?)?.trim() ?? '';
              final nameSrc = lineDesc.isNotEmpty ? lineDesc.split(' · ').first : '';
              await _assetDialog(
                suggestionId: s['id'] as String,
                prefill: {
                  'name': nameSrc.length > 80 ? nameSrc.substring(0, 80) : nameSrc,
                  'cost': remaining == 0 ? null : (remaining % 1 == 0 ? remaining.toStringAsFixed(0) : remaining.toStringAsFixed(2)),
                  'date': s['entry_date'],
                  'supplier': s['party_name'],
                  'branch_id': s['branch_id'],
                  'source': s['source_number'],
                  'notes': 'From ${s['source_number'] ?? 'a posted entry'}'
                      '${s['account_name'] != null ? ' · ${s['account_name']}' : ''}'
                      '${lineDesc.isNotEmpty ? '\n$lineDesc' : ''}'
                      '${narr.isNotEmpty ? '\n$narr' : ''}',
                },
              );
            },
          ),
        ]),
      ]),
    );
  }

  Future<void> _dismissSuggestion(Map<String, dynamic> s, VoidCallback rebuild) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, setR) => AlertDialog(
        title: const Text('Dismiss suggestion'),
        content: SizedBox(width: 400, child: TextField(
          controller: ctrl, autofocus: true, minLines: 2, maxLines: 4,
          onChanged: (_) => setR(() {}),
          decoration: const InputDecoration(
              labelText: 'Why is no asset needed? *',
              hintText: 'e.g. repair cost, already recorded, wrong account',
              border: OutlineInputBorder()),
        )),
        actions: [
          TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.of(d, rootNavigator: true).pop(ctrl.text.trim()),
            child: const Text('Dismiss')),
        ],
      )),
    );
    if (reason == null || reason.isEmpty) return;
    await _closeSuggestion(s, true, reason, rebuild);
  }

  Future<void> _finishSuggestion(Map<String, dynamic> s, VoidCallback rebuild) =>
      _closeSuggestion(s, false, null, rebuild);

  Future<void> _closeSuggestion(Map<String, dynamic> s, bool dismiss, String? reason, VoidCallback rebuild) async {
    try {
      await Supabase.instance.client.rpc('close_asset_suggestion',
          params: {'p_id': s['id'], 'p_dismiss': dismiss, 'p_reason': reason});
      setState(() => _suggestions = _suggestions.where((x) => x['id'] != s['id']).toList());
      rebuild();
      ref.invalidate(assetSuggestionCountProvider);
      _snack(dismiss ? 'Suggestion dismissed' : 'Suggestion marked done');
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not save: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _assetDialog({Map<String, dynamic>? existing,
      Map<String, dynamic>? prefill, String? suggestionId}) async {
    final isEdit = existing != null;
    final pre = isEdit ? null : prefill;
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
        TextEditingController(text: existing?['name'] as String? ?? pre?['name'] as String? ?? '');
    final descCtrl =
        TextEditingController(text: existing?['description'] as String? ?? '');
    final serialCtrl =
        TextEditingController(text: existing?['serial_no'] as String? ?? '');
    final modelCtrl =
        TextEditingController(text: existing?['model'] as String? ?? '');
    final mfgCtrl = TextEditingController(
        text: existing?['manufacturer'] as String? ?? '');
    final supplierCtrl =
        TextEditingController(text: existing?['supplier_id'] as String? ?? pre?['supplier'] as String? ?? '');
    final costCtrl = TextEditingController(
        text: existing?['purchase_cost']?.toString() ?? pre?['cost']?.toString() ?? '');
    final locCtrl = TextEditingController(
        text: existing?['location_text'] as String? ?? '');
    final notesCtrl =
        TextEditingController(text: existing?['notes'] as String? ?? pre?['notes'] as String? ?? '');

    String? categoryId = existing?['category_id'] as String?;
    String status = existing?['status'] as String? ?? 'in_use';
    String? condition = existing?['condition'] as String?;
    String? branchId = existing?['branch_id'] as String? ??
        (_branches.any((b) => b['id'] == pre?['branch_id']) ? pre!['branch_id'] as String : null);
    String? custodian = existing?['assigned_to'] as String?;
    DateTime? purchaseDate = _parseDate(existing?['purchase_date'] ?? pre?['date']);
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
                  .update({
                    ...payload,
                    // Saving a rejected asset sends it back to the supervisor.
                    if (_supFlow && existing['rejected_at'] != null && existing['supervised_at'] == null)
                      'rejected_at': null,
                  })
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
              // Created from a suggestion: link it (closes it once covered).
              if (suggestionId != null) {
                try {
                  final st = await client.rpc('link_asset_suggestion',
                      params: {'p_id': suggestionId, 'p_asset_id': id});
                  if (mounted && st != 'done') {
                    _snack('Asset created. The suggestion stays open — create more assets from it, or mark it done.');
                  }
                } catch (_) {}
              }
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
          title: Text(isEdit ? 'Edit asset · $code'
              : pre != null ? 'New asset · $code (from ${pre['source'] ?? 'suggestion'})'
              : 'New asset · $code'),
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
                    child: _optionDropdown(
                      ctx: ctx,
                      kind: 'status',
                      label: 'Status',
                      value: status,
                      allowNone: false,
                      onChanged: (v) => setS(() => status = v ?? status),
                      rebuild: () => setS(() {}),
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
                        for (final b in _branchOptions(branchId))
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
                      child: _optionDropdown(
                    ctx: ctx,
                    kind: 'condition',
                    label: 'Condition',
                    value: condition,
                    allowNone: true,
                    onChanged: (v) => setS(() => condition = v),
                    rebuild: () => setS(() {}),
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
                  for (final b in _branchOptions(branchId))
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
              _optionDropdown(
                ctx: ctx,
                kind: 'status',
                label: 'Status',
                value: status,
                allowNone: false,
                onChanged: (v) => setS(() => status = v ?? status),
                rebuild: () => setS(() {}),
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

  bool get _isSuperAdmin => ref.read(currentUserProvider)?.role == WebUserRole.superAdmin;

  // Void: off the list with a reason, no longer a pending item (SQL 368).
  Future<void> _voidAsset(Map<String, dynamic> a) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, setR) => AlertDialog(
        title: Text('Void ${a['asset_code'] ?? 'asset'}?'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('"${a['name'] ?? ''}" will be removed from the asset list and will no longer wait for '
              'supervision. It stays on record.',
              style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          TextField(controller: ctrl, autofocus: true, minLines: 2, maxLines: 4,
              onChanged: (_) => setR(() {}),
              decoration: const InputDecoration(labelText: 'Reason *',
                  hintText: 'e.g. created by mistake, duplicate', border: OutlineInputBorder())),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: ctrl.text.trim().isEmpty ? null : () => Navigator.of(d, rootNavigator: true).pop(ctrl.text.trim()),
            child: const Text('Void')),
        ],
      )),
    );
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('void_asset', params: {'p_id': a['id'], 'p_reason': reason});
      _snack('${a['asset_code'] ?? 'Asset'} voided');
      setState(() => _selectedId = null);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not void: ${e.toString().split('\n').first}');
    }
  }

  // Delete for good — Super Admin only (checked again on the server).
  Future<void> _deleteAsset(Map<String, dynamic> a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${a['asset_code'] ?? 'asset'} permanently?'),
        content: Text('"${a['name'] ?? ''}" and its history, files list and maintenance log '
            'will be removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(d, rootNavigator: true).pop(true),
            child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('delete_asset', params: {'p_id': a['id']});
      _snack('${a['asset_code'] ?? 'Asset'} deleted');
      setState(() => _selectedId = null);
      await _load();
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not delete: ${e.toString().split('\n').first}');
    }
  }

  bool get _isMaster {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
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
          final emailCtrl =
              TextEditingController(text: existing?['email'] as String? ?? '');
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
                    decoration: const InputDecoration(
                        labelText: 'Phone', helperText: 'Maintenance reminders go here by SMS')),
                const SizedBox(height: 10),
                TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email', helperText: '…and here by email, if given')),
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
            try {
              if (existing == null) {
                await client.from('asset_custodians').insert({
                  'id': 'acus_${DateTime.now().millisecondsSinceEpoch}',
                  'org_id': orgId,
                  'name': nameCtrl.text.trim(),
                  'phone': _nz(phoneCtrl.text),
                  'email': _nz(emailCtrl.text),
                  'designation': _nz(desigCtrl.text),
                });
              } else {
                await client.from('asset_custodians').update({
                  'name': nameCtrl.text.trim(),
                  'phone': _nz(phoneCtrl.text),
                  'email': _nz(emailCtrl.text),
                  'designation': _nz(desigCtrl.text),
                }).eq('id', existing['id']);
              }
            } catch (e) {
              _snack('Could not save: ${e.toString().split('\n').first}');
            }
            await _load();
            setS(() {});
          }
        }

        // Pick one or more existing employees and add them as custodians
        // (name, phone, email and designation copied from HR).
        Future<void> fromEmployees() async {
          final client = Supabase.instance.client;
          List<Map<String, dynamic>> emps = [];
          final desig = <String, String>{};
          try {
            emps = List<Map<String, dynamic>>.from(await client
                .from('hr_employees')
                .select('id, full_name, employee_code, phone, email, designation_id, status')
                .eq('org_id', orgId)
                .order('full_name'));
            emps = emps.where((e) => e['status'] != 'left').toList();
            final ds = await client.from('hr_designations').select('id, name').eq('org_id', orgId);
            for (final d in ds as List) {
              desig['${d['id']}'] = '${d['name'] ?? ''}';
            }
          } catch (e) {
            _snack('Could not load employees: ${e.toString().split('\n').first}');
            return;
          }
          final already = {
            for (final c in _custodians)
              if (c['employee_id'] != null) '${c['employee_id']}'
          };
          final picked = <String>{};
          var q = '';
          if (!ctx.mounted) return;
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (c2) => StatefulBuilder(builder: (c2, setP) {
              final list = emps.where((e) {
                final s = '${e['full_name'] ?? ''} ${e['employee_code'] ?? ''} ${e['phone'] ?? ''}'.toLowerCase();
                return q.isEmpty || s.contains(q.toLowerCase());
              }).toList();
              return AlertDialog(
                title: const Text('Add from employees'),
                content: SizedBox(
                  width: 440,
                  height: 460,
                  child: Column(children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'Search name, code or phone',
                          isDense: true),
                      onChanged: (v) => setP(() => q = v.trim()),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: list.isEmpty
                          ? const Center(
                              child: Text('No employees found',
                                  style: TextStyle(color: AppTheme.textSecondary)))
                          : ListView.builder(
                              itemCount: list.length,
                              itemBuilder: (_, i) {
                                final e = list[i];
                                final id = '${e['id']}';
                                final isIn = already.contains(id);
                                final d = desig['${e['designation_id']}'] ?? '';
                                final sub = [e['employee_code'], d, e['phone']]
                                    .whereType<String>()
                                    .where((s) => s.trim().isNotEmpty)
                                    .join('  ·  ');
                                return CheckboxListTile(
                                  dense: true,
                                  value: isIn || picked.contains(id),
                                  onChanged: isIn
                                      ? null
                                      : (v) => setP(() => v == true ? picked.add(id) : picked.remove(id)),
                                  title: Text('${e['full_name'] ?? '—'}'),
                                  subtitle: Text(isIn ? 'Already a custodian' : sub,
                                      style: const TextStyle(fontSize: 11)),
                                );
                              }),
                    ),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c2, false),
                      child: const Text('Cancel')),
                  ElevatedButton(
                      onPressed: picked.isEmpty ? null : () => Navigator.pop(c2, true),
                      child: Text(picked.isEmpty ? 'Add' : 'Add ${picked.length}')),
                ],
              );
            }),
          );
          if (ok != true || picked.isEmpty) return;
          final stamp = DateTime.now().millisecondsSinceEpoch;
          var n = 0;
          final rows = [
            for (final e in emps)
              if (picked.contains('${e['id']}'))
                {
                  'id': 'acus_${stamp}_${n++}',
                  'org_id': orgId,
                  'employee_id': e['id'],
                  'name': e['full_name'],
                  'phone': e['phone'],
                  'email': e['email'],
                  'designation': desig['${e['designation_id']}'],
                }
          ];
          try {
            await client.from('asset_custodians').insert(rows);
            _snack('${rows.length} custodian${rows.length == 1 ? '' : 's'} added from employees');
          } catch (e) {
            _snack('Could not add: ${e.toString().split('\n').first}');
          }
          await _load();
          setS(() {});
        }

        int countFor(String id) =>
            _assets.where((a) => a['assigned_to'] == id).length;

        return AlertDialog(
          title: const Text('Custodians'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
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
                    final sub = [c['designation'], c['phone'], c['email']]
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
                      leading: Icon(c['employee_id'] != null ? Icons.badge_outlined : Icons.person_outline,
                          size: 18, color: AppTheme.textSecondary),
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
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Close')),
            OutlinedButton.icon(
                onPressed: fromEmployees,
                icon: const Icon(Icons.badge_outlined, size: 16),
                label: const Text('From employees')),
            ElevatedButton.icon(
                onPressed: () => addOrEdit(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add manually')),
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
        int countFor(String id) =>
            _assets.where((a) => a['category_id'] == id).length;

        Future<void> addOrEdit({Map<String, dynamic>? existing}) async {
          final nameCtrl =
              TextEditingController(text: existing?['name'] as String? ?? '');
          final codeCtrl =
              TextEditingController(text: existing?['code'] as String? ?? '');
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (c2) => AlertDialog(
              title: Text(existing == null ? 'New category' : 'Edit category'),
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
                    child: Text(existing == null ? 'Add' : 'Save')),
              ],
            ),
          );
          if (ok == true && nameCtrl.text.trim().isNotEmpty) {
            final client = Supabase.instance.client;
            try {
              if (existing == null) {
                await client.from('asset_categories').insert({
                  'id': 'acat_${DateTime.now().millisecondsSinceEpoch}',
                  'org_id': orgId,
                  'name': nameCtrl.text.trim(),
                  'code': _nz(codeCtrl.text),
                });
              } else {
                await client.from('asset_categories').update({
                  'name': nameCtrl.text.trim(),
                  'code': _nz(codeCtrl.text),
                }).eq('id', existing['id']);
              }
            } catch (e) {
              _snack('Could not save: ${e.toString().split('\n').first}');
            }
            await _load();
            setS(() {});
          }
        }

        Future<void> remove(Map<String, dynamic> c) async {
          final n = countFor(c['id'] as String);
          if (n > 0) {
            _snack('“${c['name']}” still has $n asset${n == 1 ? '' : 's'}. Move them to another category first.');
            return;
          }
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (c2) => AlertDialog(
              title: const Text('Delete category?'),
              content: Text('“${c['name']}” has no assets and will be removed.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c2, false), child: const Text('Cancel')),
                ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(c2, true),
                    child: const Text('Delete')),
              ],
            ),
          );
          if (ok != true) return;
          try {
            await Supabase.instance.client
                .from('asset_categories')
                .update({'is_active': false}).eq('id', c['id']);
          } catch (e) {
            _snack('Could not delete: ${e.toString().split('\n').first}');
          }
          await _load();
          setS(() {});
        }

        return AlertDialog(
          title: const Text('Asset categories'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_categories.isNotEmpty)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Tap a category to see its assets.',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                  ),
                const SizedBox(height: 6),
                ..._categories.map((c) {
                  final n = countFor(c['id'] as String);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    onTap: () {
                      setState(() => _catFilter = c['id'] as String);
                      Navigator.of(ctx, rootNavigator: true).pop();
                    },
                    title: Text(c['name'] as String? ?? '—'),
                    subtitle: (c['code'] as String?)?.isNotEmpty == true
                        ? Text(c['code'] as String)
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: AppTheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10)),
                        child: Text('$n asset${n == 1 ? '' : 's'}',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                      ),
                      IconButton(
                          tooltip: 'Edit',
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          onPressed: () => addOrEdit(existing: c)),
                      if (_isMaster)
                        IconButton(
                            tooltip: n > 0 ? 'Has assets — move them first' : 'Delete',
                            icon: Icon(Icons.delete_outline,
                                size: 16, color: n > 0 ? AppTheme.textSecondary : Colors.red),
                            onPressed: () => remove(c)),
                    ]),
                  );
                }),
                if (_categories.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('No categories yet.',
                        style: TextStyle(color: AppTheme.textSecondary)),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Close')),
            ElevatedButton.icon(
                onPressed: () => addOrEdit(),
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
