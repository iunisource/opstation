import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../../fleet/fleet_common.dart' show openPrint, esc;

/// One person's app version (SQL 475 app_versions).
class AppVersionRow {
  final String userId, name, role, phone;
  final bool active;
  final String? version, model, os;
  final int? build;
  final DateTime? lastSeen;
  AppVersionRow.from(Map m)
      : userId = '${m['user_id']}',
        name = '${m['name'] ?? ''}',
        role = '${m['role'] ?? ''}',
        phone = '${m['phone'] ?? ''}'.trim(),
        active = m['is_active'] != false,
        version = (m['app_version'] as String?)?.trim(),
        build = (m['build'] as num?)?.toInt(),
        model = m['device_model'] as String?,
        os = m['os_version'] as String?,
        lastSeen = DateTime.tryParse('${m['last_seen'] ?? ''}')?.toLocal();

  /// "1.3.6 (34)"
  String get label {
    final v = version;
    if (v == null || v.isEmpty) return '—';
    final p = v.split('+');
    return p.length == 2 ? '${p[0]} (${p[1]})' : v;
  }
}

/// Latest build in use and the minimum set in Admin Settings, for one org.
class AppVersionInfo {
  final List<AppVersionRow> rows;
  final int? latest; // newest build any phone of the org reports
  final int? minimum; // Admin Settings → org.app_min_build (only when the banner is on)
  const AppVersionInfo(this.rows, this.latest, this.minimum);

  /// The build to compare against: the minimum if set, else the latest.
  int? get target => minimum ?? latest;

  /// 'ok' | 'old' | 'unknown'
  String statusOf(AppVersionRow r) {
    if (r.build == null) return 'unknown';
    final t = target;
    if (t == null) return 'ok';
    return r.build! < t ? 'old' : 'ok';
  }

  /// "Outdated · 2 builds behind" / "Up to date" / "Unknown"
  String labelOf(AppVersionRow r) {
    final s = statusOf(r);
    if (s == 'unknown') return 'Unknown';
    if (s == 'ok') return 'Up to date';
    final behind = (latest ?? target!) - r.build!;
    return behind > 0 ? 'Outdated · $behind build${behind == 1 ? '' : 's'} behind' : 'Outdated';
  }

  static Future<AppVersionInfo> load(String orgId) async {
    final db = Supabase.instance.client;
    final res = await Future.wait<dynamic>([
      db.rpc('app_versions', params: {'p_org': orgId}),
      db.from('app_config').select('key, value, branch_id').eq('org_id', orgId)
          .inFilter('key', ['org.app_update_banner', 'org.app_min_build']),
    ]);
    final rows = [for (final m in res[0] as List) AppVersionRow.from(m as Map)];
    final cfg = <String, String>{};
    final cfgRows = [for (final x in res[1] as List) Map<String, dynamic>.from(x as Map)]
      ..sort((a, b) => (a['branch_id'] == null ? 1 : 0).compareTo(b['branch_id'] == null ? 1 : 0));
    for (final x in cfgRows) {
      final v = '${x['value'] ?? ''}'.trim();
      if (v.isNotEmpty) cfg['${x['key']}'] = v;
    }
    final min = cfg['org.app_update_banner'] == 'true' ? int.tryParse(cfg['org.app_min_build'] ?? '') : null;
    int? latest;
    for (final r in rows) {
      if (r.build != null && (latest == null || r.build! > latest)) latest = r.build;
    }
    return AppVersionInfo(rows, latest, min != null && min > 0 ? min : null);
  }
}

String appRoleLabel(String r) => switch (r) {
      'salesperson' => 'Salesperson',
      'driver' => 'Driver',
      'surveyor' => 'Surveyor',
      'dispatchManager' => 'Dispatch Manager',
      'masterAdmin' => 'Master Admin',
      'admin' => 'Admin',
      final x when x.isNotEmpty => x[0].toUpperCase() + x.substring(1),
      _ => '',
    };

(String, Color, Color) appStatusColors(String s) => switch (s) {
      'old' => ('', const Color(0xFFB91C1C), const Color(0xFFFEF2F2)),
      'ok' => ('', const Color(0xFF047857), const Color(0xFFECFDF5)),
      _ => ('', const Color(0xFF64748B), const Color(0xFFF1F5F9)),
    };

