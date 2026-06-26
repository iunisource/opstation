import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/services/notification_service.dart';

import '../../../core/theme/app_colors.dart';
import '../../audit/data/audit_repository.dart';
import '../../auth/providers/auth_controller.dart';
import '../../auth/models/user_role.dart';
import '../../customers/data/customer_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../team/data/team_repository.dart';
import '../../team/models/team_user.dart';
import '../data/delivery_repository.dart';
import '../models/delivery.dart';

/// Screen for creating a new delivery or editing an existing draft /
/// assigned delivery.
///
/// Pass [existingId] = null for create, or the delivery ID to edit.
class DeliveryWizardScreen extends ConsumerStatefulWidget {
  final String? existingId;
  const DeliveryWizardScreen({super.key, this.existingId});

  @override
  ConsumerState<DeliveryWizardScreen> createState() =>
      _DeliveryWizardScreenState();
}

class _DeliveryWizardScreenState
    extends ConsumerState<DeliveryWizardScreen> {
  String? _driverId;
  String? _driverName;
  String? _driverRole;
  final _notesCtrl = TextEditingController();
  final List<_StopDraft> _stops = [];
  bool _loading = true;
  bool _saving = false;
  // If editing, the current delivery status governs what actions are
  // available at the bottom of the screen.
  DeliveryStatus? _currentStatus;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final s in _stops) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInitial() async {
    if (widget.existingId == null) {
      setState(() => _loading = false);
      return;
    }
    final repo = ref.read(deliveryRepositoryProvider);
    final d = await repo.byId(widget.existingId!);
    if (d == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _driverId = d.driverId;
    _driverName = d.driverName;
    _driverRole = d.driverRole;
    _notesCtrl.text = d.notes ?? '';
    _currentStatus = d.status;
    _stops.addAll(d.stops.map((s) => _StopDraft.fromExisting(s)));
    if (mounted) setState(() => _loading = false);
  }

  bool get _isEdit => widget.existingId != null;

  bool get _canEdit {
    if (!_isEdit) return true;
    return _currentStatus == DeliveryStatus.draft ||
        _currentStatus == DeliveryStatus.assigned;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          _isEdit ? 'Edit delivery' : 'New delivery',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('Driver'),
                  _driverPicker(),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _sectionLabel('Stops'),
                      const Spacer(),
                      if (_canEdit) ...[
                        TextButton.icon(
                          onPressed: _addFromDo,
                          icon: const Icon(Icons.local_shipping_outlined, size: 18),
                          label: const Text('Add from DO'),
                        ),
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: _addStop,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add stop'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (_stops.isEmpty)
                    _emptyStops()
                  else
                    for (int i = 0; i < _stops.length; i++)
                      _StopCard(
                        key: ValueKey(_stops[i].uid),
                        draft: _stops[i],
                        index: i,
                        readOnly: !_canEdit,
                        onRemove: _canEdit ? () => _removeStop(i) : null,
                        onTap: _canEdit ? () => _editStop(i) : null,
                        onMoveUp: _canEdit && i > 0
                            ? () => _moveStop(i, i - 1)
                            : null,
                        onMoveDown: _canEdit && i < _stops.length - 1
                            ? () => _moveStop(i, i + 1)
                            : null,
                      ),
                  const SizedBox(height: 18),
                  _sectionLabel('Notes (optional)'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _notesCtrl,
                    readOnly: !_canEdit,
                    minLines: 2,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Anything the driver should know...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _totalsBox(),
                ],
              ),
            ),
          ),
          _bottomActions(),
        ],
      ),
    );
  }

  Widget _sectionLabel(String s) => Text(
        s.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondaryLight,
        ),
      );

  Widget _driverPicker() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: _canEdit ? _pickDriver : null,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border.all(color: AppColors.borderLight),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_outline,
                  size: 20, color: AppColors.textSecondaryLight),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _driverName ?? 'Pick a driver (optional for drafts)',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        _driverName == null ? FontWeight.w400 : FontWeight.w600,
                    color: _driverName == null
                        ? AppColors.textTertiaryLight
                        : null,
                  ),
                ),
              ),
              if (_canEdit)
                const Icon(Icons.chevron_right,
                    size: 20, color: AppColors.textTertiaryLight),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyStops() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.borderLight.withOpacity(0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.inventory_2_outlined,
              size: 32, color: AppColors.textTertiaryLight),
          const SizedBox(height: 8),
          const Text(
            'No stops yet',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondaryLight,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Add stops to build the delivery.',
            style: TextStyle(
              fontSize: 11,
              color: AppColors.textSecondaryLight.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsBox() {
    int total = 0;
    int cash = 0;
    int credit = 0;
    for (final s in _stops) {
      total += s.amount;
      if (s.paymentType == PaymentType.cash) {
        cash += s.amount;
      } else {
        credit += s.amount;
      }
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryLight.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: _totalCell('Rs $total', 'TOTAL'),
          ),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          Expanded(child: _totalCell('Rs $cash', 'CASH')),
          Container(width: 1, height: 32, color: AppColors.borderLight),
          Expanded(child: _totalCell('Rs $credit', 'CREDIT')),
        ],
      ),
    );
  }

  Widget _totalCell(String value, String label) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.textSecondaryLight,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _bottomActions() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        10 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: const Border(
          top: BorderSide(color: AppColors.borderLight, width: 0.5),
        ),
      ),
      child: _buildActions(),
    );
  }

  Widget _buildActions() {
    if (!_canEdit) {
      return OutlinedButton(
        onPressed: () => Navigator.of(context).pop(),
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        child: const Text('Close'),
      );
    }
    // New OR draft/assigned edit: offer Save draft + Save & assign.
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _saveDraft,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save draft'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _saveAndAssign,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Save & assign'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ),
      ],
    );
  }

  // ---- Driver picking ------------------------------------------------

  Future<void> _pickDriver() async {
    final users = await ref.read(teamRepositoryProvider).all(includeInactive: false);
    final drivers =
        users.where((u) => u.role == UserRole.driver && u.isActive).toList();
    if (!mounted) return;

    if (drivers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active drivers in the team.')),
      );
      return;
    }

    final picked = await showModalBottomSheet<TeamUser?>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DriverPickSheet(
        drivers: drivers,
        currentId: _driverId,
      ),
    );

    if (picked != null) {
      setState(() {
        _driverId = picked.id;
        _driverName = picked.name;
        _driverRole = picked.role.name;
      });
    } else if (picked == null && _driverId != null) {
      // The sheet uses null to mean "clear" too. We need to distinguish
      // "user backed out" from "user tapped Unassign." Handled by the
      // sheet using Navigator.pop(context, const _UnassignSentinel()) —
      // but to keep things simple, wrap the clear action in a separate
      // bool we check via return type. For now, no-op on null.
    }
  }

  // ---- Stop editing --------------------------------------------------

  Future<void> _addStop() async {
    final draft = _StopDraft();
    final ok = await _openStopEditor(draft, isNew: true);
    if (ok == true) {
      setState(() => _stops.add(draft));
    } else {
      draft.dispose();
    }
  }

  /// Fetches the dispatch pool (approved DOs not yet assigned) and lets the
  /// user pick one or more to add as stops, each carrying its do_id.
  Future<void> _addFromDo() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    final orgId = auth?.orgId;
    if (orgId == null) return;
    final client = Supabase.instance.client;

    List<Map<String, dynamic>> pool = [];
    try {
      // Candidate DOs: dispatchable, not voided, org-scoped.
      final dos = await client
          .from('delivery_orders')
          .select('id, voucher_number, customer_id, collect_amount, status, '
              'is_voided, customers(shop_name, code)')
          .eq('org_id', orgId)
          .inFilter('status', const ['saved', 'invoiced', 'partially_delivered'])
          .order('created_at', ascending: false);

      // Pool-exit: do_ids already on a stop of a non-cancelled delivery.
      final taken = <String>{};
      try {
        final t = await client
            .from('delivery_stops')
            .select('do_id, deliveries(status)')
            .not('do_id', 'is', null);
        for (final s in t as List) {
          if ((s['deliveries']?['status']) != 'cancelled') {
            final id = s['do_id'] as String?;
            if (id != null) taken.add(id);
          }
        }
      } catch (_) {}

      // Exclude any already in this wizard's stop list.
      final inWizard = _stops.map((s) => s.doId).whereType<String>().toSet();

      for (final d in dos as List) {
        final id = d['id'] as String?;
        if (id == null || taken.contains(id) || inWizard.contains(id)) continue;
        if ((d['is_voided'] as bool?) == true) continue;
        if ((d['customer_id'] as String?) == null) continue;
        pool.add(Map<String, dynamic>.from(d as Map));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to load DOs: $e')));
      return;
    }

    if (!mounted) return;
    if (pool.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No unassigned delivery orders available.')),
      );
      return;
    }

    final selectedIds = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _DoPickerSheet(pool: pool),
    );

    if (selectedIds == null || selectedIds.isEmpty) return;

    setState(() {
      for (final d in pool) {
        final id = d['id'] as String;
        if (!selectedIds.contains(id)) continue;
        final collect = (d['collect_amount'] as num?) ?? 0;
        final draft = _StopDraft(
          customer: Customer(
            id: d['customer_id'] as String,
            code: d['customers']?['code'] as String? ?? '',
            shopName: d['customers']?['shop_name'] as String? ?? '',
            contactPerson: '',
            phone: '',
            address: '',
            isActive: true,
          ),
          description: d['voucher_number'] as String? ?? '',
          amount: collect.round(),
          paymentType: collect > 0 ? PaymentType.cash : PaymentType.credit,
          doId: id,
        );
        _stops.add(draft);
      }
    });
  }

  Future<void> _editStop(int index) async {
    final draft = _stops[index];
    final ok = await _openStopEditor(draft, isNew: false);
    if (ok == true) setState(() {});
  }

  Future<bool?> _openStopEditor(_StopDraft draft, {required bool isNew}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _StopEditorSheet(draft: draft, isNew: isNew),
    );
  }

  void _removeStop(int i) {
    final removed = _stops.removeAt(i);
    removed.dispose();
    setState(() {});
  }

  void _moveStop(int from, int to) {
    final item = _stops.removeAt(from);
    _stops.insert(to, item);
    setState(() {});
  }

  // ---- Save ----------------------------------------------------------

  String? _validateForSave({required bool requireDriver}) {
    if (_stops.isEmpty) return 'Add at least one stop.';
    for (int i = 0; i < _stops.length; i++) {
      final s = _stops[i];
      if (s.customer == null) {
        return 'Stop ${i + 1}: pick a customer.';
      }
      if (s.amount < 0) {
        return 'Stop ${i + 1}: amount cannot be negative.';
      }
    }
    if (requireDriver && _driverId == null) {
      return 'Pick a driver to assign.';
    }
    return null;
  }

  Future<void> _saveDraft() => _save(assign: false);
  Future<void> _saveAndAssign() => _save(assign: true);

  Future<void> _save({required bool assign}) async {
    final err = _validateForSave(requireDriver: assign);
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _saving = true);
    final actor = ref.read(authControllerProvider).valueOrNull;
    final repo = ref.read(deliveryRepositoryProvider);
    final logger = ref.read(auditLoggerProvider);
    final inputs = _stops
        .map((s) => DeliveryStopInput(
              id: s.existingId,
              customerId: s.customer!.id,
              customerCode: s.customer!.code,
              customerName: s.customer!.shopName,
              itemDescription: s.descriptionCtrl.text.trim(),
              amount: s.amount,
              paymentType: s.paymentType,
              doId: s.doId,
            ))
        .toList();

    try {
      Delivery saved;
      if (_isEdit) {
        saved = await repo.updateDelivery(
          id: widget.existingId!,
          driverId: _driverId,
          driverName: _driverName,
          driverRole: _driverRole,
          notes: _notesCtrl.text.trim().isEmpty
              ? null
              : _notesCtrl.text.trim(),
          stops: inputs,
        );
        await logger.deliveryUpdated(
          deliveryId: saved.id,
          stopCount: saved.stops.length,
          totalAmount: saved.totalAmount,
        );
      } else {
        saved = await repo.createDraft(
          driverId: _driverId,
          driverName: _driverName,
          driverRole: _driverRole,
          createdBy: actor?.id ?? 'unknown',
          createdByName: actor?.name ?? 'System',
          createdByRole: actor?.role.name ?? '',
          notes: _notesCtrl.text.trim().isEmpty
              ? null
              : _notesCtrl.text.trim(),
          stops: inputs,
        );
        await logger.deliveryCreated(
          deliveryId: saved.id,
          stopCount: saved.stops.length,
          totalAmount: saved.totalAmount,
          driverName: saved.driverName,
        );
      }

      if (assign && saved.status == DeliveryStatus.draft) {
        await repo.assign(saved.id);
        await logger.deliveryAssigned(
          deliveryId: saved.id,
          driverName: _driverName ?? 'driver',
        );
        // Notify driver of assignment
        if (saved.driverId != null) {
          Future.microtask(() async {
            try {
              await ref.read(notificationServiceProvider).sendToUser(
                targetUserId: saved.driverId!,
                title: 'New Delivery Assigned',
                body: 'You have a new delivery with ${saved.stops.length} stops.',
              );
            } catch (_) {}
          });
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ---- Driver picker sheet ---------------------------------------------

class _DriverPickSheet extends StatelessWidget {
  final List<TeamUser> drivers;
  final String? currentId;
  const _DriverPickSheet({required this.drivers, required this.currentId});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Pick driver',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            for (final d in drivers)
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: AppColors.primaryLight,
                  child: Text(
                    d.name.isNotEmpty ? d.name[0].toUpperCase() : 'D',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                title: Text(d.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                trailing: currentId == d.id
                    ? const Icon(Icons.check_circle, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.of(context).pop(d),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Stop editor sheet ------------------------------------------------

class _StopEditorSheet extends ConsumerStatefulWidget {
  final _StopDraft draft;
  final bool isNew;
  const _StopEditorSheet({required this.draft, required this.isNew});

  @override
  ConsumerState<_StopEditorSheet> createState() => _StopEditorSheetState();
}

class _StopEditorSheetState extends ConsumerState<_StopEditorSheet> {
  late Customer? _customer = widget.draft.customer;
  late PaymentType _paymentType = widget.draft.paymentType;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: keyboard),
      duration: const Duration(milliseconds: 150),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isNew ? 'Add stop' : 'Edit stop',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                _label('Customer'),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _pickCustomer,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.borderLight),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.storefront_outlined, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _customer == null
                                ? 'Pick customer'
                                : '${_customer!.code} · ${_customer!.shopName}',
                            style: TextStyle(
                              fontSize: 13,
                              color: _customer == null
                                  ? AppColors.textTertiaryLight
                                  : null,
                              fontWeight: _customer == null
                                  ? FontWeight.w400
                                  : FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 18, color: AppColors.textTertiaryLight),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _label('Item description'),
                const SizedBox(height: 6),
                TextField(
                  controller: widget.draft.descriptionCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'e.g. 10 x 60W LED, carton',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Amount + Payment row.
                //
                // When Credit is selected, the amount isn't relevant at
                // delivery time (the customer is on account), so we hide
                // the Amount field entirely and let the Payment toggle
                // span the full row width.
                if (_paymentType == PaymentType.cash)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _label('Amount (Rs)'),
                            const SizedBox(height: 6),
                            TextField(
                              controller: widget.draft.amountCtrl,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                prefixText: 'Rs ',
                                hintText: '0',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _paymentPicker()),
                    ],
                  )
                else
                  // Credit: payment toggle takes the full row.
                  _paymentPicker(),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 44)),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _commit,
                        style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 44)),
                        child: const Text('Save stop'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String s) => Text(
        s.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondaryLight,
        ),
      );

  Future<void> _pickCustomer() async {
    final customers =
        await ref.read(customerRepositoryProvider).all(includeInactive: false);
    if (!mounted) return;
    final picked = await showModalBottomSheet<Customer>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CustomerPickSheet(customers: customers),
    );
    if (picked != null) {
      setState(() => _customer = picked);
    }
  }

  void _commit() {
    if (_customer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a customer first.')),
      );
      return;
    }
    widget.draft.customer = _customer;
    widget.draft.paymentType = _paymentType;
    // Credit stops have no amount at delivery time — driver doesn't
    // collect anything at drop. Force the draft's amount text to '0'
    // so the persisted row and any subsequent edit form don't carry a
    // stale cash figure.
    if (_paymentType == PaymentType.credit) {
      widget.draft.amountCtrl.text = '0';
    }
    Navigator.of(context).pop(true);
  }

  /// Payment-type segmented button. Extracted so the layout can place
  /// it either in a half-width column (Cash mode, alongside Amount) or
  /// full-width (Credit mode, Amount hidden). Label font is shrunk one
  /// notch so "Credit" doesn't wrap on narrow screens.
  Widget _paymentPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Payment'),
        const SizedBox(height: 6),
        SegmentedButton<PaymentType>(
          segments: const [
            ButtonSegment(
              value: PaymentType.cash,
              label: Text('Cash', style: TextStyle(fontSize: 13)),
              icon: Icon(Icons.payments_outlined, size: 16),
            ),
            ButtonSegment(
              value: PaymentType.credit,
              label: Text('Credit', style: TextStyle(fontSize: 13)),
              icon: Icon(Icons.credit_score_outlined, size: 16),
            ),
          ],
          selected: {_paymentType},
          showSelectedIcon: false,
          onSelectionChanged: (s) =>
              setState(() => _paymentType = s.first),
        ),
      ],
    );
  }
}

