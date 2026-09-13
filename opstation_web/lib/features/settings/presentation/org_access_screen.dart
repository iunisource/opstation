import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/search/text_search.dart';
import '../../auth/auth_controller.dart';

/// Account Linking — join a person's separate per-org accounts under ONE login
/// so they can switch orgs without logging out.
///
/// Scope is enforced server-side by the RPCs (linkable_users / link_accounts /
/// unlink_account): a super admin sees & links across ANY orgs; a master admin
/// only within orgs they own. Initial owner consolidation is a super-admin
/// action (a not-yet-linked owner can't prove they own their other orgs).
class OrgAccessScreen extends ConsumerStatefulWidget {
  const OrgAccessScreen({super.key});
  @override
  ConsumerState<OrgAccessScreen> createState() => _OrgAccessScreenState();
}

class _Row {
  final String email, name, role, orgId, orgName, accountId, userId;
  final bool isHome;
  _Row(this.email, this.name, this.role, this.orgId, this.orgName, this.accountId,
      {this.userId = '', this.isHome = false});
}

class _OrgAccessScreenState extends ConsumerState<OrgAccessScreen> {
  bool _loading = true;
  String? _error;
  List<_Row> _rows = [];
  List<Map<String, dynamic>> _ownedOrgs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = Supabase.instance.client;
      final res = await client.rpc('linkable_users');
      final rows = List<Map<String, dynamic>>.from(res as List? ?? const [])
          .map((m) => _Row(
                (m['email'] as String?) ?? '',
                (m['name'] as String?) ?? '',
                (m['role'] as String?) ?? '',
                (m['org_id'] as String?) ?? '',
                (m['org_name'] as String?) ?? '',
                (m['account_id'] as String?) ?? '',
                userId: (m['user_id'] as String?) ?? '',
                isHome: (m['is_home'] as bool?) ?? false,
              ))
          .toList();
      List<Map<String, dynamic>> owned = const [];
      try {
        final o = await client.rpc('my_owned_orgs');
        owned = List<Map<String, dynamic>>.from(o as List? ?? const []);
      } catch (_) {}
      if (!mounted) return;
      setState(() { _rows = rows; _ownedOrgs = owned; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString().split('\n').first; _loading = false; });
    }
  }

  Future<void> _generateFlow() async {
    if (_ownedOrgs.isEmpty) return;
    Map<String, dynamic>? org = _ownedOrgs.first;
    if (_ownedOrgs.length > 1) {
      org = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Generate a join code for…'),
          children: [
            for (final o in _ownedOrgs)
              SimpleDialogOption(
                onPressed: () => Navigator.of(c).pop(o),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    const Icon(Icons.apartment_rounded, size: 18, color: AppTheme.primary),
                    const SizedBox(width: 10),
                    Text((o['org_name'] as String?) ?? 'Organization',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
          ],
        ),
      );
    }
    if (org == null) return;
    try {
      final res = await Supabase.instance.client.rpc('generate_org_join_code',
          params: {'p_org': org['org_id']});
      final row = (res is List && res.isNotEmpty)
          ? Map<String, dynamic>.from(res.first as Map)
          : <String, dynamic>{};
      final code = (row['code'] as String?) ?? '';
      if (!mounted || code.isEmpty) { _snack('Could not generate a code.'); return; }
      await _showCodeDialog(code, (org['org_name'] as String?) ?? 'your organization');
    } catch (e) {
      _snack('Could not generate code: ${e.toString().replaceFirst('Exception: ', '').split('\n').first}');
    }
  }

  Future<void> _showCodeDialog(String code, String orgName) {
    return showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Join code'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Share this code with the person you want to add to $orgName. '
                'They open “Join an organization” from the org menu and enter it.',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
              ),
              alignment: Alignment.center,
              child: Text(code,
                  style: const TextStyle(
                      fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 10,
                      color: AppTheme.primary)),
            ),
            const SizedBox(height: 10),
            const Text('Single use · expires in 15 minutes · adds them as admin',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              _snack('Code copied');
            },
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(c).pop(),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Map<String, List<_Row>> get _byAccount {
    final m = <String, List<_Row>>{};
    for (final r in _rows) { (m[r.accountId] ??= []).add(r); }
    return m;
  }

  Future<void> _unlink(String email) async {
    try {
      await Supabase.instance.client.rpc('unlink_account', params: {'p_email': email});
      await _load();
      _snack('Unlinked $email');
    } catch (e) { _snack('Unlink failed: $e'); }
  }

  Future<void> _linkFlow() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _LinkDialog(rows: _rows),
    );
    if (done == true) await _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final groups = _byAccount;
    final linked = groups.entries.where((e) => e.value.length > 1).toList()
      ..sort((a, b) => a.value.first.name.toLowerCase().compareTo(b.value.first.name.toLowerCase()));
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Account Linking',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Refresh'),
            onPressed: _load,
          ),
          const SizedBox(width: 8),
          if (_ownedOrgs.isNotEmpty) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.vpn_key_outlined, size: 18),
              label: const Text('Generate join code'),
              onPressed: _generateFlow,
            ),
            const SizedBox(width: 8),
          ],
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary),
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Link accounts'),
            onPressed: _rows.isEmpty ? null : _linkFlow,
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
            'Join a person’s separate per-org accounts under one login so they can switch '
            'organizations without logging out. You can only link accounts in organizations you manage.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Failed to load: $_error',
                      style: const TextStyle(color: AppTheme.danger)))
                  : ListView(children: [
                      Text('Linked logins (${linked.length})',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      if (linked.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('No multi-org logins yet. Use “Link accounts” to create one.',
                              style: TextStyle(color: AppTheme.textSecondary)),
                        ),
                      for (final g in linked) _linkedCard(g.value),
                    ]),
        ),
      ]),
    );
  }

  Widget _linkedCard(List<_Row> members) {
    members.sort((a, b) => a.orgName.toLowerCase().compareTo(b.orgName.toLowerCase()));
    final name = members.first.name;
    final ownedIds = _ownedOrgs.map((o) => o['org_id'] as String).toSet();
    final myEmail = ref.read(currentUserProvider)?.email?.toLowerCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(children: [
            const Icon(Icons.hub_outlined, size: 16, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20)),
              child: Text('${members.length} orgs',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primary)),
            ),
          ]),
        ),
        const Divider(height: 1),
        for (final m in members)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(children: [
              const Icon(Icons.apartment_outlined, size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.orgName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  Text('${m.email} · ${m.role}',
                      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              ),
              if (m.isHome)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: AppTheme.textSecondary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20)),
                  child: const Text('Home',
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
                )
              else if (myEmail != null && m.email.toLowerCase() == myEmail)
                TextButton(
                  onPressed: () => _confirmLeave(m),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.warning),
                  child: const Text('Leave'),
                )
              else if (ownedIds.contains(m.orgId))
                TextButton(
                  onPressed: () => _confirmRemove(m),
                  style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
                  child: const Text('Remove'),
                ),
            ]),
          ),
      ]),
    );
  }

  Future<void> _confirmLeave(_Row m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Leave organization?'),
        content: Text('You will lose access to ${m.orgName} and it will no longer appear in your switcher. Your home organization is unaffected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.warning),
            onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('leave_org', params: {'p_org': m.orgId});
      await _load();
      _snack('Left ${m.orgName}');
    } catch (e) {
      _snack('Could not leave: ${e.toString().replaceFirst('Exception: ', '').split('\n').first}');
    }
  }

  Future<void> _confirmRemove(_Row m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove from organization?'),
        content: Text('${m.name} (${m.email}) will lose access to ${m.orgName}. This removes the seat you invited them into; their home organization is unaffected.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('remove_member',
          params: {'p_account_id': m.accountId, 'p_org': m.orgId});
      await _load();
      _snack('Removed ${m.name} from ${m.orgName}');
    } catch (e) {
      _snack('Could not remove: ${e.toString().replaceFirst('Exception: ', '').split('\n').first}');
    }
  }

  Future<void> _confirmUnlink(String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unlink account?'),
        content: Text('$email will become a separate login again and lose the org switcher.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unlink')),
        ],
      ),
    );
    if (ok == true) await _unlink(email);
  }
}

