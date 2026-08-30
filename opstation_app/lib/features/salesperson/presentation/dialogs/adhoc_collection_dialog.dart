import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/sound_controller.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/salesperson_repository.dart';
import '../../models/customer.dart';
import '../../models/trip.dart';
import '../../providers/trip_controller.dart';

/// Ad-hoc cash receipt.
///
/// The scenario: a customer from an inactive route (or no route at all) sends a
/// payment while the salesperson is elsewhere. This lets the rep record that
/// receipt against ANY customer — search, pick, enter CR# + amount + an optional
/// remark — with no location gate. The SMS still fires and the collection joins
/// the ongoing route summary, or starts a fresh "Off-route collections" summary
/// if no route is active (both handled by [TripController.recordAdHocCollection]).
class AdHocCollectionDialog extends ConsumerStatefulWidget {
  const AdHocCollectionDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const AdHocCollectionDialog(),
    );
  }

  @override
  ConsumerState<AdHocCollectionDialog> createState() =>
      _AdHocCollectionDialogState();
}

class _AdHocCollectionDialogState extends ConsumerState<AdHocCollectionDialog> {
  final _searchCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _crCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  Timer? _debounce;
  List<Customer> _results = const [];
  bool _searching = false;
  Customer? _selected;

  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _prefillReceipt();
  }

  /// Same "next in sequence" convenience as the mark-visit sheet: pre-fill CR#
  /// with the highest numeric receipt entered today + 1, fully editable. Left
  /// blank when nothing has been entered yet so we never invent a start number.
  void _prefillReceipt() {
    final s = ref.read(tripControllerProvider).valueOrNull;
    if (s == null) return;
    int? maxNum;
    void scan(Iterable<Visit> visits) {
      for (final v in visits) {
        final r = v.receiptNumber;
        if (r == null) continue;
        for (final m in RegExp(r'\d+').allMatches(r)) {
          final n = int.tryParse(m.group(0)!);
          if (n != null && (maxNum == null || n > maxNum!)) maxNum = n;
        }
      }
    }

    if (s.active != null) scan(s.active!.visits);
    for (final t in s.completedToday) {
      scan(t.visits);
    }
    if (maxNum != null) _crCtrl.text = '${maxNum! + 1}';
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _amountCtrl.dispose();
    _crCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final repo = ref.read(salespersonRepositoryProvider);
      final rows = await repo.searchCustomers(q);
      if (!mounted) return;
      setState(() {
        _results = rows;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _searching = false);
    }
  }

  void _pick(Customer c) {
    setState(() {
      _selected = c;
      _results = const [];
      _searchCtrl.text = c.shopName;
    });
    FocusScope.of(context).unfocus();
  }

  void _clearSelection() {
    setState(() {
      _selected = null;
      _searchCtrl.clear();
      _results = const [];
    });
  }

  Future<void> _submit() async {
    final customer = _selected;
    if (customer == null) {
      setState(() => _errorText = 'Select a customer first.');
      return;
    }
    final amountText = _amountCtrl.text.trim();
    final amount = amountText.isEmpty ? 0 : (int.tryParse(amountText) ?? -1);
    if (amount <= 0) {
      setState(() => _errorText = 'Enter a valid amount.');
      return;
    }
    if (_crCtrl.text.trim().isEmpty) {
      setState(() => _errorText = 'Receipt number (CR#) is required.');
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await ref.read(tripControllerProvider.notifier).recordAdHocCollection(
            customer: customer,
            amount: amount,
            receiptNumber: _crCtrl.text.trim(),
            notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
          );
      ref.read(soundControllerProvider.notifier).play(AppSound.visitMarked);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _submitting = false;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: DraggableScrollableSheet(
          initialChildSize: 0.9,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.borderLight,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    children: [
                      // Header
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.successLight,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.receipt_long_outlined,
                                color: AppColors.successDark),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('New cash receipt',
                                    style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w700)),
                                Text('Record a payment from any customer',
                                    style: TextStyle(
                                        fontSize: 12.5,
                                        color: AppColors.textSecondaryLight)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      // Customer search / selection
                      if (selected == null) ...[
                        TextField(
                          controller: _searchCtrl,
                          autofocus: true,
                          onChanged: _onSearchChanged,
                          decoration: InputDecoration(
                            hintText: 'Search customer by name or code',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searching
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2)),
                                  )
                                : null,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_results.isNotEmpty)
                          Container(
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: AppColors.borderLight),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              children: [
                                for (final c in _results)
                                  ListTile(
                                    dense: true,
                                    leading: const Icon(Icons.store_outlined,
                                        size: 20, color: AppColors.primary),
                                    title: Text(c.shopName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    subtitle: Text(
                                      [
                                        if (c.code.isNotEmpty) c.code,
                                        if (c.phone.isNotEmpty) c.phone,
                                      ].join(' · '),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    onTap: () => _pick(c),
                                  ),
                              ],
                            ),
                          )
                        else if (!_searching &&
                            _searchCtrl.text.trim().isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('No customers found',
                                style: TextStyle(
                                    color: AppColors.textSecondaryLight)),
                          ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.store,
                                  color: AppColors.primary, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(selected.shopName,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w700)),
                                    if (selected.code.isNotEmpty ||
                                        selected.phone.isNotEmpty)
                                      Text(
                                        [
                                          if (selected.code.isNotEmpty)
                                            selected.code,
                                          if (selected.phone.isNotEmpty)
                                            selected.phone,
                                        ].join(' · '),
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color:
                                                AppColors.textSecondaryLight),
                                      ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed:
                                    _submitting ? null : _clearSelection,
                                child: const Text('Change'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Amount
                        TextField(
                          controller: _amountCtrl,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                            hintText: 'Amount (Rs)',
                            prefixIcon: Icon(Icons.payments_outlined),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _crCtrl,
                          decoration: const InputDecoration(
                            hintText: 'CR# (receipt number)',
                            prefixIcon: Icon(Icons.receipt_long_outlined),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _notesCtrl,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            hintText: 'Remark (optional)',
                            prefixIcon: Icon(Icons.notes),
                          ),
                        ),
                      ],

                      const SizedBox(height: 18),
                      if (_errorText != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.dangerLight,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline,
                                color: AppColors.dangerDark, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(_errorText!,
                                    style: const TextStyle(
                                        color: AppColors.dangerDark,
                                        fontSize: 13))),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],

                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _submitting
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed:
                                (_submitting || selected == null) ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.check_circle_outline,
                                    size: 18),
                            label: const Text('Save receipt'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.success,
                            ),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
