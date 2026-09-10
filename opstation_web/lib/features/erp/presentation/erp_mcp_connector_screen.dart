import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// AI Connector — generate/revoke the per-org token that connects this
/// organization's Opstation data (read-only) to ChatGPT and Claude as a remote
/// MCP connector. The raw token is shown once, inside the ready-to-paste URL.
class ErpMcpConnectorScreen extends ConsumerStatefulWidget {
  const ErpMcpConnectorScreen({super.key});
  @override
  ConsumerState<ErpMcpConnectorScreen> createState() => _ErpMcpConnectorScreenState();
}

class _ErpMcpConnectorScreenState extends ConsumerState<ErpMcpConnectorScreen> {
  static const _base =
      'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/erp-mcp/';
  // The single public connector URL. Everyone adds this same URL and signs in
  // with their Opstation account; their login decides which company is read.
  static const _connectorUrl =
      'https://xgptodkasmytddmdnbtb.supabase.co/functions/v1/erp-mcp';

  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _tokens = [];

  // Freshly-created key is shown INLINE (not in a second dialog — nested dialogs
  // on the web canvas were blanking the app). Cleared when dismissed.
  String? _newUrl;
  String? _newName;
  final TextEditingController _newUrlCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController(); // inline key name

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _userId => ref.read(currentUserProvider)?.id;

