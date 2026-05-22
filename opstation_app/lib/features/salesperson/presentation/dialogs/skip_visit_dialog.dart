import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../models/customer.dart';
import '../../providers/trip_controller.dart';

/// Modal for skipping a stop with a reason.
class SkipVisitDialog extends ConsumerStatefulWidget {
  final Customer customer;
  const SkipVisitDialog({super.key, required this.customer});

  @override
  ConsumerState<SkipVisitDialog> createState() => _SkipVisitDialogState();
}

class _SkipVisitDialogState extends ConsumerState<SkipVisitDialog> {
  static const _presets = [
    'Shop closed',
    'Shop shifted',
    '0 balance',
    'Not interested',
    'Other',
  ];

  String _selected = _presets.first;
  final _otherCtrl = TextEditingController();

  @override
  void dispose() {
    _otherCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _selected == 'Other' ? _otherCtrl.text.trim() : _selected;
    if (_selected == 'Other' && reason.isEmpty) return;

    await ref.read(tripControllerProvider.notifier).skipVisit(
          customer: widget.customer,
          reason: reason,
        );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.borderLight,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.warningLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.skip_next,
                        color: AppColors.warningDark),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Skip stop',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        Text(
                          widget.customer.shopName,
                          style: TextStyle(
                            color: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.color
                                ?.withOpacity(0.65),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Reason',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in _presets)
                    InkWell(
                      onTap: () => setState(() => _selected = p),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: _selected == p
                              ? AppColors.warningDark
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _selected == p
                                ? AppColors.warningDark
                                : AppColors.borderLight,
                          ),
                        ),
                        child: Text(
                          p,
                          style: TextStyle(
                            color: _selected == p
                                ? Colors.white
                                : Theme.of(context).textTheme.bodyMedium?.color,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_selected == 'Other') ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _otherCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    hintText: 'Describe the reason',
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _submit,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.warningDark),
                      child: const Text('Skip stop'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
