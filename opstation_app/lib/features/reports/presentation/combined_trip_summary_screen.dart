import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../../salesperson/data/salesperson_repository.dart';
import '../../salesperson/models/sales_route.dart';
import '../../salesperson/models/trip.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../providers/report_service.dart';
import '../services/report_context_builder.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/utils/free_visits.dart';

/// Combined Trip Summary: a multi-date, distance-only reimbursement sheet.
/// Pick a salesperson (or all) and a period; the PDF lists each day's total
/// road distance and a grand total, with Rate/km and Total Amount left blank
/// for finance. Optionally scoped to one salesperson via [scopedUserId].
class CombinedTripSummaryScreen extends ConsumerStatefulWidget {
  final String? scopedUserId;
  const CombinedTripSummaryScreen({super.key, this.scopedUserId});

  @override
  ConsumerState<CombinedTripSummaryScreen> createState() =>
      _CombinedTripSummaryScreenState();
}

enum _Period { week, month, custom }

enum _Action { preview, generate, share }

class _CombinedTripSummaryScreenState
    extends ConsumerState<CombinedTripSummaryScreen> {
  _Period _period = _Period.month;
  DateTimeRange? _custom;
  String? _userId;
  String? _routeId;
  bool _busy = false;

  // Generate / Share (a claim is recorded once, by Generate; Share only sends the copy).
  String? _statusKey; // what the status below was checked for
  bool? _generated; // null = still checking
  DateTime? _generatedAt; // known only when generated in this session
  Uint8List? _bytes; // the generated copy, kept so Share/View send exactly it

  bool get _isScoped => widget.scopedUserId != null;

  DateTimeRange _currentRange() {
    final now = DateTime.now();
    switch (_period) {
      case _Period.week:
        return DateTimeRange(
          start: DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 6)),
          end: now,
        );
      case _Period.month:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: now,
        );
      case _Period.custom:
        return _custom ??
            DateTimeRange(
              start: DateTime(now.year, now.month, 1),
              end: now,
            );
    }
  }

  String _periodLabel(DateTimeRange r) =>
      '${DateFormat('d MMM y').format(r.start)} - ${DateFormat('d MMM y').format(r.end)}';

  Map<String, String> _lastNames = const {};

  Future<_LoadResult> _loadTrips(DateTime start, DateTime end) async {
    final teamRepo = ref.read(scopedTeamRepositoryProvider);
    final salesRepo = ref.read(salespersonRepositoryProvider);
    final users = await teamRepo.all(includeInactive: true);
    final userNames = {for (final u in users) u.id: u.name};
    _lastNames = userNames;

    final targetIds = <String>[];
    final effectiveUserId = widget.scopedUserId ?? _userId;
    if (effectiveUserId != null) {
      targetIds.add(effectiveUserId);
    } else {
      for (final u in users) {
        if (u.role == UserRole.salesperson) targetIds.add(u.id);
      }
    }

    final trips = <Trip>[];
    for (final uid in targetIds) {
      trips.addAll(await salesRepo.tripsInRangeForUser(start, end, uid));
    }
    // Abandoned trips (ended with no visits) are left out of the summary. Visits
    // marked on the Free Route without a customer count as visits.
    final freeTrips = await FreeVisits.tripIdsWithVisits(ref.read(appDatabaseProvider));
    final filtered = (_routeId == null ? trips : trips.where((t) => t.routeId == _routeId))
        .where((t) => !(t.endedAt != null && t.visits.isEmpty && !freeTrips.contains(t.id)))
        .toList();
    return _LoadResult(trips: filtered, userNames: userNames);
  }

  String? _issueKey() {
    final range = _currentRange();
    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final end = DateTime(range.end.year, range.end.month, range.end.day);
    final effectiveUserId = widget.scopedUserId ?? _userId;
    return '${effectiveUserId ?? 'all'}|${_ymd(start)}|${_ymd(end)}';
  }

  /// Re-check "already generated?" whenever the dates / person / route change. Read-only.
  void _syncStatus() {
    final key = '${_issueKey()}|${_routeId ?? ''}';
    if (_statusKey == key) return;
    _statusKey = key;
    _generated = null;
    _generatedAt = null;
    _bytes = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStatus(key));
  }

  Future<void> _checkStatus(String statusKey) async {
    final actor = ref.read(authControllerProvider).valueOrNull;
    final issued = await ref.read(reportServiceProvider).registerReportIssue(
          type: 'combined_summary',
          key: _issueKey()!,
          orgId: actor?.organizationId,
          by: actor?.id,
          claim: false,
        );
    if (!mounted || _statusKey != statusKey) return;
    setState(() => _generated = issued);
  }

  /// Builds the PDF. [claim] = Generate (records the claim once); otherwise it only reads.
  Future<Uint8List?> _build({required bool claim}) async {
    final range = _currentRange();
    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final end = DateTime(range.end.year, range.end.month, range.end.day);
    final actor = ref.read(authControllerProvider).valueOrNull;
    final loaded = await _loadTrips(start, end);
    if (loaded.trips.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No trips in the selected period.')),
        );
      }
      return null;
    }
    final effectiveUserId = widget.scopedUserId ?? _userId;
    final showSalesperson = effectiveUserId == null;
    final salespersonLabel = effectiveUserId == null
        ? 'All salespersons'
        : (loaded.userNames[effectiveUserId] ?? 'Salesperson');

    final svc = ref.read(reportServiceProvider);
    final key = _issueKey()!;
    await svc.registerReportIssue(
      type: 'combined_summary',
      key: key,
      orgId: actor?.organizationId,
      by: actor?.id,
      claim: claim,
    );
    // Same days one week earlier, for the "Last week" column.
    final lastWeek = await _loadTrips(
        start.subtract(const Duration(days: 7)), end.subtract(const Duration(days: 7)));
    return svc.buildCombinedSummaryBytes(
      trips: loaded.trips,
      lastWeekTrips: lastWeek.trips,
      userNames: loaded.userNames,
      showSalesperson: showSalesperson,
      periodLabel: _periodLabel(range),
      salespersonLabel: salespersonLabel,
      actor: actor,
      duplicate: false, // replaced by the "already generated" note (SQL 470)
      reimbKey: key,
      claimantId: effectiveUserId,
      reimbRecord: claim,
      trail: (claim || svc.isAdminActor)
          ? await svc.logReportIssue(type: 'combined_summary', key: key, orgId: actor?.organizationId)
          : const [],
    );
  }

  String get _fname {
    final range = _currentRange();
    return 'combined_summary_${_ymd(range.start)}_${_ymd(range.end)}.pdf';
  }

  Future<void> _run(_Action action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final statusKey = _statusKey;
    try {
      switch (action) {
        case _Action.generate:
          final bytes = await _build(claim: true);
          if (bytes == null) return;
          if (mounted && _statusKey == statusKey) {
            setState(() {
              _bytes = bytes;
              _generated = true;
              _generatedAt = DateTime.now();
            });
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Generated and sent for approval. You can share it now.')),
            );
          }
          break;
        case _Action.preview:
          final bytes = _bytes ?? await _build(claim: false);
          if (bytes == null) return;
          await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fname);
          break;
        case _Action.share:
          final bytes = _bytes ?? await _build(claim: false);
          if (bytes == null) return;
          try {
            await Printing.sharePdf(bytes: bytes, filename: _fname);
          } on PlatformException {
            // Platform without a share sheet (e.g. emulator) — ignore.
          }
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final range = _currentRange();
    _syncStatus();
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Combined trip summary',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _periodChip('This week', _period == _Period.week, () {
                      setState(() {
                        _period = _Period.week;
                        _custom = null;
                      });
                    }),
                    _periodChip('This month', _period == _Period.month, () {
                      setState(() {
                        _period = _Period.month;
                        _custom = null;
                      });
                    }),
                    _periodChip(
                      _custom == null
                          ? 'Date range'
                          : '${DateFormat('d MMM').format(_custom!.start)} – ${DateFormat('d MMM').format(_custom!.end)}',
                      _period == _Period.custom,
                      _pickRange,
                      icon: Icons.calendar_today_outlined,
                    ),
                  ],
                ),
                if (!_isScoped) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: _userDropdown()),
                      const SizedBox(width: 8),
                      Expanded(child: _routeDropdown()),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _DaysPreview(
              start: DateTime(range.start.year, range.start.month, range.start.day),
              end: DateTime(range.end.year, range.end.month, range.end.day),
              load: _loadTrips,
              onOpenDay: _openDay,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _actionBar(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _spinner() => const SizedBox(
      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));

  Widget _actionBar() {
    final isAdmin = ref.read(reportServiceProvider).isAdminActor;
    final generated = _generated == true;
    final canShare = generated || isAdmin;
    final status = _generated == null
        ? ('Checking…', Colors.grey.shade700, const Color(0xFFF3F4F6), Icons.hourglass_empty)
        : generated
            ? (
                _generatedAt == null
                    ? 'Generated · sent for approval'
                    : 'Generated ${DateFormat('d MMM, h:mm a').format(_generatedAt!)} · sent for approval',
                const Color(0xFF047857),
                const Color(0xFFECFDF5),
                Icons.check_circle_outline
              )
            : ('Not generated yet', Colors.grey.shade700, const Color(0xFFF3F4F6), Icons.radio_button_unchecked);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!isAdmin)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(color: status.$3, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(status.$4, size: 16, color: status.$2),
              const SizedBox(width: 8),
              Expanded(child: Text(status.$1, style: TextStyle(fontSize: 12.5, color: status.$2))),
            ]),
          ),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_Action.preview),
              icon: const Icon(Icons.preview_outlined, size: 18),
              label: Text(generated ? 'View PDF' : 'Preview PDF'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            ),
          ),
          if (!isAdmin) ...[
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: generated
                  ? OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Generated'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    )
                  : ElevatedButton.icon(
                      onPressed: _busy || _generated == null ? null : () => _run(_Action.generate),
                      icon: _busy ? _spinner() : const Icon(Icons.bolt, size: 18),
                      label: const Text('Generate'),
                      style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
                    ),
            ),
          ],
        ]),
        const SizedBox(height: 10),
        ElevatedButton.icon(
          onPressed: _busy || !canShare ? null : () => _run(_Action.share),
          icon: _busy && isAdmin ? _spinner() : const Icon(Icons.ios_share, size: 18),
          label: const Text('Share'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
        if (!isAdmin && !generated && _generated != null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Generate records this claim for approval, once.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _periodChip(String label, bool selected, VoidCallback onTap,
      {IconData? icon}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.borderLight),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 13,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).textTheme.bodyMedium?.color),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected
                    ? Colors.white
                    : Theme.of(context).textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userDropdown() {
    final teamRepo = ref.watch(scopedTeamRepositoryProvider);
    return FutureBuilder<List<TeamUser>>(
      future: teamRepo.all(includeInactive: false),
      builder: (context, snap) {
        final users = (snap.data ?? const <TeamUser>[])
            .where((u) => u.role == UserRole.salesperson)
            .toList();
        return DropdownButtonFormField<String?>(
          value: _userId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Salesperson',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.person_outline, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All salespersons'),
            ),
            for (final u in users)
              DropdownMenuItem<String?>(
                value: u.id,
                child: Text(u.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _userId = v),
        );
      },
    );
  }

  Widget _routeDropdown() {
    final salesRepo = ref.watch(salespersonRepositoryProvider);
    return FutureBuilder<List<SalesRoute>>(
      future: salesRepo.allRoutesIncludingInactive(),
      builder: (context, snap) {
        final routes = snap.data ?? const <SalesRoute>[];
        return DropdownButtonFormField<String?>(
          value: _routeId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Route',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            prefixIcon: const Icon(Icons.route_outlined, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All routes'),
            ),
            for (final r in routes)
              DropdownMenuItem<String?>(
                value: r.id,
                child: Text(r.isActive ? r.name : '${r.name} (inactive)',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => _routeId = v),
        );
      },
    );
  }

  void _openDay(_DayGroup g) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DaySheet(group: g, userNames: _lastNames),
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2, 1, 1),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _custom,
    );
    if (picked != null) {
      setState(() {
        _custom = picked;
        _period = _Period.custom;
      });
    }
  }
}

