import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/auth_controller.dart';
import '../../orders/models/order.dart';
import '../services/dispatch_order_service.dart';
import '../../../core/utils/friendly_error.dart';

class DispatchAssignModal extends ConsumerStatefulWidget {
  final Order order;
  const DispatchAssignModal({super.key, required this.order});

  static Future<bool?> show(BuildContext context, Order order) {
    return showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 760),
          child: DispatchAssignModal(order: order),
        ),
      ),
    );
  }

  @override
  ConsumerState<DispatchAssignModal> createState() =>
      _DispatchAssignModalState();
}

class _DispatchAssignModalState extends ConsumerState<DispatchAssignModal> {
  String? _driverId;
  String? _driverName;
  final _noteCtl = TextEditingController();
  final _driverNoteCtl = TextEditingController();
  final _soInvoiceCtl = TextEditingController();
  List<Map<String, dynamic>> _drivers = [];
  bool _busy = false;
  bool _loadingDrivers = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _driverId = widget.order.driverId;
    _driverName = widget.order.driverName;
    _noteCtl.text = widget.order.statusNote ?? '';
    _driverNoteCtl.text = widget.order.driverNote ?? '';
    _soInvoiceCtl.text = widget.order.soInvoiceNumber ?? '';
    _loadDrivers();
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

  @override
  void dispose() {
    _noteCtl.dispose();
    _driverNoteCtl.dispose();
    _soInvoiceCtl.dispose();
    super.dispose();
  }

  Future<void> _doAssign() async {
    if (_driverId == null) {
      setState(() => _error = 'Pick a driver first');
      return;
    }
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth?.orgId == null || auth?.id == null) {
      setState(() => _error = 'Missing auth context');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DispatchOrderService(Supabase.instance.client)
          .assignDeliveryOrdersToDriver(
        orders: [widget.order],
        driverId: _driverId!,
        driverName: _driverName!,
        currentUserId: auth!.id,
        currentUserName: auth.name,
        orgId: auth.orgId!,
        driverNoteOverrides: {widget.order.id: _driverNoteCtl.text},
        soInvoiceOverrides: {widget.order.id: _soInvoiceCtl.text},
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to assign: $e';
        _busy = false;
      });
    }
  }

  Future<void> _doStatusUpdate(OrderStatus newStatus) async {
    final requiresNote = newStatus == OrderStatus.onHold ||
        newStatus == OrderStatus.cancelled;
    if (requiresNote && _noteCtl.text.trim().isEmpty) {
      setState(() => _error = 'A note is required for this change');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DispatchOrderService(Supabase.instance.client).updateStatus(
        orderId: widget.order.id,
        newStatus: newStatus.key,
        note: _noteCtl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError('That did not work', e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final isApproved = o.status == OrderStatus.approved;
    final isDispatched = o.status == OrderStatus.dispatched;
    final isOnHold = o.status == OrderStatus.onHold;
    final canChangeStatus = isDispatched || isOnHold;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Order details',
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
          _row('Customer',
              '${o.customerName ?? "—"}${o.customerCode != null ? "  #${o.customerCode}" : ""}'),
          _row('Salesperson', o.salespersonName ?? '—'),
          _row('Created', o.createdAt.toString().split('.').first),
          if (o.driverName != null) _row('Driver', o.driverName!),
          _row('Status', o.status.label),
          if ((o.statusNote ?? '').isNotEmpty)
            _row('Note', o.statusNote!),
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
          if (isApproved) ...[
            const Divider(),
            const SizedBox(height: 8),
            TextField(
              controller: _driverNoteCtl,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note for driver',
                hintText: 'Visible to the driver (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _soInvoiceCtl,
              decoration: const InputDecoration(
                labelText: 'SO / Invoice #',
                hintText: 'Reference number (optional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            Text('Assign driver',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_loadingDrivers)
              const LinearProgressIndicator()
            else if (_drivers.isEmpty)
              const Text(
                  'No drivers available. Add one in Team first.')
            else
              DropdownButtonFormField<String>(
                value: _driverId,
                decoration: const InputDecoration(
                  labelText: 'Driver',
                  border: OutlineInputBorder(),
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
            const SizedBox(height: 16),
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
                label: const Text('Assign and dispatch'),
                onPressed:
                    _busy || _driverId == null ? null : _doAssign,
              ),
            ),
          ] else if (canChangeStatus) ...[
            const Divider(),
            const SizedBox(height: 8),
            Text('Update status',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _noteCtl,
              decoration: const InputDecoration(
                labelText: 'Note (required for hold or cancel)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isDispatched)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.pause_circle_outline),
                    label: const Text('Put on hold'),
                    onPressed: _busy
                        ? null
                        : () => _doStatusUpdate(OrderStatus.onHold),
                  ),
                if (isOnHold)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('Resume dispatch'),
                    onPressed: _busy
                        ? null
                        : () =>
                            _doStatusUpdate(OrderStatus.dispatched),
                  ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel order'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade400,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _doStatusUpdate(OrderStatus.cancelled),
                ),
              ],
            ),
          ] else ...[
            const Divider(),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, color: Colors.grey.shade600),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This order is ${o.status.label.toLowerCase()}. No dispatch action available.',
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 110,
                child: Text(k, style: const TextStyle(color: Colors.grey))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}
