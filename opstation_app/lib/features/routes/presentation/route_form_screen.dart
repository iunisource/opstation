import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../customers/data/customer_repository.dart';
import '../../salesperson/models/customer.dart';
import '../../salesperson/models/sales_route.dart';
import '../providers/routes_controller.dart';

class RouteFormScreen extends ConsumerStatefulWidget {
  final String? routeId;
  const RouteFormScreen({super.key, this.routeId});

  @override
  ConsumerState<RouteFormScreen> createState() => _RouteFormScreenState();
}

class _RouteFormScreenState extends ConsumerState<RouteFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  RouteKind _kind = RouteKind.recurring;

  /// Ordered list of stops currently on the route.
  final List<Customer> _stops = [];

  bool _hydrated = false;
  bool _submitting = false;

  bool get _isEdit => widget.routeId != null;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _hydrate(SalesRoute r) {
    if (_hydrated) return;
    _hydrated = true;
    _nameCtrl.text = r.name;
    _kind = r.kind;
    _stops
      ..clear()
      ..addAll(r.stops);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_stops.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add at least one customer stop before saving.'),
        ),
      );
      return;
    }
    setState(() => _submitting = true);
    final ctrl = ref.read(routesControllerProvider.notifier);
    try {
      if (_isEdit) {
        await ctrl.updateRoute(
          id: widget.routeId!,
          name: _nameCtrl.text,
          kind: _kind,
          customerIds: [for (final c in _stops) c.id],
        );
      } else {
        await ctrl.create(
          name: _nameCtrl.text,
          kind: _kind,
          customerIds: [for (final c in _stops) c.id],
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEdit ? 'Route updated' : 'Route created')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
      setState(() => _submitting = false);
    }
  }

  Future<void> _openPicker() async {
    final currentIds = _stops.map((c) => c.id).toSet();
    final picked = await showModalBottomSheet<List<Customer>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CustomerPicker(excludeIds: currentIds),
    );
    if (picked != null && picked.isNotEmpty) {
      setState(() => _stops.addAll(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isEdit) {
      final async = ref.watch(routesControllerProvider);
      async.whenData((state) {
        final match = state.all.where((r) => r.id == widget.routeId).toList();
        if (match.isNotEmpty) _hydrate(match.first);
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(_isEdit ? 'Edit route' : 'New route',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: (_isEdit && !_hydrated)
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Route name *',
                          ),
                          validator: (v) =>
                              v == null || v.trim().isEmpty ? 'Required' : null,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Route kind',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<RouteKind>(
                          segments: const [
                            ButtonSegment(
                              value: RouteKind.recurring,
                              label: Text('Recurring'),
                              icon: Icon(Icons.all_inclusive, size: 16),
                            ),
                            ButtonSegment(
                              value: RouteKind.oneTime,
                              label: Text('One-time'),
                              icon: Icon(Icons.event_outlined, size: 16),
                            ),
                          ],
                          selected: {_kind},
                          onSelectionChanged: (s) =>
                              setState(() => _kind = s.first),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _kind == RouteKind.recurring
                              ? 'Salesperson can start this route any number of times.'
                              : 'Salesperson can start this route only once per assignment.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textTertiaryLight,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        const Text(
                          'STOPS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_stops.length}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondaryLight,
                          ),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _openPicker,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Add customers'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _stops.isEmpty
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.place_outlined,
                                  color: AppColors.textTertiaryLight,
                                  size: 36,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'No stops yet.',
                                  style: TextStyle(
                                    color: AppColors.textSecondaryLight,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _openPicker,
                                  icon: const Icon(Icons.add, size: 16),
                                  label: const Text('Add customers'),
                                ),
                              ],
                            ),
                          )
                        : ReorderableListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                            itemCount: _stops.length,
                            onReorder: (oldIdx, newIdx) {
                              setState(() {
                                var ni = newIdx;
                                if (ni > oldIdx) ni -= 1;
                                final item = _stops.removeAt(oldIdx);
                                _stops.insert(ni, item);
                              });
                            },
                            itemBuilder: (_, i) {
                              final c = _stops[i];
                              return _StopTile(
                                key: ValueKey(c.id),
                                index: i,
                                customer: c,
                                onRemove: () =>
                                    setState(() => _stops.removeAt(i)),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.check_circle_outline, size: 18),
                        label:
                            Text(_isEdit ? 'Save changes' : 'Create route'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _StopTile extends StatelessWidget {
  final int index;
  final Customer customer;
  final VoidCallback onRemove;

  const _StopTile({
    super.key,
    required this.index,
    required this.customer,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  customer.shopName,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  customer.address,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondaryLight,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove',
            onPressed: onRemove,
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.drag_handle, color: AppColors.textTertiaryLight),
            ),
          ),
        ],
      ),
    );
  }
}

/// Multi-select customer picker as a bottom sheet. Excludes any customers
/// already on the route.
class _CustomerPicker extends ConsumerStatefulWidget {
  final Set<String> excludeIds;
  const _CustomerPicker({required this.excludeIds});

  @override
  ConsumerState<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends ConsumerState<_CustomerPicker> {
  final _searchCtrl = TextEditingController();
  final Set<String> _selected = {};
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(customerRepositoryProvider);
    // Let the sheet take its natural height; use AnimatedPadding to lift
    // the whole sheet above the keyboard. Using viewInsets inside the
    // sheet's own ConstrainedBox was wrong — it shrank the container
    // *and* inflated internal padding, causing RenderFlex overflow.
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Add customers',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${_selected.length} selected',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondaryLight,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Search name or address...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: FutureBuilder<List<Customer>>(
                  future: repo.all(includeInactive: false),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    final all = snap.data ?? const <Customer>[];
                    final available = all
                        .where((c) => !widget.excludeIds.contains(c.id))
                        .toList();
                    final q = _query.trim().toLowerCase();
                    final filtered = q.isEmpty
                        ? available
                        : available
                            .where((c) =>
                                c.shopName.toLowerCase().contains(q) ||
                                c.address.toLowerCase().contains(q) ||
                                c.code.toLowerCase().contains(q))
                            .toList();
                    if (filtered.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: Text(
                              'No customers match. Create them in Customers first.'),
                        ),
                      );
                    }
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final selected = _selected.contains(c.id);
                        return InkWell(
                          onTap: () => setState(() {
                            if (selected) {
                              _selected.remove(c.id);
                            } else {
                              _selected.add(c.id);
                            }
                          }),
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.primaryLight
                                      .withOpacity(0.5)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.borderLight,
                              ),
                            ),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: selected,
                                  onChanged: (v) => setState(() {
                                    if (v ?? false) {
                                      _selected.add(c.id);
                                    } else {
                                      _selected.remove(c.id);
                                    }
                                  }),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.shopName,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        c.address,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textSecondaryLight,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () async {
                              final repo =
                                  ref.read(customerRepositoryProvider);
                              final all = await repo.all(
                                  includeInactive: false);
                              final picked = [
                                for (final c in all)
                                  if (_selected.contains(c.id)) c,
                              ];
                              if (!mounted) return;
                              Navigator.of(context).pop(picked);
                            },
                      child: Text('Add ${_selected.length}'),
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
}
