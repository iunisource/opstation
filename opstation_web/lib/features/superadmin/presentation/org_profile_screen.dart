import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/modules/app_modules.dart';
import '../../../core/theme/app_theme.dart';
import 'orgs_screen.dart' show showOrgModulesDialog;
import 'storage_usage_widgets.dart';

/// Super Admin → Organizations → one org's profile.
/// Shows how the org USES Opstation — engagement, activity rhythm, module
/// adoption, people, setup, storage — and never its business figures
/// (no sales, purchases, customers or stock). Data: org_profile_summary
/// (SQL 354) + the Storage panel (SQL 350–352).
class OrgProfileScreen extends StatefulWidget {
  final String orgId;
  const OrgProfileScreen({super.key, required this.orgId});
  @override
  State<OrgProfileScreen> createState() => _OrgProfileScreenState();
}

class _OrgProfileScreenState extends State<OrgProfileScreen> {
  Map<String, dynamic>? _d;
  String? _err;
  bool _loading = true;
  final _date = DateFormat('d MMM y');
  final _dateTime = DateFormat('d MMM y, h:mm a');

  static const _ink = Color(0xFF0F172A);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final r = await Supabase.instance.client.rpc('org_profile_summary', params: {'p_org': widget.orgId});
      if (!mounted) return;
      setState(() { _d = r == null ? null : Map<String, dynamic>.from(r as Map); _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _err = e.toString().contains('org_profile_summary')
            ? 'Run SQL 354 in Supabase first.'
            : 'Could not load: ${e.toString().split('\n').first}';
      });
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────
  DateTime? _dt(dynamic v) => DateTime.tryParse('${v ?? ''}')?.toLocal();

  String _ago(DateTime? d) {
    if (d == null) return 'never';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    return _date.format(d);
  }

  Color _recency(DateTime? d) {
    if (d == null) return const Color(0xFFCBD5E1);
    final h = DateTime.now().difference(d).inHours;
    if (h < 24) return const Color(0xFF22C55E);
    if (h < 24 * 7) return const Color(0xFFF59E0B);
    return const Color(0xFF94A3B8);
  }

  String _roleLabel(String? r) => switch (r) {
        'masterAdmin' => 'Master admin',
        'admin' => 'Admin',
        'superAdmin' => 'Super admin',
        'erpUser' => 'ERP user',
        'accountant' => 'Accountant',
        'dispatchManager' => 'Dispatch manager',
        'salesperson' => 'Salesperson',
        'driver' => 'Driver',
        'retailer' => 'Retailer',
        null => '—',
        final String other => other,
      };

  List<Map> get _users => ((_d?['users'] as List?) ?? const []).cast<Map>();
  List<Map> get _daily => ((_d?['daily'] as List?) ?? const []).cast<Map>();
  Map<String, bool> get _enabled => {
        for (final m in ((_d?['modules'] as List?) ?? const []).cast<Map>()) '${m['module']}': m['enabled'] == true,
      };
  Map<String, Map> get _usage => {
        for (final m in ((_d?['module_usage'] as List?) ?? const []).cast<Map>()) '${m['module']}': m,
      };

  int get _activeUsers30 => _users.where((u) {
        final d = _dt(u['last_sign_in']);
        return u['active'] != false && d != null && DateTime.now().difference(d).inDays < 30;
      }).length;
  int get _activeUsers7 => _users.where((u) {
        final d = _dt(u['last_sign_in']);
        return u['active'] != false && d != null && DateTime.now().difference(d).inDays < 7;
      }).length;
  int get _seatUsers => _users.where((u) => u['active'] != false).length;
  int get _daysActive => _daily.where((d) => ((d['n'] as num?) ?? 0) > 0).length;
  int get _modulesOn => _enabled.values.where((v) => v).length;
  int get _modulesUsed => _enabled.entries.where((e) {
        if (!e.value) return false;
        final u = _usage[e.key];
        return ((u?['n30'] as num?) ?? 0) > 0;
      }).length;

  /// 0–100: people signing in, working days used, enabled modules in use.
  int get _health {
    final seats = math.max(_seatUsers, 1);
    final people = (_activeUsers30 / seats).clamp(0.0, 1.0);
    final days = (_daysActive / 22).clamp(0.0, 1.0);
    final mods = _modulesOn == 0 ? 0.0 : (_modulesUsed / _modulesOn).clamp(0.0, 1.0);
    return ((people * 0.4 + days * 0.35 + mods * 0.25) * 100).round();
  }

