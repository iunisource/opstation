import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../../../core/services/notification_service.dart';
import '../../../core/services/tts_service.dart';
import '../retailer_auth_controller.dart';
import 'retailer_complaints_screen.dart';
import 'retailer_files_screen.dart';
import 'retailer_home_screen.dart';
import 'retailer_ledger_screen.dart';
import 'retailer_notifications_sheet.dart';
import 'retailer_orders_screen.dart';

/// Unread notification count. Notifications carry a per-recipient `read_at`
/// (null = unread), so the count is derived rather than stored — no separate
/// counter to drift out of sync with the list itself.
final retailerUnreadProvider = FutureProvider.autoDispose<int>((ref) async {
  try {
    final res = await Supabase.instance.client.rpc('retailer_my_notifications');
    if (res is! List) return 0;
    return res.where((n) => (n as Map)['read_at'] == null).length;
  } catch (_) {
    return 0;
  }
});

/// The retailer app shell.
///
/// Four tabs — Home, Orders, Complaints, Files. Updates are deliberately NOT a
/// tab: nobody opens the app to browse announcements, they open it to order. A
/// bell with an unread badge interrupts when there is something to say, and
/// buys back a nav slot for something people actually navigate to.
class RetailerShell extends ConsumerStatefulWidget {
  const RetailerShell({super.key});

  @override
  ConsumerState<RetailerShell> createState() => _RetailerShellState();
}

class _RetailerShellState extends ConsumerState<RetailerShell> {
  int _index = 0;

  // Whether this retailer may see their account ledger (admin toggle, per
  // customers.retailer_ledger_visible). Loaded once on open; the Ledger tab is
  // shown only when true.
  bool _ledgerEnabled = false;
  bool _fcmRegistered = false;
  bool _realtimeSet = false;
  String? _orgName;
  StreamSubscription<RemoteMessage>? _msgSub;
  RealtimeChannel? _ordersChannel;

