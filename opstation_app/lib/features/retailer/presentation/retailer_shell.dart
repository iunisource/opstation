import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/i18n/retailer_i18n.dart';
import '../retailer_auth_controller.dart';
import 'retailer_complaints_screen.dart';
import 'retailer_files_screen.dart';
import 'retailer_home_screen.dart';
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

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(retailerAuthControllerProvider).valueOrNull;
    final unread = ref.watch(retailerUnreadProvider).valueOrNull ?? 0;

    return RetailerLocaleScope(
      child: Builder(builder: (context) {
        final t = T.of(context);
        final titles = [t.home, t.orders, t.complaints, t.files];
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: Text(
              _index == 0 ? (me?.name ?? t.home) : titles[_index],
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
            index: _index,
            children: const [
              RetailerHomeScreen(),
              RetailerOrdersScreen(),
              RetailerComplaintsScreen(),
              RetailerFilesScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
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
            ],
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
