import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

class DeliveriesScreen extends ConsumerStatefulWidget {
  const DeliveriesScreen({super.key});
  @override
  ConsumerState<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

/// Logical groupings used by the status pill bar. "Active" maps to
/// assigned + in_progress so users have one tab for "currently in
/// flight." Drafts and completed/cancelled get their own pills.
enum _StatusFilter { all, draft, active, completed, cancelled }

class _DeliveriesScreenState extends ConsumerState<DeliveriesScreen> {
  // All deliveries with their hydrated stop counts. Filtering happens
  // in-memory off this base list — fine at our scale, avoids re-querying
  // Supabase on every keystroke.
  List<_DeliveryRow> _all = [];
  List<_DeliveryRow> _filtered = [];
  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _suppliers = [];
  bool _loading = true;

  // Filter state
  final _searchCtrl = TextEditingController();
  _StatusFilter _statusFilter = _StatusFilter.all;
  // null = all types, 'delivery' or 'pickup'
  String? _typeFilter;
  DateTime? _dateFrom;
  DateTime? _dateTo;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_filter);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final deliveries = await client
          .from('deliveries')
          .select()
          .eq('org_id', orgId)
          .order('created_at', ascending: false);

      final stops = await client
          .from('delivery_stops')
          .select('delivery_id, stop_type');

      // Per-job composition: total stops plus how many are deliveries vs
      // pickups (a job can mix both).
      final countByDelivery = <String, int>{};
      final delByDelivery = <String, int>{};
      final pickByDelivery = <String, int>{};
      for (final s in (stops as List)) {
        final m = s as Map;
        final id = m['delivery_id'] as String;
        countByDelivery[id] = (countByDelivery[id] ?? 0) + 1;
        if ((m['stop_type'] as String?) == 'pickup') {
          pickByDelivery[id] = (pickByDelivery[id] ?? 0) + 1;
        } else {
          delByDelivery[id] = (delByDelivery[id] ?? 0) + 1;
        }
      }

      final drivers = await client
          .from('users')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('role', 'driver');
      // Paginate past PostgREST's 1000-row default cap
      final List<Map<String, dynamic>> customers = [];
      {
        const pageSize = 1000;
        var offset = 0;
        while (true) {
          final page = await client
              .from('customers')
              .select('id, shop_name, code, latitude, longitude')
              .eq('org_id', orgId)
              .order('shop_name')
              .range(offset, offset + pageSize - 1);
          customers.addAll(List<Map<String, dynamic>>.from(page));
          if (page.length < pageSize) break;
          offset += pageSize;
        }
      }

      // Suppliers (for the Create Pickups modal). Paginated the same way.
      final List<Map<String, dynamic>> suppliers = [];
      {
        const pageSize = 1000;
        var offset = 0;
        while (true) {
          final page = await client
              .from('suppliers')
              .select('id, name, latitude, longitude')
              .eq('org_id', orgId)
              .order('name')
              .range(offset, offset + pageSize - 1);
          suppliers.addAll(List<Map<String, dynamic>>.from(page));
          if (page.length < pageSize) break;
          offset += pageSize;
        }
      }

