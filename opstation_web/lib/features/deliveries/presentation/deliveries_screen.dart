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
  bool _loading = true;

  // Filter state
  final _searchCtrl = TextEditingController();
  _StatusFilter _statusFilter = _StatusFilter.all;
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
          .select('delivery_id');

      final countByDelivery = <String, int>{};
      for (final s in (stops as List)) {
        final id = (s as Map)['delivery_id'] as String;
        countByDelivery[id] = (countByDelivery[id] ?? 0) + 1;
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
              .select('id, shop_name, code')
              .eq('org_id', orgId)
              .order('shop_name')
              .range(offset, offset + pageSize - 1);
          customers.addAll(List<Map<String, dynamic>>.from(page));
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
            )
        ];
        _drivers = List<Map<String, dynamic>>.from(drivers);
        _customers = customers;
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
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Deliveries',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          ElevatedButton.icon(
              onPressed: () =>
                  _showDeliveryDialog(context, existing: null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create Delivery')),
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
    ]);
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
                              child: Text(createdAt,
                                  style: const TextStyle(fontSize: 13))),
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
                                          _assign(d['id'] as String),
                                      tooltip: 'Assign'),
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

  Future<void> _assign(String id) async {
    try {
      await Supabase.instance.client
          .from('deliveries')
          .update({'status': 'assigned'}).eq('id', id);
      _showSnack('Delivery assigned');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
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
        int totalCash = 0;
        int totalCredit = 0;
        for (final s in stops) {
          if (s.paymentType == 'cash') {
            totalCash += s.amount;
          } else {
            totalCredit += s.amount;
          }
        }
        final total = totalCash + totalCredit;

        final isEdit = existing != null;
        final currentStatus =
            existing?.data['status'] as String? ?? 'draft';

        return AlertDialog(
          title: Text(isEdit ? 'Edit Delivery' : 'Create Delivery'),
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
                          Expanded(
                              flex: 3,
                              child: Text('Customer',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textSecondary))),
                          Expanded(
                              flex: 3,
                              child: Text('Item (optional)',
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
            SnackBar(content: Text('Stop ${i + 1}: pick a customer.')));
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
          'created_at': now.toIso8601String(),
        });
      }

      // Insert (or re-insert) stops
      final stopRows = [
        for (int i = 0; i < stops.length; i++)
          {
            'id': 'stp_${now.millisecondsSinceEpoch}_$i',
            'delivery_id': deliveryId,
            'customer_id': stops[i].customerId,
            'customer_code': stops[i].customerCode,
            'customer_name': stops[i].customerName,
            'sequence': i + 1,
            'item_description':
                stops[i].descriptionCtrl.text.trim(), // empty allowed
            'amount': stops[i].paymentType == 'credit'
                ? 0
                : stops[i].amount,
            'payment_type': stops[i].paymentType,
            'status': 'pending',
            'verification': 'pending',
            'photo_paths_json': '[]',
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
        try {
          debugPrint('FCM: invoking send-notification for driver $driverId');
          await client.functions.invoke(
            'send-notification',
            body: {
              'userId': driverId,
              'title': 'New Delivery Assigned',
              'body':
                  '${stops.length} stop${stops.length == 1 ? '' : 's'} assigned to you',
              'data': {
                'deliveryId': deliveryId,
                'type': 'delivery_assigned',
              },
            },
          );
        } catch (e, st) {
          debugPrint('FCM notify failed: $e\n$st');
        }
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
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  const _StopEditorRow({
    required this.index,
    required this.draft,
    required this.customers,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 32, child: Text('${index + 1}')),
        Expanded(
          flex: 3,
          child: Autocomplete<Map<String, dynamic>>(
            displayStringForOption: (c) =>
                '${c['code']} · ${c['shop_name']}',
            optionsBuilder: (TextEditingValue v) {
              final q = v.text.toLowerCase().trim();
              if (q.isEmpty) return customers;
              return customers.where((c) {
                final code =
                    (c['code'] as String? ?? '').toLowerCase();
                final name =
                    (c['shop_name'] as String? ?? '').toLowerCase();
                return code.contains(q) || name.contains(q);
              });
            },
            initialValue: TextEditingValue(
                text: draft.customerName == null
                    ? ''
                    : '${draft.customerCode ?? ''} · ${draft.customerName}'),
            onSelected: (c) {
              draft.customerId = c['id'] as String;
              draft.customerCode = c['code'] as String;
              draft.customerName = c['shop_name'] as String;
              onChanged();
            },
            fieldViewBuilder: (ctx, ctrl, focus, onFieldSubmitted) {
              return TextField(
                controller: ctrl,
                focusNode: focus,
                decoration: const InputDecoration(
                  hintText: 'Search code or name',
                  isDense: true,
                  border: OutlineInputBorder(),
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
            decoration: const InputDecoration(
              hintText: 'optional',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: DropdownButtonFormField<String>(
            value: draft.paymentType,
            isDense: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'credit', child: Text('Credit')),
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
          child: TextField(
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

class _StopDraft {
  String? customerId;
  String? customerCode;
  String? customerName;
  String paymentType = 'cash';
  final TextEditingController descriptionCtrl = TextEditingController();
  final TextEditingController amountCtrl = TextEditingController();

  int get amount => int.tryParse(amountCtrl.text.trim()) ?? 0;
}

class _DeliveryRow {
  final Map<String, dynamic> data;
  final int stopCount;
  const _DeliveryRow({required this.data, required this.stopCount});
}
