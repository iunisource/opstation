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

  // Form state — levels are navigation only
  String? _selectedGroup;
  Map<String, dynamic>? _sel1, _sel2, _sel3;
  bool _show1 = false, _show2 = false, _show3 = false;

  // Actual account creation
  final _nameCtrl = TextEditingController();
  String? _accountType;
  bool _saving = false;

  // Tree
  final Map<String, bool> _treeExpanded = {};
  String _search = '';

  static const _groups = ['Assets', 'Capital', 'Liability', 'Income', 'Expense'];
  static const _accountTypes = ['BANK', 'CASH IN HAND', 'CUSTOMER', 'EMPLOYEE', 'EXPENSE', 'FIXED ASSETS', 'G/L ACCOUNT', 'PURCHASES', 'SALES', 'SUPPLIER'];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override void initState() { super.initState(); _load(); }
  @override void dispose() { _nameCtrl.dispose(); super.dispose(); }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _load() async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client.from('chart_of_accounts')
          .select().eq('org_id', orgId).order('level').order('code');
      setState(() { _accounts = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (e) { _snack('Error: $e'); setState(() => _loading = false); }
  }

  List<Map<String, dynamic>> _getLevel(int level, {String? group, String? parentId}) =>
      _accounts.where((a) => a['level'] == level
          && (group == null || a['account_group'] == group)
          && (parentId == null || a['parent_id'] == parentId)).toList();

  // Generate code automatically
  String _genCode({String? parentCode, String? group, required int level}) {
    final prefix = parentCode?.isNotEmpty == true
        ? parentCode!
        : (group?.substring(0, 1).toUpperCase() ?? 'X');
    final siblings = _accounts.where((a) {
      if (parentCode != null) return (a['code'] as String? ?? '').startsWith(prefix) && a['level'] == level;
      return a['account_group'] == group && a['level'] == level;
    }).toList();
    final seq = (siblings.length + 1).toString().padLeft(2, '0');
    return '$prefix$seq';
  }

  // Show dialog to add a level account (1, 2, or 3)
  Future<void> _showAddLevelDialog({required int level, required String group, String? parentId, String? parentCode}) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('New Level $level Account'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('Under: ${_sel2?['name'] ?? _sel1?['name'] ?? group}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Account Name *', hintText: 'e.g. Current Assets')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () { if (ctrl.text.trim().isNotEmpty) Navigator.pop(ctx, true); }, child: const Text('Add'), style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary)),
      ],
    ));
    if (ok != true || !mounted) return;
    final orgId = _orgId; if (orgId == null) return;
    final code = _genCode(parentCode: parentCode, group: group, level: level);
    try {
      await Supabase.instance.client.from('chart_of_accounts').insert({
        'id': 'coa_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId, 'parent_id': parentId,
        'code': code, 'name': ctrl.text.trim(),
        'account_group': group, 'level': level,
        'account_type': null, 'is_active': true,
      });
      await _load();
      _snack('Level $level account added');
    } catch (e) { _snack('Failed: $e'); }
    ctrl.dispose();
  }

  // Parent for the actual account being created
  String? get _parentId => _sel3?['id'] as String? ?? _sel2?['id'] as String? ?? _sel1?['id'] as String?;
  int get _newLevel => _sel3 != null ? 4 : _sel2 != null ? 3 : _sel1 != null ? 2 : 1;
  String? get _parentCode => _sel3?['code'] as String? ?? _sel2?['code'] as String? ?? _sel1?['code'] as String?;

  bool get _canSubmit => _selectedGroup != null && _nameCtrl.text.trim().isNotEmpty && _accountType != null;

  Future<void> _submit() async {
    if (!_canSubmit) { _snack('Fill all required fields'); return; }
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _saving = true);
    final code = _genCode(parentCode: _parentCode, group: _selectedGroup, level: _newLevel);
    try {
      await Supabase.instance.client.from('chart_of_accounts').insert({
        'id': 'coa_${DateTime.now().millisecondsSinceEpoch}',
        'org_id': orgId, 'parent_id': _parentId,
        'code': code, 'name': _nameCtrl.text.trim(),
        'account_group': _selectedGroup, 'level': _newLevel,
        'account_type': _accountType, 'is_active': true,
      });
      _snack('Account $code created');
      _resetForm();
      await _load();
    } catch (e) { _snack('Failed: $e'); }
    setState(() => _saving = false);
  }

  void _resetForm() {
    setState(() { _selectedGroup = null; _sel1 = null; _sel2 = null; _sel3 = null; _accountType = null; _show1 = false; _show2 = false; _show3 = false; });
    _nameCtrl.clear();
  }

  Future<void> _toggleActive(Map<String, dynamic> acc) async {
    try {
      await Supabase.instance.client.from('chart_of_accounts').update({'is_active': !(acc['is_active'] as bool? ?? true)}).eq('id', acc['id'] as String);
      await _load();
    } catch (e) { _snack('Failed: $e'); }
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
      if (q.isNotEmpty && !name.toLowerCase().contains(q) && !code.toLowerCase().contains(q) &&
          !children.any((c) => (c['name'] as String).toLowerCase().contains(q))) continue;
      result.add(InkWell(
        onTap: hasChildren ? () => setState(() => _treeExpanded[id] = !expanded) : null,
        child: Container(
          padding: EdgeInsets.only(left: 12.0 + indent * 18, right: 12, top: 7, bottom: 7),
          decoration: BoxDecoration(color: !active ? Colors.grey.shade50 : null, border: Border(bottom: BorderSide(color: AppTheme.border.withOpacity(0.3)))),
          child: Row(children: [
            SizedBox(width: 18, child: hasChildren ? Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 14, color: color) : const SizedBox()),
            const SizedBox(width: 4),
            Container(width: 3, height: 24, decoration: BoxDecoration(color: color.withOpacity(0.7), borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(3)), child: Text('L$level', style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w800))),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(code.isNotEmpty ? '$code — $name' : name, style: TextStyle(fontSize: 12, fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w500, color: active ? AppTheme.textPrimary : Colors.grey), overflow: TextOverflow.ellipsis),
              if (type != null) Text(type, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
            ])),
            Switch.adaptive(value: active, onChanged: (_) => _toggleActive(node), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ]),
        ),
      ));
      if (expanded && hasChildren) result.addAll(_buildTree(children, indent: indent + 1));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final l1 = _selectedGroup != null ? _getLevel(1, group: _selectedGroup) : <Map<String, dynamic>>[];
    final l2 = _sel1 != null ? _getLevel(2, group: _selectedGroup, parentId: _sel1!['id'] as String) : <Map<String, dynamic>>[];
    final l3 = _sel2 != null ? _getLevel(3, group: _selectedGroup, parentId: _sel2!['id'] as String) : <Map<String, dynamic>>[];

    return Container(color: AppTheme.background, child: Row(children: [
      // ── LEFT TREE ──────────────────────────────────────────────────
      Container(width: 380, decoration: const BoxDecoration(color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))), child: Column(children: [
        Container(padding: const EdgeInsets.fromLTRB(14, 14, 14, 8), decoration: BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Accounts', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            Text('${_accounts.length} total', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 8),
          TextField(decoration: const InputDecoration(hintText: 'Search accounts...', prefixIcon: Icon(Icons.search, size: 15), isDense: true), onChanged: (v) => setState(() => _search = v)),
        ])),
        Expanded(child: _loading ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
            for (final group in _groups) ...[
              InkWell(
                onTap: () => setState(() => _treeExpanded['_g_$group'] = !(_treeExpanded['_g_$group'] ?? true)),
                child: Container(color: _groupColor(group).withOpacity(0.07), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9), child: Row(children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(color: _groupColor(group), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(group, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _groupColor(group)))),
                  Text('${_accounts.where((a) => a['account_group'] == group).length}', style: TextStyle(fontSize: 10, color: _groupColor(group))),
                  const SizedBox(width: 4),
                  Icon((_treeExpanded['_g_$group'] ?? true) ? Icons.expand_less : Icons.expand_more, size: 14, color: _groupColor(group)),
                ])),
              ),
              if (_treeExpanded['_g_$group'] ?? true) ..._buildTree(_accounts.where((a) => a['account_group'] == group && a['level'] == 1).toList()),
            ],
          ])),
      ])),
      // ── RIGHT FORM ────────────────────────────────────────────────
      Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.account_balance_outlined, color: AppTheme.primary, size: 20)),
          const SizedBox(width: 12),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Add Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Text('Select levels to navigate, then fill in account details', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
          const Spacer(),
          TextButton(onPressed: _resetForm, child: const Text('Reset')),
        ]),
        const SizedBox(height: 20),
        // ── Level Navigation ──────────────────────────────────────
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Account Hierarchy', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 14),
          // Group
          _FieldLabel('Account Group *'),
          DropdownButtonFormField<String>(
            value: _selectedGroup,
            decoration: _inputDec('Select Account Group'),
            items: _groups.map((g) => DropdownMenuItem(value: g, child: Row(children: [Container(width: 10, height: 10, decoration: BoxDecoration(color: _groupColor(g), shape: BoxShape.circle)), const SizedBox(width: 8), Text(g)]))).toList(),
            onChanged: (v) => setState(() { _selectedGroup = v; _sel1 = null; _sel2 = null; _sel3 = null; _show1 = v != null; _show2 = false; _show3 = false; }),
          ),
          const SizedBox(height: 14),
          // Level 1
          _LevelHeader(label: '1st Level', enabled: _selectedGroup != null, expanded: _show1,
            onToggle: _selectedGroup != null ? () => setState(() { _show1 = !_show1; if (!_show1) { _sel1 = null; _sel2 = null; _sel3 = null; _show2 = false; _show3 = false; } }) : null),
          if (_show1) Padding(padding: const EdgeInsets.only(top: 8), child: _LevelDropdown(
            hint: 'Select or create 1st level',
            items: l1, value: _sel1,
            onSelect: (v) => setState(() { _sel1 = v; _sel2 = null; _sel3 = null; _show2 = v != null; _show3 = false; }),
            onAddNew: _selectedGroup != null ? () => _showAddLevelDialog(level: 1, group: _selectedGroup!, parentId: null, parentCode: null) : null,
          )),
          const SizedBox(height: 12),
          // Level 2
          _LevelHeader(label: '2nd Level', enabled: _sel1 != null, expanded: _show2,
            onToggle: _sel1 != null ? () => setState(() { _show2 = !_show2; if (!_show2) { _sel2 = null; _sel3 = null; _show3 = false; } }) : null),
          if (_show2) Padding(padding: const EdgeInsets.only(top: 8), child: _LevelDropdown(
            hint: 'Select or create 2nd level',
            items: l2, value: _sel2,
            onSelect: (v) => setState(() { _sel2 = v; _sel3 = null; _show3 = v != null; }),
            onAddNew: _sel1 != null ? () => _showAddLevelDialog(level: 2, group: _selectedGroup!, parentId: _sel1!['id'] as String, parentCode: _sel1!['code'] as String?) : null,
          )),
          const SizedBox(height: 12),
          // Level 3
          _LevelHeader(label: '3rd Level', enabled: _sel2 != null, expanded: _show3,
            onToggle: _sel2 != null ? () => setState(() { _show3 = !_show3; if (!_show3) _sel3 = null; }) : null),
          if (_show3) Padding(padding: const EdgeInsets.only(top: 8), child: _LevelDropdown(
            hint: 'Select or create 3rd level',
            items: l3, value: _sel3,
            onSelect: (v) => setState(() => _sel3 = v),
            onAddNew: _sel2 != null ? () => _showAddLevelDialog(level: 3, group: _selectedGroup!, parentId: _sel2!['id'] as String, parentCode: _sel2!['code'] as String?) : null,
          )),
        ])),
        // Breadcrumb info
        if (_selectedGroup != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary.withOpacity(0.2))),
          child: Row(children: [
            const Icon(Icons.info_outline, size: 14, color: AppTheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text('Creating Level $_newLevel account under: ${_sel3?['name'] ?? _sel2?['name'] ?? _sel1?['name'] ?? _selectedGroup}', style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600))),
          ]),
        )),
        // ── Account Details ───────────────────────────────────────
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Account Details', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
          const SizedBox(height: 14),
          _FieldLabel('Account Name *'),
          TextField(controller: _nameCtrl, decoration: _inputDec('e.g. Petty Cash Fund'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          _FieldLabel('Account Type *'),
          DropdownButtonFormField<String>(
            value: _accountType,
            decoration: _inputDec('Select Account Type'),
            items: _accountTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
            onChanged: (v) => setState(() => _accountType = v),
          ),
          const SizedBox(height: 6),
          Row(children: [const Icon(Icons.auto_awesome, size: 12, color: AppTheme.textSecondary), const SizedBox(width: 4), Text('Account code will be auto-generated by the system', style: TextStyle(fontSize: 11, color: Colors.grey.shade500))]),
          const SizedBox(height: 16),
          Row(children: [
            ElevatedButton.icon(
              icon: _saving ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.add, size: 16),
              label: const Text('Add Account'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11)),
              onPressed: _canSubmit && !_saving ? _submit : null,
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _resetForm, child: const Text('Reset')),
          ]),
        ])),
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

