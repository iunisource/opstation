import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Definition of a single org-level admin toggle.
/// To add a new setting, append one entry to [_toggles] below — the screen
/// renders, loads, and persists it automatically. Each value is stored in
/// `app_config` as the string 'true'/'false' under [key] (org-scoped,
/// branch_id NULL), matching the existing app_config convention.
class _AdminToggle {
  final String key; // app_config key, e.g. 'org.credit_limit_alert'
  final String title;
  final String subtitle;
  const _AdminToggle(this.key, this.title, this.subtitle);
}

const List<_AdminToggle> _toggles = [
  _AdminToggle(
    'org.credit_limit_alert',
    'Credit limit alert on Delivery Order',
    'When a Delivery Order is created for a customer whose outstanding balance '
        'exceeds their credit limit, show an alert with the limit details. '
        'The user can override and proceed.',
  ),

  // ─── Add more org-level toggles here ─────────────────────────────────────
  // _AdminToggle('org.some_flag', 'Title shown to admin', 'What it does.'),
];

class ErpAdminSettingsScreen extends ConsumerStatefulWidget {
  const ErpAdminSettingsScreen({super.key});

  @override
  ConsumerState<ErpAdminSettingsScreen> createState() =>
      _ErpAdminSettingsScreenState();
}

class _ErpAdminSettingsScreenState
    extends ConsumerState<ErpAdminSettingsScreen> {
  final Map<String, bool> _values = {};
  final Set<String> _saving = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId);
      final cfg = <String, String>{};
      for (final r in rows as List) {
        cfg[r['key'] as String] = r['value'] as String? ?? '';
      }
      setState(() {
        for (final t in _toggles) {
          _values[t.key] = cfg[t.key] == 'true';
        }
        _loading = false;
      });
    } catch (_) {
      setState(() {
        for (final t in _toggles) {
          _values[t.key] = false;
        }
        _loading = false;
      });
    }
  }

  Future<void> _setToggle(String key, bool val) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() {
      _values[key] = val;
      _saving.add(key);
    });
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': key,
        'value': val.toString(),
        'org_id': orgId,
      }, onConflict: 'key,org_id,branch_id');
    } catch (e) {
      if (mounted) {
        setState(() => _values[key] = !val); // revert on failure
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Admin Settings',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text(
                    'Organization-wide toggles. Changes apply to all branches and save immediately.',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 760),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < _toggles.length; i++) ...[
                          if (i > 0)
                            const Divider(height: 1, color: AppTheme.border),
                          SwitchListTile(
                            activeColor: AppTheme.primary,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(_toggles[i].title,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                ),
                                if (_saving.contains(_toggles[i].key)) ...[
                                  const SizedBox(width: 10),
                                  const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                ],
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(_toggles[i].subtitle,
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppTheme.textSecondary,
                                      height: 1.35)),
                            ),
                            value: _values[_toggles[i].key] ?? false,
                            onChanged: (v) => _setToggle(_toggles[i].key, v),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
