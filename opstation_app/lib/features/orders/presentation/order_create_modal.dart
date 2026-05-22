import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/order_photo_capture_service.dart';
import '../services/order_service.dart';

/// Modal sheet to create a new order.
///
/// If [customerId] is provided, the customer is pre-locked and the
/// picker is hidden. Otherwise the modal loads the salesperson's
/// route-assigned customers and shows a searchable list.
class OrderCreateModal extends ConsumerStatefulWidget {
  final String? customerId;
  final String? customerName;
  final String? customerCode;

  const OrderCreateModal({
    super.key,
    this.customerId,
    this.customerName,
    this.customerCode,
  });

  static Future<bool?> show(
    BuildContext context, {
    String? customerId,
    String? customerName,
    String? customerCode,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => OrderCreateModal(
        customerId: customerId,
        customerName: customerName,
        customerCode: customerCode,
      ),
    );
  }

  @override
  ConsumerState<OrderCreateModal> createState() => _OrderCreateModalState();
}

class _OrderCreateModalState extends ConsumerState<OrderCreateModal> {
  late final String _orderId;
  late final TextEditingController _notesCtrl;
  final TextEditingController _searchCtrl = TextEditingController();
  final List<String> _photoPaths = [];
  Timer? _searchDebounce;

  // For the customer picker (when no pre-selected customer)
  Map<String, dynamic>? _selectedCustomer; // {id, shop_name, code}
  List<Map<String, dynamic>>? _availableCustomers;
  bool _loadingCustomers = false;
  String? _customersError;

  bool _capturing = false;
  bool _submitting = false;
  String? _error;

  bool get _preLocked => widget.customerId != null;

