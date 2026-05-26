// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class ErpChartOfAccountsScreen extends ConsumerStatefulWidget {
  const ErpChartOfAccountsScreen({super.key});
  @override ConsumerState<ErpChartOfAccountsScreen> createState() => _ErpChartOfAccountsScreenState();
}

class _ErpChartOfAccountsScreenState extends ConsumerState<ErpChartOfAccountsScreen> {
  List<Map<String, dynamic>> _accounts = [];
  bool _loading = true;

  // Form state
  String? _selectedGroup;
  Map<String, dynamic>? _sel1, _sel2, _sel3;
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  String? _accountType;
  bool _saving = false;

  // Expand/collapse for add form levels
  bool _show1 = false, _show2 = false, _show3 = false;

  // Tree expand state
  final Map<String, bool> _treeExpanded = {};

  // Search
  String _search = '';

  static const _groups = ['Assets', 'Capital', 'Liability', 'Income', 'Expense'];
  static const _accountTypes = ['BANK', 'CASH IN HAND', 'RECEIVABLE', 'PAYABLE', 'INCOME', 'EXPENSE', 'FIXED ASSET', 'INVENTORY', 'CUSTOMER', 'EMPLOYEE', 'OTHER'];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _codeCtrl.dispose(); _nameCtrl.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client.from('chart_of_accounts')
          .select().eq('org_id', orgId).order('account_group').order('level').order('code');
      setState(() { _accounts = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) { _snack('Error: $e'); setState(() => _loading = false); }
  }

  // Get accounts filtered by group + level + parent
  List<Map<String, dynamic>> _getLevel(int level, {String? group, String? parentId}) {
    return _accounts.where((a) {
      if (a['level'] != level) return false;
      if (group != null && (a['account_group'] as String?) != group) return false;
      if (parentId != null && (a['parent_id'] as String?) != parentId) return false;
      return (a['is_active'] as bool? ?? true);
    }).toList();
  }

  // Determine where to create (deepest selected parent)
  String? get _parentId {
    if (_sel3 != null) return _sel3!['id'] as String;
    if (_sel2 != null) return _sel2!['id'] as String;
    if (_sel1 != null) return _sel1!['id'] as String;
    return null;
  }

  int get _newLevel {
    if (_sel3 != null) return 4;
    if (_sel2 != null) return 3;
    if (_sel1 != null) return 2;
    return 1;
  }

  bool get _canSubmit => _selectedGroup != null && _nameCtrl.text.trim().isNotEmpty && _accountType != null;

