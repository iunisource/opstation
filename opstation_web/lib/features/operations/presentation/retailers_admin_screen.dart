// ignore_for_file: avoid_web_libraries_in_flutter
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Admin "Retailers" screen (Operations). Search a customer, create a retailer
/// login for them (calls the provision-retailer Edge Function), and toggle
/// whether they may share their location. A retailer is a single users row
/// with role='retailer' linked to the customer — created once, here.
class RetailersAdminScreen extends ConsumerStatefulWidget {
  const RetailersAdminScreen({super.key});
  @override
  ConsumerState<RetailersAdminScreen> createState() => _RetailersAdminScreenState();
}

class _RetailersAdminScreenState extends ConsumerState<RetailersAdminScreen> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;
  List<Map<String, dynamic>> _results = [];
  // customer_id -> existing retailer login row (email, etc.)
  final Map<String, Map<String, dynamic>> _logins = {};

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  /// Preload customers that already have a retailer login, so the screen
  /// opens showing existing accounts rather than a blank search.
  Future<void> _loadExisting() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _searching = true);
    try {
      final client = Supabase.instance.client;
      final loginRows = await client
          .from('users')
          .select('id, customer_id, email, password_temporary, is_active')
          .eq('org_id', orgId)
          .eq('role', 'retailer');
      final logins = <String, Map<String, dynamic>>{};
      final ids = <String>[];
      for (final l in loginRows as List) {
        final cid = l['customer_id'] as String?;
        if (cid == null) continue;
        logins[cid] = Map<String, dynamic>.from(l);
        ids.add(cid);
      }
      var results = <Map<String, dynamic>>[];
      if (ids.isNotEmpty) {
        final rows = await client
            .from('customers')
            .select('id, shop_name, code, phone, location_capture_allowed')
            .inFilter('id', ids)
            .order('shop_name');
        results = List<Map<String, dynamic>>.from(rows);
      }
      if (!mounted) return;
      setState(() {
        _logins
          ..clear()
          ..addAll(logins);
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _search() async {
    final orgId = _orgId;
    final q = _searchCtrl.text.trim();
    if (orgId == null || q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('customers')
          .select('id, shop_name, code, phone, location_capture_allowed')
          .eq('org_id', orgId)
          .or('shop_name.ilike.%$q%,code.ilike.%$q%')
          .limit(25);
      final results = List<Map<String, dynamic>>.from(rows);
      final ids = [for (final c in results) c['id'] as String];

      _logins.clear();
      if (ids.isNotEmpty) {
        final loginRows = await client
            .from('users')
            .select('id, customer_id, email, password_temporary, is_active')
            .inFilter('customer_id', ids)
            .eq('role', 'retailer');
        for (final l in loginRows as List) {
          _logins[l['customer_id'] as String] = Map<String, dynamic>.from(l);
        }
      }
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      setState(() => _searching = false);
      _snack('Search error: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _provision(Map<String, dynamic> c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create retailer login'),
        content: Text(
            'Create a portal/app login for "${c['shop_name']}" (code ${c['code']})?\n\n'
            'Default password is their code; they will be asked to change it on first login.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await Supabase.instance.client.functions
          .invoke('provision-retailer', body: {'customerId': c['id']});
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : null;
      if (data == null || data['error'] != null) {
        _snack('Could not create login: ${data?['error'] ?? 'unknown error'}');
        return;
      }
      await _showCredentials(c, data);
      _search(); // refresh login status
    } on FunctionException catch (e) {
      final detail = e.details is Map ? (e.details as Map)['error'] : e.details;
      _snack('Could not create login: ${detail ?? e.reasonPhrase ?? 'failed'}');
    } catch (e) {
      _snack('Could not create login: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _showCredentials(Map<String, dynamic> c, Map<String, dynamic> data) async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Login created'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${c['shop_name']} can now sign in to the retailer portal.'),
            const SizedBox(height: 12),
            _credRow('Login code', '${data['loginCode'] ?? c['code']}'),
            _credRow('Temp password', '${data['tempPassword'] ?? c['code']}'),
            const SizedBox(height: 8),
            const Text('They will be prompted to set a new password on first login.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
        ),
        actions: [
          ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }

  Widget _credRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(
              width: 120,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          Expanded(
              child: SelectableText(value,
                  style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );

  /// Block / unblock a retailer's portal login.
  ///
  /// Flips users.is_active, which auth_controller already enforces at sign-in —
  /// so this genuinely locks them out, it is not a cosmetic badge. Reversible:
  /// the user row, its customer link and history all survive, and the toggle
  /// flips straight back. Supabase's own auth.users (banned_until / deleted_at)
  /// is deliberately left alone; is_active on public.users is the layer this
  /// app reads.
  Future<void> _toggleLogin(Map<String, dynamic> c, Map<String, dynamic> login, bool val) async {
    final userId = login['id'] as String?;
    if (userId == null) {
      _snack('Cannot update: login record has no id');
      return;
    }
    // Blocking locks a real person out of the portal — confirm it. Unblocking
    // is harmless, so it goes through without a prompt.
    if (!val) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Block login'),
          content: Text(
              '"${c['shop_name']}" will no longer be able to sign in to the retailer portal.\n\n'
              'Their account and history are kept — you can re-enable the login at any time.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Block login'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final prev = login['is_active'] == true;
    setState(() => login['is_active'] = val); // optimistic
    try {
      await Supabase.instance.client
          .from('users')
          .update({'is_active': val}).eq('id', userId);
      _snack(val ? 'Login enabled' : 'Login blocked');
    } catch (e) {
      setState(() => login['is_active'] = prev); // roll back on failure
      _snack('Could not update: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _toggleLocation(Map<String, dynamic> c, bool val) async {
    final prev = c['location_capture_allowed'] == true;
    setState(() => c['location_capture_allowed'] = val); // optimistic
    try {
      await Supabase.instance.client
          .from('customers')
          .update({'location_capture_allowed': val}).eq('id', c['id']);
    } catch (e) {
      setState(() => c['location_capture_allowed'] = prev);
      _snack('Could not update: ${e.toString().split('\n').first}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserProvider)?.role;
    final canProvision =
        role == WebUserRole.masterAdmin || role == WebUserRole.superAdmin;

    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Retailer Accounts',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
              'Give a customer a portal/app login, block or re-enable it, and control whether they can share their location.',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          if (!canProvision) ...[
            const SizedBox(height: 8),
            const Text(
                'Note: creating logins requires a master-admin account.',
                style: TextStyle(fontSize: 12, color: AppTheme.warning)),
          ],
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search a customer by shop name or code',
                filled: true,
                fillColor: Colors.white,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                    : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
              ),
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _results.isEmpty
                ? const Center(
                    child: Text('No retailer accounts yet. Search for a customer to create one.',
                        style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final c = _results[i];
                      final login = _logins[c['id']];
                      final hasLogin = login != null;
                      final loginOn = hasLogin && login['is_active'] == true;
                      final blocked = hasLogin && !loginOn;
                      final locOn = c['location_capture_allowed'] == true;
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppTheme.border),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(c['shop_name'] as String? ?? '',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    c['code'] as String? ?? '',
                                    if (blocked)
                                      'Login blocked'
                                    else if (hasLogin)
                                      'Login active'
                                    else
                                      'No login',
                                  ].join('  •  '),
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: blocked ? FontWeight.w700 : FontWeight.w400,
                                      color: blocked
                                          ? AppTheme.danger
                                          : hasLogin
                                              ? AppTheme.success
                                              : AppTheme.textSecondary),
                                ),
                              ],
                            ),
                          ),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Text('Location',
                                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                            Switch(
                              value: locOn,
                              onChanged: (v) => _toggleLocation(c, v),
                            ),
                          ]),
                          const SizedBox(width: 12),
                          if (hasLogin)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('Login',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: blocked ? FontWeight.w700 : FontWeight.w400,
                                      color: blocked ? AppTheme.danger : AppTheme.textSecondary)),
                              Switch(
                                value: loginOn,
                                activeColor: AppTheme.success,
                                onChanged: canProvision
                                    ? (v) => _toggleLogin(c, login, v)
                                    : null,
                              ),
                            ])
                          else
                            ElevatedButton.icon(
                              icon: const Icon(Icons.person_add_alt, size: 16),
                              label: const Text('Create login'),
                              onPressed: canProvision ? () => _provision(c) : null,
                            ),
                        ]),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
