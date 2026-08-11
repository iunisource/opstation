// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart'; // orgModulesProvider
import '../../auth/auth_controller.dart';

/// Expand a receipt-number field into every slip number it represents.
/// Ported verbatim from the Team 360 profile so the Super Summary's app-usage
/// read matches it exactly ("31457 & 31458", "32282 83 84", etc.).
List<int> _receiptSlipNumbers(String raw) {
  final toks = RegExp(r'\d+').allMatches(raw).map((m) => m.group(0)!).toList();
  final out = <int>[];
  int? prevFull;
  for (final t in toks) {
    final n = int.parse(t);
    final prevLen = prevFull?.toString().length ?? 0;
    if (prevFull == null || t.length >= prevLen) {
      out.add(n);
      prevFull = n;
    } else {
      var p10 = 1;
      for (var i = 0; i < t.length; i++) p10 *= 10;
      final expanded = (prevFull - (prevFull % p10)) + n;
      out.add(expanded);
      prevFull = expanded;
    }
  }
  return out;
}

/// One conversational app-usage note (severity drives colour on screen + print).
class _Note {
  final String sev; // 'danger' | 'warn' | 'ok'
  final String text;
  const _Note(this.sev, this.text);
}

/// Per-salesperson app-usage read (the Team 360 "How they use the app" card).
class _Usage {
  final String name;
  final String role;
  final int visits;
  final int days;
  final int? daysSince;
  final String headSev; // danger | warn | ok
  final String headLabel;
  final List<_Note> notes;
  final bool hasBulk; // a "logs in bulk" note fired (over ACTUAL visits only)
  final int skipped;  // shops marked 'skipped' (not visited)
  // Raw visit events (sorted by event time), each with customer name + the
  // event timestamp and the server sync time (created_at), so the bulk-entry
  // modal can show whether it was late syncing or genuine bulk logging.
  final List<Map<String, dynamic>> events;
  _Usage(this.name, this.role, this.visits, this.days, this.daysSince,
      this.headSev, this.headLabel, this.notes, this.hasBulk, this.skipped, this.events);
}

/// Org-Wide Super Summary — executive report for the leadership committee.
/// Master-Admin (and admin) only. KPI blocks from rpc_org_super_summary plus a
/// conversational per-salesperson app-usage read (same logic as Team 360).
class ErpSuperSummaryScreen extends ConsumerStatefulWidget {
  const ErpSuperSummaryScreen({super.key});
  @override
  ConsumerState<ErpSuperSummaryScreen> createState() => _State();
}

class _State extends ConsumerState<ErpSuperSummaryScreen> {
  final _money = NumberFormat('#,##0');
  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();
  bool _loading = false;
  bool _loaded = false;
  Map<String, dynamic>? _data;
  List<_Usage> _usage = [];
  Map<String, dynamic>? _mfg; // manufacturing overview (null = module off / no load)

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String get _orgName => ref.read(currentUserProvider)?.orgName ?? '';

  String _rs(num? v) => 'Rs. ${_money.format((v ?? 0).toDouble())}';
  static String _s(Object? v) => (v ?? '').toString();

  List<Map<String, dynamic>> _list(String key) =>
      [for (final e in (_data?[key] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];

  static Color _sev(String s) => s == 'danger'
      ? AppTheme.danger
      : s == 'warn'
          ? Colors.amber.shade800
          : AppTheme.success;
  static String _sevHex(String s) => s == 'danger' ? '#c2410c' : s == 'warn' ? '#b45309' : '#15803d';

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final fromS = DateFormat('yyyy-MM-dd').format(_from);
      final toS = DateFormat('yyyy-MM-dd').format(_to);
      final res = await client.rpc('rpc_org_super_summary', params: {
        'p_org': orgId, 'p_from': fromS, 'p_to': toS,
      });
      final usage = await _loadUsage(client, orgId);
      // Manufacturing overview — only for orgs that have the Manufacturing
      // ('production') module enabled. Await the provider's FUTURE so a cold
      // load (provider still resolving) doesn't wrongly report "no module" and
      // drop the section from both screen and PDF.
      Set<String> modules = const <String>{};
      try {
        modules = await ref.read(orgModulesProvider.future);
      } catch (_) {
        modules = ref.read(orgModulesProvider).valueOrNull ?? const <String>{};
      }
      final mfg = modules.contains('production')
          ? await _loadManufacturing(client, orgId)
          : null;
      if (mounted) {
        setState(() {
          _data = Map<String, dynamic>.from(res as Map);
          _usage = usage;
          _mfg = mfg;
          _loaded = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Summary error: $e')));
      }
    }
  }

  // Fetch this org's field-salesperson visits in the period and derive the same
  // conversational usage read the Team 360 profile shows, per salesperson.
  Future<List<_Usage>> _loadUsage(SupabaseClient client, String orgId) async {
    // Org users (id -> {name, role}); we only surface field roles with visits.
    final urows = await client.from('users').select('id, name, role').eq('org_id', orgId);
    final uname = <String, String>{}; final urole = <String, String>{};
    for (final u in urows as List) {
      final id = u['id'] as String?; if (id == null) continue;
      uname[id] = (u['name'] as String?) ?? id;
      urole[id] = (u['role'] as String?) ?? '';
    }
    if (uname.isEmpty) return [];
    // Customer id -> shop name, to label each visit in the bulk-entry modal.
    final cname = <String, String>{};
    try {
      final crows = await client.from('customers').select('id, shop_name').eq('org_id', orgId);
      for (final c in crows as List) {
        final id = c['id'] as String?; if (id == null) continue;
        cname[id] = (c['shop_name'] as String?) ?? id;
      }
    } catch (_) {}
    final fromIso = DateFormat('yyyy-MM-dd').format(_from);
    final toIso = DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));
    // Page through visits for this org's users in the window. created_at (the
    // server sync time) is pulled alongside the event timestamp; if the column
    // is absent the query falls back gracefully.
    const selFull = 'user_id, customer_id, status, timestamp, amount, receipt_number, created_at';
    const selBasic = 'user_id, customer_id, status, timestamp, amount, receipt_number';
    var sel = selFull;
    final byUser = <String, List<Map<String, dynamic>>>{};
    int from = 0; const page = 1000;
    while (true) {
      List rows;
      try {
        rows = await client.from('visits').select(sel)
            .inFilter('user_id', uname.keys.toList())
            .gte('timestamp', fromIso).lt('timestamp', toIso)
            .order('timestamp').range(from, from + page - 1);
      } catch (e) {
        if (sel == selFull) { sel = selBasic; continue; } // no created_at column
        rethrow;
      }
      final list = List<Map<String, dynamic>>.from(rows);
      for (final v in list) {
        final uid = v['user_id'] as String?; if (uid == null) continue;
        v['customer'] = cname[v['customer_id'] as String? ?? ''] ?? '';
        (byUser[uid] ??= []).add(v);
      }
      if (list.length < page) break;
      from += page; if (from > 100000) break;
    }
    final out = <_Usage>[];
    byUser.forEach((uid, evs) {
      out.add(_behaviour(uname[uid] ?? uid, urole[uid] ?? '', evs));
    });
    // Most visits first.
    out.sort((a, b) => b.visits.compareTo(a.visits));
    return out;
  }