  (String, Color) get _healthLabel {
    final h = _health;
    if (h >= 75) return ('Thriving', const Color(0xFF16A34A));
    if (h >= 50) return ('Healthy', const Color(0xFF2563EB));
    if (h >= 25) return ('Needs attention', const Color(0xFFD97706));
    return ('At risk', const Color(0xFFDC2626));
  }

  // ── build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final narrow = w < 760;
    if (_loading) return const ColoredBox(color: AppTheme.background, child: Center(child: CircularProgressIndicator()));
    if (_err != null || _d == null) {
      return ColoredBox(
        color: AppTheme.background,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_err ?? 'Organization not found', style: const TextStyle(color: AppTheme.danger)),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final pad = narrow ? 12.0 : 28.0;
    return ColoredBox(
      color: AppTheme.background,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(pad, pad, pad, 40),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.go('/orgs'),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Organizations'),
              ),
            ),
            const SizedBox(height: 6),
            _hero(narrow),
            const SizedBox(height: 16),
            _pulseRow(narrow),
            const SizedBox(height: 16),
            if (narrow) ...[
              _activityCard(),
              _modulesCard(narrow),
            ] else
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 3, child: _activityCard()),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _modulesCard(narrow)),
                ]),
              ),
            _peopleCard(narrow),
            if (narrow) ...[
              _setupCard(),
              _subscriptionCard(),
            ] else
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: _setupCard()),
                  const SizedBox(width: 16),
                  Expanded(child: _subscriptionCard()),
                ]),
              ),
            _card(icon: Icons.storage_outlined, title: 'Storage & retention', child: OrgStoragePanel(orgId: widget.orgId)),
          ],
        ),
      ),
    );
  }

  // ── hero ───────────────────────────────────────────────────────────────────
  Widget _hero(bool narrow) {
    final o = Map<String, dynamic>.from((_d!['org'] as Map?) ?? const {});
    final active = o['is_active'] as bool? ?? true;
    final archived = o['archived'] as bool? ?? false;
    final created = _dt(o['created_at']);
    final expires = _dt(o['expires_at']);
    final expired = expires != null && expires.isBefore(DateTime.now());
    final master = _users.cast<Map?>().firstWhere((u) => u?['id'] == o['master_admin_id'], orElse: () => null);
    final name = '${o['name'] ?? ''}';
    final (hLabel, hColor) = _healthLabel;
    final tenure = created == null ? null : DateTime.now().difference(created).inDays;

    Widget pill(String t, {IconData? icon, Color? bg}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg ?? Colors.white.withOpacity(0.16),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 13, color: Colors.white), const SizedBox(width: 5)],
            Text(t, style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
        );

    final ring = SizedBox(
      width: narrow ? 92 : 118,
      height: narrow ? 92 : 118,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: _health / 100,
            strokeWidth: narrow ? 8 : 10,
            backgroundColor: Colors.white.withOpacity(0.18),
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$_health', style: TextStyle(fontSize: narrow ? 24 : 32, fontWeight: FontWeight.w900, color: Colors.white)),
          Text('health', style: TextStyle(fontSize: 10.5, color: Colors.white.withOpacity(0.85))),
        ]),
      ]),
    );

    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: narrow ? 44 : 54,
          height: narrow ? 44 : 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: Text(name.isEmpty ? 'O' : name.substring(0, 1).toUpperCase(),
              style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w900, fontSize: narrow ? 20 : 24)),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: TextStyle(fontSize: narrow ? 20 : 28, fontWeight: FontWeight.w900, color: Colors.white, height: 1.1)),
            const SizedBox(height: 3),
            SelectableText('${o['id']}', style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.75))),
          ]),
        ),
      ]),
      const SizedBox(height: 14),
      Wrap(spacing: 6, runSpacing: 6, children: [
        pill(active ? 'Active' : 'Inactive',
            icon: active ? Icons.check_circle : Icons.block,
            bg: active ? const Color(0xFF16A34A).withOpacity(0.55) : const Color(0xFFDC2626).withOpacity(0.6)),
        pill(hLabel, icon: Icons.favorite, bg: hColor.withOpacity(0.55)),
        if (archived) pill('Archived', icon: Icons.archive_outlined),
        if (tenure != null)
          pill(tenure < 60 ? 'Joined $tenure days ago' : 'Customer since ${DateFormat('MMM y').format(created!)}',
              icon: Icons.celebration_outlined),
        pill(expires == null ? 'No expiry' : (expired ? 'Expired ${_date.format(expires)}' : 'Until ${_date.format(expires)}'),
            icon: Icons.event_outlined, bg: expired ? const Color(0xFFDC2626).withOpacity(0.6) : null),
      ]),
      if (master != null) ...[
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.verified_user_outlined, size: 14, color: Colors.white.withOpacity(0.85)),
          const SizedBox(width: 6),
          Flexible(
            child: Text('${master['name']} · ${master['email']}',
                style: TextStyle(fontSize: 12.5, color: Colors.white.withOpacity(0.9)), overflow: TextOverflow.ellipsis),
          ),
        ]),
      ],
    ]);

    return Container(
      padding: EdgeInsets.all(narrow ? 16 : 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primary, Color.lerp(AppTheme.primary, _ink, 0.55)!],
        ),
        boxShadow: [BoxShadow(color: AppTheme.primary.withOpacity(0.25), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(children: [
        Positioned(
          right: -40,
          top: -40,
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.06)),
          ),
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: info),
          const SizedBox(width: 16),
          Column(children: [
            ring,
            const SizedBox(height: 6),
            IconButton(
              onPressed: _load,
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh, color: Colors.white.withOpacity(0.85), size: 18),
            ),
          ]),
        ]),
      ]),
    );
  }

  // ── pulse tiles ────────────────────────────────────────────────────────────
  Widget _pulseRow(bool narrow) {
    final o = Map<String, dynamic>.from((_d!['org'] as Map?) ?? const {});
    final maxUsers = o['max_users'] as int?;
    final last = _dt(_d!['last_activity']);
    final tiles = [
      _pulse(Icons.bolt, 'Last activity', _ago(last), _recency(last),
          sub: last == null ? 'No activity in 90 days' : _dateTime.format(last)),
      _pulse(Icons.people_alt_outlined, 'Active this week', '$_activeUsers7 of $_seatUsers', const Color(0xFF8B5CF6),
          sub: '$_activeUsers30 signed in this month'),
      _pulse(Icons.calendar_month_outlined, 'Days active', '$_daysActive / 30', const Color(0xFF0EA5E9),
          sub: 'days with any activity'),
      _pulse(Icons.extension_outlined, 'Modules in use', '$_modulesUsed of $_modulesOn', const Color(0xFF14B8A6),
          sub: 'enabled modules used in 30 days'),
      _pulse(Icons.event_seat_outlined, 'Seats', maxUsers == null ? '$_seatUsers' : '$_seatUsers / $maxUsers',
          maxUsers != null && _seatUsers >= maxUsers ? AppTheme.danger : const Color(0xFFF97316),
          sub: maxUsers == null ? 'no user limit' : (_seatUsers >= maxUsers ? 'limit reached' : '${maxUsers - _seatUsers} free')),
    ];
    return LayoutBuilder(builder: (_, c) {
      final cols = c.maxWidth > 1000 ? 5 : (c.maxWidth > 640 ? 3 : 2);
      final tileW = (c.maxWidth - (cols - 1) * 12) / cols;
      return Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) SizedBox(width: tileW, child: t)]);
    });
  }

  Widget _pulse(IconData icon, String label, String value, Color color, {String? sub}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              if (sub != null)
                Text(sub, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      );

  // ── cards ──────────────────────────────────────────────────────────────────
  Widget _card({required IconData icon, required String title, required Widget child, Widget? action, String? sub}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: AppTheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: _ink)),
                if (sub != null) Text(sub, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              ]),
            ),
            if (action != null) action,
          ]),
          const SizedBox(height: 14),
          child,
        ]),
      );

  Widget _activityCard() {
    final days = _daily;
    final maxN = days.fold<num>(0, (m, d) => math.max(m, (d['n'] as num?) ?? 0));
    final today = DateTime.now();
    return _card(
      icon: Icons.insights_outlined,
      title: 'Activity rhythm',
      sub: 'How busy the workspace was each day — last 30 days',
      child: days.isEmpty
          ? const Text('No activity recorded yet.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                height: 120,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final d in days)
                    Expanded(
                      child: Tooltip(
                        message: DateFormat('EEE d MMM').format(DateTime.parse('${d['day']}')) +
                            (((d['n'] as num?) ?? 0) == 0 ? ' · no activity' : ' · active'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: _bar(((d['n'] as num?) ?? 0).toDouble(), maxN.toDouble(),
                              DateTime.parse('${d['day']}').weekday == DateTime.sunday),
                        ),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 6),
              Row(children: [
                Text(DateFormat('d MMM').format(today.subtract(const Duration(days: 29))),
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
                const Spacer(),
                const Text('Today', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 14, runSpacing: 4, children: [
                _legend(AppTheme.primary, 'Working day'),
                _legend(const Color(0xFFA5B4FC), 'Sunday'),
                _legend(const Color(0xFFE2E8F0), 'Quiet'),
              ]),
            ]),
    );
  }

  Widget _bar(double n, double max, bool sunday) {
    final h = n <= 0 || max <= 0 ? 0.04 : (0.15 + 0.85 * math.sqrt(n / max)); // sqrt: keeps quiet days visible
    return FractionallySizedBox(
      heightFactor: h,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          gradient: n <= 0
              ? null
              : LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: sunday
                      ? const [Color(0xFFA5B4FC), Color(0xFFC7D2FE)]
                      : [AppTheme.primary, AppTheme.primary.withOpacity(0.6)],
                ),
          color: n <= 0 ? const Color(0xFFE2E8F0) : null,
        ),
      ),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 5),
        Text(t, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
      ]);

  Widget _modulesCard(bool narrow) {
    final enabled = _enabled;
    final usage = _usage;
    final total30 = usage.values.fold<num>(0, (s, m) => s + ((m['n30'] as num?) ?? 0));
    final name = '${(_d!['org'] as Map?)?['name'] ?? ''}';
    final mods = [...kAppModules]..sort((a, b) {
        int rank(AppModule m) => enabled[m.key] == true ? (((usage[m.key]?['n30'] as num?) ?? 0) > 0 ? 0 : 1) : 2;
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return ((usage[b.key]?['n30'] as num?) ?? 0).compareTo((usage[a.key]?['n30'] as num?) ?? 0);
      });
    return _card(
      icon: Icons.extension_outlined,
      title: 'Module adoption',
      sub: 'Share of activity in the last 30 days',
      action: TextButton(
        onPressed: () async {
          await showOrgModulesDialog(context, widget.orgId, name);
          _load();
        },
        child: const Text('Manage'),
      ),
      child: Column(children: [
        for (final m in mods)
          Builder(builder: (_) {
            final on = enabled[m.key] == true;
            final u = usage[m.key];
            final n30 = ((u?['n30'] as num?) ?? 0).toDouble();
            final share = total30 <= 0 ? 0.0 : n30 / total30;
            final last = _dt(u?['last_at']);
            final idle = on && n30 == 0;
            final color = !on ? const Color(0xFFCBD5E1) : (idle ? const Color(0xFFF59E0B) : AppTheme.primary);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(8)),
                  child: Icon(m.icon, size: 16, color: on ? color : AppTheme.textSecondary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(m.label,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: on ? _ink : AppTheme.textSecondary)),
                      ),
                      Text(
                        !on ? 'Off' : (idle ? (last == null ? 'Not used yet' : 'Idle · ${_ago(last)}') : _ago(last)),
                        style: TextStyle(fontSize: 10.5, color: idle ? const Color(0xFFB45309) : AppTheme.textSecondary),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: on ? math.max(share, n30 > 0 ? 0.03 : 0.0) : 0.0,
                        minHeight: 6,
                        backgroundColor: const Color(0xFFF1F5F9),
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                  ]),
                ),
              ]),
            );
          }),
      ]),
    );
  }

  Widget _peopleCard(bool narrow) {
    final users = _users;
    final roles = <String, int>{};
    for (final u in users.where((u) => u['active'] != false)) {
      final r = _roleLabel(u['role'] as String?);
      roles[r] = (roles[r] ?? 0) + 1;
    }
    return _card(
      icon: Icons.groups_2_outlined,
      title: 'People',
      sub: '${users.where((u) => u['active'] != false).length} active · '
          '${users.where((u) => u['active'] == false).length} deactivated',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final e in roles.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(20)),
              child: Text('${e.key} · ${e.value}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
        ]),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (_, c) {
          final cols = c.maxWidth > 1000 ? 4 : (c.maxWidth > 680 ? 3 : (c.maxWidth > 420 ? 2 : 1));
          final tw = (c.maxWidth - (cols - 1) * 10) / cols;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final u in users) SizedBox(width: tw, child: _personTile(u)),
          ]);
        }),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _legend(const Color(0xFF22C55E), 'Signed in today'),
          _legend(const Color(0xFFF59E0B), 'This week'),
          _legend(const Color(0xFF94A3B8), 'Earlier'),
          _legend(const Color(0xFFCBD5E1), 'Never'),
        ]),
      ]),
    );
  }

  Widget _personTile(Map u) {
    final off = u['active'] == false;
    final last = _dt(u['last_sign_in']);
    final name = '${u['name'] ?? '—'}';
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
    final hue = (name.codeUnits.fold<int>(0, (a, b) => a + b) * 37) % 360;
    final avatarColor = HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.55).toColor();
    return Opacity(
      opacity: off ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border.withOpacity(0.7)),
        ),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: avatarColor.withOpacity(0.18),
              child: Text(initials, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: avatarColor)),
            ),
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: _recency(last),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ]),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      decoration: off ? TextDecoration.lineThrough : null)),
              Text(_roleLabel(u['role'] as String?),
                  style: const TextStyle(fontSize: 10.5, color: AppTheme.primary, fontWeight: FontWeight.w600)),
              Tooltip(
                message: '${u['email'] ?? ''}${last == null ? '' : '\nLast sign-in ${_dateTime.format(last)}'}',
                child: Text(off ? 'Deactivated' : 'Seen ${_ago(last)}',
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _setupCard() {
    final b = ((_d!['branches'] as List?) ?? const []).cast<Map>();
    final real = b.where((x) => x['is_virtual'] != true).toList();
    final virt = b.length - real.length;
    return _card(
      icon: Icons.account_tree_outlined,
      title: 'Setup',
      sub: '${real.length} branch${real.length == 1 ? '' : 'es'}${virt > 0 ? ' · $virt processor / off-site' : ''}',
      child: real.isEmpty
          ? const Text('No branches yet', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : Wrap(spacing: 8, runSpacing: 8, children: [
              for (final x in real)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: x['is_active'] == false ? const Color(0xFFF1F5F9) : AppTheme.primary.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: x['is_active'] == false ? AppTheme.border : AppTheme.primary.withOpacity(0.25)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.storefront_outlined, size: 14,
                        color: x['is_active'] == false ? AppTheme.textSecondary : AppTheme.primary),
                    const SizedBox(width: 6),
                    Text('${x['name']}${x['is_active'] == false ? ' (inactive)' : ''}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
            ]),
    );
  }

  Widget _subscriptionCard() {
    final s = (_d!['subscription'] as Map?);
    const keys = {
      'plan': 'Plan', 'plan_name': 'Plan', 'status': 'Status', 'billing_cycle': 'Billing',
      'seats': 'Seats', 'trial_ends_at': 'Trial ends', 'current_period_end': 'Renews / ends',
      'next_billing_date': 'Next billing', 'started_at': 'Started',
    };
    final rows = <Widget>[];
    if (s != null) {
      for (final e in keys.entries) {
        final v = s[e.key];
        if (v == null || '$v'.isEmpty) continue;
        final d = e.key.endsWith('_at') || e.key.endsWith('_end') || e.key.endsWith('_date') ? _dt(v) : null;
        rows.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            SizedBox(width: 110, child: Text(e.value, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
            Expanded(
              child: Text(d != null ? _date.format(d) : '$v'.replaceAll('_', ' '),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
            ),
          ]),
        ));
      }
    }
    return _card(
      icon: Icons.workspace_premium_outlined,
      title: 'Subscription',
      action: TextButton(onPressed: () => context.go('/subscriptions'), child: const Text('Open')),
      child: rows.isEmpty
          ? const Text('No subscription record', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
          : Column(children: rows),
    );
  }
}