      setState(() {
        _all = [
          for (final d in (deliveries as List))
            _DeliveryRow(
              data: Map<String, dynamic>.from(d as Map),
              stopCount: countByDelivery[(d as Map)['id'] as String] ?? 0,
              deliveryCount: delByDelivery[(d as Map)['id'] as String] ?? 0,
              pickupCount: pickByDelivery[(d as Map)['id'] as String] ?? 0,
            )
        ];
        _drivers = List<Map<String, dynamic>>.from(drivers);
        _customers = customers;
        _suppliers = suppliers;
        _loading = false;
      });
      _filter();
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _all.where((row) {
        final d = row.data;
        // Driver name match (search)
        if (q.isNotEmpty) {
          final name =
              (d['driver_name'] as String? ?? '').toLowerCase();
          if (!name.contains(q)) return false;
        }
        // Type filter: jobs that CONTAIN deliveries / pickups (a job can mix).
        if (_typeFilter == 'delivery' && row.deliveryCount == 0) return false;
        if (_typeFilter == 'pickup' && row.pickupCount == 0) return false;
        // Status filter
        final status = d['status'] as String? ?? 'draft';
        switch (_statusFilter) {
          case _StatusFilter.all:
            break;
          case _StatusFilter.draft:
            if (status != 'draft') return false;
            break;
          case _StatusFilter.active:
            if (status != 'assigned' && status != 'in_progress') {
              return false;
            }
            break;
          case _StatusFilter.completed:
            if (status != 'completed') return false;
            break;
          case _StatusFilter.cancelled:
            if (status != 'cancelled') return false;
            break;
        }
        // Date range filter on created_at
        if (_dateFrom != null || _dateTo != null) {
          final raw = d['created_at'] as String?;
          if (raw == null) return false;
          DateTime created;
          try {
            created = DateTime.parse(raw).toLocal();
          } catch (_) {
            return false;
          }
          if (_dateFrom != null && created.isBefore(_dateFrom!)) {
            return false;
          }
          if (_dateTo != null) {
            // Include the entire end-day
            final endOfDay = DateTime(_dateTo!.year, _dateTo!.month,
                _dateTo!.day, 23, 59, 59);
            if (created.isAfter(endOfDay)) return false;
          }
        }
        return true;
      }).toList();
    });
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'assigned':
        return AppTheme.warning;
      case 'in_progress':
        return AppTheme.primary;
      case 'completed':
        return AppTheme.success;
      case 'cancelled':
      case 'failed':
        return AppTheme.danger;
      case 'draft':
      default:
        return AppTheme.textSecondary;
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Deliveries',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
              onPressed: () => _showDeliveryDialog(context, existing: null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create Job')),
        ]),
        const SizedBox(height: 8),
        Text('${_filtered.length} of ${_all.length} deliveries',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        _buildFilters(),
        const SizedBox(height: 16),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else
          Expanded(child: _buildTable()),
      ]),
    );
  }

  Widget _buildFilters() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Row 1: search + date range
      Row(children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: _searchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search by driver name...',
              prefixIcon: Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: _DatePickerField(
            label: 'From',
            value: _dateFrom,
            onChanged: (d) => setState(() {
              _dateFrom = d;
              _filter();
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _DatePickerField(
            label: 'To',
            value: _dateTo,
            onChanged: (d) => setState(() {
              _dateTo = d;
              _filter();
            }),
          ),
        ),
        if (_dateFrom != null || _dateTo != null) ...[
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Clear dates',
            onPressed: () => setState(() {
              _dateFrom = null;
              _dateTo = null;
              _filter();
            }),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      // Row 2: status pills
      Wrap(spacing: 8, children: [
        _statusPill('All', _StatusFilter.all),
        _statusPill('Draft', _StatusFilter.draft),
        _statusPill('Active', _StatusFilter.active),
        _statusPill('Completed', _StatusFilter.completed),
        _statusPill('Cancelled', _StatusFilter.cancelled),
      ]),
      const SizedBox(height: 10),
      // Row 3: job-type pills
      Wrap(spacing: 8, children: [
        _typePill('All jobs', null),
        _typePill('With deliveries', 'delivery'),
        _typePill('With pickups', 'pickup'),
      ]),
    ]);
  }

  Widget _typeTag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(5)),
        child: Text(text,
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: color)),
      );

  Widget _typePill(String label, String? t) {
    final selected = _typeFilter == t;
    return InkWell(
      onTap: () => setState(() {
        _typeFilter = t;
        _filter();
      }),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.white : AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }

  Widget _statusPill(String label, _StatusFilter f) {
    final selected = _statusFilter == f;
    return InkWell(
      onTap: () => setState(() {
        _statusFilter = f;
        _filter();
      }),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.white : AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            )),
      ),
    );
  }

  Widget _buildTable() {
    return Container(
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(12))),
          child: const Row(children: [
            Expanded(
                flex: 2,
                child: Text('Created',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('Driver',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('Created By',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 1,
                child: Text('Stops',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            Expanded(
                flex: 2,
                child: Text('Status',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppTheme.textSecondary))),
            SizedBox(width: 160),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _filtered.isEmpty
              ? const Center(
                  child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No deliveries match your filters.',
                      style: TextStyle(color: AppTheme.textSecondary)),
                ))
              : ListView.separated(
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final row = _filtered[i];
                    final d = row.data;
                    final status = d['status'] as String? ?? 'draft';
                    final canEdit =
                        status == 'draft' || status == 'assigned';
                    final canCancel =
                        status != 'completed' && status != 'cancelled';
                    final canComplete =
                        status == 'assigned' || status == 'in_progress';
                    final createdAt = d['created_at'] != null
                        ? DateFormat('d MMM · HH:mm').format(
                            DateTime.parse(d['created_at'] as String)
                                .toLocal())
                        : '-';
                    return InkWell(
                      onTap: () =>
                          context.push('/deliveries/${d['id']}'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Row(children: [
                          Expanded(
                              flex: 2,
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(createdAt,
                                        style:
                                            const TextStyle(fontSize: 13)),
                                    const SizedBox(height: 3),
                                    // Composition tags: a job can mix
                                    // deliveries (blue) and pickups (amber).
                                    Wrap(spacing: 4, children: [
                                      if (row.deliveryCount > 0)
                                        _typeTag(
                                            '${row.deliveryCount} DEL',
                                            AppTheme.primary),
                                      if (row.pickupCount > 0)
                                        _typeTag(
                                            '${row.pickupCount} PICK',
                                            AppTheme.warning),
                                    ]),
                                  ])),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  d['driver_name'] as String? ??
                                      'Unassigned',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: d['driver_name'] != null
                                          ? AppTheme.textPrimary
                                          : AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  d['created_by_name'] as String? ?? '-',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 1,
                              child: Text('${row.stopCount}',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600))),
                          Expanded(
                              flex: 2,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                    color: _statusColor(status)
                                        .withOpacity(0.1),
                                    borderRadius:
                                        BorderRadius.circular(6)),
                                child: Center(
                                  child: Text(status,
                                      style: TextStyle(
                                          color: _statusColor(status),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600)),
                                ),
                              )),
                          SizedBox(
                              width: 160,
                              child: Row(children: [
                                IconButton(
                                    icon: const Icon(
                                        Icons.visibility_outlined,
                                        size: 18),
                                    onPressed: () => context.push(
                                        '/deliveries/${d['id']}'),
                                    tooltip: 'View'),
                                if (canEdit)
                                  IconButton(
                                      icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18),
                                      onPressed: () => _showDeliveryDialog(
                                          context,
                                          existing: row),
                                      tooltip: 'Edit'),
                                if (status == 'draft')
                                  IconButton(
                                      icon: const Icon(
                                          Icons.send_outlined,
                                          size: 18,
                                          color: AppTheme.success),
                                      onPressed: () =>
                                          _assign(row),
                                      tooltip: 'Assign'),
                                if (canComplete)
                                  IconButton(
                                      icon: const Icon(
                                          Icons.check_circle_outline,
                                          size: 18,
                                          color: AppTheme.success),
                                      onPressed: () =>
                                          _markCompleted(d['id'] as String),
                                      tooltip: 'Mark Completed'),
                                if (canCancel)
                                  IconButton(
                                      icon: const Icon(
                                          Icons.delete_outline,
                                          size: 18,
                                          color: AppTheme.danger),
                                      onPressed: () =>
                                          _cancel(d['id'] as String),
                                      tooltip: 'Cancel'),
                              ])),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  /// Informational job_type for the deliveries row, derived from its stops.
  static String _jobSummary(List<_StopDraft> stops) {
    final hasPick = stops.any((s) => s.isPickup);
    final hasDel = stops.any((s) => !s.isPickup);
    if (hasPick && hasDel) return 'mixed';
    return hasPick ? 'pickup' : 'delivery';
  }

  static String _describe(int deliveryCount, int pickupCount) {
    final parts = <String>[
      if (deliveryCount > 0) '$deliveryCount ${deliveryCount == 1 ? 'delivery' : 'deliveries'}',
      if (pickupCount > 0) '$pickupCount ${pickupCount == 1 ? 'pickup' : 'pickups'}',
    ];
    return parts.isEmpty ? 'a job' : parts.join(' and ');
  }

  /// Push the "new job" alert to the driver's phone via the send-notification
  /// edge function. The app rings, pulls the job into local storage and shows
  /// a banner. Never fails the caller, but DOES surface a failure to the
  /// dispatcher (stale/missing FCM token is the usual cause) so it isn't a
  /// silent mystery why a driver "didn't get it".
  ///
  /// `type` is always 'delivery_assigned' — that's the one value every app
  /// build reacts to (ring + auto-pull). The delivery/pickup counts ride
  /// along in the data payload.
  Future<void> _notifyDriver({
    required String deliveryId,
    required String driverId,
    required int deliveryCount,
    required int pickupCount,
  }) async {
    try {
      debugPrint('FCM: invoking send-notification for driver $driverId');
      final res = await Supabase.instance.client.functions.invoke(
        'send-notification',
        body: {
          'userId': driverId,
          'title': 'New Job Assigned',
          'body': '${_describe(deliveryCount, pickupCount)} assigned to you',
          'data': {
            'deliveryId': deliveryId,
            'type': 'delivery_assigned',
            'deliveries': '$deliveryCount',
            'pickups': '$pickupCount',
          },
        },
      );
      // The function returns 200 even when FCM itself rejects the token, so
      // inspect the body for an FCM error and tell the dispatcher.
      final data = res.data;
      final fcmErr = (data is Map && data['error'] != null)
          ? (data['error'] is Map
              ? (data['error']['message'] ?? data['error']['status'])
              : data['error'])
          : null;
      if (fcmErr != null) {
        _showSnack('Assigned, but the driver push failed: $fcmErr');
      }
    } on FunctionException catch (e) {
      final detail = (e.details is Map) ? (e.details as Map)['error'] : null;
      _showSnack('Assigned, but the driver push failed: ${detail ?? e.status}');
    } catch (e, st) {
      debugPrint('FCM notify failed: $e\n$st');
      _showSnack('Assigned, but the driver push failed.');
    }
  }

  /// Draft -> assigned from the list. Previously this only flipped the status
  /// and never notified the driver, so the phone stayed silent and the job
  /// only appeared after a manual refresh.
  Future<void> _assign(_DeliveryRow row) async {
    final d = row.data;
    final id = d['id'] as String;
    final driverId = d['driver_id'] as String?;
    if (driverId == null) {
      _showSnack('Pick a driver first (edit the job), then assign.');
      return;
    }
    try {
      await Supabase.instance.client
          .from('deliveries')
          .update({'status': 'assigned'}).eq('id', id);
      _showSnack('Job assigned');
      await _notifyDriver(
        deliveryId: id,
        driverId: driverId,
        deliveryCount: row.deliveryCount,
        pickupCount: row.pickupCount,
      );
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _markCompleted(String id) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Mark Delivery Completed'),
              content: const Text(
                  'Mark this delivery completed? All its stops will be marked '
                  'delivered (use this for third-party / manual deliveries done '
                  'outside the driver app).'),
              actions: [
                TextButton(
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(false),
                    child: const Text('Cancel')),
                ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success),
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(true),
                    child: const Text('Mark Completed')),
              ],
            ));
    if (confirm == true) {
      final now = DateTime.now().toIso8601String();
      try {
        // Flip undelivered stops -> delivered. The trg_mark_do_delivered
        // trigger cascades this to each linked DO's delivered_at.
        await Supabase.instance.client
            .from('delivery_stops')
            .update({'status': 'delivered', 'delivered_at': now})
            .eq('delivery_id', id)
            .neq('status', 'delivered');
        await Supabase.instance.client.from('deliveries').update({
          'status': 'completed',
          'completed_at': now,
        }).eq('id', id);
        _showSnack('Delivery marked completed');
        _load();
      } catch (e) {
        _showSnack('Failed: ${e.toString().split('\n').first}');
      }
    }
  }

  Future<void> _cancel(String id) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Cancel Delivery'),
              content: const Text(
                  'Are you sure you want to cancel this delivery?'),
              actions: [
                TextButton(
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true)
                            .pop(false),
                    child: const Text('No')),
                ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.danger),
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true)
                            .pop(true),
                    child: const Text('Yes, Cancel')),
              ],
            ));
    if (confirm == true) {
      try {
        await Supabase.instance.client.from('deliveries').update({
          'status': 'cancelled',
          'completed_at': DateTime.now().toIso8601String(),
        }).eq('id', id);
        _showSnack('Delivery cancelled');
        _load();
      } catch (e) {
        _showSnack('Failed: ${e.toString().split('\n').first}');
      }
    }
  }

  /// Single modal that handles both Create and Edit. When [existing]
  /// is null, we're creating fresh. When non-null, we're editing — the
  /// modal pre-populates from the existing data, the save path goes
  /// UPDATE instead of INSERT, and stops are replaced wholesale on
  /// save (matching the mobile wizard's pattern).
  void _showDeliveryDialog(BuildContext context,
      {required _DeliveryRow? existing}) async {
    String? driverId = existing?.data['driver_id'] as String?;
    String? driverName = existing?.data['driver_name'] as String?;
    final notesCtrl =
        TextEditingController(text: existing?.data['notes'] as String? ?? '');
    final stops = <_StopDraft>[];

    // For edits, hydrate stops from delivery_stops first
    if (existing != null) {
      try {
        final rows = await Supabase.instance.client
            .from('delivery_stops')
            .select()
            .eq('delivery_id', existing.data['id'])
            .order('sequence');
        for (final r in (rows as List)) {
          final m = Map<String, dynamic>.from(r as Map);
          final draft = _StopDraft();
          draft.customerId = m['customer_id'] as String?;
          draft.customerCode = m['customer_code'] as String?;
          draft.customerName = m['customer_name'] as String?;
          draft.descriptionCtrl.text =
              m['item_description'] as String? ?? '';
          draft.amountCtrl.text = '${m['amount'] ?? 0}';
          draft.paymentType =
              m['payment_type'] as String? ?? 'cash';
          draft.stopType = m['stop_type'] as String? ?? 'delivery';
          draft.targetLat = (m['target_lat'] as num?)?.toDouble();
          draft.targetLng = (m['target_lng'] as num?)?.toDouble();
          stops.add(draft);
        }
      } catch (e) {
        _showSnack(
            'Failed to load stops: ${e.toString().split('\n').first}');
        return;
      }
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setS) {
        // Money only comes from delivery stops; pickups collect goods.
        int totalCash = 0;
        int totalCredit = 0;
        for (final s in stops) {
          if (s.isPickup) continue;
          if (s.paymentType == 'cash') {
            totalCash += s.amount;
          } else if (s.paymentType == 'credit') {
            totalCredit += s.amount;
          }
          // 'not_required' contributes to neither.
        }
        final total = totalCash + totalCredit;
        final hasDeliveries = stops.any((s) => !s.isPickup);

        final isEdit = existing != null;
        final currentStatus =
            existing?.data['status'] as String? ?? 'draft';

        return AlertDialog(
          title: Text(isEdit ? 'Edit Job' : 'Create Job'),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Driver
                DropdownButtonFormField<String>(
                  value: driverId,
                  decoration: const InputDecoration(
                      labelText: 'Driver (required to assign)'),
                  hint: const Text('Select driver'),
                  items: _drivers
                      .map((d) => DropdownMenuItem(
                          value: d['id'] as String,
                          child: Text(d['name'] as String)))
                      .toList(),
                  onChanged: (v) => setS(() {
                    driverId = v;
                    driverName = v == null
                        ? null
                        : _drivers.firstWhere(
                            (d) => d['id'] == v)['name'] as String;
                  }),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Notes (optional)'),
                  maxLines: 2,
                ),
                const SizedBox(height: 20),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Stops (${stops.length})',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                if (stops.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.circular(8)),
                    child: const Center(
                        child: Text(
                            'No stops yet. Click "Add Stop" below.',
                            style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontStyle: FontStyle.italic))),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                        border: Border.all(color: AppTheme.border),
                        borderRadius: BorderRadius.circular(8)),
                    child: Column(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: const BoxDecoration(
                            color: AppTheme.background,
                            borderRadius: BorderRadius.vertical(
                                top: Radius.circular(8))),
                        child: const Row(children: [
                          SizedBox(
                              width: 32,
                              child: Text('#',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          SizedBox(
                              width: 118,
                              child: Text('Type',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 3,
                              child: Text('Customer / Supplier',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 3,
                              child: Text('Item / Remarks',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('Payment',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 2,
                              child: Text('Amount',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          SizedBox(width: 32),
                        ]),
                      ),
                      const Divider(height: 1),
                      for (int i = 0; i < stops.length; i++)
                        _StopEditorRow(
                          index: i,
                          draft: stops[i],
                          customers: _customers,
                          suppliers: _suppliers,
                          onChanged: () => setS(() {}),
                          onRemove: () =>
                              setS(() => stops.removeAt(i)),
                        ),
                    ]),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Stop'),
                    onPressed: () =>
                        setS(() => stops.add(_StopDraft())),
                  ),
                ),
                if (hasDeliveries) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: AppTheme.primary.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      Expanded(child: _totalCell('Rs $total', 'TOTAL')),
                      Container(
                          width: 1, height: 32, color: AppTheme.border),
                      Expanded(
                          child: _totalCell('Rs $totalCash', 'CASH')),
                      Container(
                          width: 1, height: 32, color: AppTheme.border),
                      Expanded(
                          child: _totalCell(
                              'Rs $totalCredit', 'CREDIT')),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.of(ctx, rootNavigator: true).pop(),
                child: const Text('Cancel')),
            // Save Draft button: only shown for new + draft edits.
            // Once a delivery is assigned, we don't want to "downgrade"
            // it back to draft via this dialog.
            if (!isEdit || currentStatus == 'draft')
              OutlinedButton(
                  onPressed: () => _saveDelivery(
                        ctx,
                        existing: existing,
                        stops: stops,
                        driverId: driverId,
                        driverName: driverName,
                        notes: notesCtrl.text.trim(),
                        targetStatus: 'draft',
                      ),
                  child: const Text('Save Draft')),
            ElevatedButton(
                onPressed: () => _saveDelivery(
                      ctx,
                      existing: existing,
                      stops: stops,
                      driverId: driverId,
                      driverName: driverName,
                      notes: notesCtrl.text.trim(),
                      targetStatus: 'assigned',
                    ),
                child: Text(isEdit && currentStatus == 'assigned'
                    ? 'Save'
                    : 'Save & Assign')),
          ],
        );
      }),
    );
  }

  Widget _totalCell(String value, String label) {
    return Column(children: [
      Text(value,
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700)),
      const SizedBox(height: 2),
      Text(label,
          style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: AppTheme.textSecondary)),
    ]);
  }

  /// Saves the delivery — handles both create (existing == null) and
  /// edit cases. For edits, stops are replaced wholesale: delete all
  /// existing rows, insert new ones. This mirrors the mobile wizard's
  /// pattern and avoids diff complexity at our scale.
  Future<void> _saveDelivery(
    BuildContext ctx, {
    required _DeliveryRow? existing,
    required List<_StopDraft> stops,
    required String? driverId,
    required String? driverName,
    required String notes,
    required String targetStatus,
  }) async {
    // Validate
    if (stops.isEmpty) {
      ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Add at least one stop.')));
      return;
    }
    for (int i = 0; i < stops.length; i++) {
      final s = stops[i];
      if (s.customerId == null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('Stop ${i + 1}: pick a '
                '${s.isPickup ? 'supplier' : 'customer'}.')));
        return;
      }
      if (s.amount < 0) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content: Text(
                'Stop ${i + 1}: amount cannot be negative.')));
        return;
      }
    }
    if (targetStatus == 'assigned' && driverId == null) {
      ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('Pick a driver to assign.')));
      return;
    }

    final user = ref.read(currentUserProvider);
    final orgId = user?.orgId;
    final now = DateTime.now();
    final client = Supabase.instance.client;
    final isEdit = existing != null;

    try {
      String deliveryId;
      if (isEdit) {
        deliveryId = existing.data['id'] as String;
        // Determine the new status. If the existing status is already
        // 'assigned' and the user clicked Save, we keep it assigned.
        // If they clicked Save Draft on a draft, we keep it draft.
        // Otherwise apply targetStatus.
        final currentStatus =
            existing.data['status'] as String? ?? 'draft';
        final newStatus =
            currentStatus == 'assigned' ? 'assigned' : targetStatus;
        await client.from('deliveries').update({
          'driver_id': driverId,
          'driver_name': driverName,
          'driver_role': driverId == null ? null : 'driver',
          'notes': notes.isEmpty ? null : notes,
          'status': newStatus,
        }).eq('id', deliveryId);
        // Check if any existing stops have an order_id linkage
        // (i.e. this delivery came from Dispatch Orders). If so, DO NOT
        // touch the stops — a wholesale delete-and-reinsert would lose
        // order_id, driver-completion state, delivered_at, etc., and
        // break the delivery_stop_to_order_sync trigger.
        final existingStops = await client
            .from('delivery_stops')
            .select('order_id')
            .eq('delivery_id', deliveryId);
        final hasDispatchStops = (existingStops as List)
            .any((s) => (s as Map)['order_id'] != null);
        if (hasDispatchStops) {
          if (ctx.mounted) {
            Navigator.of(ctx, rootNavigator: true).pop();
          }
          _showSnack(
              'Delivery updated (stops are managed via Dispatch Orders)');
          _load();
          return;
        }
        // Manual delivery — replace stops wholesale (original behavior).
        await client
            .from('delivery_stops')
            .delete()
            .eq('delivery_id', deliveryId);
      } else {
        deliveryId = 'del_${now.millisecondsSinceEpoch}';
        await client.from('deliveries').insert({
          'id': deliveryId,
          'driver_id': driverId,
          'driver_name': driverName,
          'driver_role': driverId == null ? null : 'driver',
          'created_by': user?.id,
          'created_by_name': user?.name,
          'created_by_role': user?.role.name,
          'status': targetStatus,
          'notes': notes.isEmpty ? null : notes,
          'org_id': orgId,
          // Informational summary only — behaviour is driven per stop.
          'job_type': _jobSummary(stops),
          'created_at': now.toIso8601String(),
        });
      }

      // Insert (or re-insert) stops. Each stop carries its own type. Pickups
      // have no payment/amount (stored as 'not_required' / 0). The party's
      // geo-coordinates are snapshotted onto the stop so the driver app can
      // validate location without a local supplier lookup.
      final stopRows = [
        for (int i = 0; i < stops.length; i++)
          {
            'id': 'stp_${now.millisecondsSinceEpoch}_$i',
            'delivery_id': deliveryId,
            'stop_type': stops[i].stopType,
            'customer_id': stops[i].customerId,
            'customer_code': stops[i].customerCode,
            'customer_name': stops[i].customerName,
            'sequence': i + 1,
            'item_description':
                stops[i].descriptionCtrl.text.trim(), // empty allowed
            'amount': stops[i].isPickup
                ? 0
                : (stops[i].paymentType == 'credit' ? 0 : stops[i].amount),
            'payment_type':
                stops[i].isPickup ? 'not_required' : stops[i].paymentType,
            'status': 'pending',
            'verification': 'pending',
            'photo_paths_json': '[]',
            'target_lat': stops[i].targetLat,
            'target_lng': stops[i].targetLng,
          }
      ];
      await client.from('delivery_stops').insert(stopRows);

      // Fire FCM notification if delivery was just assigned to a driver.
      // Covers: create-with-assign, edit that adds/changes a driver, and
      // draft -> assigned transitions. Wrapped so notify failures never
      // fail the save itself.
      final wasNewlyAssigned = !isEdit
          ? (targetStatus == 'assigned' && driverId != null)
          : (driverId != null &&
              (driverId != (existing!.data['driver_id'] as String?) ||
                  (existing.data['status'] as String? ?? 'draft') != 'assigned'));
      if (wasNewlyAssigned) {
        await _notifyDriver(
          deliveryId: deliveryId,
          driverId: driverId!,
          deliveryCount: stops.where((s) => !s.isPickup).length,
          pickupCount: stops.where((s) => s.isPickup).length,
        );
      }

      if (ctx.mounted) {
        Navigator.of(ctx, rootNavigator: true).pop();
      }
      _showSnack(isEdit
          ? 'Delivery updated'
          : (targetStatus == 'assigned'
              ? 'Delivery created & assigned'
              : 'Delivery saved as draft'));
      _load();
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
            content:
                Text('Failed: ${e.toString().split('\n').first}')));
      }
    }
  }
}