class _LevelHeader extends StatelessWidget {
  final String label;
  final bool enabled, expanded;
  final VoidCallback? onToggle;
  const _LevelHeader({required this.label, required this.enabled, required this.expanded, this.onToggle});
  @override Widget build(BuildContext context) => InkWell(onTap: onToggle, borderRadius: BorderRadius.circular(4), child: Row(children: [
    Container(padding: const EdgeInsets.all(3), decoration: BoxDecoration(color: enabled ? (expanded ? AppTheme.primary.withOpacity(0.1) : AppTheme.background) : Colors.grey.shade100, borderRadius: BorderRadius.circular(4), border: Border.all(color: enabled ? AppTheme.border : Colors.grey.shade200)),
      child: Icon(expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right, size: 15, color: enabled ? (expanded ? AppTheme.primary : AppTheme.textSecondary) : Colors.grey.shade400)),
    const SizedBox(width: 8),
    Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: enabled ? AppTheme.textPrimary : Colors.grey.shade400)),
  ]));
}

// Dropdown that also has "➕ Add new..." at the bottom
class _LevelDropdown extends StatelessWidget {
  final String hint;
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic>? value;
  final ValueChanged<Map<String, dynamic>?> onSelect;
  final VoidCallback? onAddNew;
  const _LevelDropdown({required this.hint, required this.items, this.value, required this.onSelect, this.onAddNew});

  @override Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value?['id'] as String?,
      decoration: _inputDec(hint),
      items: [
        const DropdownMenuItem(value: '__none__', child: Text('— None (create here) —', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
        ...items.map((a) => DropdownMenuItem(value: a['id'] as String, child: Text('${a['code'] != null ? '${a['code']} — ' : ''}${a['name']}', overflow: TextOverflow.ellipsis))),
        if (onAddNew != null) const DropdownMenuItem(value: '__new__', child: Row(children: [Icon(Icons.add_circle_outline, size: 14, color: AppTheme.primary), SizedBox(width: 6), Text('Create new level...', style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 13))])),
      ],
      onChanged: (v) {
        if (v == '__new__') { onAddNew?.call(); return; }
        if (v == '__none__' || v == null) { onSelect(null); return; }
        final acc = items.firstWhere((a) => a['id'] == v, orElse: () => {});
        onSelect(acc.isNotEmpty ? acc : null);
      },
    );
  }
}