class _LoadResult {
  final List<Trip> trips;
  final Map<String, String> userNames;
  _LoadResult({required this.trips, required this.userNames});
}

/// Lightweight in-app list of the days that will appear in the report. It shows
/// the routes and trip count per day; the road distances are computed when the
/// PDF is previewed or shared (that's the network-heavy step).
class _DaysPreview extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final Future<_LoadResult> Function(DateTime, DateTime) load;
  final void Function(_DayGroup) onOpenDay;

  const _DaysPreview(
      {required this.start,
      required this.end,
      required this.load,
      required this.onOpenDay});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LoadResult>(
      future: load(start, end),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final trips = snap.data?.trips ?? const <Trip>[];
        final names = snap.data?.userNames ?? const <String, String>{};
        if (trips.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No trips in the selected period / filters.',
                  textAlign: TextAlign.center),
            ),
          );
        }
        // Group by (salesperson, day).
        final groups = <String, _DayGroup>{};
        for (final t in trips) {
          final d = DateTime(t.startedAt.year, t.startedAt.month, t.startedAt.day);
          final key = '${t.userId}|${d.toIso8601String()}';
          final g = groups.putIfAbsent(
            key,
            () => _DayGroup(date: d, salesperson: names[t.userId] ?? t.userName),
          );
          g.trips += 1;
          g.tripList.add(t);
          if (t.routeName.trim().isNotEmpty) g.routes.add(t.routeName.trim());
        }
        final list = groups.values.toList()
          ..sort((a, b) {
            final s = a.salesperson.compareTo(b.salesperson);
            return s != 0 ? s : a.date.compareTo(b.date);
          });
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: [
            Text(
              '${list.length} day${list.length == 1 ? '' : 's'} · ${trips.length} trip${trips.length == 1 ? '' : 's'} — tap a day for its breakdown.',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondaryLight),
            ),
            const SizedBox(height: 10),
            for (final g in list)
              InkWell(
                onTap: () => onOpenDay(g),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.borderLight),
                ),
                child: Row(children: [
                  Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            DateFormat('EEE, d MMM y').format(g.date),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text('${g.trips} trip${g.trips == 1 ? '' : 's'}',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondaryLight)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${g.salesperson} · ${g.routes.join(', ')}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondaryLight),
                    ),
                  ],
                )),
                  const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                ]),
              ),
              ),
          ],
        );
      },
    );
  }
}

