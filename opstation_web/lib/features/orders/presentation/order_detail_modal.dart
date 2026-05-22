import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/photo_url.dart';
import '../../auth/auth_controller.dart';
import '../models/order.dart';
import '../services/order_service.dart';

/// Detail dialog for a single order. Shows full info plus the
/// accountant's status-change controls. Status is locked when the
/// order is dispatched or delivered.
class OrderDetailModal extends ConsumerStatefulWidget {
  final Order order;
  const OrderDetailModal({super.key, required this.order});

  static Future<bool?> show(BuildContext context, Order order) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: OrderDetailModal(order: order),
        ),
      ),
    );
  }

  @override
  ConsumerState<OrderDetailModal> createState() => _OrderDetailModalState();
}

class _OrderDetailModalState extends ConsumerState<OrderDetailModal> {
  late OrderStatus _selectedStatus;
  // 'cash' / 'credit' / null (= not yet picked). Required when approving.
  String? _selectedPaymentType;
  late final TextEditingController _noteCtrl;
  // PKR int. Required when approving with cash; ignored for credit.
  late final TextEditingController _amountCtrl;
  late final TextEditingController _driverNoteCtrl;
  late final TextEditingController _soInvoiceCtrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedStatus = widget.order.status;
    // No pre-selection for orders still in review — force an explicit
    // choice. For already-approved orders, show the current value so the
    // accountant can confirm or change it.
    _selectedPaymentType = widget.order.status == OrderStatus.inReview
        ? null
        : widget.order.paymentType;
    _amountCtrl = TextEditingController(
        text: widget.order.amount > 0 ? widget.order.amount.toString() : '');
    _noteCtrl = TextEditingController(text: widget.order.statusNote ?? '');
    _driverNoteCtrl = TextEditingController(text: widget.order.driverNote ?? '');
    _soInvoiceCtrl = TextEditingController(text: widget.order.soInvoiceNumber ?? '');
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _amountCtrl.dispose();
    _driverNoteCtrl.dispose();
    _soInvoiceCtrl.dispose();
    super.dispose();
  }

  bool get _dirty {
    if (_selectedStatus != widget.order.status) return true;
    if (_noteCtrl.text.trim() != (widget.order.statusNote ?? '')) return true;
    if (_driverNoteCtrl.text.trim() != (widget.order.driverNote ?? '')) {
      return true;
    }
    if (_soInvoiceCtrl.text.trim() != (widget.order.soInvoiceNumber ?? '')) {
      return true;
    }
    // Payment-type changes count only when we're on the approved branch.
    if (_selectedStatus == OrderStatus.approved &&
        _selectedPaymentType != widget.order.paymentType) {
      return true;
    }
    // Amount changes count only on the approved+cash branch.
    if (_selectedStatus == OrderStatus.approved &&
        _selectedPaymentType == 'cash') {
      final entered = int.tryParse(_amountCtrl.text.trim()) ?? 0;
      if (entered != widget.order.amount) return true;
    }
    return false;
  }

  Future<void> _save() async {
    if (_selectedStatus.requiresNote && _noteCtrl.text.trim().isEmpty) {
      setState(() => _error = 'A note is required for ${_selectedStatus.label}.');
      return;
    }
    if (_selectedStatus == OrderStatus.approved &&
        _selectedPaymentType == null) {
      setState(() => _error = 'Select Cash or Credit before approving.');
      return;
    }
    if (_selectedStatus == OrderStatus.approved &&
        _selectedPaymentType == 'cash') {
      final entered = int.tryParse(_amountCtrl.text.trim()) ?? 0;
      if (entered <= 0) {
        setState(() => _error = 'Enter the amount to collect (PKR).');
        return;
      }
    }
    final actor = ref.read(authControllerProvider).valueOrNull;
    if (actor == null) {
      setState(() => _error = 'Not authenticated');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(orderServiceProvider).updateStatus(
            orderId: widget.order.id,
            newStatus: _selectedStatus,
            statusNote:
                _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
            actorUserId: actor.id,
            driverNote: _driverNoteCtrl.text,
            soInvoiceNumber: _soInvoiceCtrl.text,
            includeDriverFields: true,
            paymentType: _selectedStatus == OrderStatus.approved
                ? _selectedPaymentType
                : null,
            amount: _selectedStatus == OrderStatus.approved
                ? (_selectedPaymentType == 'credit'
                    ? 0
                    : int.tryParse(_amountCtrl.text.trim()) ?? 0)
                : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    final locked = o.status.accountantLocked;
    final availableStatuses = [
      OrderStatus.inReview,
      OrderStatus.approved,
      OrderStatus.declined,
      OrderStatus.onHold,
      OrderStatus.cancelled,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(o, locked),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _section('Customer', children: [
                  Text(o.customerName ?? '(no name)',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  if (o.customerCode != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('#${o.customerCode}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280))),
                    ),
                ]),
                _section('Salesperson', children: [
                  Text(o.salespersonName ?? '—',
                      style: const TextStyle(fontSize: 14)),
                ]),
                _section('Created', children: [
                  Text(_fmtDateTime(o.createdAt),
                      style: const TextStyle(fontSize: 14)),
                ]),
                _section('Notes from salesperson', children: [
                  Text(
                    (o.notes ?? '').isEmpty ? '(no notes)' : o.notes!,
                    style: TextStyle(
                      fontSize: 14,
                      color: (o.notes ?? '').isEmpty
                          ? const Color(0xFF9CA3AF)
                          : Colors.black87,
                    ),
                  ),
                ]),
                if (o.photoPaths.isNotEmpty)
                  _section('Photos', children: [
                    SizedBox(
                      height: 80,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: o.photoPaths.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => GestureDetector(
                          onTap: () => _openPhotoViewer(o.photoPaths, i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              PhotoUrl.build(o.photoPaths[i]),
                              width: 80,
                              height: 80,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 80,
                                height: 80,
                                color: const Color(0xFFF3F4F6),
                                alignment: Alignment.center,
                                child: const Icon(
                                    Icons.broken_image_outlined,
                                    size: 24,
                                    color: Color(0xFF9CA3AF)),
                              ),
                              loadingBuilder: (_, child, progress) {
                                if (progress == null) return child;
                                return Container(
                                  width: 80,
                                  height: 80,
                                  color: const Color(0xFFF3F4F6),
                                  alignment: Alignment.center,
                                  child: const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                _section('Status', children: [
                  if (locked) ...[
                    Row(
                      children: [
                        const Icon(Icons.lock_outline,
                            size: 16, color: Color(0xFF6B7280)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            o.status == OrderStatus.delivered
                                ? 'Order delivered — no further changes allowed.'
                                : 'Order dispatched — locked until dispatch sets it back to cancelled.',
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF6B7280)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _statusChip(o.status),
                  ] else ...[
                    DropdownButtonFormField<OrderStatus>(
                      value: _selectedStatus,
                      decoration: const InputDecoration(
                        labelText: 'Set status',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final s in availableStatuses)
                          DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: _saving
                          ? null
                          : (v) {
                              if (v == null) return;
                              setState(() => _selectedStatus = v);
                            },
                    ),
                    if (_selectedStatus == OrderStatus.approved) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'Payment type *',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF374151)),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Cash'),
                            selected: _selectedPaymentType == 'cash',
                            onSelected: _saving
                                ? null
                                : (_) => setState(
                                    () => _selectedPaymentType = 'cash'),
                          ),
                          ChoiceChip(
                            label: const Text('Credit'),
                            selected: _selectedPaymentType == 'credit',
                            onSelected: _saving
                                ? null
                                : (_) => setState(
                                    () => _selectedPaymentType = 'credit'),
                          ),
                        ],
                      ),
                      if (_selectedPaymentType == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text(
                            'Required when approving.',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFFDC2626)),
                          ),
                        ),
                      if (_selectedPaymentType == 'cash') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: false),
                          enabled: !_saving,
                          decoration: const InputDecoration(
                            labelText: 'Amount to collect (PKR) *',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ],
                    if (_selectedStatus.requiresNote ||
                        _noteCtrl.text.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _noteCtrl,
                        minLines: 2,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: _selectedStatus.requiresNote
                              ? 'Reason (required)'
                              : 'Note (optional)',
                          hintText: _selectedStatus == OrderStatus.declined
                              ? 'Why is this order declined?'
                              : _selectedStatus == OrderStatus.onHold
                                  ? 'Why is this on hold?'
                                  : 'Reason or comment',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ],
                ]),
                if (!locked) ...[
                  _section('Note for driver', children: [
                    TextField(
                      controller: _driverNoteCtrl,
                      minLines: 2,
                      maxLines: 3,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        hintText: 'Visible to the driver (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ]),
                  _section('SO / Invoice #', children: [
                    TextField(
                      controller: _soInvoiceCtrl,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        hintText: 'Reference number (optional)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ]),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: const TextStyle(color: Color(0xFFDC2626))),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(
            children: [
              const Spacer(),
              OutlinedButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                child: const Text('Close'),
              ),
              if (!locked) ...[
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: (_saving || !_dirty) ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check, size: 16),
                  label: const Text('Save'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _header(Order o, bool locked) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Order',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(o.id,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9CA3AF),
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }

  Widget _section(String label, {required List<Widget> children}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  Widget _statusChip(OrderStatus s) {
    final (bg, fg) = _palette(s);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(s.label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg)),
      ),
    );
  }

  (Color, Color) _palette(OrderStatus s) {
    switch (s) {
      case OrderStatus.inReview:
        return (const Color(0xFFFEF3C7), const Color(0xFF92400E));
      case OrderStatus.approved:
        return (const Color(0xFFD1FAE5), const Color(0xFF065F46));
      case OrderStatus.declined:
        return (const Color(0xFFFEE2E2), const Color(0xFF991B1B));
      case OrderStatus.dispatched:
        return (const Color(0xFFDBEAFE), const Color(0xFF1E40AF));
      case OrderStatus.onHold:
        return (const Color(0xFFF3E8FF), const Color(0xFF6B21A8));
      case OrderStatus.cancelled:
        return (const Color(0xFFE5E7EB), const Color(0xFF374151));
      case OrderStatus.delivered:
        return (const Color(0xFFC7F9CC), const Color(0xFF14532D));
    }
  }

  String _fmtDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _openPhotoViewer(List<String> paths, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          _PhotoViewer(paths: paths, initialIndex: initialIndex),
    ));
  }
}

/// Full-screen swipeable photo viewer with pinch-to-zoom. Used to view
/// salesperson-uploaded order photos at full resolution.
class _PhotoViewer extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;
  const _PhotoViewer({required this.paths, required this.initialIndex});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _controller;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_currentIndex + 1} / ${widget.paths.length}'),
        elevation: 0,
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.paths.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image.network(
              PhotoUrl.build(widget.paths[i]),
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.broken_image_outlined,
                size: 48,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
