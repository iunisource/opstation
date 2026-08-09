// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Skipped Receipt Serials — salesperson-wise.
///
/// For every salesperson, expands their logged receipt numbers into individual
/// slip numbers, sorts them, and flags any number that falls INSIDE a run they
/// entered but was never logged (a gap of 2–20; bigger jumps = a new receipt
/// book and are ignored). A gap can mean a collection was made but not entered,
/// or a voided/torn slip. Mirrors the per-person "skipped receipts" popup on the
/// team member profile, rolled up across the whole org for a chosen period.
///
/// Access is gated by the permission registry (report: skipped_receipts_report).

/// Expand a receipt-number field into every slip number it represents.
/// Handles "31457 & 31458", "31451 to 31452", and the shorthand "32282 83 84"
/// (= 32282, 32283, 32284). A plain "31457" returns [31457]; garbage returns [].
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

class _PersonGaps {
  final String userId;
  final String name;
  final int receiptsLogged; // distinct slip numbers found
  final List<int> skipped;
  _PersonGaps(this.userId, this.name, this.receiptsLogged, this.skipped);
}

class ErpSkippedReceiptsReportScreen extends ConsumerStatefulWidget {
  const ErpSkippedReceiptsReportScreen({super.key});
  @override
  ConsumerState<ErpSkippedReceiptsReportScreen> createState() =>
      _ErpSkippedReceiptsReportScreenState();
}

