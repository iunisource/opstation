import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';

class ErpProductionInverseVoucherScreen extends ConsumerWidget {
  const ErpProductionInverseVoucherScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Production Inverse Voucher', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('De-assemble a finished product back into its components (the reverse of a Production Voucher).',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.undo_outlined, size: 56, color: AppTheme.textSecondary.withOpacity(0.3)),
          const SizedBox(height: 12),
          const Text('Coming soon', style: TextStyle(color: AppTheme.textSecondary, fontSize: 16, fontWeight: FontWeight.w600)),
        ]))),
      ]),
    );
  }
}
