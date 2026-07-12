import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import 'retailer_shell.dart';

/// Balance + aging for the signed-in retailer.
///
/// Calls `retailer_my_aging()`, which wraps the SAME `rpc_customer_aging` that
/// backs the staff Customer Aging report — so the buckets a shopkeeper sees can
/// never drift from the ones your team sees. Reimplementing the arithmetic on
/// the phone is exactly how two versions of "what is owed" end up disagreeing.
final retailerAgingProvider =
    FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final res = await Supabase.instance.client.rpc('retailer_my_aging');
  if (res == null) return null;
  return Map<String, dynamic>.from(res as Map);
});

class RetailerHomeScreen extends ConsumerStatefulWidget {
  const RetailerHomeScreen({super.key});

  @override
  ConsumerState<RetailerHomeScreen> createState() => _RetailerHomeScreenState();
}

class _RetailerHomeScreenState extends ConsumerState<RetailerHomeScreen> {
  bool _showAging = false;

  double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(retailerAgingProvider);
    final t = T.of(context);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(retailerAgingProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [
          const SizedBox(height: 120),
          Center(
            child: Column(children: [
              Icon(Icons.cloud_off_outlined,
                  size: 36, color: AppColors.textSecondaryLight),
              const SizedBox(height: 10),
              Text(t.somethingWentWrong,
                  style: TextStyle(color: AppColors.textSecondaryLight)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(retailerAgingProvider),
                child: Text(t.retry),
              ),
            ]),
          ),
        ]),
        data: (d) {
          final shop = (d?['shop_name'] as String?) ?? '';
          final code = (d?['code'] as String?) ?? '';
          final total = _d(d?['total']);
          final limit = _d(d?['credit_limit']);
          final overLimit = limit > 0 && total > limit;
          final usage = limit > 0 ? (total / limit).clamp(0.0, 1.0) : 0.0;

          final buckets = <(String, double, int)>[
            (t.bucketCur, _d(d?['cur']), 0),
            (t.bucket1, _d(d?['b1']), 1),
            (t.bucket2, _d(d?['b2']), 2),
            (t.bucket3, _d(d?['b3']), 3),
            (t.bucket4, _d(d?['b4']), 4),
          ];

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              // ── Shop ───────────────────────────────────────────────────
              Row(children: [
                Container(
                  height: 44,
                  width: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.storefront,
                      color: Colors.white, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(shop,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      if (code.isNotEmpty)
                        Text('# $code',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textSecondaryLight)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 20),

              // ── Outstanding ────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: overLimit
                      ? AppColors.danger.withValues(alpha: 0.06)
                      : AppColors.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: overLimit
                        ? AppColors.danger.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.outstanding,
                        style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 4),
                    Text(
                      total <= 0 ? rs(0) : rs(total),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: total <= 0
                            ? Colors.teal
                            : overLimit
                                ? AppColors.danger
                                : AppColors.primary,
                      ),
                    ),
                    if (total <= 0) ...[
                      const SizedBox(height: 4),
                      Text(t.noDues,
                          style: const TextStyle(
                              fontSize: 13,
                              color: Colors.teal,
                              fontWeight: FontWeight.w600)),
                    ],
                    if (limit > 0) ...[
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: usage,
                          minHeight: 7,
                          backgroundColor: Colors.black12,
                          color: overLimit ? AppColors.danger : AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('${t.creditLimit}: ${rs(limit)}',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondaryLight)),
                    ],
                    if (total > 0) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact),
                          icon: Icon(
                              _showAging
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18),
                          label: Text(_showAging ? t.hideAging : t.showAging,
                              style: const TextStyle(fontSize: 13)),
                          onPressed: () =>
                              setState(() => _showAging = !_showAging),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ── Aging (on demand) ──────────────────────────────────────
              if (_showAging && total > 0) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Column(
                    children: [
                      for (final b in buckets)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          child: Row(children: [
                            Container(
                              height: 9,
                              width: 9,
                              decoration: BoxDecoration(
                                color: agingColor(b.$3),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Text(b.$1,
                                    style: const TextStyle(fontSize: 13.5))),
                            Text(rs(b.$2),
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: b.$2 > 0
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: b.$2 > 0
                                        ? agingColor(b.$3)
                                        : AppColors.textSecondaryLight)),
                          ]),
                        ),
                    ],
                  ),
                ),
              ],

              // ── Over-limit warning ─────────────────────────────────────
              if (overLimit) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                    border:
                        Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          color: Colors.amber.shade900, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.overLimitTitle,
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.amber.shade900)),
                            const SizedBox(height: 2),
                            Text(t.overLimitBody,
                                style: const TextStyle(
                                    fontSize: 12.5, height: 1.35)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 26),

              // ── Primary action ─────────────────────────────────────────
              SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_shopping_cart),
                  label: Text(t.placeOrder,
                      style: const TextStyle(
                          fontSize: 16.5, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  // Phase 3. Deliberately inert with an honest message rather
                  // than a dead button that looks broken.
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.orderingSoon)),
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