class _ErpSkippedReceiptsReportScreenState
    extends ConsumerState<ErpSkippedReceiptsReportScreen> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 29));
  DateTime _to = DateTime.now();
  bool _loading = false;
  bool _loaded = false;
  String? _error;

  List<_PersonGaps> _rows = []; // salespeople WITH gaps, worst first
  int _cleanCount = 0; // salespeople with receipts but no gaps

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String get _orgName => ref.read(currentUserProvider)?.orgName ?? '';

  static DateTime _d(DateTime d) => DateTime(d.year, d.month, d.day);

  (DateTime, DateTime) _quickRange(String key) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (key) {
      case 'yesterday':
        final y = today.subtract(const Duration(days: 1));
        return (y, y);
      case 'week':
        return (today.subtract(Duration(days: today.weekday - 1)), today);
      case 'month':
        return (DateTime(now.year, now.month, 1), today);
      case 'today':
      default:
        return (today, today);
    }
  }

  bool _isQuick(String key) {
    final r = _quickRange(key);
    return _d(_from) == r.$1 && _d(_to) == r.$2;
  }

  void _applyQuick(String key) {
    final r = _quickRange(key);
    setState(() {
      _from = r.$1;
      _to = r.$2;
    });
    _load();
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
    }
  }

  String get _periodLabel =>
      '${DateFormat('d MMM yyyy').format(_from)} – ${DateFormat('d MMM yyyy').format(_to)}';

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final fromStr = DateFormat('yyyy-MM-dd').format(_from);
      final toStr =
          DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));

      // Salesperson names.
      final usersRaw = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId);
      final names = <String, String>{
        for (final u in usersRaw as List)
          u['id'] as String: (u['name'] as String? ?? 'Unknown')
      };

      // Trips in the window → who owns which trip.
      final tripsRaw = await client
          .from('trips')
          .select('id, user_id')
          .eq('org_id', orgId)
          .gte('started_at', fromStr)
          .lt('started_at', toStr);
      final tripUser = <String, String>{};
      for (final t in tripsRaw as List) {
        final id = t['id'] as String?;
        final uid = t['user_id'] as String?;
        if (id != null && uid != null) tripUser[id] = uid;
      }
      if (tripUser.isEmpty) {
        setState(() {
          _rows = [];
          _cleanCount = 0;
          _loaded = true;
          _loading = false;
        });
        return;
      }

      // Visit receipts for those trips, in chunks (URL length safety).
      final tripIds = tripUser.keys.toList();
      final perUser = <String, List<int>>{};
      const chunk = 150;
      for (var i = 0; i < tripIds.length; i += chunk) {
        final slice = tripIds.sublist(
            i, i + chunk > tripIds.length ? tripIds.length : i + chunk);
        final vRes = await client
            .from('visits')
            .select('trip_id, receipt_number')
            .inFilter('trip_id', slice);
        for (final v in vRes as List) {
          final uid = tripUser[v['trip_id'] as String?];
          if (uid == null) continue;
          final slips = _receiptSlipNumbers((v['receipt_number'] as String?) ?? '');
          if (slips.isEmpty) continue;
          (perUser[uid] ??= <int>[]).addAll(slips);
        }
      }

      // Gap detection per user.
      final rows = <_PersonGaps>[];
      int clean = 0;
      perUser.forEach((uid, nums) {
        final uniq = nums.toSet().toList()..sort();
        final missing = <int>[];
        for (var i = 1; i < uniq.length; i++) {
          final gap = uniq[i] - uniq[i - 1];
          if (gap > 1 && gap <= 20) {
            for (var n = uniq[i - 1] + 1; n < uniq[i]; n++) missing.add(n);
          }
        }
        if (missing.isEmpty) {
          if (uniq.length >= 3) clean++;
        } else {
          rows.add(_PersonGaps(uid, names[uid] ?? 'Unknown', uniq.length, missing));
        }
      });
      rows.sort((a, b) => b.skipped.length.compareTo(a.skipped.length));

      setState(() {
        _rows = rows;
        _cleanCount = clean;
        _loaded = true;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  int get _totalSkipped => _rows.fold(0, (s, r) => s + r.skipped.length);

  // ── Print (Safari-safe: same-origin iframe self-print, never a blob tab) ──
  String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  void _print() {
    final gen = DateFormat('d MMM yyyy, h:mm a').format(DateTime.now());
    final b = StringBuffer();
    for (final r in _rows) {
      b.write('<h3>${_esc(r.name)} '
          '<span class="cnt">${r.skipped.length} skipped</span></h3>');
      b.write('<div class="serials">');
      for (final n in r.skipped) {
        b.write('<span class="s">$n</span>');
      }
      b.write('</div>');
    }
    if (_rows.isEmpty) {
      b.write('<p class="ok">No skipped receipt serials in this period.</p>');
    }
    final doc = '<!DOCTYPE html><html><head><meta charset="UTF-8">'
        '<title>Skipped Receipt Serials — ${_esc(_orgName)}</title><style>'
        'body{font-family:Arial,sans-serif;padding:22px;color:#111;font-size:12px}'
        'h1{font-size:20px;margin:0 0 2px}'
        'h3{font-size:13px;margin:18px 0 6px;border-bottom:1px solid #eee;padding-bottom:4px}'
        '.cnt{font-size:11px;color:#b45309;font-weight:700;margin-left:6px}'
        '.info{font-size:11px;color:#444;margin:1px 0}'
        '.serials{display:flex;flex-wrap:wrap;gap:5px}'
        '.s{border:1px solid #f0d58a;background:#fffbeb;border-radius:4px;'
        'padding:2px 7px;font-size:11px;font-variant-numeric:tabular-nums}'
        '.ok{color:#15803d;font-size:13px;margin-top:16px}'
        '.foot{margin-top:22px;font-size:10px;color:#888;border-top:1px solid #ccc;padding-top:8px}'
        '@media print{.no-print{display:none}}@page{margin:0.7cm}'
        '</style></head><body>'
        '<div class="no-print" style="margin-bottom:12px">'
        '<button onclick="window.print()">Print / Save PDF</button></div>'
        '<h1>Skipped Receipt Serials — by Salesperson</h1>'
        '${_orgName.isEmpty ? '' : '<div class="info"><b>Company:</b> ${_esc(_orgName)}</div>'}'
        '<div class="info"><b>Period:</b> ${_esc(_periodLabel)}</div>'
        '<div class="info"><b>Generated:</b> $gen</div>'
        '<div class="info"><b>Totals:</b> ${_rows.length} salespeople with gaps, '
        '$_totalSkipped skipped serial${_totalSkipped == 1 ? '' : 's'}.</div>'
        '${b.toString()}'
        '<div class="foot">A gap is a receipt number that falls between two the '
        'salesperson logged but was never entered (jumps over 20 are treated as a '
        'new book and ignored). Check the physical receipt books for these.</div>'
        '</body></html>';
    try {
      html.document.getElementById('ops-print-frame')?.remove();
      final frame = html.IFrameElement()
        ..id = 'ops-print-frame'
        ..style.position = 'fixed'
        ..style.left = '-9999px'
        ..style.width = '0'
        ..style.height = '0'
        ..style.border = '0';
      frame.srcdoc = doc.replaceFirst(
          '</body>',
          '<script>window.onload=function(){setTimeout(function(){'
              'try{window.focus();window.print();}catch(e){}},350);};</script></body>');
      html.document.body!.append(frame);
    } catch (_) {
      final blob = html.Blob([doc], 'text/html;charset=utf-8');
      html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
              Text('Skipped Receipt Serials',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text('Salesperson-wise gap check on logged receipt numbers',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.date_range, size: 16),
              label: Text(_periodLabel, style: const TextStyle(fontSize: 12)),
              onPressed: _pickRange,
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: _loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow, size: 18),
              label: const Text('Generate'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
              onPressed: _loading ? null : _load,
            ),
            const SizedBox(width: 8),
            if (_loaded && _rows.isNotEmpty)
              OutlinedButton.icon(
                icon: const Icon(Icons.print_outlined, size: 16),
                label: const Text('Print / PDF', style: TextStyle(fontSize: 12)),
                onPressed: _print,
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            _quickChip('Today', 'today'),
            _quickChip('Yesterday', 'yesterday'),
            _quickChip('This week', 'week'),
            _quickChip('This month', 'month'),
          ]),
        ),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _quickChip(String label, String key) {
    final sel = _isQuick(key);
    return ActionChip(
      label: Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? Colors.white : AppTheme.textPrimary)),
      backgroundColor: sel ? AppTheme.primary : Colors.white,
      side: BorderSide(color: sel ? AppTheme.primary : AppTheme.border),
      visualDensity: VisualDensity.compact,
      onPressed: _loading ? null : () => _applyQuick(key),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
          child: Text('Could not load: $_error',
              style: const TextStyle(color: AppTheme.danger)));
    }
    if (!_loaded) {
      return const Center(
          child: Text('Pick a period and Generate',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    if (_rows.isEmpty) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.check_circle_outline, color: AppTheme.success, size: 40),
        const SizedBox(height: 10),
        const Text('No skipped receipt serials in this period.',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (_cleanCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('$_cleanCount salespeople ran clean sequences.',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
      ]));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Summary strip.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.amber.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.amber.shade200),
          ),
          child: Row(children: [
            Icon(Icons.receipt_long, size: 18, color: Colors.amber.shade800),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '${_rows.length} salespeople have skipped serials — '
                  '$_totalSkipped in total for $_periodLabel. '
                  'A gap can mean a collection was made but not entered (or a voided/torn slip).',
                  style: const TextStyle(fontSize: 12.5)),
            ),
            if (_cleanCount > 0)
              Text('$_cleanCount clean',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.success)),
          ]),
        ),
        const SizedBox(height: 14),
        for (final r in _rows) _personCard(r),
      ]),
    );
  }

  Widget _personCard(_PersonGaps r) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r.name,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(20)),
            child: Text('${r.skipped.length} skipped',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.amber.shade900)),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 8),
          child: Text('${r.receiptsLogged} receipt numbers logged in this period',
              style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        ),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final n in r.skipped)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xFFF0D58A)),
              ),
              child: Text('$n', style: const TextStyle(fontSize: 12)),
            ),
        ]),
      ]),
    );
  }
}
