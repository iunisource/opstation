import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

class SalespersonHistoryScreen extends ConsumerStatefulWidget {
  final String userId;
  final String userName;
  const SalespersonHistoryScreen({
    super.key,
    required this.userId,
    required this.userName,
  });

  @override
  ConsumerState<SalespersonHistoryScreen> createState() =>
      _SalespersonHistoryScreenState();
}

class _SalespersonHistoryScreenState
    extends ConsumerState<SalespersonHistoryScreen> {
  List<Map<String, dynamic>> _trips = [];
  Map<String, List<Map<String, dynamic>>> _visitsByTrip = {};
  Map<String, Map<String, dynamic>> _customers = {};
  final Set<String> _expanded = {};
  bool _loading = true;
  String? _error;

  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _to = DateTime(now.year, now.month, now.day);
    _from = _to.subtract(const Duration(days: 30));
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fromIso = DateFormat('yyyy-MM-dd').format(_from);
      final toIso =
          DateFormat('yyyy-MM-dd').format(_to.add(const Duration(days: 1)));

      final tripsRes = await Supabase.instance.client
          .from('trips')
          .select()
          .eq('user_id', widget.userId)
          .gte('started_at', fromIso)
          .lt('started_at', toIso)
          .order('started_at', ascending: false);
      final trips = List<Map<String, dynamic>>.from(tripsRes);

      final visitsByTrip = <String, List<Map<String, dynamic>>>{};
      final customers = <String, Map<String, dynamic>>{};

      if (trips.isNotEmpty) {
        final tripIds = trips.map((t) => t['id'] as String).toList();
        final visitsRes = await Supabase.instance.client
            .from('visits')
            .select()
            .inFilter('trip_id', tripIds)
            .order('timestamp', ascending: true);
        final visits = List<Map<String, dynamic>>.from(visitsRes);
        for (final v in visits) {
          (visitsByTrip[v['trip_id'] as String] ??= []).add(v);
        }

        final custIds =
            visits.map((v) => v['customer_id'] as String?).whereType<String>().toSet().toList();
        if (custIds.isNotEmpty) {
          final custRes = await Supabase.instance.client
              .from('customers')
              .select('id, shop_name, code')
              .inFilter('id', custIds);
          for (final c in custRes) {
            customers[c['id'] as String] = Map<String, dynamic>.from(c);
          }
        }
      }

      setState(() {
        _trips = trips;
        _visitsByTrip = visitsByTrip;
        _customers = customers;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? _from : _to;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked;
        if (_from.isAfter(_to)) _from = _to;
      }
    });
    _load();
  }

  // ---- Aggregates ------------------------------------------------------

  int get _totalVisits =>
      _visitsByTrip.values.fold(0, (sum, list) => sum + list.length);
  int get _totalCollected => _visitsByTrip.values.fold(0, (sum, list) {
        return sum + list.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));
      });

  // ---- Build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM y');
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _Header(
              userName: widget.userName,
              onBack: () => Navigator.of(context).pop(),
              onRefresh: _load,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
              child: Row(
                children: [
                  _DateChip(
                    label: 'From',
                    date: df.format(_from),
                    onTap: () => _pickDate(isFrom: true),
                  ),
                  const SizedBox(width: 8),
                  _DateChip(
                    label: 'To',
                    date: df.format(_to),
                    onTap: () => _pickDate(isFrom: false),
                  ),
                  const SizedBox(width: 16),
                  _StatPill(label: 'Trips', value: '${_trips.length}'),
                  const SizedBox(width: 8),
                  _StatPill(label: 'Visits', value: '$_totalVisits'),
                  const SizedBox(width: 8),
                  _StatPill(
                      label: 'Collected', value: 'Rs $_totalCollected'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Failed to load: $_error',
              style: const TextStyle(color: AppTheme.danger)),
        ),
      );
    }
    if (_trips.isEmpty) {
      return const Center(
        child: Text('No trips in this date range',
            style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      itemCount: _trips.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final t = _trips[i];
        final tripId = t['id'] as String;
        final visits = _visitsByTrip[tripId] ?? const [];
        return _TripCard(
          trip: t,
          visits: visits,
          customers: _customers,
          expanded: _expanded.contains(tripId),
          onToggle: () => setState(() {
            if (_expanded.contains(tripId)) {
              _expanded.remove(tripId);
            } else {
              _expanded.add(tripId);
            }
          }),
        );
      },
    );
  }
}

// ---- Header ----------------------------------------------------------

