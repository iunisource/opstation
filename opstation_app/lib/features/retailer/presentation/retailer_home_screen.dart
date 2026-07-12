import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../retailer_auth_controller.dart';

/// Retailer home.
///
/// Phase 2a scaffold: proves the auth path end-to-end (sign in → hydrate →
/// land here → sign out) and shows the shop identity. The balance / aging /
/// credit-limit panel and the Place Order flow are Phase 2b–3; the placeholder
/// below is deliberately explicit rather than a fake empty state, so nobody
/// mistakes "not built yet" for "you have no data".
class RetailerHomeScreen extends ConsumerStatefulWidget {
  const RetailerHomeScreen({super.key});

  @override
  ConsumerState<RetailerHomeScreen> createState() => _RetailerHomeScreenState();
}

class _RetailerHomeScreenState extends ConsumerState<RetailerHomeScreen> {
  Map<String, dynamic>? _customer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// retailer_me() gives us the customer_id but not the shop record — fetch it
  /// so the shopkeeper sees their own shop name, not their login name.
  Future<void> _load() async {
    final me = ref.read(retailerAuthControllerProvider).valueOrNull;
    if (me == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from('customers')
          .select('id, shop_name, code, phone, credit_limit')
          .eq('id', me.customerId)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        _customer = row == null ? null : Map<String, dynamic>.from(row);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(retailerAuthControllerProvider).valueOrNull;
    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        final shop = (_customer?['shop_name'] as String?) ?? me?.name ?? '';
        final code = (_customer?['code'] as String?) ?? '';
        return Scaffold(
          appBar: AppBar(
            title: Text(t.retailer),
            actions: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Center(child: LanguageToggle()),
              ),
              IconButton(
                tooltip: t.logout,
                icon: const Icon(Icons.logout),
                onPressed: () => ref
                    .read(retailerAuthControllerProvider.notifier)
                    .signOut(),
              ),
            ],
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(children: [
                          Container(
                            height: 46,
                            width: 46,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.storefront,
                                color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(shop,
                                    style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                                if (code.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text('# $code',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color:
                                              AppColors.textSecondaryLight)),
                                ],
                              ],
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 28),
                      Center(
                        child: Column(children: [
                          Icon(Icons.construction_outlined,
                              size: 34, color: AppColors.textSecondaryLight),
                          const SizedBox(height: 10),
                          Text(
                            t.isUrdu
                                ? 'آرڈر کی سہولت جلد آ رہی ہے'
                                : 'Ordering is coming next',
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondaryLight),
                          ),
                        ]),
                      ),
                    ],
                  ),
                ),
        );
      }),
    );
  }
}