/// Select the admin accounts (across orgs) that belong to one person, then pick
/// which is the primary login. Admin-tier only (masterAdmin / admin), searchable.
class _LinkDialog extends StatefulWidget {
  final List<_Row> rows;
  const _LinkDialog({required this.rows});
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final Set<String> _selected = {}; // emails to link (incl. primary)
  String? _primaryEmail;
  final _searchCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() { _searchCtrl.dispose(); super.dispose(); }

  // Admin-tier accounts only, de-duplicated by email.
  List<_Row> get _adminRows {
    final seen = <String>{};
    final out = <_Row>[];
    for (final r in widget.rows) {
      if (r.role != 'masterAdmin' && r.role != 'admin') continue;
      if (seen.add(r.email.toLowerCase())) out.add(r);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  List<_Row> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _adminRows;
    return _adminRows
        .where((r) => matchesQuery('${r.name} ${r.email} ${r.orgName} ${r.role}', q))
        .toList();
  }

  Future<void> _submit() async {
    if (_primaryEmail == null) return;
    final others = _selected.where((e) => e != _primaryEmail).toList();
    if (others.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('link_accounts', params: {
        'p_primary_email': _primaryEmail,
        'p_other_emails': others,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$res')));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Link failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the primary valid & default it to the first selected.
    if (_primaryEmail != null && !_selected.contains(_primaryEmail)) _primaryEmail = null;
    if (_primaryEmail == null && _selected.isNotEmpty) {
      _primaryEmail = (_selected.toList()..sort()).first;
    }
    final selectedList = _selected.toList()..sort();
    return AlertDialog(
      title: const Text('Link accounts into one login'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Pick the admin accounts that belong to the same person (across orgs), then choose which one is the primary login.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const SizedBox(height: 8),
          TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
                hintText: 'Search admin by name / email / org…',
                prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 240,
            child: _filtered.isEmpty
                ? const Center(child: Text('No matching admins', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView(children: [
                    for (final r in _filtered)
                      CheckboxListTile(
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _selected.contains(r.email),
                        onChanged: (v) => setState(() {
                          if (v == true) _selected.add(r.email); else _selected.remove(r.email);
                        }),
                        title: Text('${r.name} — ${r.orgName}', style: const TextStyle(fontSize: 13)),
                        subtitle: Text('${r.email} · ${r.role}',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      ),
                  ]),
          ),
          const SizedBox(height: 10),
          if (_selected.length >= 2) ...[
            const Text('Primary login (the main one — every linked email still works):',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _primaryEmail,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
              items: [for (final e in selectedList) DropdownMenuItem(value: e, child: Text(e, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _primaryEmail = v),
            ),
          ] else
            Text('Selected ${_selected.length} — pick at least 2 accounts to link.',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: (_busy || _selected.length < 2 || _primaryEmail == null) ? null : _submit,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('Link ${_selected.length} accounts'),
        ),
      ],
    );
  }
}