class _DayGroup {
  final DateTime date;
  final String salesperson;
  final Set<String> routes = {};
  final List<Trip> tripList = [];
  int trips = 0;
  _DayGroup({required this.date, required this.salesperson});
}


/// Bottom sheet for one day: per-trip distance and a plain "day summary" PDF.
/// Generate builds the PDF (no claim is recorded, no approval marks); Share
/// stays locked until it has been generated.
class _DaySheet extends ConsumerStatefulWidget {
  final _DayGroup group;
  final Map<String, String> userNames;
  const _DaySheet({required this.group, required this.userNames});

  @override
  ConsumerState<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends ConsumerState<_DaySheet> {
  Map<String, double>? _km; // trip id -> km (null while loading)
  Object? _error;
  Map<String, Uint8List>? _pdfs; // trip id -> that trip's Trip Summary PDF
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadKm();
  }

  Future<void> _loadKm() async {
    try {
      final builder = ref.read(reportContextBuilderProvider);
      final trips = widget.group.tripList;
      final ctxs = await Future.wait(trips.map((t) => builder.build(t)));
      if (!mounted) return;
      setState(() => _km = {
            for (var i = 0; i < trips.length; i++) trips[i].id: ctxs[i].totalDistanceKm
          });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _fname(Trip t) =>
      'trip_summary_${DateFormat('yyyyMMdd').format(t.startedAt.toLocal())}_${t.id.length > 6 ? t.id.substring(t.id.length - 6) : t.id}.pdf';

  /// Generate = build the regular single-trip Trip Summary for each trip of the
  /// day. Read-only: it records no claim (that stays with the trip's own Export).
  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final actor = ref.read(authControllerProvider).valueOrNull;
      final svc = ref.read(reportServiceProvider);
      final out = <String, Uint8List>{};
      for (final t in widget.group.tripList) {
        out[t.id] = await svc.buildBytes(kind: ReportKind.summary, trip: t, actor: actor);
      }
      if (mounted) setState(() => _pdfs = out);
    } catch (e) {
      _toast('Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view(Trip t) async {
    final b = _pdfs?[t.id];
    if (b == null) return;
    await Printing.layoutPdf(onLayout: (_) async => b, name: _fname(t));
  }

  Future<void> _share(Trip t) async {
    final b = _pdfs?[t.id];
    if (b == null) return;
    try {
      await Printing.sharePdf(bytes: b, filename: _fname(t));
    } on PlatformException {
      // No share sheet on this platform.
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final km = _km;
    final total = km == null ? null : km.values.fold<double>(0, (a, b) => a + b);
    final generated = _pdfs != null;
    final single = g.tripList.length == 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(DateFormat('EEE, d MMM y').format(g.date),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(
              '${g.salesperson} · ${g.trips} trip${g.trips == 1 ? '' : 's'}'
              '${total == null ? '' : ' · ${total.toStringAsFixed(1)} km'}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text('Could not calculate distances: $_error',
                  style: const TextStyle(fontSize: 12.5, color: Colors.red))
            else if (km == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.borderLight),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(children: [
                  for (var i = 0; i < g.tripList.length; i++)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        border: i == 0
                            ? null
                            : const Border(top: BorderSide(color: AppColors.borderLight)),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                                g.tripList[i].routeName.trim().isEmpty
                                    ? 'Free route'
                                    : g.tripList[i].routeName.trim(),
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                            Text(
                                DateFormat('h:mm a').format(g.tripList[i].startedAt.toLocal()) +
                                    (g.tripList[i].endedAt == null
                                        ? ' · in progress'
                                        : ' – ${DateFormat('h:mm a').format(g.tripList[i].endedAt!.toLocal())}'),
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textSecondaryLight)),
                          ]),
                        ),
                        Text('${(km[g.tripList[i].id] ?? 0).toStringAsFixed(1)} km',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        if (generated && !single) ...[
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'View',
                            icon: const Icon(Icons.preview_outlined, size: 20),
                            onPressed: () => _view(g.tripList[i]),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Share',
                            icon: const Icon(Icons.ios_share, size: 20),
                            onPressed: () => _share(g.tripList[i]),
                          ),
                        ],
                      ]),
                    ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: AppColors.borderLight)),
                    ),
                    child: Row(children: [
                      const Expanded(
                          child: Text('Day total',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
                      Text('${total!.toStringAsFixed(1)} km',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ]),
              ),
            const SizedBox(height: 14),
            if (generated && !single)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Generated. Use the icons on each trip to view or share its summary.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              )
            else
            Row(children: [
              Expanded(
                child: generated
                    ? OutlinedButton.icon(
                        onPressed: () => _view(g.tripList.first),
                        icon: const Icon(Icons.preview_outlined, size: 18),
                        label: const Text('View PDF'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                      )
                    : ElevatedButton.icon(
                        onPressed: _busy || km == null ? null : _generate,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                        label: Text(single ? 'Generate PDF' : 'Generate ${g.tripList.length} PDFs'),
                        style: ElevatedButton.styleFrom(minimumSize: const Size(0, 46)),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: generated ? () => _share(g.tripList.first) : null,
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(0, 46)),
                ),
              ),
            ]),
            if (!generated)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Trip Summary for this day. Share unlocks after it is generated.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }
}
