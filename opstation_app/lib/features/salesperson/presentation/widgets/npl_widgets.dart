import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../services/npl_providers.dart';

String _qs(num n) {
  final d = n.toDouble();
  return d % 1 == 0 ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}

/// Small rocket on a collapsed stop row when the outlet is in an active launch.
class NplRocket extends ConsumerWidget {
  final String customerId;
  const NplRocket({super.key, required this.customerId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = ref.watch(nplOutletIndexProvider).valueOrNull?[customerId];
    if (l == null || l.isEmpty) return const SizedBox.shrink();
    final ordered = l.any((e) => ((e['orders'] as num?) ?? 0) > 0);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(Icons.rocket_launch,
          size: 16, color: ordered ? AppColors.success : AppColors.primary),
    );
  }
}

/// "LAUNCH OUTLET" strip on the visit card: what to pitch here, and its status.
class NplStopStrip extends ConsumerWidget {
  final String customerId;
  const NplStopStrip({super.key, required this.customerId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launches = ref.watch(nplOutletIndexProvider).valueOrNull?[customerId];
    if (launches == null || launches.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final l in launches) _strip(l),
    ]);
  }

  Widget _strip(Map<String, dynamic> l) {
    final orders = ((l['orders'] as num?) ?? 0).toInt();
    final qty = (l['qty'] as num?) ?? 0;
    final outcome = l['outcome'] as String?;
    final reason = (l['reason'] as String?)?.trim() ?? '';
    final schemes = [for (final s in (l['schemes'] as List? ?? const [])) '$s'];
    String status;
    Color tone;
    if (orders > 0) {
      status = orders >= 2
          ? 'Ordered $orders times (${_qs(qty)} sold). Repeat outlet'
          : 'Ordered once (${_qs(qty)} sold). Push a repeat';
      tone = AppColors.success;
    } else if (outcome == 'declined') {
      status = reason.isEmpty ? 'Declined earlier' : 'Declined: $reason';
      tone = const Color(0xFFFDE68A);
    } else if (outcome == 'later') {
      status = reason.isEmpty ? 'Will order later' : 'Will order later: $reason';
      tone = const Color(0xFFFDE68A);
    } else {
      status = 'Not ordered yet. Pitch this product';
      tone = Colors.white;
    }
    final done = orders > 0;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: done ? AppColors.successLight : AppColors.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? Icons.check_circle : Icons.rocket_launch,
              size: 14, color: done ? AppColors.successDark : Colors.white70),
          const SizedBox(width: 6),
          Text('LAUNCH OUTLET',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: done ? AppColors.successDark : Colors.white70)),
        ]),
        const SizedBox(height: 4),
        Text('${l['product_name'] ?? l['name']}',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: done ? AppColors.textPrimaryLight : Colors.white)),
        if (schemes.isNotEmpty)
          Text('Offer: ${schemes.join(', ')}',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: done ? AppColors.textSecondaryLight : Colors.white)),
        const SizedBox(height: 3),
        Text(status,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: done ? AppColors.successDark : tone)),
      ]),
    );
  }
}