  Future<void> _submit() async {
    if (!_canSubmit) { _snack('Fill all required fields'); return; }
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('chart_of_accounts').insert({
        'id': 'coa_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId,
        'parent_id': _parentId,
        'code': _codeCtrl.text.trim().isEmpty ? null : _codeCtrl.text.trim(),
        'name': _nameCtrl.text.trim(),
        'account_group': _selectedGroup,
        'level': _newLevel,
        'account_type': _accountType,
        'is_active': true,
      });
      _snack('Account created');
      _resetForm();
      await _load();
    } catch (e) { _snack('Failed: $e'); }
    setState(() => _saving = false);
  }

  void _resetForm() {
    setState(() {
      _selectedGroup = null; _sel1 = null; _sel2 = null; _sel3 = null;
      _accountType = null; _show1 = false; _show2 = false; _show3 = false;
    });
    _codeCtrl.clear(); _nameCtrl.clear();
  }

  Future<void> _toggleActive(Map<String, dynamic> acc) async {
    final newVal = !(acc['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client.from('chart_of_accounts')
          .update({'is_active': newVal}).eq('id', acc['id'] as String);
      await _load();
    } catch (e) { _snack('Failed: $e'); }
  }

  // Build tree for display
  List<Widget> _buildTree(List<Map<String, dynamic>> nodes, {int indent = 0}) {
    final result = <Widget>[];
    for (final node in nodes) {
      final id = node['id'] as String;
      final level = node['level'] as int;
      final code = node['code'] as String? ?? '';
      final name = node['name'] as String;
      final group = node['account_group'] as String;
      final type = node['account_type'] as String?;
      final active = node['is_active'] as bool? ?? true;
      final children = _accounts.where((a) => a['parent_id'] == id).toList();
      final hasChildren = children.isNotEmpty;
      final expanded = _treeExpanded[id] ?? false;
      final color = _groupColor(group);

      final q = _search.toLowerCase();
      final matches = q.isEmpty || name.toLowerCase().contains(q) || code.toLowerCase().contains(q);

      if (q.isNotEmpty && !matches && !children.any((c) => (c['name'] as String).toLowerCase().contains(q) || (c['code'] as String? ?? '').toLowerCase().contains(q))) continue;

      result.add(InkWell(
        onTap: hasChildren ? () => setState(() => _treeExpanded[id] = !expanded) : null,
        child: Container(
          padding: EdgeInsets.only(left: 16.0 + indent * 20, right: 16, top: 8, bottom: 8),
          decoration: BoxDecoration(
            color: !active ? Colors.grey.shade50 : Colors.transparent,
            border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.4))),
          ),
          child: Row(children: [
            SizedBox(width: 20, child: hasChildren
                ? Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: color)
                : const SizedBox()),
            const SizedBox(width: 4),
            Container(width: 4, height: 28, decoration: BoxDecoration(color: color.withOpacity(0.6), borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(code.isNotEmpty ? '$code — $name' : name,
                  style: TextStyle(fontSize: 13, fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w500,
                      color: active ? AppTheme.textPrimary : Colors.grey)),
              if (type != null) Text(type, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
              child: Text('L$level', style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700))),
            const SizedBox(width: 8),
            Switch.adaptive(value: active, onChanged: (_) => _toggleActive(node), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ]),
        ),
      ));
      if (expanded && hasChildren) {
        result.addAll(_buildTree(children, indent: indent + 1));
      }
    }
    return result;
  }

  Color _groupColor(String group) {
    switch (group) {
      case 'Assets': return const Color(0xFF2196F3);
      case 'Capital': return const Color(0xFF9C27B0);
      case 'Liability': return const Color(0xFFF44336);
      case 'Income': return const Color(0xFF4CAF50);
      case 'Expense': return const Color(0xFFFF9800);
      default: return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final level1List = _selectedGroup != null ? _getLevel(1, group: _selectedGroup) : <Map<String, dynamic>>[];
    final level2List = _sel1 != null ? _getLevel(2, group: _selectedGroup, parentId: _sel1!['id'] as String) : <Map<String, dynamic>>[];
    final level3List = _sel2 != null ? _getLevel(3, group: _selectedGroup, parentId: _sel2!['id'] as String) : <Map<String, dynamic>>[];

    // Root nodes for tree (level 1, no parent)
    final rootNodes = _accounts.where((a) => a['parent_id'] == null && a['level'] == 1).toList();
    // Group roots by account_group
    final groupRoots = <String, List<Map<String, dynamic>>>{};
    for (final g in _groups) {
      groupRoots[g] = _accounts.where((a) => a['account_group'] == g && a['level'] == 1).toList();
    }

    return Container(color: AppTheme.background, child: Row(children: [
      // ── LEFT: Account Tree ──────────────────────────────────────────
      Container(width: 420, decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
        child: Column(children: [
          // Header
          Container(padding: const EdgeInsets.fromLTRB(16, 16, 16, 10), decoration: BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Accounts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text('${_accounts.where((a) => a['is_active'] == true).length} active accounts', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              TextField(decoration: const InputDecoration(hintText: 'Search accounts...', prefixIcon: Icon(Icons.search, size: 16), isDense: true), onChanged: (v) => setState(() => _search = v)),
            ])),
          // Tree grouped by account group
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
              for (final group in _groups) ...[
                // Group header
                InkWell(
                  onTap: () => setState(() => _treeExpanded['_g_$group'] = !(_treeExpanded['_g_$group'] ?? true)),
                  child: Container(color: _groupColor(group).withOpacity(0.08), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: _groupColor(group), shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(group, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _groupColor(group)))),
                      Icon((_treeExpanded['_g_$group'] ?? true) ? Icons.expand_less : Icons.expand_more, size: 16, color: _groupColor(group)),
                    ])),
                ),
                if (_treeExpanded['_g_$group'] ?? true)
                  ...(() {
                    final grpAccs = _accounts.where((a) => a['account_group'] == group && a['level'] == 1).toList();
                    if (grpAccs.isEmpty) return [Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: Text('No accounts', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)))];
                    return _buildTree(grpAccs);
                  })(),
              ],
            ])),
        ])),
      // ── RIGHT: Add Account Form ─────────────────────────────────────
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title
        Row(children: [
          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.account_balance_outlined, color: AppTheme.primary, size: 20)),
          const SizedBox(width: 12),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Add Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Text('Create a new account in the chart', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const Spacer(),
          TextButton(onPressed: _resetForm, child: const Text('Reset')),
        ]),
        const SizedBox(height: 20),
        _FormCard(children: [
          // Account Group
          _FieldLabel('Account Group *'),
          DropdownButtonFormField<String>(
            value: _selectedGroup,
            decoration: _inputDec('Select Account Group'),
            items: _groups.map((g) => DropdownMenuItem(value: g, child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: _groupColor(g), shape: BoxShape.circle)),
              const SizedBox(width: 8), Text(g),
            ]))).toList(),
            onChanged: (v) => setState(() { _selectedGroup = v; _sel1 = null; _sel2 = null; _sel3 = null; _show1 = v != null; _show2 = false; _show3 = false; }),
          ),
          const SizedBox(height: 16),

          // 1st Level
          _LevelRow(
            label: '1st Level',
            enabled: _selectedGroup != null,
            expanded: _show1,
            onToggle: _selectedGroup != null ? () => setState(() { _show1 = !_show1; if (!_show1) { _sel1 = null; _sel2 = null; _sel3 = null; _show2 = false; _show3 = false; } }) : null,
            child: _show1 ? Padding(padding: const EdgeInsets.only(top: 8), child: DropdownButtonFormField<Map<String, dynamic>>(
              value: _sel1,
              decoration: _inputDec('Select 1st Level'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— None (create here) —', style: TextStyle(color: AppTheme.textSecondary))),
                ...level1List.map((a) => DropdownMenuItem(value: a, child: Text('${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}'))),
              ],
              onChanged: (v) => setState(() { _sel1 = v; _sel2 = null; _sel3 = null; _show2 = v != null; _show3 = false; }),
            )) : null,
          ),
          const SizedBox(height: 12),

          // 2nd Level
          _LevelRow(
            label: '2nd Level',
            enabled: _sel1 != null,
            expanded: _show2,
            onToggle: _sel1 != null ? () => setState(() { _show2 = !_show2; if (!_show2) { _sel2 = null; _sel3 = null; _show3 = false; } }) : null,
            child: _show2 ? Padding(padding: const EdgeInsets.only(top: 8), child: DropdownButtonFormField<Map<String, dynamic>>(
              value: _sel2,
              decoration: _inputDec('Select 2nd Level'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— None (create here) —', style: TextStyle(color: AppTheme.textSecondary))),
                ...level2List.map((a) => DropdownMenuItem(value: a, child: Text('${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}'))),
              ],
              onChanged: (v) => setState(() { _sel2 = v; _sel3 = null; _show3 = v != null; }),
            )) : null,
          ),
          const SizedBox(height: 12),

          // 3rd Level
          _LevelRow(
            label: '3rd Level',
            enabled: _sel2 != null,
            expanded: _show3,
            onToggle: _sel2 != null ? () => setState(() { _show3 = !_show3; if (!_show3) _sel3 = null; }) : null,
            child: _show3 ? Padding(padding: const EdgeInsets.only(top: 8), child: DropdownButtonFormField<Map<String, dynamic>>(
              value: _sel3,
              decoration: _inputDec('Select 3rd Level'),
              items: [
                const DropdownMenuItem(value: null, child: Text('— None (create here) —', style: TextStyle(color: AppTheme.textSecondary))),
                ...level3List.map((a) => DropdownMenuItem(value: a, child: Text('${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}'))),
              ],
              onChanged: (v) => setState(() => _sel3 = v),
            )) : null,
          ),
          const SizedBox(height: 20),

          // Will create at level indicator
          if (_selectedGroup != null) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.06), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary.withOpacity(0.2))),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 14, color: AppTheme.primary),
              const SizedBox(width: 6),
              Text('Creating Level $_newLevel account under: ${_sel3?['name'] ?? _sel2?['name'] ?? _sel1?['name'] ?? _selectedGroup}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600)),
            ])),
          const SizedBox(height: 20),
        ]),

        const SizedBox(height: 16),
        _FormCard(children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _FieldLabel('Account Code'),
              TextField(controller: _codeCtrl, decoration: _inputDec('e.g. 1011'), onChanged: (_) => setState(() {})),
            ])),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _FieldLabel('Account Name *'),
              TextField(controller: _nameCtrl, decoration: _inputDec('e.g. Petty Cash Fund'), onChanged: (_) => setState(() {})),
            ])),
          ]),
          const SizedBox(height: 16),
          _FieldLabel('Account Type *'),
          DropdownButtonFormField<String>(
            value: _accountType,
            decoration: _inputDec('Select Account Type'),
            items: _accountTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => _accountType = v),
          ),
          const SizedBox(height: 20),
          Row(children: [
            ElevatedButton.icon(
              icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add, size: 18),
              label: const Text('Add Account'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              onPressed: _canSubmit && !_saving ? _submit : null,
            ),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: _resetForm, child: const Text('Reset')),
          ]),
        ]),
      ]))),
    ]));
  }
}

InputDecoration _inputDec(String hint) => InputDecoration(hintText: hint, isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppTheme.border)));

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)));
}

class _FormCard extends StatelessWidget {
  final List<Widget> children;
  const _FormCard({required this.children});
  @override Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children));
}

class _LevelRow extends StatelessWidget {
  final String label;
  final bool enabled, expanded;
  final VoidCallback? onToggle;
  final Widget? child;
  const _LevelRow({required this.label, required this.enabled, required this.expanded, this.onToggle, this.child});

  @override Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      InkWell(onTap: onToggle, borderRadius: BorderRadius.circular(4), child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: enabled ? (expanded ? AppTheme.primary.withOpacity(0.1) : AppTheme.background) : Colors.grey.shade100, borderRadius: BorderRadius.circular(4), border: Border.all(color: enabled ? AppTheme.border : Colors.grey.shade200)),
        child: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 16, color: enabled ? (expanded ? AppTheme.primary : AppTheme.textSecondary) : Colors.grey.shade400))),
      const SizedBox(width: 8),
      Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: enabled ? AppTheme.textPrimary : Colors.grey.shade400)),
    ]),
    if (child != null) child!,
  ]);
}