class _Header extends StatelessWidget {
  final String userName;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  const _Header(
      {required this.userName, required this.onBack, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 16, 32, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: onBack,
            tooltip: 'Back',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Visit history',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(userName,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

// ---- Filter chips ----------------------------------------------------

class _DateChip extends StatelessWidget {
  final String label;
  final String date;
  final VoidCallback onTap;
  const _DateChip(
      {required this.label, required this.date, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Text('$label: ',
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          Text(date,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.calendar_today_outlined,
              size: 14, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  const _StatPill({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Text(label,
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(width: 6),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
      ]),
    );
  }
}

// ---- Trip card -------------------------------------------------------

class _TripCard extends StatelessWidget {
  final Map<String, dynamic> trip;
  final List<Map<String, dynamic>> visits;
  final Map<String, Map<String, dynamic>> customers;
  final bool expanded;
  final VoidCallback onToggle;

  const _TripCard({
    required this.trip,
    required this.visits,
    required this.customers,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final routeName = trip['route_name'] as String? ?? '—';
    final startedAt = trip['started_at'] != null
        ? DateTime.parse(trip['started_at'] as String).toLocal()
        : null;
    final endedAt = trip['ended_at'] != null
        ? DateTime.parse(trip['ended_at'] as String).toLocal()
        : null;
    final closeReason = trip['close_reason'] as String?;
    final isActive = endedAt == null;
    final dfDate = DateFormat('d MMM y');
    final dfTime = DateFormat('HH:mm');
    final amount =
        visits.fold<int>(0, (s, v) => s + ((v['amount'] as int?) ?? 0));
    final verifiedCount =
        visits.where((v) => v['status'] == 'verified').length;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: (isActive ? AppTheme.warning : AppTheme.success)
                          .withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      isActive ? Icons.timelapse : Icons.check_circle,
                      color: isActive ? AppTheme.warning : AppTheme.success,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(routeName,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Row(children: [
                          if (startedAt != null) ...[
                            Text(dfDate.format(startedAt),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                            const SizedBox(width: 6),
                            Text('· ${dfTime.format(startedAt)}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                            if (endedAt != null) ...[
                              const SizedBox(width: 4),
                              Text('→ ${dfTime.format(endedAt)}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary)),
                            ],
                          ],
                        ]),
                      ],
                    ),
                  ),
                  _MiniStat(label: 'visits', value: '${visits.length}'),
                  const SizedBox(width: 10),
                  _MiniStat(
                      label: 'verified', value: '$verifiedCount'),
                  const SizedBox(width: 10),
                  _MiniStat(label: 'collected', value: 'Rs $amount'),
                  const SizedBox(width: 10),
                  if (isActive)
                    _StatusPill(label: 'Active', color: AppTheme.warning),
                  if (!isActive && closeReason == 'cutoff')
                    _StatusPill(label: 'Cutoff', color: AppTheme.danger),
                  if (!isActive && closeReason != 'cutoff')
                    _StatusPill(label: 'Completed', color: AppTheme.success),
                  const SizedBox(width: 8),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (visits.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('No visits recorded on this trip',
                    style: TextStyle(color: AppTheme.textSecondary)),
              )
            else
              Column(
                children: [
                  for (final v in visits) _VisitRow(visit: v, customers: customers),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        Text(label,
            style:
                const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ---- Visit row -------------------------------------------------------

class _VisitRow extends StatelessWidget {
  final Map<String, dynamic> visit;
  final Map<String, Map<String, dynamic>> customers;
  const _VisitRow({required this.visit, required this.customers});

  @override
  Widget build(BuildContext context) {
    final status = visit['status'] as String? ?? '';
    final cust = customers[visit['customer_id']];
    final custName = cust?['shop_name'] as String? ?? '(unknown customer)';
    final custCode = cust?['code'] as String? ?? '';
    final ts = visit['timestamp'] != null
        ? DateTime.parse(visit['timestamp'] as String).toLocal()
        : null;
    final amount = (visit['amount'] as int?) ?? 0;
    final receipt = visit['receipt_number'] as String?;
    final notes = visit['notes'] as String?;
    final lat = (visit['captured_lat'] as num?)?.toDouble();
    final lng = (visit['captured_lng'] as num?)?.toDouble();
    final distance = (visit['distance_meters'] as num?)?.toDouble();

    final (icon, color, label) = switch (status) {
      'verified' => (Icons.check_circle, AppTheme.success, 'Verified'),
      'outside' => (Icons.warning_amber_rounded, AppTheme.warning, 'Outside'),
      'noLocation' => (Icons.location_off_outlined, AppTheme.danger, 'No location'),
      'skipped' => (Icons.skip_next, AppTheme.textSecondary, 'Skipped'),
      _ => (Icons.circle_outlined, AppTheme.textSecondary, status),
    };

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.border, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      custCode.isNotEmpty ? '$custCode · $custName' : custName,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 10,
                            color: color,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 4),
                if (ts != null)
                  Text(DateFormat('HH:mm · d MMM').format(ts),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                if (lat != null && lng != null) ...[
                  const SizedBox(height: 4),
                  _CoordsRow(lat: lat, lng: lng, distance: distance),
                ],
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(notes,
                      style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: AppTheme.textSecondary)),
                ],
              ],
            ),
          ),
          if (amount > 0) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Rs $amount',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                if (receipt != null && receipt.isNotEmpty)
                  Text('#$receipt',
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CoordsRow extends StatelessWidget {
  final double lat;
  final double lng;
  final double? distance;
  const _CoordsRow(
      {required this.lat, required this.lng, this.distance});

  @override
  Widget build(BuildContext context) {
    final formatted = '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.location_on_outlined,
            size: 12, color: AppTheme.textSecondary),
        const SizedBox(width: 3),
        InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: formatted));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Coordinates copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            }
          },
          child: Text(formatted,
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: () async {
            final uri = Uri.parse(
                'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          child: const Text('Open in Maps',
              style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w700)),
        ),
        if (distance != null) ...[
          const SizedBox(width: 8),
          Text('· ${distance!.toStringAsFixed(0)} m away',
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ],
    );
  }
}
