import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show PdfGoogleFonts;

import '../../../core/pdf/pdf_output.dart';
import '../../../core/search/text_search.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';
import 'time_in_market.dart';

/// Operations → Time in Market: each salesperson's / driver's day from
/// route (delivery) start and end and the time of every visit (drop).
class TimeInMarketScreen extends ConsumerStatefulWidget {
  const TimeInMarketScreen({super.key});
  @override
  ConsumerState<TimeInMarketScreen> createState() => _State();
}

class _State extends ConsumerState<TimeInMarketScreen> {
  DateTime _from = DateTime.now(), _to = DateTime.now();
  String _role = 'all'; // all | salesperson | driver
  String _query = '';
  bool _loading = true;
  String? _error;
  TimSettings _s = TimSettings.defaults;
  List<TimDay> _days = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.superAdmin || r == WebUserRole.masterAdmin || r == WebUserRole.admin;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final org = _orgId;
    if (org == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final s = await TimSettings.load(org);
      final days = await loadTimDays(org, _from, _to);
      if (!mounted) return;
      setState(() { _s = s; _days = days; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError('Could not load', e); _loading = false; });
    }
  }

  DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);
  bool _isRange(DateTime a, DateTime b) => _d(_from) == _d(a) && _d(_to) == _d(b);

  void _quick(String k) {
    final t = _d(DateTime.now());
    final (a, b) = switch (k) {
      'yesterday' => (t.subtract(const Duration(days: 1)), t.subtract(const Duration(days: 1))),
      'week' => (t.subtract(Duration(days: t.weekday - 1)), t),
      _ => (t, t),
    };
    setState(() { _from = a; _to = b; });
    _load();
  }

  Future<void> _pickRange() async {
    final p = await showDateRangePicker(
      context: context, firstDate: DateTime(2024), lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (p == null) return;
    setState(() { _from = p.start; _to = p.end; });
    _load();
  }

  List<TimDay> get _visible {
    final q = _query.trim().toLowerCase();
    return _days.where((d) {
      if (_role != 'all' && d.role != _role) return false;
      if (q.isNotEmpty && !matchesQuery('${d.name} ${d.routes.join(' ')}', q)) return false;
      return true;
    }).toList();
  }

  Future<void> _settings() async {
    final ctl = {
      'start': TextEditingController(text: TimSettings.hm(_s.dayStart)),
      'end': TextEditingController(text: TimSettings.hm(_s.dayEnd)),
      'late': TextEditingController(text: TimSettings.hm(_s.lateAfter)),
      'early': TextEditingController(text: TimSettings.hm(_s.earlyBefore)),
      'gap': TextEditingController(text: '${_s.gapMin}'),
    };
    String? err;
    int? hm(String v) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v.trim());
      if (m == null) return null;
      final h = int.parse(m.group(1)!), mi = int.parse(m.group(2)!);
      return (h > 23 || mi > 59) ? null : h * 60 + mi;
    }
    final next = await showDialog<TimSettings>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        Widget f(String k, String label, String hint) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(controller: ctl[k], decoration: InputDecoration(labelText: label, hintText: hint)),
            );
        return AlertDialog(
          title: const Text('Time in Market settings'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: f('start', 'Working day from', '09:30')),
                const SizedBox(width: 10),
                Expanded(child: f('end', 'to', '17:30')),
              ]),
              f('late', 'Late start if first stop is after', '10:00'),
              f('early', 'Early close if finished before', '17:00'),
              f('gap', 'Flag a gap longer than (minutes)', '45'),
              if (err != null) Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final a = hm(ctl['start']!.text), b = hm(ctl['end']!.text), l = hm(ctl['late']!.text),
                    e = hm(ctl['early']!.text), g = int.tryParse(ctl['gap']!.text.trim());
                if (a == null || b == null || l == null || e == null) {
                  return setLocal(() => err = 'Enter times like 09:30.');
                }
                if (b <= a) return setLocal(() => err = 'The day must end after it starts.');
                if (g == null || g < 5 || g > 600) return setLocal(() => err = 'Gap must be 5–600 minutes.');
                Navigator.pop(ctx, TimSettings(a, b, l, e, g));
              },
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
    if (next == null) return;
    try {
      await next.save(_orgId!);
      setState(() => _s = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not save', e))));
      }
    }
  }

  Future<void> _print() async {
    final days = _visible;
    if (days.isEmpty) return;
    pw.ThemeData? theme;
    try {
      theme = pw.ThemeData.withFont(base: await PdfGoogleFonts.notoSansRegular(), bold: await PdfGoogleFonts.notoSansBold());
    } catch (_) {}
    final s = _s;
    final doc = pw.Document(title: 'Time in Market', theme: theme);
    final head = pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey800);
    pw.Widget c(String t, {bool bold = false, PdfColor? col, pw.TextAlign a = pw.TextAlign.left}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
        child: pw.Text(t, textAlign: a, style: pw.TextStyle(fontSize: 8, color: col,
            fontWeight: bold ? pw.FontWeight.bold : null)));
    final range = _d(_from) == _d(_to)
        ? DateFormat('d MMM yyyy').format(_from)
        : '${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM yyyy').format(_to)}';
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      footer: (ctx) => pw.Row(children: [
        pw.Text('Printed ${DateFormat('d MMM yyyy, h:mm a').format(DateTime.now())}',
            style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
        pw.Spacer(),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
      ]),
      build: (ctx) => [
        if ((ref.read(currentUserProvider)?.orgName ?? '').isNotEmpty)
          pw.Text(ref.read(currentUserProvider)!.orgName!, style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        pw.Text('Time in Market — $range', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('Day ${TimSettings.hm(s.dayStart)}–${TimSettings.hm(s.dayEnd)} · late after ${TimSettings.hm(s.lateAfter)} · '
            'early before ${TimSettings.hm(s.earlyBefore)} · gaps over ${s.gapMin} min',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.SizedBox(height: 8),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
          columnWidths: const {0: pw.FlexColumnWidth(3), 11: pw.FlexColumnWidth(3)},
          children: [
            pw.TableRow(repeat: true, decoration: const pw.BoxDecoration(color: PdfColors.grey200), children: [
              for (final h in ['Name · route', 'Date', 'Start', 'First stop', 'Last stop', 'End', 'In market',
                'Stops', 'Per hr', 'Per stop', 'Longest gap', 'Flags'])
                pw.Padding(padding: const pw.EdgeInsets.all(4), child: pw.Text(h, style: head)),
            ]),
            for (final d in days)
              pw.TableRow(children: [
                c('${d.name}${d.routes.isEmpty ? '' : ' · ${d.routes.join(', ')}'}', bold: true),
                c(DateFormat('d MMM').format(d.date)),
                c(timClock(d.start)),
                c(timClock(d.first), col: d.lateStart(s) ? PdfColors.red700 : null),
                c(timClock(d.last)),
                c(d.open ? 'out' : timClock(d.end), col: d.earlyClose(s) ? PdfColors.red700 : null),
                c(timDur(d.inMarket)),
                c(d.totalStops > 0 ? '${d.visits}/${d.totalStops}' : '${d.visits}'),
                c(d.perHour.toStringAsFixed(1)),
                c(timDur(d.avgPerStop(s))),
                c(timDur(d.longestGap(s))),
                c(timFlags(d, s).map((f) => f.$1).join(', ')),
              ]),
          ],
        ),
      ],
    ));
    final Uint8List bytes = await doc.save();
    await outputPdf(bytes, 'Time in Market');
  }

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    final s = _s;
    final withStops = list.where((d) => d.visits > 0).toList();
    final avgIn = withStops.isEmpty
        ? Duration.zero
        : Duration(minutes: withStops.fold<int>(0, (a, d) => a + d.inMarket.inMinutes) ~/ withStops.length);
    final avgPh = withStops.isEmpty ? 0.0 : withStops.fold<double>(0, (a, d) => a + d.perHour) / withStops.length;
    final late = list.where((d) => d.lateStart(s)).length;
    final gaps = list.fold<int>(0, (a, d) => a + d.longGapCount(s));
    final early = list.where((d) => d.earlyClose(s)).length;
    Widget chip(String label, bool on, VoidCallback f) => ChoiceChip(label: Text(label), selected: on, onSelected: (_) => f());

    return Container(
      color: AppTheme.background,
      padding: context.pagePadding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 8, children: [
          const Text('Time in Market', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
          if (_isAdmin)
            IconButton(tooltip: 'Settings', onPressed: _settings, icon: const Icon(Icons.tune, size: 20)),
          OutlinedButton.icon(onPressed: _loading || list.isEmpty ? null : _print,
              icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
        ]),
        Text('How each salesperson\'s and driver\'s day was spent · day ${TimSettings.hm(s.dayStart)}–${TimSettings.hm(s.dayEnd)}, '
            'gaps over ${s.gapMin} min flagged',
            style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          chip('Today', _isRange(DateTime.now(), DateTime.now()), () => _quick('today')),
          chip('Yesterday', _isRange(DateTime.now().subtract(const Duration(days: 1)), DateTime.now().subtract(const Duration(days: 1))),
              () => _quick('yesterday')),
          chip('This week', _isRange(DateTime.now().subtract(Duration(days: DateTime.now().weekday - 1)), DateTime.now()),
              () => _quick('week')),
          OutlinedButton.icon(
            onPressed: _pickRange,
            icon: const Icon(Icons.date_range, size: 16),
            label: Text(_d(_from) == _d(_to)
                ? DateFormat('d MMM yyyy').format(_from)
                : '${DateFormat('d MMM').format(_from)} – ${DateFormat('d MMM yyyy').format(_to)}'),
          ),
          const SizedBox(width: 6),
          chip('All', _role == 'all', () => setState(() => _role = 'all')),
          chip('Salespeople', _role == 'salesperson', () => setState(() => _role = 'salesperson')),
          chip('Drivers', _role == 'driver', () => setState(() => _role = 'driver')),
          SizedBox(
            width: context.isMobile ? double.infinity : 260,
            child: TextField(
              decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search name or route…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        if (!_loading && _error == null)
          Wrap(spacing: 10, runSpacing: 10, children: [
            _kpi('${list.length}', 'days out (people × days)'),
            _kpi(timDur(avgIn), 'average time in market'),
            _kpi(avgPh.toStringAsFixed(1), 'stops per hour (average)'),
            _kpi(timDur(timAvgPerStop(list, s)), 'average time per stop'),
            _kpi('$late', 'late starts', bad: late > 0),
            _kpi('$gaps', 'long gaps', warn: gaps > 0),
            _kpi('$early', 'closed early', bad: early > 0),
          ]),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.danger)))
                  : list.isEmpty
                      ? const Center(child: Text('No routes or deliveries in this period.',
                          style: TextStyle(color: AppTheme.textSecondary)))
                      : SingleChildScrollView(child: Column(children: [
                          TimDayList(days: list, s: s),
                          const SizedBox(height: 8),
                          const Text('Worked out from route / delivery start and end and the time each stop was marked. '
                              'Time spent inside each shop is not measured.',
                              style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                        ])),
        ),
      ]),
    );
  }

  Widget _kpi(String v, String l, {bool bad = false, bool warn = false}) => Container(
        width: 170,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800,
              color: bad ? AppTheme.danger : warn ? Colors.amber.shade800 : null)),
          Text(l, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ]),
      );
}