  @override
  void initState() {
    super.initState();
    _orderId =
        'order_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond.toRadixString(16)}';
    _notesCtrl = TextEditingController();
    if (_preLocked) {
      _selectedCustomer = {
        'id': widget.customerId,
        'shop_name': widget.customerName,
        'code': widget.customerCode,
      };
    } else {
      _loadAssignedCustomers();
    }
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadAssignedCustomers([String query = '']) async {
    final isFirstLoad = _availableCustomers == null;
    setState(() {
      if (isFirstLoad) _loadingCustomers = true;
      _customersError = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth == null) {
        setState(() {
          _loadingCustomers = false;
          _customersError = 'Not authenticated';
        });
        return;
      }
      final orgId = auth.organizationId;
      if (orgId == null) {
        setState(() {
          _loadingCustomers = false;
          _customersError = 'No organization';
        });
        return;
      }
      final client = Supabase.instance.client;

      // Server-side ilike search. PostgREST caps unbounded selects at
      // ~1000 rows by default, which is why client-side filtering missed
      // customers further down the alphabet. Push the filter to Postgres
      // and cap displayed results at 50 — enough for a dropdown picker.
      var builder = client
          .from('customers')
          .select('id, code, shop_name, phone')
          .eq('org_id', orgId)
          .eq('is_active', true);

      final q = query.trim().replaceAll(',', '');
      if (q.isNotEmpty) {
        final pattern = '%$q%';
        builder = builder
            .or('shop_name.ilike.$pattern,code.ilike.$pattern');
      }

      final rows = await builder.order('shop_name').limit(50);

      setState(() {
        _loadingCustomers = false;
        _availableCustomers = (rows as List).cast<Map<String, dynamic>>();
      });
    } catch (e) {
      setState(() {
        _loadingCustomers = false;
        _customersError = e.toString();
      });
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
        const Duration(milliseconds: 300),
        () => _loadAssignedCustomers(value));
  }

  Future<void> _addPhoto() async {
    if (_capturing) return;
    final source = await _pickPhotoSource();
    if (source == null) return;
    setState(() => _capturing = true);
    try {
      final svc = ref.read(orderPhotoCaptureServiceProvider);
      final path = await svc.capture(orderId: _orderId, source: source);
      if (path != null && mounted) {
        setState(() => _photoPaths.add(path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<OrderPhotoSource?> _pickPhotoSource() {
    return showModalBottomSheet<OrderPhotoSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.of(ctx).pop(OrderPhotoSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pick from gallery'),
              onTap: () => Navigator.of(ctx).pop(OrderPhotoSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_selectedCustomer == null) {
      setState(() => _error = 'Pick a customer first');
      return;
    }
    final notes = _notesCtrl.text.trim();
    if (notes.isEmpty && _photoPaths.isEmpty) {
      setState(() => _error = 'Add a note or a photo');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth == null) throw 'Not authenticated';
      final orgId = auth.organizationId;
      if (orgId == null) throw 'No organization';

      await ref.read(orderServiceProvider).create(
            id: _orderId,
            orgId: orgId,
            customerId: _selectedCustomer!['id'] as String,
            customerName: _selectedCustomer!['shop_name'] as String?,
            customerCode: _selectedCustomer!['code'] as String?,
            salespersonId: auth.id,
            salespersonName: auth.name,
            notes: notes,
            photoPaths: _photoPaths,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Order submitted for review.')),
      );
    } catch (e) {
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabber(),
            _header(),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _customerSection(),
                    const SizedBox(height: 16),
                    _photosSection(),
                    const SizedBox(height: 16),
                    _notesSection(),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
                          style: const TextStyle(color: AppColors.danger)),
                    ],
                  ],
                ),
              ),
            ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _grabber() => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 8, bottom: 4),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Row(
          children: [
            const Expanded(
              child: Text('New Order',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 22),
              onPressed:
                  _submitting ? null : () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      );

  Widget _customerSection() {
    final c = _selectedCustomer;
    if (_preLocked && c != null) {
      return _customerCard(c, lockedReason: 'From this route stop');
    }
    if (_loadingCustomers && _availableCustomers == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_customersError != null) {
      return Text('Could not load customers: $_customersError',
          style: const TextStyle(color: AppColors.danger));
    }
    if (c != null) {
      return Column(
        children: [
          _customerCard(c),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('Change customer'),
              onPressed: _submitting
                  ? null
                  : () => setState(() => _selectedCustomer = null),
            ),
          ),
        ],
      );
    }
    return _customerPicker();
  }

  Widget _customerCard(Map<String, dynamic> c, {String? lockedReason}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primaryLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primaryLight),
      ),
      child: Row(
        children: [
          const Icon(Icons.store, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (c['shop_name'] as String?) ?? '(no name)',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
                if (c['code'] != null)
                  Text('#${c['code']}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54)),
                if (lockedReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(lockedReason,
                        style: const TextStyle(
                            fontSize: 11, color: Colors.black45)),
                  ),
              ],
            ),
          ),
          if (lockedReason != null)
            const Icon(Icons.lock_outline, size: 16, color: Colors.black38),
        ],
      ),
    );
  }

  Widget _customerPicker() {
    final filtered = _availableCustomers ?? const [];
    final hasQuery = _searchCtrl.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Search by name or code',
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          onChanged: _onSearchChanged,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: filtered.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      hasQuery
                          ? 'No matches'
                          : 'No active customers in your org',
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = filtered[i];
                    return ListTile(
                      leading:
                          const Icon(Icons.store_outlined, size: 20),
                      title: Text((c['shop_name'] as String?) ?? '',
                          style: const TextStyle(
                              fontWeight: FontWeight.w500)),
                      subtitle:
                          Text('#${(c['code'] as String?) ?? ''}'),
                      dense: true,
                      onTap: () =>
                          setState(() => _selectedCustomer = c),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _photosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Photos',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const Spacer(),
            TextButton.icon(
              onPressed: _capturing || _submitting ? null : _addPhoto,
              icon: _capturing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_a_photo_outlined, size: 18),
              label: const Text('Add photo'),
            ),
          ],
        ),
        if (_photoPaths.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No photos yet (optional)',
                style: TextStyle(
                    color: Colors.grey.shade600, fontSize: 13)),
          )
        else
          SizedBox(
            height: 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _photoPaths.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final path = _photoPaths[i];
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        Supabase.instance.client.storage
                            .from('opstation-photos')
                            .getPublicUrl(path),
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                        loadingBuilder: (_, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            width: 90,
                            height: 90,
                            color: Colors.grey.shade100,
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2),
                            ),
                          );
                        },
                        errorBuilder: (_, __, ___) => Container(
                          width: 90,
                          height: 90,
                          color: Colors.grey.shade100,
                          alignment: Alignment.center,
                          child: const Icon(Icons.broken_image_outlined,
                              size: 22, color: Colors.black38),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: InkWell(
                        onTap: _submitting
                            ? null
                            : () => setState(() => _photoPaths.removeAt(i)),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              size: 14, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _notesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Order details',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        const SizedBox(height: 6),
        TextField(
          controller: _notesCtrl,
          maxLines: 5,
          minLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Items, quantities, special instructions…',
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 18),
                label: const Text('Submit'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  backgroundColor: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