  // Port of Team 360 _behaviorCard, over one salesperson's visit rows.
  _Usage _behaviour(String name, String role, List<Map<String, dynamic>> ev) {
    final total = ev.length;
    int verified = 0, located = 0, afterHours = 0, skippedVisits = 0;
    // Burst (bulk logging) is measured over ACTUAL visits only — a skipped shop
    // is a single tap and naturally lands seconds after the previous one, so
    // including skips produces false "bulk logging" flags.
    final times = <DateTime>[];
    final nums = <int>[];
    DateTime? last;
    final days = <String>{};
    for (final e in ev) {
      final st = (e['status'] as String?) ?? '';
      final isSkipped = st == 'skipped';
      if (isSkipped) skippedVisits++;
      if (st == 'verified') { verified++; located++; }
      else if (st == 'outside' || st == 'noLocation') { located++; }
      final ts = e['timestamp'] as String?;
      final t = ts == null ? null : DateTime.tryParse(ts)?.toLocal();
      if (t != null) {
        if (!isSkipped) {
          times.add(t);
          if (t.hour >= 20 || t.hour < 6) afterHours++;
        }
        if (last == null || t.isAfter(last!)) last = t;
        days.add('${t.year}-${t.month}-${t.day}');
      }
      nums.addAll(_receiptSlipNumbers((e['receipt_number'] as String?) ?? ''));
    }
    final realVisits = total - skippedVisits; // actual mark-visit events
    final verifiedPct = located == 0 ? null : verified / located * 100;
    times.sort();
    int burst = 0;
    for (var i = 1; i < times.length; i++) {
      if (times[i].difference(times[i - 1]).inSeconds.abs() < 90) burst++;
    }
    final burstPct = times.length < 2 ? 0.0 : burst / (times.length - 1) * 100;
    nums.sort();
    var skipped = 0;
    for (var i = 1; i < nums.length; i++) {
      final gap = nums[i] - nums[i - 1];
      if (gap > 1 && gap <= 20) skipped += gap - 1;
    }
    final daysSince = last == null ? null : DateTime.now().difference(last!).inDays;

    final notes = <_Note>[];
    if (verifiedPct != null) {
      if (verifiedPct >= 70) {
        notes.add(_Note('ok', '${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified at the shop — locations are trustworthy.'));
      } else if (verifiedPct >= 40) {
        notes.add(_Note('warn', 'Only ${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified — many are logged outside the shop geofence.'));
      } else {
        notes.add(_Note('danger', 'Just ${verifiedPct.toStringAsFixed(0)}% of visits are GPS-verified — most are recorded away from the shop, so locations can\'t be trusted.'));
      }
    }
    final hasBulk = burstPct >= 40;
    if (hasBulk) {
      notes.add(_Note('danger', 'Often logs in bulk — ${burstPct.toStringAsFixed(0)}% of actual visits are entered within 90s of the previous one, a sign of after-the-fact entry rather than live at each shop.'));
    }
    if (skippedVisits > 0) {
      notes.add(_Note('warn', 'Skipped $skippedVisits of $total shops on the route — marked skipped, not visited.'));
    }
    if (afterHours > 0 && realVisits > 0 && afterHours / realVisits >= 0.3) {
      notes.add(_Note('warn', '$afterHours of $realVisits visits were entered late at night (after 8 PM) — suggesting a day\'s collections keyed in one sitting.'));
    }
    if (skipped > 0) {
      notes.add(_Note('warn', '$skipped receipt number${skipped == 1 ? '' : 's'} skipped in sequence — collections may have been made but not entered.'));
    } else if (nums.length >= 3) {
      notes.add(_Note('ok', 'Receipt numbers run in clean sequence — no obvious missed entries.'));
    }
    if (daysSince != null && daysSince >= 3) {
      notes.add(_Note('warn', 'No visits entered in the last $daysSince days — nothing logged recently.'));
    }
    if (notes.isEmpty) {
      notes.add(_Note('ok', 'Records visits live at the shop with receipts in order — good app discipline.'));
    }
    final concerns = notes.where((n) => n.sev == 'danger').length;
    final warns = notes.where((n) => n.sev == 'warn').length;
    final headSev = concerns > 0 ? 'danger' : (warns > 0 ? 'warn' : 'ok');
    final headLabel = concerns > 0 ? 'Needs attention' : (warns > 0 ? 'A few habits to watch' : 'Healthy app usage');
    final sorted = List<Map<String, dynamic>>.from(ev)..sort((a, b) =>
        (a['timestamp'] as String? ?? '').compareTo(b['timestamp'] as String? ?? ''));
    return _Usage(name, role, total, days.length, daysSince, headSev, headLabel, notes, hasBulk, skippedVisits, sorted);
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context, firstDate: DateTime(2020), lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null) setState(() { _from = picked.start; _to = picked.end; });
  }

  String get _periodLabel =>
      '${DateFormat('d MMM yyyy').format(_from)} – ${DateFormat('d MMM yyyy').format(_to)}';

  // ── Manufacturing overview (jobs, production, delays, efficiency) ──────────
  // Jobs are a live snapshot (open/queued/in-progress now); production units and
  // reject rate are for the selected period (from job_card_runs). A job is
  // flagged "behind" when it has been open more than 7 days and isn't finished.
  static const int _kDelayDays = 7;

  Future<Map<String, dynamic>?> _loadManufacturing(
      SupabaseClient client, String orgId) async {
    try {
      final fromStr = DateFormat('yyyy-MM-dd').format(_from);
      final toStrExcl =
          DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));

      final jobsRaw = await client
          .from('job_cards')
          .select(
              'id, job_number, product_id, status, planned_qty, produced_qty, is_open_ended, created_at, updated_at')
          .eq('org_id', orgId)
          .order('created_at', ascending: false)
          .limit(4000);
      final jobs = List<Map<String, dynamic>>.from(jobsRaw as List);

      // Product names for the delayed-job list.
      final pids = <String>{
        for (final j in jobs)
          if (j['product_id'] != null) j['product_id'] as String
      };
      final prodName = <String, String>{};
      if (pids.isNotEmpty) {
        final prows = await client
            .from('products')
            .select('id, name, sku')
            .inFilter('id', pids.toList());
        for (final p in prows as List) {
          final sku = (p['sku'] as String?) ?? '';
          prodName[p['id'] as String] =
              (sku.isNotEmpty ? '$sku — ' : '') + ((p['name'] as String?) ?? '');
        }
      }

      // Production batches in the period (RLS scopes job_card_runs to the org).
      num unitsProduced = 0, rejected = 0;
      int batches = 0;
      try {
        final runs = await client
            .from('job_card_runs')
            .select('produced_qty, rejected_qty, run_date')
            .gte('run_date', fromStr)
            .lt('run_date', toStrExcl);
        for (final r in runs as List) {
          unitsProduced += (r['produced_qty'] as num? ?? 0);
          rejected += (r['rejected_qty'] as num? ?? 0);
          batches++;
        }
      } catch (_) {/* runs table/date column optional */}

      DateTime? parse(dynamic s) => s == null ? null : DateTime.tryParse('$s');
      final periodEnd = _to.add(const Duration(days: 1));
      bool inPeriod(DateTime? d) =>
          d != null && !d.isBefore(_from) && d.isBefore(periodEnd);

      final now = DateTime.now();
      int created = 0, completedInPeriod = 0, queued = 0, inProgress = 0;
      int openCount = 0;
      double progressSum = 0;
      final delayed = <Map<String, dynamic>>[];

      for (final j in jobs) {
        final st = (j['status'] as String?) ?? 'queued';
        final cAt = parse(j['created_at']);
        if (inPeriod(cAt)) created++;
        if (st == 'completed' && inPeriod(parse(j['updated_at']))) {
          completedInPeriod++;
        }
        if (st == 'queued' || st == 'in_progress') {
          if (st == 'queued') {
            queued++;
          } else {
            inProgress++;
          }
          openCount++;
          final planned = (j['planned_qty'] as num? ?? 0).toDouble();
          final produced = (j['produced_qty'] as num? ?? 0).toDouble();
          final openEnded = (j['is_open_ended'] as bool?) ?? false;
          final prog = (!openEnded && planned > 0)
              ? (produced / planned).clamp(0.0, 1.0)
              : (produced > 0 ? 1.0 : 0.0);
          progressSum += prog;
          final ageDays = cAt == null ? 0 : now.difference(cAt).inDays;
          final behind = openEnded || planned <= 0 || produced < planned;
          if (ageDays >= _kDelayDays && behind) {
            delayed.add({
              'job_number': (j['job_number'] as String?) ?? '',
              'product': prodName[j['product_id']] ?? '',
              'age': ageDays,
              'progress': (prog * 100).round(),
              'open_ended': openEnded,
            });
          }
        }
      }
      delayed.sort((a, b) => (b['age'] as int).compareTo(a['age'] as int));
      final avgOpenProgress = openCount > 0 ? progressSum / openCount : 0.0;
      final rejectRate = unitsProduced > 0 ? rejected / unitsProduced : 0.0;

      final insights = <String>[];
      if (delayed.isNotEmpty) {
        final w = delayed.first;
        insights.add(
            '${delayed.length} job${delayed.length == 1 ? '' : 's'} running behind — open over a week and not yet complete. Oldest: ${w['job_number']} at ${w['age']} days'
            '${(w['open_ended'] as bool? ?? false) ? '' : ', ${w['progress']}% done'}.');
      } else if (openCount > 0) {
        insights.add('No jobs are stuck beyond a week — the floor is keeping pace.');
      }
      if (unitsProduced > 0) {
        final rr = rejectRate * 100;
        final word = rr <= 2 ? 'tight' : (rr <= 5 ? 'acceptable' : 'high');
        insights.add(
            'Reject rate is ${rr.toStringAsFixed(1)}% this period ($word) — ${_money.format(rejected)} of ${_money.format(unitsProduced)} units scrapped across $batches batch${batches == 1 ? '' : 'es'}.');
      }
      if (created > 0 || completedInPeriod > 0 || openCount > 0) {
        insights.add(
            '$completedInPeriod job${completedInPeriod == 1 ? '' : 's'} completed vs $created created this period'
            '${openCount > 0 ? '; $openCount still open (avg ${(avgOpenProgress * 100).round()}% done)' : ''}.');
      }
      if (insights.isEmpty) {
        insights.add('No manufacturing activity in this period.');
      }

      return {
        'created': created,
        'completed': completedInPeriod,
        'open': openCount,
        'queued': queued,
        'in_progress': inProgress,
        'units': unitsProduced,
        'batches': batches,
        'rejected': rejected,
        'rejectRate': rejectRate,
        'avgOpenProgress': avgOpenProgress,
        'delayed': delayed,
        'insights': insights,
      };
    } catch (_) {
      return null;
    }
  }

  // Is the current range exactly this named shortcut? (to highlight the chip)
  bool _isQuickRange(String key) {
    final r = _quickRange(key);
    return _dateOnly(_from) == r.$1 && _dateOnly(_to) == r.$2;
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// (from, to) for a named shortcut, using local "now". Week starts Monday.
  (DateTime, DateTime) _quickRange(String key) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (key) {
      case 'yesterday':
        final y = today.subtract(const Duration(days: 1));
        return (y, y);
      case 'week':
        // Monday..today (weekday: Mon=1 … Sun=7).
        return (today.subtract(Duration(days: today.weekday - 1)), today);
      case 'month':
        return (DateTime(now.year, now.month, 1), today);
      case 'today':
      default:
        return (today, today);
    }
  }

  void _applyQuickRange(String key) {
    final r = _quickRange(key);
    setState(() {
      _from = r.$1;
      _to = r.$2;
    });
    _load(); // generate immediately — that's the point of a shortcut
  }

  Widget _quickChip(String label, String key) {
    final selected = _isQuickRange(key);
    return ActionChip(
      label: Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : AppTheme.textPrimary)),
      backgroundColor: selected ? AppTheme.primary : Colors.white,
      side: BorderSide(color: selected ? AppTheme.primary : AppTheme.border),
      visualDensity: VisualDensity.compact,
      onPressed: _loading ? null : () => _applyQuickRange(key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.read(currentUserProvider)?.role;
    final allowed = role == WebUserRole.masterAdmin || role == WebUserRole.admin;
    if (!allowed) {
      return Container(color: AppTheme.background, alignment: Alignment.center,
        child: const Text('The Super Summary is restricted to administrators.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)));
    }
    final totals = Map<String, dynamic>.from(_data?['totals'] as Map? ?? {});
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Org-Wide Super Summary', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text(_orgName.isEmpty ? 'Executive summary' : _orgName,
                  style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range, size: 16),
              label: Text(_periodLabel, style: const TextStyle(fontSize: 12)),
              onPressed: _pickRange,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _loading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow, size: 18),
              label: const Text('Generate'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
              onPressed: _loading ? null : _load,
            ),
            const SizedBox(width: 8),
            if (_loaded)
              OutlinedButton.icon(
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
                onPressed: _print,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
          ]),
        ),
        // Quick date shortcuts — set the range and generate in one tap.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _quickChip('Today', 'today'),
            _quickChip('Yesterday', 'yesterday'),
            _quickChip('This week', 'week'),
            _quickChip('This month', 'month'),
          ]),
        ),
        Expanded(
          child: !_loaded
              ? const Center(child: Text('Pick a period and Generate', style: TextStyle(color: AppTheme.textSecondary)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      _tile('Total Sale', _rs(totals['sales'] as num?), AppTheme.primary),
                      const SizedBox(width: 12),
                      _tile('Total Purchase', _rs(totals['purchase'] as num?), Colors.indigo),
                      const SizedBox(width: 12),
                      _tile('Total Collection', _rs(totals['collection'] as num?), Colors.green.shade700),
                      const SizedBox(width: 12),
                      _tile('Payments Made', _rs(totals['payments'] as num?), Colors.orange.shade800),
                    ]),
                    const SizedBox(height: 20),
                    Wrap(spacing: 20, runSpacing: 20, children: [
                      _card('Collection by Salesperson', 560, _collectionBySalesperson()),
                      _card('Collection by Customer Group', 380, _twoColTable(
                        _list('collection_by_group'), 'group', 'amount', 'Customer Group', 'Amount')),
                      _card('Payments — Paid to Accounts', 420, _twoColTable(
                        _list('payments_by_account'), 'account', 'amount', 'Account', 'Amount')),
                      _card('Expenses', 420, _twoColTable(
                        _list('expenses'), 'head', 'amount', 'Expense Head', 'Amount')),
                      _card('Placement Score by Market', 460, _placementByMarket()),
                      _card('Usage — ERP Users', 380, _usageErp()),
                    ]),
                    if (_mfg != null) ...[
                      const SizedBox(height: 24),
                      _manufacturingSection(),
                    ],
                    const SizedBox(height: 24),
                    const Text('Salesperson — App Usage', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    const Text('How each salesperson uses the field app — the same read as their Team 360 profile.',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(height: 12),
                    if (_usage.isEmpty)
                      const Text('No field visits in this period.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                    else
                      Wrap(spacing: 16, runSpacing: 16, children: [for (final u in _usage) _usageCard(u)]),
                  ]),
                ),
        ),
      ]),
    );
  }

  // ── UI building blocks ─────────────────────────────────────────────────────
  Widget _tile(String label, String value, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
      ]),
    ),
  );

  Widget _card(String title, double width, Widget child) => Container(
    width: width,
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.all(12), child: child),
    ]),
  );

  TextStyle get _th => const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary);
  TextStyle get _td => const TextStyle(fontSize: 12.5);

  Widget _manufacturingSection() {
    final m = _mfg!;
    final delayed = [
      for (final d in (m['delayed'] as List? ?? const []))
        Map<String, dynamic>.from(d as Map)
    ];
    final insights = [
      for (final s in (m['insights'] as List? ?? const [])) s.toString()
    ];
    final rr = (m['rejectRate'] as num? ?? 0).toDouble() * 100;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: const [
        Icon(Icons.precision_manufacturing_outlined, size: 18, color: AppTheme.primary),
        SizedBox(width: 8),
        Text('Manufacturing', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 2),
      Text(
          'Jobs, production and operational efficiency for $_periodLabel. Open-job counts are a live snapshot.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      const SizedBox(height: 12),
      Row(children: [
        _tile('Open Jobs', '${m['open'] ?? 0}', AppTheme.primary),
        const SizedBox(width: 12),
        _tile('Completed', '${m['completed'] ?? 0}', Colors.green.shade700),
        const SizedBox(width: 12),
        _tile('Units Produced', _money.format((m['units'] as num? ?? 0)), Colors.indigo),
        const SizedBox(width: 12),
        _tile('Reject Rate', '${rr.toStringAsFixed(1)}%',
            rr <= 5 ? Colors.green.shade700 : Colors.red.shade700),
        const SizedBox(width: 12),
        _tile('Running Behind', '${delayed.length}',
            delayed.isEmpty ? Colors.green.shade700 : Colors.orange.shade800),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 20, runSpacing: 20, children: [
        _card('What to watch', 560,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final s in insights)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                    padding: EdgeInsets.only(top: 5, right: 8),
                    child: Icon(Icons.circle, size: 6, color: AppTheme.textSecondary)),
                Expanded(child: Text(s, style: const TextStyle(fontSize: 12.5, height: 1.4))),
              ]),
            ),
        ])),
        _card('Jobs Running Behind (>$_kDelayDays days)', 520,
            delayed.isEmpty
                ? const Text('None — no job has been open longer than a week.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
                : Column(children: [
                    Row(children: [
                      Expanded(flex: 3, child: Text('Job', style: _th)),
                      Expanded(flex: 4, child: Text('Product', style: _th)),
                      SizedBox(width: 52, child: Text('Age', textAlign: TextAlign.right, style: _th)),
                      SizedBox(width: 64, child: Text('Progress', textAlign: TextAlign.right, style: _th)),
                    ]),
                    const Divider(height: 12),
                    for (final d in delayed.take(12))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(children: [
                          Expanded(flex: 3, child: Text('${d['job_number']}', style: _td.copyWith(fontWeight: FontWeight.w700))),
                          Expanded(flex: 4, child: Text('${d['product']}', style: _td, overflow: TextOverflow.ellipsis)),
                          SizedBox(width: 52, child: Text('${d['age']}d', textAlign: TextAlign.right, style: _td)),
                          SizedBox(
                              width: 64,
                              child: Text(
                                  (d['open_ended'] as bool? ?? false) ? '—' : '${d['progress']}%',
                                  textAlign: TextAlign.right, style: _td)),
                        ]),
                      ),
                    if (delayed.length > 12)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('+${delayed.length - 12} more',
                            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                      ),
                  ])),
      ]),
    ]);
  }

  Widget _emptyRow() => const Padding(padding: EdgeInsets.symmetric(vertical: 12),
      child: Text('No data for this period.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)));

  Widget _twoColTable(List<Map<String, dynamic>> rows, String k1, String k2, String h1, String h2) {
    if (rows.isEmpty) return _emptyRow();
    return Column(children: [
      Row(children: [Expanded(child: Text(h1, style: _th)), SizedBox(width: 120, child: Text(h2, textAlign: TextAlign.right, style: _th))]),
      const Divider(height: 12),
      for (final r in rows)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
          Expanded(child: Text(_s(r[k1]), style: _td, overflow: TextOverflow.ellipsis)),
          SizedBox(width: 120, child: Text(_rs(r[k2] as num?), textAlign: TextAlign.right, style: _td.copyWith(fontWeight: FontWeight.w600))),
        ])),
    ]);
  }

  Widget _collectionBySalesperson() {
    final rows = _list('collection_by_salesperson');
    if (rows.isEmpty) return _emptyRow();
    return Column(children: [
      Row(children: [
        Expanded(child: Text('Salesperson', style: _th)),
        SizedBox(width: 120, child: Text('Collection', textAlign: TextAlign.right, style: _th)),
        SizedBox(width: 70, child: Text('Visits', textAlign: TextAlign.right, style: _th)),
        SizedBox(width: 90, child: Text('Visit Score', textAlign: TextAlign.right, style: _th)),
      ]),
      const Divider(height: 12),
      for (final r in rows)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
          Expanded(child: Text(_s(r['name']), style: _td, overflow: TextOverflow.ellipsis)),
          SizedBox(width: 120, child: Text(_rs(r['collection'] as num?), textAlign: TextAlign.right, style: _td.copyWith(fontWeight: FontWeight.w600))),
          SizedBox(width: 70, child: Text('${r['visits'] ?? 0}', textAlign: TextAlign.right, style: _td)),
          SizedBox(width: 90, child: _scorePill(r['visit_score'] as num?)),
        ])),
    ]);
  }

  Widget _placementByMarket() {
    final rows = _list('placement_by_market');
    if (rows.isEmpty) return _emptyRow();
    return Column(children: [
      Row(children: [
        Expanded(child: Text('Market', style: _th)),
        SizedBox(width: 80, child: Text('Audited', textAlign: TextAlign.right, style: _th)),
        SizedBox(width: 80, child: Text('Present', textAlign: TextAlign.right, style: _th)),
        SizedBox(width: 70, child: Text('Score', textAlign: TextAlign.right, style: _th)),
      ]),
      const Divider(height: 12),
      for (final r in rows)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(children: [
          Expanded(child: Text(_s(r['market']), style: _td, overflow: TextOverflow.ellipsis)),
          SizedBox(width: 80, child: Text('${r['audited'] ?? 0}', textAlign: TextAlign.right, style: _td)),
          SizedBox(width: 80, child: Text('${r['present'] ?? 0}', textAlign: TextAlign.right, style: _td)),
          SizedBox(width: 70, child: _scorePill(r['score'] as num?)),
        ])),
    ]);
  }

  Widget _usageErp() {
    final rows = _list('usage_erp');
    if (rows.isEmpty) return _emptyRow();
    return Column(children: [
      Row(children: [
        Expanded(child: Text('ERP User', style: _th)),
        SizedBox(width: 90, child: Text('Vouchers', textAlign: TextAlign.right, style: _th)),
        SizedBox(width: 90, child: Text('Active Days', textAlign: TextAlign.right, style: _th)),
      ]),
      const Divider(height: 12),
      for (final r in rows) ...[
        Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Expanded(child: Text(_s(r['name']), style: _td, overflow: TextOverflow.ellipsis)),
          SizedBox(width: 90, child: Text('${r['vouchers'] ?? 0}', textAlign: TextAlign.right, style: _td.copyWith(fontWeight: FontWeight.w700))),
          SizedBox(width: 90, child: Text('${r['active_days'] ?? 0}', textAlign: TextAlign.right, style: _td)),
        ])),
        _erpTypeChips(r['by_type']),
      ],
    ]);
  }

  // The per-voucher-type breakdown that makes up an ERP user's total.
  Widget _erpTypeChips(Object? byType) {
    final map = <String, int>{};
    if (byType is Map) {
      byType.forEach((k, v) { final n = (v is num) ? v.toInt() : int.tryParse('$v') ?? 0; if (n > 0) map['$k'] = n; });
    }
    if (map.isEmpty) return const SizedBox(height: 4);
    final entries = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 5, runSpacing: 5, children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.primary.withOpacity(0.18))),
            child: Text('${e.key} · ${e.value}',
                style: const TextStyle(fontSize: 10.5, color: AppTheme.primary, fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }

  Widget _usageCard(_Usage u) {
    final c = _sev(u.headSev);
    return Container(
      width: 468,
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(color: c.withOpacity(0.06), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
          child: Row(children: [
            CircleAvatar(radius: 16, backgroundColor: c.withOpacity(0.15),
                child: Text(u.name.isNotEmpty ? u.name[0].toUpperCase() : 'U',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: c))),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(u.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
              Text('${u.visits} visits · active ${u.days} day${u.days == 1 ? '' : 's'}${u.daysSince != null ? ' · last ${u.daysSince == 0 ? 'today' : '${u.daysSince}d ago'}' : ''}',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
              child: Text(u.headLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: c)),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final n in u.notes)
              Padding(padding: const EdgeInsets.only(bottom: 7), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(margin: const EdgeInsets.only(top: 5, right: 8), width: 8, height: 8,
                    decoration: BoxDecoration(color: _sev(n.sev), shape: BoxShape.circle)),
                Expanded(child: Text(n.text, style: const TextStyle(fontSize: 12.5, height: 1.35))),
              ])),
            if (u.hasBulk || u.skipped > 0) ...[
              const SizedBox(height: 2),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
                icon: const Icon(Icons.travel_explore, size: 15),
                label: const Text('View visit trail', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.danger,
                    side: BorderSide(color: AppTheme.danger.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: () => _showBulkDetails(u),
              )),
            ],
          ]),
        ),
      ]),
    );
  }

  // Full visit trail for one salesperson, showing the event time AND the server
  // sync time side by side. If sync clusters while event times are spread, it's
  // late syncing; if the event times themselves are seconds apart, it's genuine
  // bulk logging. Rows <90s from the previous event are flagged.
  void _showBulkDetails(_Usage u) {
    final ev = u.events;
    final tf = DateFormat('d MMM, h:mm:ss a');
    DateTime? prevReal;
    final rows = <Widget>[];
    var bulkCount = 0; var skipCount = 0;
    for (var i = 0; i < ev.length; i++) {
      final e = ev[i];
      final st = '${e['status'] ?? ''}';
      final isSkipped = st == 'skipped';
      if (isSkipped) skipCount++;
      final tE = DateTime.tryParse('${e['timestamp'] ?? ''}')?.toLocal();
      final tC = DateTime.tryParse('${e['created_at'] ?? ''}')?.toLocal();
      // Bulk only measured between actual visits — skips don't create a gap.
      final gap = (!isSkipped && prevReal != null && tE != null) ? tE.difference(prevReal).inSeconds : null;
      final bulk = gap != null && gap.abs() < 90;
      if (bulk) bulkCount++;
      rows.add(Container(
        color: isSkipped
            ? AppTheme.textSecondary.withOpacity(0.06)
            : (bulk ? AppTheme.danger.withOpacity(0.06) : (i.isEven ? AppTheme.background.withOpacity(0.4) : null)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(children: [
          SizedBox(width: 24, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
          Expanded(flex: 3, child: Text('${e['customer'] ?? ''}'.isEmpty ? '—' : '${e['customer']}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis)),
          SizedBox(width: 128, child: Text(tE != null ? tf.format(tE) : '—', style: const TextStyle(fontSize: 11))),
          SizedBox(width: 128, child: Text(tC != null ? tf.format(tC) : '—', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary))),
          SizedBox(width: 66, child: Text(isSkipped ? 'skip' : (gap == null ? '—' : '${gap}s'),
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, fontWeight: bulk ? FontWeight.w700 : FontWeight.normal,
                  color: isSkipped ? AppTheme.textSecondary : (bulk ? AppTheme.danger : AppTheme.textSecondary))))
          ,
          SizedBox(width: 90, child: Text(_rs(e['amount'] as num?), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11))),
          SizedBox(width: 74, child: Text(st, textAlign: TextAlign.right, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary))),
        ]),
      ));
      if (!isSkipped && tE != null) prevReal = tE;
    }
    showDialog(context: context, builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(width: 760, height: 560, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 12, 8), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${u.name} — visit trail', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            Text('$bulkCount of ${ev.length - skipCount} actual visits logged within 90s of the previous · $skipCount shop${skipCount == 1 ? '' : 's'} skipped (excluded from bulk). Compare "Event time" (when the visit was marked) with "Synced" (when it reached the server) — clustered syncs but spread event times = late syncing, not bulk logging.',
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary, height: 1.3)),
          ])),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
        ])),
        const Divider(height: 1),
        Container(
          color: AppTheme.background,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(children: [
            SizedBox(width: 24, child: Text('#', style: _th)),
            Expanded(flex: 3, child: Text('Customer', style: _th)),
            SizedBox(width: 128, child: Text('Event time', style: _th)),
            SizedBox(width: 128, child: Text('Synced', style: _th)),
            SizedBox(width: 66, child: Text('Gap', textAlign: TextAlign.right, style: _th)),
            SizedBox(width: 90, child: Text('Amount', textAlign: TextAlign.right, style: _th)),
            SizedBox(width: 74, child: Text('Status', textAlign: TextAlign.right, style: _th)),
          ]),
        ),
        const Divider(height: 1),
        Expanded(child: ev.isEmpty
            ? const Center(child: Text('No visits in this period.', style: TextStyle(color: AppTheme.textSecondary)))
            : ListView(children: rows)),
      ])),
    ));
  }

  Widget _scorePill(num? score) {
    if (score == null) return Align(alignment: Alignment.centerRight, child: Text('—', style: _td.copyWith(color: AppTheme.textSecondary)));
    final s = score.toDouble();
    final c = s >= 75 ? Colors.green.shade700 : (s >= 50 ? Colors.amber.shade800 : AppTheme.danger);
    return Align(alignment: Alignment.centerRight, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
      child: Text('${s.round()}%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c)),
    ));
  }

  // ── Print / PDF (hidden iframe srcdoc) ─────────────────────────────────────
  void _print() {
    if (!_loaded) return;
    final totals = Map<String, dynamic>.from(_data?['totals'] as Map? ?? {});
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    String rs(num? v) => 'Rs. ${_money.format((v ?? 0).toDouble())}';
    String scoreCell(num? v) {
      if (v == null) return '<td class="r"><span class="muted">—</span></td>';
      final s = v.toDouble();
      final cls = s >= 75 ? 'pill-ok' : (s >= 50 ? 'pill-warn' : 'pill-bad');
      return '<td class="r"><span class="pill $cls">${s.round()}%</span></td>';
    }

    // A titled table; `cols` = [(header, align, isScore)].
    String tbl(String title, List<List<dynamic>> cols, List<List<dynamic>> rows) {
      final head = StringBuffer('<tr>');
      for (final c in cols) { head.write('<th class="${c[1]}">${esc(c[0] as String)}</th>'); }
      head.write('</tr>');
      if (rows.isEmpty) return '<div class="sec"><h2>${esc(title)}</h2><p class="muted">No data for this period.</p></div>';
      final body = StringBuffer();
      for (final r in rows) {
        body.write('<tr>');
        for (var i = 0; i < cols.length; i++) {
          final isScore = cols[i][2] == true;
          if (isScore) { body.write(scoreCell(r[i] as num?)); }
          else { body.write('<td class="${cols[i][1]}">${esc(r[i].toString())}</td>'); }
        }
        body.write('</tr>');
      }
      return '<div class="sec"><h2>${esc(title)}</h2><table><thead>$head</thead><tbody>$body</tbody></table></div>';
    }

    final collSp = tbl('Collection by Salesperson',
      [['Salesperson','l',false],['Collection','r',false],['Visits','r',false],['Visit Score','r',true]],
      [for (final r in _list('collection_by_salesperson'))
        [_s(r['name']), rs(r['collection'] as num?), '${r['visits'] ?? 0}', r['visit_score'] as num?]]);

    final collGrp = tbl('Collection by Customer Group', [['Customer Group','l',false],['Amount','r',false]],
      [for (final r in _list('collection_by_group')) [_s(r['group']), rs(r['amount'] as num?)]]);

    final payAcc = tbl('Payments — Paid to Accounts', [['Account','l',false],['Amount','r',false]],
      [for (final r in _list('payments_by_account')) [_s(r['account']), rs(r['amount'] as num?)]]);

    final exp = tbl('Expenses', [['Expense Head','l',false],['Amount','r',false]],
      [for (final r in _list('expenses')) [_s(r['head']), rs(r['amount'] as num?)]]);

    final plc = tbl('Placement Score by Market', [['Market','l',false],['Audited','r',false],['Present','r',false],['Score','r',true]],
      [for (final r in _list('placement_by_market'))
        [_s(r['market']), '${r['audited'] ?? 0}', '${r['present'] ?? 0}', r['score'] as num?]]);

    String erpName(Map<String, dynamic> r) {
      final bt = r['by_type'];
      final parts = <String>[];
      if (bt is Map) {
        final es = bt.entries.map((e) => MapEntry('${e.key}', (e.value is num) ? (e.value as num).toInt() : 0)).toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        for (final e in es) { if (e.value > 0) parts.add('${e.key} ${e.value}'); }
      }
      final base = _s(r['name']);
      return parts.isEmpty ? base : '$base  —  ${parts.join(', ')}';
    }
    final erp = tbl('Usage — ERP Users', [['ERP User','l',false],['Vouchers','r',false],['Active Days','r',false]],
      [for (final r in _list('usage_erp')) [erpName(r), '${r['vouchers'] ?? 0}', '${r['active_days'] ?? 0}']]);

    // Conversational usage blocks.
    final usg = StringBuffer();
    if (_usage.isNotEmpty) {
      usg.write('<div class="sec"><h2>Salesperson — App Usage</h2><div class="usage">');
      for (final u in _usage) {
        final hex = _sevHex(u.headSev);
        usg.write('<div class="ucard" style="border-left:4px solid $hex">');
        usg.write('<div class="uhead"><b>${esc(u.name)}</b>'
            '<span class="ubadge" style="color:$hex;background:${hex}1a">${esc(u.headLabel)}</span></div>');
        usg.write('<div class="umeta">${u.visits} visits · active ${u.days} day${u.days == 1 ? '' : 's'}'
            '${u.daysSince != null ? ' · last ${u.daysSince == 0 ? 'today' : '${u.daysSince}d ago'}' : ''}</div>');
        for (final n in u.notes) {
          usg.write('<div class="unote"><span class="dot" style="background:${_sevHex(n.sev)}"></span>${esc(n.text)}</div>');
        }
        usg.write('</div>');
      }
      usg.write('</div></div>');
    }

    // Manufacturing section (only present for orgs with the module).
    String mfg = '';
    if (_mfg != null) {
      final m = _mfg!;
      final delayed = [
        for (final d in (m['delayed'] as List? ?? const []))
          Map<String, dynamic>.from(d as Map)
      ];
      final insights = [
        for (final s in (m['insights'] as List? ?? const [])) s.toString()
      ];
      final rr = (m['rejectRate'] as num? ?? 0).toDouble() * 100;
      final mkpi = '<div class="kpis">'
          '<div class="kpi kb"><div class="kl">Open Jobs</div><div class="kv">${m['open'] ?? 0}</div></div>'
          '<div class="kpi kg"><div class="kl">Completed</div><div class="kv">${m['completed'] ?? 0}</div></div>'
          '<div class="kpi ki"><div class="kl">Units Produced</div><div class="kv">${_money.format((m['units'] as num? ?? 0))}</div></div>'
          '<div class="kpi ko"><div class="kl">Reject Rate</div><div class="kv">${rr.toStringAsFixed(1)}%</div></div>'
          '<div class="kpi kp"><div class="kl">Running Behind</div><div class="kv">${delayed.length}</div></div>'
          '</div>';
      final ins = StringBuffer('<ul class="ins">');
      for (final s in insights) {
        ins.write('<li>${esc(s)}</li>');
      }
      ins.write('</ul>');
      String delTbl;
      if (delayed.isEmpty) {
        delTbl = '<p class="muted">No job has been open longer than a week.</p>';
      } else {
        final rows = StringBuffer();
        for (final d in delayed.take(20)) {
          final prog =
              (d['open_ended'] as bool? ?? false) ? '—' : '${d['progress']}%';
          rows.write(
              '<tr><td>${esc('${d['job_number']}')}</td><td>${esc('${d['product']}')}</td>'
              '<td class="r">${d['age']}d</td><td class="r">$prog</td></tr>');
        }
        delTbl =
            '<table><thead><tr><th>Job</th><th>Product</th><th class="r">Age</th><th class="r">Progress</th></tr></thead><tbody>$rows</tbody></table>';
      }
      mfg = '<div class="sec"><h2>Manufacturing</h2>$mkpi'
          '<h3 class="sub">What to watch</h3>$ins'
          '<h3 class="sub">Jobs Running Behind (&gt;$_kDelayDays days)</h3>$delTbl</div>';
    }

    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final kpi = '<div class="kpis">'
        '<div class="kpi kb"><div class="kl">Total Sale</div><div class="kv">${rs(totals['sales'] as num?)}</div></div>'
        '<div class="kpi ki"><div class="kl">Total Purchase</div><div class="kv">${rs(totals['purchase'] as num?)}</div></div>'
        '<div class="kpi kg"><div class="kl">Total Collection</div><div class="kv">${rs(totals['collection'] as num?)}</div></div>'
        '<div class="kpi ko"><div class="kl">Payments Made</div><div class="kv">${rs(totals['payments'] as num?)}</div></div>'
        '</div>';

    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Super Summary</title>'
        '<style>'
        '@page { size: A4; margin: 0.7cm; } '
        '* { -webkit-print-color-adjust: exact; print-color-adjust: exact; box-sizing: border-box; } '
        'body { font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 11px; margin: 0; padding: 4px; } '
        '.hd { display:flex; justify-content:space-between; align-items:flex-end; border-bottom:3px solid #1e2a78; padding-bottom:8px; margin-bottom:12px; } '
        '.hd h1 { font-size: 20px; margin: 0; color:#1e2a78; } '
        '.hd .org { font-size: 12px; color:#444; margin-top:2px; } '
        '.hd .meta { font-size: 10px; color:#666; text-align:right; } '
        '.kpis { display:flex; gap:10px; margin: 4px 0 6px; } '
        '.kpi { flex:1; border-radius:10px; padding:10px 12px; color:#fff; } '
        '.kpi .kl { font-size:9.5px; text-transform:uppercase; letter-spacing:.5px; opacity:.9; } '
        '.kpi .kv { font-size:16px; font-weight:800; margin-top:3px; } '
        '.kb { background:#1e40af; } .ki { background:#3730a3; } .kg { background:#15803d; } .ko { background:#c2410c; } .kp { background:#7c3aed; } '
        '.sub { font-size:11px; margin:10px 0 4px; color:#444; text-transform:uppercase; letter-spacing:.4px; } '
        '.ins { margin:2px 0 4px; padding-left:16px; } .ins li { font-size:10.5px; line-height:1.5; margin-bottom:2px; } '
        '.sec { margin-top:16px; break-inside:avoid; } '
        'h2 { font-size:13px; margin:0 0 6px; color:#1e2a78; } '
        '.muted { color:#999; } '
        'table { width:100%; border-collapse:collapse; } '
        'th,td { border:1px solid #e3e6ef; padding:5px 8px; font-size:10px; } '
        'th { background:#eef2ff; text-align:left; font-weight:700; color:#333; } '
        'td.r, th.r { text-align:right; white-space:nowrap; } '
        'tbody tr:nth-child(even) td { background:#fafbff; } '
        '.pill { display:inline-block; padding:1px 8px; border-radius:10px; font-weight:700; font-size:10px; } '
        '.pill-ok { color:#15803d; background:#dcfce7; } .pill-warn { color:#b45309; background:#fef3c7; } .pill-bad { color:#b91c1c; background:#fee2e2; } '
        '.usage { display:grid; grid-template-columns:1fr 1fr; gap:10px; } '
        '.ucard { background:#fbfbfd; border:1px solid #e3e6ef; border-radius:8px; padding:9px 11px; break-inside:avoid; } '
        '.uhead { display:flex; justify-content:space-between; align-items:center; font-size:12px; } '
        '.ubadge { font-size:9px; font-weight:800; padding:1px 7px; border-radius:10px; } '
        '.umeta { font-size:9.5px; color:#666; margin:2px 0 6px; } '
        '.unote { font-size:10px; line-height:1.4; margin-bottom:3px; padding-left:12px; position:relative; } '
        '.dot { position:absolute; left:0; top:4px; width:7px; height:7px; border-radius:50%; } '
        '</style></head><body>'
        '<div class="hd"><div><h1>Org-Wide Super Summary</h1><div class="org">${esc(_orgName)}</div></div>'
        '<div class="meta">Period: ${esc(_periodLabel)}<br>Generated: $gen</div></div>'
        '$kpi$collSp$collGrp$payAcc$exp$plc$erp$mfg$usg'
        '<script>window.onload=function(){setTimeout(function(){window.focus();window.print();},350);};</script>'
        '</body></html>';

    final iframe = html.IFrameElement()
      ..style.position = 'fixed' ..style.right = '0' ..style.bottom = '0'
      ..style.width = '0' ..style.height = '0' ..style.border = '0';
    html.document.body!.append(iframe);
    iframe.srcdoc = doc;
    Future.delayed(const Duration(minutes: 2), () { try { iframe.remove(); } catch (_) {} });
  }
}