/// A date picker formatted to match the search/dropdown row's height.
/// Tapping the field opens the standard Material date picker.
class _DatePickerField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  const _DatePickerField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? now,
          firstDate: DateTime(now.year - 2),
          lastDate: DateTime(now.year + 1),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixIcon:
              const Icon(Icons.calendar_today_outlined, size: 16),
        ),
        child: Text(
            value == null
                ? 'Any'
                : DateFormat('d MMM yyyy').format(value!),
            style: TextStyle(
                fontSize: 13,
                color: value == null ? AppTheme.textSecondary : null)),
      ),
    );
  }
}

class _StopEditorRow extends StatelessWidget {
  final int index;
  final _StopDraft draft;
  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> suppliers;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _StopEditorRow({
    required this.index,
    required this.draft,
    required this.customers,
    required this.suppliers,
    required this.onChanged,
    required this.onRemove,
  });

  bool get _isPickup => draft.isPickup;
  List<Map<String, dynamic>> get _parties => _isPickup ? suppliers : customers;

  // Suppliers have `name` and no `code`; customers have `shop_name` + `code`.
  String _label(Map<String, dynamic> p) => _isPickup
      ? (p['name'] as String? ?? '')
      : '${p['code'] ?? ''} · ${p['shop_name'] ?? ''}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 32, child: Text('${index + 1}')),
        // Per-stop type. Switching clears the chosen party (it belongs to
        // the other list) and resets payment for pickups.
        SizedBox(
          width: 110,
          child: DropdownButtonFormField<String>(
            value: draft.stopType,
            isDense: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'delivery', child: Text('Delivery')),
              DropdownMenuItem(value: 'pickup', child: Text('Pickup')),
            ],
            onChanged: (v) {
              if (v == null || v == draft.stopType) return;
              draft.stopType = v;
              draft.customerId = null;
              draft.customerCode = null;
              draft.customerName = null;
              draft.targetLat = null;
              draft.targetLng = null;
              if (draft.isPickup) {
                draft.paymentType = 'not_required';
                draft.amountCtrl.clear();
              } else {
                draft.paymentType = 'cash';
              }
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: Autocomplete<Map<String, dynamic>>(
            // Keyed on type so the field rebuilds (and clears) when the type
            // flips between customer and supplier lists.
            key: ValueKey('party-${draft.stopType}-$index'),
            displayStringForOption: _label,
            optionsBuilder: (TextEditingValue v) {
              final q = v.text.toLowerCase().trim();
              if (q.isEmpty) return _parties;
              return _parties.where((p) {
                final code = (p['code'] as String? ?? '').toLowerCase();
                final name = ((_isPickup ? p['name'] : p['shop_name'])
                            as String? ??
                        '')
                    .toLowerCase();
                return code.contains(q) || name.contains(q);
              });
            },
            initialValue: TextEditingValue(
                text: draft.customerName == null
                    ? ''
                    : (_isPickup
                        ? draft.customerName!
                        : '${draft.customerCode ?? ''} · ${draft.customerName}')),
            onSelected: (p) {
              draft.customerId = p['id'] as String;
              draft.customerCode =
                  _isPickup ? '' : (p['code'] as String? ?? '');
              draft.customerName =
                  (_isPickup ? p['name'] : p['shop_name']) as String? ?? '';
              draft.targetLat = (p['latitude'] as num?)?.toDouble();
              draft.targetLng = (p['longitude'] as num?)?.toDouble();
              onChanged();
            },
            fieldViewBuilder: (ctx, ctrl, focus, onFieldSubmitted) {
              return TextField(
                controller: ctrl,
                focusNode: focus,
                decoration: InputDecoration(
                  hintText: _isPickup ? 'Search supplier' : 'Search code or name',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextField(
            controller: draft.descriptionCtrl,
            decoration: InputDecoration(
              hintText: _isPickup ? 'what to pick up' : 'optional',
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Payment + Amount: only meaningful for deliveries. For pickups the
        // cells stay in the grid (so columns line up) but read "—".
        Expanded(
          flex: 2,
          child: _isPickup
              ? const _DashCell()
              : DropdownButtonFormField<String>(
                  value: draft.paymentType,
                  isDense: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                    DropdownMenuItem(value: 'credit', child: Text('Credit')),
                    DropdownMenuItem(
                        value: 'not_required', child: Text('Not Required')),
                  ],
                  onChanged: (v) {
                    draft.paymentType = v ?? 'cash';
                    onChanged();
                  },
                ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _isPickup
              ? const _DashCell()
              : TextField(
                  controller: draft.amountCtrl,
                  enabled: draft.paymentType == 'cash',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    hintText: '0',
                    prefixText: 'Rs ',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => onChanged(),
                ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 32,
          child: IconButton(
            icon: const Icon(Icons.close,
                size: 16, color: AppTheme.danger),
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: onRemove,
          ),
        ),
      ]),
    );
  }
}

/// Placeholder cell for columns that don't apply to a pickup stop.
class _DashCell extends StatelessWidget {
  const _DashCell();
  @override
  Widget build(BuildContext context) => const Center(
      child: Text('—', style: TextStyle(color: AppTheme.textSecondary)));
}

class _StopDraft {
  String stopType = 'delivery'; // 'delivery' | 'pickup'
  String? customerId;
  String? customerCode;
  String? customerName;
  String paymentType = 'cash';
  double? targetLat;
  double? targetLng;
  final TextEditingController descriptionCtrl = TextEditingController();
  final TextEditingController amountCtrl = TextEditingController();

  bool get isPickup => stopType == 'pickup';
  int get amount => int.tryParse(amountCtrl.text.trim()) ?? 0;
}

class _DeliveryRow {
  final Map<String, dynamic> data;
  final int stopCount;
  final int deliveryCount;
  final int pickupCount;
  const _DeliveryRow({
    required this.data,
    required this.stopCount,
    this.deliveryCount = 0,
    this.pickupCount = 0,
  });

  /// "2 deliveries · 1 pickup" style summary of the job's composition.
  String get composition {
    final parts = <String>[
      if (deliveryCount > 0) '$deliveryCount ${deliveryCount == 1 ? 'delivery' : 'deliveries'}',
      if (pickupCount > 0) '$pickupCount ${pickupCount == 1 ? 'pickup' : 'pickups'}',
    ];
    return parts.isEmpty ? '$stopCount stops' : parts.join(' · ');
  }
}