  @override
  void dispose() {
    _newUrlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() => _loading = false); return; }
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('mcp_list_tokens', params: {'p_org': orgId});
      setState(() { _tokens = List<Map<String, dynamic>>.from(res as List); _loading = false; });
    } catch (e) {
      setState(() => _loading = false);
      _snack(friendlyError('Could not load connectors', e));
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    // Name comes from the inline field in the header — no dialog (a dialog with
    // an autofocus field was blanking the web canvas).
    final name = _nameCtrl.text.trim();
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('mcp_create_token',
          params: {'p_org': _orgId, 'p_name': name, 'p_user': _userId});
      // The RPC returns a table row; accept either a list-of-rows or a single
      // map, and read the raw token defensively so a shape surprise can never
      // crash the screen.
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty && res.first is Map) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res as Map);
      }
      final raw = row?['raw_token']?.toString();
      await _load();
      if (!mounted) return;
      if (raw == null || raw.isEmpty) {
        _snack('Key created, but the token could not be read back. It is listed below — revoke it and create a new one.');
      } else {
        // Show the URL inline at the top of the page (no second dialog).
        setState(() {
          _newName = name.isEmpty ? 'Connector key' : name;
          _newUrl = '$_base$raw';
          _newUrlCtrl.text = _newUrl!;
          _nameCtrl.clear();
        });
      }
    } catch (e) {
      _snack(friendlyError('Could not create the key', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> t) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Revoke this key?'),
      content: Text('Revoking "${t['name'] ?? t['token_prefix']}" immediately disconnects any ChatGPT/Claude using it. This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: () => Navigator.pop(context, true), child: const Text('Revoke')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('mcp_revoke_token', params: {'p_id': t['id'], 'p_org': _orgId});
      await _load();
      _snack('Key revoked');
    } catch (e) { _snack(friendlyError('Could not revoke', e)); }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('AI Connector', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          SizedBox(width: 220, child: TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Key name (optional)', isDense: true, border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
            onSubmitted: (_) { if (!_busy) _create(); },
          )),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _busy ? null : _create,
            icon: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add, size: 18),
            label: const Text('Create key')),
        ]),
        const SizedBox(height: 4),
        const Text('Connect your data (read-only) to ChatGPT and Claude. '
            'Add the one connector URL below, sign in with your Opstation account, then '
            'ask about your stock, balances, sales and more — in plain language.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 20),
        Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_newUrl != null) ...[
            _newKeyBanner(),
            const SizedBox(height: 20),
          ],
          _connectorUrlCard(),
          const SizedBox(height: 20),
          _howToCard(),
          const SizedBox(height: 20),
          _keysCard(),
          const SizedBox(height: 20),
          _safetyCard(),
        ]))),
      ]),
    );
  }

  // Inline result of "New connector key" — shown on the page (no dialog).
  Widget _newKeyBanner() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.success.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.success.withOpacity(0.4)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.check_circle_outline, size: 18, color: AppTheme.success),
          const SizedBox(width: 8),
          Text('Connector key created — ${_newName ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const Spacer(),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() { _newUrl = null; _newName = null; _newUrlCtrl.clear(); }),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Paste this URL into ChatGPT or Claude as a custom connector. '
            'For security it is shown only once — copy it now.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(
            controller: _newUrlCtrl,
            readOnly: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: const InputDecoration(
              isDense: true, border: OutlineInputBorder(),
              contentPadding: EdgeInsets.all(10)),
          )),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _newUrl ?? ''));
              _snack('Connector URL copied');
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
        ]),
      ]),
    );
  }

  Widget _card({required String title, IconData? icon, required Widget child}) => Container(
    width: double.infinity,
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
    padding: const EdgeInsets.all(18),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: AppTheme.primary), const SizedBox(width: 8)],
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ]),
      const SizedBox(height: 12),
      child,
    ]),
  );

  Widget _keysCard() {
    return _card(title: 'Static keys (optional)', icon: Icons.key_outlined, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Most people don\'t need this — just use the Connector URL above and sign in. '
          'Static keys are an alternative for tools that can\'t do the sign-in: each key embeds '
          'access to this company in the URL, so treat it like a password. Create one with the button top-right.',
          style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      _loading
          ? const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          : _tokens.isEmpty
              ? const Text('No static keys.', style: TextStyle(color: AppTheme.textSecondary))
              : Column(children: [
                  for (final t in _tokens) _tokenRow(t),
                ]),
    ]));
  }

  Widget _tokenRow(Map<String, dynamic> t) {
    final revoked = t['revoked'] == true;
    final createdDt = DateTime.tryParse('${t['created_at']}');
    final usedDt = DateTime.tryParse('${t['last_used_at']}');
    final created = createdDt != null ? DateFormat('d MMM yyyy').format(createdDt.toLocal()) : '';
    final used = usedDt != null ? DateFormat('d MMM yyyy HH:mm').format(usedDt.toLocal()) : 'never used';
    return Opacity(
      opacity: revoked ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(revoked ? Icons.key_off_outlined : Icons.vpn_key_outlined, size: 18,
              color: revoked ? AppTheme.textSecondary : AppTheme.success),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(t['name'] as String? ?? '(unnamed)', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('${t['token_prefix']}…', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: AppTheme.textSecondary)),
              if (revoked) ...[
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
                  child: const Text('Revoked', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.danger))),
              ],
            ]),
            const SizedBox(height: 2),
            Text('Created $created · $used', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ])),
          if (!revoked)
            TextButton(onPressed: () => _revoke(t), child: const Text('Revoke', style: TextStyle(color: AppTheme.danger))),
        ]),
      ),
    );
  }

  Widget _step(String n, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 20, height: 20, alignment: Alignment.center,
        decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
        child: Text(n, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700))),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
    ]),
  );

  Widget _connectorUrlCard() {
    return _card(title: 'Connector URL', icon: Icons.link_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Add this one URL in ChatGPT or Claude, then sign in with your Opstation '
            'account — your login decides which company the assistant can read.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.border)),
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
          child: Row(children: [
            const Expanded(child: Text(_connectorUrl,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13))),
            IconButton(
              tooltip: 'Copy connector URL',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: _connectorUrl));
                _snack('Connector URL copied');
              },
            ),
          ]),
        ),
      ]));
  }

  Widget _howToCard() {
    return _card(title: 'How to connect', icon: Icons.help_outline, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Claude (Pro/Team/Enterprise)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      const SizedBox(height: 8),
      _step('1', 'In Claude, open Settings → Connectors → Add custom connector.'),
      _step('2', 'Paste the Connector URL above, name it "Opstation", and add it.'),
      _step('3', 'Claude detects that sign-in is required — click Connect, then sign in with your Opstation email and password on the Opstation card.'),
      _step('4', 'Back in a chat, turn on the Opstation connector and ask e.g. "What\'s my top overdue customer?"'),
      const SizedBox(height: 16),
      const Text('ChatGPT (Plus/Pro/Business, Developer Mode)', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      const SizedBox(height: 8),
      _step('1', 'In ChatGPT, Settings → Connectors (or Apps) → enable Developer Mode → Add / Create.'),
      _step('2', 'Choose MCP server, paste the same Connector URL, and set Authentication to "OAuth".'),
      _step('3', 'Click Create, then Connect and sign in with your Opstation account.'),
      _step('4', 'Start a chat with the connector on and ask about your stock, balances or sales.'),
      const SizedBox(height: 6),
      const Text('You never type a token or key — signing in with your Opstation account is what authorizes it. '
          'The exact menu names shift as both apps evolve; look for "custom connector" or "MCP server".',
          style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary, fontStyle: FontStyle.italic)),
    ]));
  }

  Widget _safetyCard() {
    return _card(title: 'What it can and can\'t do', icon: Icons.shield_outlined, child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('• Read-only. It can look up stock, customer & supplier balances, aging, and business summaries — it cannot create, edit, post or delete anything.',
          style: TextStyle(fontSize: 13, height: 1.5)),
      Text('• Sign-in required. The connector URL is public, but it exposes nothing until someone signs in with an Opstation account.',
          style: TextStyle(fontSize: 13, height: 1.5)),
      Text('• Scoped by login. Each person only ever sees the company their own Opstation account belongs to.',
          style: TextStyle(fontSize: 13, height: 1.5)),
      Text('• Static keys (if used) embed access in the URL — treat those like a password and revoke them the moment they\'re no longer needed.',
          style: TextStyle(fontSize: 13, height: 1.5)),
    ]));
  }
}