  @override
  void initState() {
    super.initState();
    _loadLedgerFlag();
    _loadOrgName();
    // When an order-status push lands while the app is open, refresh the lists
    // so the new status shows without a manual pull-to-refresh.
    _msgSub = FirebaseMessaging.onMessage.listen((m) {
      if (m.data['type'] == 'retailer_order_status') {
        ref.invalidate(retailerOrdersProvider);
        ref.invalidate(retailerAgingProvider);
        if (m.data['status'] == 'approved') _speakApproved();
      }
    });
    // Opened from the notification (app was backgrounded/terminated) — speak the
    // approval now, since TTS can't run while the app is minimized.
    FirebaseMessaging.instance.getInitialMessage().then((m) {
      if (m?.data['type'] == 'retailer_order_status' &&
          m?.data['status'] == 'approved') {
        _speakApproved();
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      if (m.data['type'] == 'retailer_order_status' &&
          m.data['status'] == 'approved') {
        _speakApproved();
      }
    });
  }

  // Locale-aware spoken confirmation. Read outside a build, so it takes the
  // locale from the provider rather than an InheritedWidget.
  void _speakApproved() {
    final urdu =
        ref.read(retailerLocaleProvider).valueOrNull == RetailerLocale.ur;
    ref.read(ttsProvider).speak(
        urdu ? 'آپ کا آرڈر منظور ہو گیا ہے' : 'Your order has been approved',
        lang: urdu ? 'ur-PK' : 'en-US');
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    final ch = _ordersChannel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  // Live updates for this retailer's own orders — approve/reject on the web
  // reflects here immediately, independent of push delivery. Relies on the
  // retailer_orders_self_read RLS policy (SQL 199).
  void _ensureRealtime(String customerId) {
    if (_realtimeSet) return;
    _realtimeSet = true;
    _ordersChannel = Supabase.instance.client
        .channel('retailer_orders_self_$customerId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'retailer_orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'customer_id',
            value: customerId,
          ),
          callback: (payload) {
            ref.invalidate(retailerOrdersProvider);
            ref.invalidate(retailerAgingProvider);
            final newStatus = payload.newRecord['status'];
            final oldStatus = payload.oldRecord['status'];
            if (newStatus == 'approved' && oldStatus != 'approved') {
              _speakApproved();
            }
          },
        )
        .subscribe();
  }

  Future<void> _loadLedgerFlag() async {
    try {
      final res = await Supabase.instance.client.rpc('retailer_ledger_enabled');
      if (mounted) setState(() => _ledgerEnabled = res == true);
    } catch (_) {
      // RPC not deployed / not permitted — keep the tab hidden.
    }
  }

  // Supplier org name for the header (the company the shop buys from), so the
  // top bar isn't just the shop's own name repeated under it.
  Future<void> _loadOrgName() async {
    try {
      final res = await Supabase.instance.client.rpc('retailer_my_org');
      final m = res is Map ? Map<String, dynamic>.from(res) : null;
      final name = (m?['name'] as String?)?.trim();
      if (mounted && name != null && name.isNotEmpty) {
        setState(() => _orgName = name);
      }
    } catch (_) {
      // RPC not deployed yet — fall back to the shop name in the header.
    }
  }

  // Register this retailer's FCM token so order-status pushes (fired by the
  // DB trigger) actually reach the phone. Retailer auth is separate from staff
  // auth, which is where staff/driver tokens get registered — so retailers must
  // register here or the server would have no token to push to.
  void _ensureFcm(String userId) {
    if (_fcmRegistered) return;
    _fcmRegistered = true;
    // Retailer-specific: saves the token via a SECURITY DEFINER RPC because a
    // retailer can't UPDATE the users table directly (RLS). Fire-and-forget.
    ref.read(notificationServiceProvider).registerRetailerToken();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(retailerAuthControllerProvider).valueOrNull;
    final unread = ref.watch(retailerUnreadProvider).valueOrNull ?? 0;
    if (me != null) {
      _ensureFcm(me.userId);
      _ensureRealtime(me.customerId);
    }

    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);

        final pages = <Widget>[
          const RetailerHomeScreen(),
          const RetailerOrdersScreen(),
          const RetailerComplaintsScreen(),
          const RetailerFilesScreen(),
          if (_ledgerEnabled) const RetailerLedgerScreen(),
        ];
        final destinations = <NavigationDestination>[
          NavigationDestination(
              icon: const Icon(Icons.home_outlined),
              selectedIcon: const Icon(Icons.home),
              label: t.home),
          NavigationDestination(
              icon: const Icon(Icons.receipt_long_outlined),
              selectedIcon: const Icon(Icons.receipt_long),
              label: t.orders),
          NavigationDestination(
              icon: const Icon(Icons.report_problem_outlined),
              selectedIcon: const Icon(Icons.report_problem),
              label: t.complaints),
          NavigationDestination(
              icon: const Icon(Icons.folder_shared_outlined),
              selectedIcon: const Icon(Icons.folder_shared),
              label: t.files),
          if (_ledgerEnabled)
            NavigationDestination(
                icon: const Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: const Icon(Icons.account_balance_wallet),
                label: t.ledger),
        ];
        final titles = [t.home, t.orders, t.complaints, t.files, t.ledger];
        final index = _index.clamp(0, pages.length - 1);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: Text(
              index == 0 ? (_orgName ?? me?.name ?? t.home) : titles[index],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                tooltip: t.updates,
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications_none),
                ),
                onPressed: () async {
                  await showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => const RetailerNotificationsSheet(),
                  );
                  ref.invalidate(retailerUnreadProvider);
                },
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.account_circle_outlined),
                onSelected: (v) {
                  if (v == 'logout') {
                    ref.read(retailerAuthControllerProvider.notifier).signOut();
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    enabled: false,
                    child: SizedBox(
                      width: 180,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: LanguageToggle(),
                      ),
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                      value: 'logout',
                      child: Row(children: [
                        const Icon(Icons.logout, size: 18),
                        const SizedBox(width: 10),
                        Text(t.logout),
                      ])),
                ],
              ),
            ],
          ),
          body: IndexedStack(
            index: index,
            children: pages,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) {
              // Re-pull orders whenever the Orders tab is opened, so an
              // approve/reject done elsewhere is reflected without a manual
              // refresh.
              if (i == 1) ref.invalidate(retailerOrdersProvider);
              setState(() => _index = i);
            },
            destinations: destinations,
          ),
        );
      }),
    );
  }
}

/// Shared money formatting so every retailer surface renders amounts the same.
String rs(num v) {
  final s = v.abs().toStringAsFixed(2);
  final parts = s.split('.');
  final whole = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buf.write(',');
    buf.write(whole[i]);
  }
  return '${v < 0 ? '-' : ''}Rs. $buf.${parts[1]}';
}

Color agingColor(int bucket) {
  switch (bucket) {
    case 0:
      return Colors.teal;
    case 1:
      return Colors.amber.shade700;
    case 2:
      return Colors.orange.shade700;
    case 3:
      return Colors.deepOrange;
    default:
      return AppColors.danger;
  }
}
