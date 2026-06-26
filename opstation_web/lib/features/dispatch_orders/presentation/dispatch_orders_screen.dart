import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_controller.dart';
import '../../orders/models/order.dart';
import '../services/dispatch_order_service.dart';
import 'dispatch_assign_modal.dart';
import 'bulk_assign_modal.dart';

class DispatchOrdersScreen extends ConsumerStatefulWidget {
  const DispatchOrdersScreen({super.key});

  @override
  ConsumerState<DispatchOrdersScreen> createState() =>
      _DispatchOrdersScreenState();
}

class _DispatchOrdersScreenState
    extends ConsumerState<DispatchOrdersScreen> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 90));
  DateTime _to = DateTime.now();
  String? _statusFilter;
  String? _driverIdFilter;
  String _searchTerm = '';
  final _searchCtl = TextEditingController();

  List<Order> _orders = [];
  List<Map<String, dynamic>> _drivers = [];
  bool _loading = true;
  String? _error;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadDrivers().then((_) => _refresh());
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadDrivers() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth?.orgId == null) return;
    try {
      final drivers = await DispatchOrderService(Supabase.instance.client)
          .listDrivers(auth!.orgId!);
      if (!mounted) return;
      setState(() => _drivers = drivers);
    } catch (_) {}
  }

  Future<void> _refresh() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth?.orgId == null) {
      setState(() {
        _error = 'No org context';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await DispatchOrderService(Supabase.instance.client)
          .listDeliveryOrdersForDispatch(
        orgId: auth!.orgId!,
        from: _from,
        to: _to.add(const Duration(days: 1)),
      );
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Order> get _filtered {
    Iterable<Order> list = _orders;
    // Status filter (Pool=approved, Assigned=dispatched, Delivered).
    final sf = OrderStatusX.fromKey(_statusFilter);
    if (sf != null) list = list.where((o) => o.status == sf);
    // Driver filter.
    if (_driverIdFilter != null) {
      list = list.where((o) => o.driverId == _driverIdFilter);
    }
    if (_searchTerm.isNotEmpty) {
      final q = _searchTerm.toLowerCase();
      list = list.where((o) {
        return (o.customerName?.toLowerCase().contains(q) ?? false) ||
            (o.customerCode?.toLowerCase().contains(q) ?? false) ||
            (o.soInvoiceNumber?.toLowerCase().contains(q) ?? false) ||
            (o.driverName?.toLowerCase().contains(q) ?? false);
      });
    }
    return list.toList();
  }

  Future<void> _pickDate(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 30)),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _to = d;
      }
    });
  }

  ({Color bg, Color fg}) _statusColors(OrderStatus s) {
    switch (s) {
      case OrderStatus.approved:
        return (bg: Colors.blue.shade100, fg: Colors.blue.shade800);
      case OrderStatus.dispatched:
        return (bg: Colors.indigo.shade100, fg: Colors.indigo.shade800);
      case OrderStatus.onHold:
        return (bg: Colors.amber.shade100, fg: Colors.amber.shade900);
      case OrderStatus.delivered:
        return (bg: Colors.green.shade100, fg: Colors.green.shade800);
      case OrderStatus.cancelled:
        return (bg: Colors.grey.shade200, fg: Colors.grey.shade700);
      case OrderStatus.declined:
        return (bg: Colors.red.shade100, fg: Colors.red.shade800);
      case OrderStatus.inReview:
        return (bg: Colors.amber.shade50, fg: Colors.amber.shade800);
    }
  }

  Future<void> _onEditOrder(Order o) async {
    // Dispatched / on-hold orders that belong to a delivery open the bulk
    // modal in edit mode loaded with every sibling order in that delivery
    // (per-order note/SO can be tweaked there, and the whole delivery can
    // be marked delivered for third-party drivers). Approved or other
    // orders keep the single-order DispatchAssignModal flow.
    final isLive = o.status == OrderStatus.dispatched ||
        o.status == OrderStatus.onHold;
    if (isLive && o.deliveryId != null) {
      List<Order> deliveryOrders;
      try {
        deliveryOrders =
            await DispatchOrderService(Supabase.instance.client)
                .listDeliveryOrdersInDelivery(o.deliveryId!);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load delivery: $e')),
        );
        return;
      }
      if (deliveryOrders.isEmpty) deliveryOrders = [o];
      final changed = await BulkAssignModal.show(
        context,
        deliveryOrders,
        mode: BulkAssignMode.editExisting,
        deliveryId: o.deliveryId,
      );
      if (changed == true) _refresh();
    } else {
      final changed = await DispatchAssignModal.show(context, o);
      if (changed == true) _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filtered;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Dispatch',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(width: 12),
              if (!_loading)
                Text(
                  '· ${visible.length} order${visible.length == 1 ? "" : "s"}',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _refresh,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text('From ${_from.toIso8601String().split("T").first}'),
                onPressed: () => _pickDate(true),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text('To ${_to.toIso8601String().split("T").first}'),
                onPressed: () => _pickDate(false),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  value: _statusFilter,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('All')),
                    DropdownMenuItem(value: 'approved', child: Text('Pool (unassigned)')),
                    DropdownMenuItem(value: 'dispatched', child: Text('Assigned')),
                    DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
                  ],
                  onChanged: (v) => setState(() => _statusFilter = v),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  decoration: const InputDecoration(
                    labelText: 'Driver',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  value: _driverIdFilter,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All drivers')),
                    ..._drivers.map((d) => DropdownMenuItem(
                          value: d['id'] as String,
                          child: Text(d['name'] as String),
                        )),
                  ],
                  onChanged: (v) => setState(() => _driverIdFilter = v),
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.search),
                label: const Text('Apply'),
                onPressed: _refresh,
              ),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _from = DateTime.now().subtract(const Duration(days: 90));
                    _to = DateTime.now();
                    _statusFilter = null;
                    _driverIdFilter = null;
                    _searchTerm = '';
                    _searchCtl.clear();
                  });
                  _refresh();
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 360,
            child: TextField(
              controller: _searchCtl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by customer, notes, driver…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchTerm = v),
            ),
          ),
          if (_selectedIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.indigo.shade200),
              ),
              child: Row(
                children: [
                  Text(
                    '${_selectedIds.length} order${_selectedIds.length == 1 ? "" : "s"} selected',
                    style: TextStyle(
                      color: Colors.indigo.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () =>
                        setState(() => _selectedIds.clear()),
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: Text('Assign ${_selectedIds.length} to driver'),
                    onPressed: () async {
                      final selected = visible
                          .where((o) => _selectedIds.contains(o.id))
                          .toList();
                      if (selected.isEmpty) return;
                      final changed = await BulkAssignModal.show(
                          context, selected);
                      if (changed == true) {
                        setState(() => _selectedIds.clear());
                        _refresh();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 48),
                            const SizedBox(height: 8),
                            Text(_error!),
                            const SizedBox(height: 8),
                            ElevatedButton(
                                onPressed: _refresh,
                                child: const Text('Retry')),
                          ],
                        ),
                      )
                    : visible.isEmpty
                        ? Center(
                            child: Text(
                              _statusFilter == null
                                  ? 'No active orders to dispatch.'
                                  : 'No orders match these filters.',
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          )
                        : Card(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SingleChildScrollView(
                                child: DataTable(
                                  columns: [
                                    DataColumn(
                                      label: Builder(builder: (_) {
                                        final approvedIds = visible
                                            .where((o) =>
                                                o.status ==
                                                OrderStatus.approved)
                                            .map((o) => o.id)
                                            .toSet();
                                        final allChecked =
                                            approvedIds.isNotEmpty &&
                                                approvedIds.every(
                                                    _selectedIds.contains);
                                        return Checkbox(
                                          value: allChecked,
                                          tristate: false,
                                          onChanged: approvedIds.isEmpty
                                              ? null
                                              : (v) {
                                                  setState(() {
                                                    if (v == true) {
                                                      _selectedIds
                                                          .addAll(approvedIds);
                                                    } else {
                                                      _selectedIds
                                                          .removeAll(approvedIds);
                                                    }
                                                  });
                                                },
                                        );
                                      }),
                                    ),
                                    const DataColumn(label: Text('Created')),
                                    const DataColumn(label: Text('Customer')),
                                    const DataColumn(
                                        label: Text('Salesperson')),
                                    const DataColumn(label: Text('Driver')),
                                    const DataColumn(
                                        label: Text('SO/Invoice')),
                                    const DataColumn(label: Text('Status')),
                                    const DataColumn(label: Text('')),
                                  ],
                                  rows: visible.map((o) {
                                    final cols = _statusColors(o.status);
                                    return DataRow(
                                      cells: [
                                        DataCell(Checkbox(
                                          value:
                                              _selectedIds.contains(o.id),
                                          onChanged: o.status ==
                                                  OrderStatus.approved
                                              ? (v) {
                                                  setState(() {
                                                    if (v == true) {
                                                      _selectedIds.add(o.id);
                                                    } else {
                                                      _selectedIds
                                                          .remove(o.id);
                                                    }
                                                  });
                                                }
                                              : null,
                                        )),
                                        DataCell(Text(o.createdAt
                                            .toString()
                                            .substring(0, 16))),
                                        DataCell(
                                          Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(o.customerName ?? '—'),
                                              if (o.customerCode != null)
                                                Text(
                                                  '#${o.customerCode}',
                                                  style: TextStyle(
                                                    color:
                                                        Colors.grey.shade600,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        DataCell(Text(o.salespersonName ?? '—')),
                                        DataCell(Text(o.driverName ?? '—')),
                                        DataCell(Text(
                                          (o.soInvoiceNumber ?? '').isEmpty
                                              ? '—'
                                              : o.soInvoiceNumber!,
                                          style: TextStyle(
                                            color:
                                                (o.soInvoiceNumber ?? '').isEmpty
                                                    ? Colors.grey
                                                    : Colors.black87,
                                          ),
                                        )),
                                        DataCell(
                                          Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 4),
                                            decoration: BoxDecoration(
                                              color: cols.bg,
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              o.status.label,
                                              style: TextStyle(
                                                color: cols.fg,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          IconButton(
                                            icon: Icon(
                                              o.status ==
                                                      OrderStatus.delivered
                                                  ? Icons.lock_outline
                                                  : Icons.edit_outlined,
                                              size: 18,
                                            ),
                                            tooltip: o.status ==
                                                    OrderStatus.delivered
                                                ? 'Delivered — cannot edit'
                                                : 'Edit assignment',
                                            onPressed: o.status ==
                                                    OrderStatus.delivered
                                                ? null
                                                : () => _onEditOrder(o),
                                          ),
                                        ),
                                      ],
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
