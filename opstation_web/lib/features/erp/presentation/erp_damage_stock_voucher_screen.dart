import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';

class ErpDamageStockVoucherScreen extends ConsumerWidget {
  const ErpDamageStockVoucherScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Damage Stock Voucher', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        const Text('Write off stock damaged during production, with reason codes and a loss posting to the GL.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.report_gmailerrorred_outlined, size: 56, color: AppTheme.textSecondary.withOpacity(0.3)),
          const SizedBox(height: 12),
          const Text('Coming soon', style: TextStyle(color: AppTheme.textSecondary, fontSize: 16, fontWeight: FontWeight.w600)),
        ]))),
      ]),
    );
  }
}