// ---- Customer picker sheet (searchable) -------------------------------

class _CustomerPickSheet extends StatefulWidget {
  final List<Customer> customers;
  const _CustomerPickSheet({required this.customers});

  @override
  State<_CustomerPickSheet> createState() => _CustomerPickSheetState();
}

class _CustomerPickSheetState extends State<_CustomerPickSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.customers
        : widget.customers.where((c) {
            return c.code.toLowerCase().contains(q) ||
                c.shopName.toLowerCase().contains(q) ||
                c.contactPerson.toLowerCase().contains(q);
          }).toList();
    final keyboard = MediaQuery.of(context).viewInsets.bottom;

    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: keyboard),
      duration: const Duration(milliseconds: 150),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick customer',
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: 'Search code or shop name',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.55,
                ),
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No matches.',
                            textAlign: TextAlign.center),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final c = filtered[i];
                          return ListTile(
                            dense: true,
                            title: Text(
                              c.shopName,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              '${c.code}${c.contactPerson.isNotEmpty ? ' · ${c.contactPerson}' : ''}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onTap: () => Navigator.of(context).pop(c),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Stop card + draft ------------------------------------------------

class _StopCard extends StatelessWidget {
  final _StopDraft draft;
  final int index;
  final bool readOnly;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const _StopCard({
    super.key,
    required this.draft,
    required this.index,
    required this.readOnly,
    this.onRemove,
    this.onTap,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    final title = draft.customer?.shopName ?? '(no customer)';
    final code = draft.customer?.code ?? '';
    final desc = draft.descriptionCtrl.text.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.primaryLight,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (code.isNotEmpty) code,
                        if (desc.isNotEmpty) desc,
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondaryLight,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: draft.paymentType == PaymentType.cash
                                ? AppColors.successLight
                                : AppColors.warningLight,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            draft.paymentType.label,
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: draft.paymentType == PaymentType.cash
                                  ? AppColors.successDark
                                  : AppColors.warningDark,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Rs ${draft.amount}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!readOnly) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: onMoveUp,
                  tooltip: 'Move up',
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: onMoveDown,
                  tooltip: 'Move down',
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      size: 18, color: AppColors.danger),
                  onPressed: onRemove,
                  tooltip: 'Remove',
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Mutable editable state for a single stop. Holds the controllers so
/// text input survives parent rebuilds.
class _StopDraft {
  static int _seq = 0;
  final int uid;

  /// ID of the existing stop row if we're editing; null for new stops.
  final String? existingId;

  Customer? customer;
  final TextEditingController descriptionCtrl;
  final TextEditingController amountCtrl;
  PaymentType paymentType;

  /// Source Delivery Order id when this stop was created from the
  /// "Add from DO" picker. Null for manually-added stops.
  String? doId;

  _StopDraft({
    this.existingId,
    this.customer,
    String description = '',
    int amount = 0,
    this.paymentType = PaymentType.cash,
    this.doId,
  })  : uid = ++_seq,
        descriptionCtrl = TextEditingController(text: description),
        amountCtrl =
            TextEditingController(text: amount == 0 ? '' : amount.toString());

  factory _StopDraft.fromExisting(DeliveryStop s) {
    final d = _StopDraft(
      existingId: s.id,
      description: s.itemDescription,
      amount: s.amount,
      paymentType: s.paymentType,
      doId: s.doId,
    );
    d.customer = Customer(
      id: s.customerId,
      code: s.customerCode,
      shopName: s.customerName,
      contactPerson: '',
      phone: '',
      address: '',
      isActive: true,
    );
    return d;
  }

  int get amount => int.tryParse(amountCtrl.text.trim()) ?? 0;

  void dispose() {
    descriptionCtrl.dispose();
    amountCtrl.dispose();
  }
}

/// Multi-select bottom sheet listing unassigned Delivery Orders. Returns the
/// set of selected DO ids, or null if cancelled.
class _DoPickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> pool;
  const _DoPickerSheet({required this.pool});

  @override
  State<_DoPickerSheet> createState() => _DoPickerSheetState();
}

class _DoPickerSheetState extends State<_DoPickerSheet> {
  final Set<String> _selected = {};
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final q = _search.trim().toLowerCase();
    final items = q.isEmpty
        ? widget.pool
        : widget.pool.where((d) {
            final vno = (d['voucher_number'] as String? ?? '').toLowerCase();
            final name =
                (d['customers']?['shop_name'] as String? ?? '').toLowerCase();
            final code =
                (d['customers']?['code'] as String? ?? '').toLowerCase();
            return vno.contains(q) || name.contains(q) || code.contains(q);
          }).toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollCtrl) {
          return Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    const Text('Add from Delivery Orders',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    Text('${_selected.length} selected',
                        style: TextStyle(
                            color: AppColors.textSecondaryLight, fontSize: 13)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Search DO / customer',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  controller: scrollCtrl,
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final d = items[i];
                    final id = d['id'] as String;
                    final collect = (d['collect_amount'] as num?) ?? 0;
                    final checked = _selected.contains(id);
                    return CheckboxListTile(
                      value: checked,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
                      title: Text(
                        d['voucher_number'] as String? ?? '—',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      subtitle: Text(
                        d['customers']?['shop_name'] as String? ?? 'Walk-in',
                        style: TextStyle(
                            color: AppColors.textSecondaryLight, fontSize: 12),
                      ),
                      secondary: Text(
                        collect > 0
                            ? 'Rs. ${collect.round()}'
                            : 'No collection',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: collect > 0
                              ? AppColors.successDark
                              : AppColors.textTertiaryLight,
                        ),
                      ),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _selected.isEmpty
                              ? null
                              : () => Navigator.pop(context, _selected),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary),
                          child: Text('Add ${_selected.length}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