Widget appStatusPill(AppVersionInfo info, AppVersionRow r) {
  final c = appStatusColors(info.statusOf(r));
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(color: c.$3, borderRadius: BorderRadius.circular(999)),
    child: Text(info.labelOf(r), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.$2)),
  );
}

/// Operations → App Versions: who is on which app version, so old phones can
/// be called to update. Each org sees only its own people.
class AppVersionsScreen extends ConsumerStatefulWidget {
  const AppVersionsScreen({super.key});
  @override
  ConsumerState<AppVersionsScreen> createState() => _AppVersionsScreenState();
}

class _AppVersionsScreenState extends ConsumerState<AppVersionsScreen> {
  AppVersionInfo? _info;
  bool _loading = true;
  String? _error;
  String _status = 'all'; // all | old | ok | unknown
  String _role = 'all'; // all | salesperson | driver | other
  String _q = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final org = ref.read(currentUserProvider)?.orgId;
    if (org == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final info = await AppVersionInfo.load(org);
      if (!mounted) return;
      setState(() { _info = info; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      final m = '$e';
      setState(() {
        _loading = false;
        _error = m.contains('PGRST202') || m.contains('Could not find the function')
            ? 'Run SQL 475 to set up App Versions.'
            : 'Could not load. Please try again.';
      });
    }
  }

  List<AppVersionRow> get _shown {
    final info = _info;
    if (info == null) return const [];
    final q = _q.toLowerCase();
    final list = info.rows.where((r) {
      if (!r.active) return false;
      if (_status != 'all' && info.statusOf(r) != _status) return false;
      if (_role == 'salesperson' && r.role != 'salesperson') return false;
      if (_role == 'driver' && r.role != 'driver') return false;
      if (_role == 'other' && (r.role == 'salesperson' || r.role == 'driver')) return false;
      if (q.isNotEmpty && !'${r.name} ${r.phone} ${r.model ?? ''}'.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
    int rank(AppVersionRow r) => switch (info.statusOf(r)) { 'old' => 0, 'unknown' => 1, _ => 2 };
    list.sort((a, b) {
      final x = rank(a).compareTo(rank(b));
      if (x != 0) return x;
      final y = (a.build ?? -1).compareTo(b.build ?? -1);
      return y != 0 ? y : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  String _seen(DateTime? d) {
    if (d == null) return '—';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final t = DateFormat('h:mm a').format(d);
    if (day == today) return 'Today, $t';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday, $t';
    return DateFormat('d MMM, h:mm a').format(d);
  }

  void _call(String phone) {
    final p = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (p.isEmpty) return;
    launchUrl(Uri.parse('tel:$p'));
  }

  void _print(List<AppVersionRow> list) {
    final info = _info!;
    final b = StringBuffer()
      ..write('<h1>App Versions</h1>')
      ..write('<div class="meta">${esc(ref.read(currentUserProvider)?.orgName ?? '')}'
          '${info.latest == null ? '' : ' · latest in use: build ${info.latest}'}'
          '${info.minimum == null ? '' : ' · minimum required: build ${info.minimum}'}</div>')
      ..write('<table><tr><th>Person</th><th>Role</th><th>Phone no.</th><th>App version</th><th>Status</th><th>Phone</th><th>Last used</th></tr>');
    for (final r in list) {
      final s = info.statusOf(r);
      b.write('<tr><td>${esc(r.name)}</td><td>${esc(appRoleLabel(r.role))}</td><td>${esc(r.phone)}</td>'
          '<td>${esc(r.label)}</td><td class="${s == 'old' ? 'overdue' : s == 'ok' ? 'ok' : ''}">${esc(info.labelOf(r))}</td>'
          '<td>${esc([r.model, r.os].where((x) => (x ?? '').isNotEmpty).join(' · '))}</td><td>${esc(_seen(r.lastSeen))}</td></tr>');
    }
    b.write('</table>');
    openPrint('App Versions', b.toString());
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final info = _info;
    final active = info?.rows.where((r) => r.active).toList() ?? const <AppVersionRow>[];
    int n(String s) => info == null ? 0 : active.where((r) => info.statusOf(r) == s).length;
    final list = _shown;
    Widget chip(String v, String l, Color c) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: c.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.3))),
          child: Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: c), children: [
            TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            TextSpan(text: '  $l'),
          ])),
        );
    Widget filter(String label, bool on, VoidCallback f) =>
        Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => f()));

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(wide ? 24 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('App Versions', style: TextStyle(fontSize: wide ? 24 : 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          if (info != null) ...[
            chip('${n('ok')}', 'up to date', const Color(0xFF047857)),
            chip('${n('old')}', 'outdated', const Color(0xFFB91C1C)),
            chip('${n('unknown')}', 'unknown', const Color(0xFF64748B)),
          ],
          const SizedBox(width: 8),
          OutlinedButton.icon(
              onPressed: list.isEmpty ? null : () => _print(list),
              icon: const Icon(Icons.print_outlined, size: 16),
              label: const Text('Print / PDF')),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
        ]),
        const SizedBox(height: 4),
        Text(
          [
            if (info?.latest != null) 'Latest in use: build ${info!.latest}',
            info?.minimum != null
                ? 'Minimum required: build ${info!.minimum} (phones below it see a "Please update" banner)'
                : 'No minimum set: compared with the latest build (set one with the gear)',
            'Phones report their version about every 10 minutes while the app is open',
          ].join(' · '),
          style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            filter('All (${active.length})', _status == 'all', () => setState(() => _status = 'all')),
            filter('Outdated (${n('old')})', _status == 'old', () => setState(() => _status = 'old')),
            filter('Up to date (${n('ok')})', _status == 'ok', () => setState(() => _status = 'ok')),
            filter('Unknown (${n('unknown')})', _status == 'unknown', () => setState(() => _status = 'unknown')),
            const SizedBox(width: 10),
            filter('Everyone', _role == 'all', () => setState(() => _role = 'all')),
            filter('Salespeople', _role == 'salesperson', () => setState(() => _role = 'salesperson')),
            filter('Drivers', _role == 'driver', () => setState(() => _role = 'driver')),
            filter('Others', _role == 'other', () => setState(() => _role = 'other')),
          ]),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 260,
          child: TextField(
            decoration: const InputDecoration(isDense: true, hintText: 'Search name or phone…', prefixIcon: Icon(Icons.search, size: 18)),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : list.isEmpty
                      ? const Center(child: Text('Nobody here.', style: TextStyle(color: AppTheme.textSecondary)))
                      : ListView(children: [for (final r in list) _row(info!, r, wide)]),
        ),
      ]),
    );
  }

  Widget _row(AppVersionInfo info, AppVersionRow r, bool wide) {
    final person = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
      if (appRoleLabel(r.role).isNotEmpty)
        Text(appRoleLabel(r.role), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
    final version = Text(r.label,
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, fontFamily: 'monospace',
            color: r.build == null ? AppTheme.textSecondary : null));
    final phone = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((r.model ?? '').isEmpty ? '—' : r.model!, style: const TextStyle(fontSize: 12.5)),
      if ((r.os ?? '').isNotEmpty) Text(r.os!, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
    final seen = Text(_seen(r.lastSeen), style: const TextStyle(fontSize: 12.5));
    final call = r.phone.isEmpty
        ? const SizedBox()
        : OutlinedButton.icon(
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () => _call(r.phone),
            icon: const Icon(Icons.call_outlined, size: 15),
            label: Text(r.phone, style: const TextStyle(fontSize: 12)),
          );
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppTheme.border)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: wide
            ? Row(children: [
                Expanded(flex: 3, child: person),
                Expanded(flex: 2, child: version),
                Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: appStatusPill(info, r))),
                Expanded(flex: 3, child: phone),
                Expanded(flex: 2, child: seen),
                SizedBox(width: 170, child: Align(alignment: Alignment.centerRight, child: call)),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Expanded(child: person), appStatusPill(info, r)]),
                const SizedBox(height: 6),
                Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [version, phone, seen]),
                if (r.phone.isNotEmpty) ...[const SizedBox(height: 6), Align(alignment: Alignment.centerRight, child: call)],
              ]),
      ),
    );
  }
}
