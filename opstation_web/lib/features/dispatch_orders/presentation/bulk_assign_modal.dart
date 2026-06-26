import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_controller.dart';
import '../../orders/models/order.dart';
import '../services/dispatch_order_service.dart';

enum BulkAssignMode { assignNew, editExisting }

class BulkAssignModal extends ConsumerStatefulWidget {
  final List<Order> orders;
  final BulkAssignMode mode;
  final String? deliveryId;

  const BulkAssignModal({
    super.key,
    required this.orders,
    this.mode = BulkAssignMode.assignNew,
    this.deliveryId,
  });

  static Future<bool?> show(
    BuildContext context,
    List<Order> orders, {
    BulkAssignMode mode = BulkAssignMode.assignNew,
    String? deliveryId,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
          child: BulkAssignModal(
            orders: orders,
            mode: mode,
            deliveryId: deliveryId,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<BulkAssignModal> createState() => _BulkAssignModalState();
}

class _BulkAssignModalState extends ConsumerState<BulkAssignModal> {
  String? _driverId;
  String? _driverName;
  List<Map<String, dynamic>> _drivers = [];
  bool _busy = false;
  bool _loadingDrivers = true;
  String? _error;

  late final Map<String, TextEditingController> _noteCtrls;
  late final Map<String, TextEditingController> _soCtrls;

  bool get _isEdit => widget.mode == BulkAssignMode.editExisting;

  @override
  void initState() {
    super.initState();
    _noteCtrls = {
      for (final o in widget.orders)
        o.id: TextEditingController(text: o.driverNote ?? ''),
    };
    _soCtrls = {
      for (final o in widget.orders)
        o.id: TextEditingController(text: o.soInvoiceNumber ?? ''),
    };
    if (_isEdit && widget.orders.isNotEmpty) {
      _driverId = widget.orders.first.driverId;
      _driverName = widget.orders.first.driverName;
    }
    _loadDrivers();
  }

  @override
  void dispose() {
    for (final c in _noteCtrls.values) {
      c.dispose();
    }
    for (final c in _soCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDrivers() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth?.orgId == null) return;
    try {
      final drivers = await DispatchOrderService(Supabase.instance.client)
          .listDrivers(auth!.orgId!);
      if (!mounted) return;
      setState(() {
        _drivers = drivers;
        _loadingDrivers = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load drivers';
        _loadingDrivers = false;
      });
    }
  }

  Map<String, String?> _collectNotes() => {
        for (final o in widget.orders) o.id: _noteCtrls[o.id]?.text,
      };

  Map<String, String?> _collectSos() => {
        for (final o in widget.orders) o.id: _soCtrls[o.id]?.text,
      };

  Future<void> _doAssignNew() async {
    if (_driverId == null) {
      setState(() => _error = 'Pick a driver first');
      return;
    }
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth?.orgId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DispatchOrderService(Supabase.instance.client)
          .assignDeliveryOrdersToDriver(
        orders: widget.orders,
        driverId: _driverId!,
        driverName: _driverName!,
        currentUserId: auth!.id,
        currentUserName: auth.name,
        orgId: auth.orgId!,
        driverNoteOverrides: _collectNotes(),
        soInvoiceOverrides: _collectSos(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed: $e';
        _busy = false;
      });
    }
  }

  Future<void> _doSaveEdit() async {
    if (widget.deliveryId == null) {
      setState(() => _error = 'Missing delivery ID');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final currentDriverId = widget.orders.first.driverId;
      final driverChanged =
          _driverId != null && _driverId != currentDriverId;
      await DispatchOrderService(Supabase.instance.client)
          .updateExistingDelivery(
        deliveryId: widget.deliveryId!,
        orders: widget.orders,
        newDriverId: driverChanged ? _driverId : null,
        newDriverName: driverChanged ? _driverName : null,
        driverNoteOverrides: _collectNotes(),
        soInvoiceOverrides: _collectSos(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed: $e';
        _busy = false;
      });
    }
  }

  Future<void> _doMarkDelivered() async {
    if (widget.deliveryId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mark delivery as delivered?'),
        content: Text(
          'This will mark all ${widget.orders.length} order'
          '${widget.orders.length == 1 ? "" : "s"} in this delivery as '
          'delivered. Use this when a third-party driver has confirmed '
          'delivery offline. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('Mark delivered'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DispatchOrderService(Supabase.instance.client)
          .markDeliveryAsDelivered(deliveryId: widget.deliveryId!);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.orders.length;
    final title = _isEdit
        ? 'Edit delivery · $n order${n == 1 ? "" : "s"}'
        : 'Assign $n order${n == 1 ? "" : "s"}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed:
                    _busy ? null : () => Navigator.of(context).pop(false),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            constraints: const BoxConstraints(maxHeight: 340),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: widget.orders.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (_, i) {
                final o = widget.orders[i];
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: Colors.indigo.shade50,
                        child: Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.indigo.shade800)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(o.customerName ?? '—',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            Text(
                              [
                                if (o.customerCode != null)
                                  '#${o.customerCode}',
                                o.salespersonName ?? '—',
                                o.status.label,
                              ].join('  ·  '),
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _noteCtrls[o.id],
                                    enabled: !_busy,
                                    minLines: 1,
                                    maxLines: 2,
                                    decoration: const InputDecoration(
                                      labelText: 'Note for driver',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 2,
                                  child: TextField(
                                    controller: _soCtrls[o.id],
                                    enabled: !_busy,
                                    decoration: const InputDecoration(
                                      labelText: 'SO / Invoice #',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_error!,
                  style: TextStyle(color: Colors.red.shade800)),
            ),
            const SizedBox(height: 12),
          ],
          if (_loadingDrivers)
            const LinearProgressIndicator()
          else if (_drivers.isEmpty)
            const Text('No drivers available. Add one in Team first.')
          else
            DropdownButtonFormField<String>(
              value: _driverId,
              decoration: InputDecoration(
                labelText: _isEdit ? 'Driver (reassign?)' : 'Driver',
                border: const OutlineInputBorder(),
              ),
              items: _drivers
                  .map((d) => DropdownMenuItem(
                        value: d['id'] as String,
                        child: Text(d['name'] as String),
                      ))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      final d = _drivers.firstWhere((d) => d['id'] == v);
                      setState(() {
                        _driverId = v;
                        _driverName = d['name'] as String;
                      });
                    },
            ),
          const SizedBox(height: 20),
          if (_isEdit)
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('Save changes'),
                      onPressed: _busy ? null : _doSaveEdit,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Mark delivered'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _busy ? null : _doMarkDelivered,
                    ),
                  ),
                ),
              ],
            )
          else
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.local_shipping_outlined),
                label: Text(
                    'Assign $n order${n == 1 ? "" : "s"} and dispatch'),
                onPressed:
                    _busy || _driverId == null ? null : _doAssignNew,
              ),
            ),
        ],
      ),
    );
  }
}
