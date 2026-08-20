import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../../features/auth/auth_controller.dart';

/// First-login guided tour. Mounted once in the shell (like the global
/// alerts). On boot it checks users.tour_seen_at — if NULL, it overlays a
/// step-by-step welcome tour tailored to the user's ROLE, then stamps
/// tour_seen_at so it never shows again (on any device).
class FirstLoginTour extends ConsumerStatefulWidget {
  const FirstLoginTour({super.key});
  @override
  ConsumerState<FirstLoginTour> createState() => _FirstLoginTourState();
}

class _TourStep {
  final IconData icon;
  final String title;
  final String body;
  const _TourStep(this.icon, this.title, this.body);
}

class _FirstLoginTourState extends ConsumerState<FirstLoginTour> {
  bool _visible = false;
  int _index = 0;
  List<_TourStep> _steps = const [];
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (_booted) return;
    final user = ref.read(currentUserProvider);
    if (user == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    if (user.role == WebUserRole.superAdmin) return; // no tour for super admin
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('tour_seen_at')
          .eq('id', user.id)
          .maybeSingle();
      if (row == null) return; // can't verify — don't nag
      if (row['tour_seen_at'] != null) return; // already seen
      final steps = _stepsForRole(user.role, user.name);
      if (steps.isEmpty) return;
      if (mounted) setState(() { _steps = steps; _visible = true; _index = 0; });
    } catch (_) {/* offline or column missing — skip quietly */}
  }

  Future<void> _markSeen() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    try {
      await Supabase.instance.client.from('users')
          .update({'tour_seen_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', user.id);
    } catch (_) {}
  }

  void _close() {
    _markSeen();
    setState(() => _visible = false);
  }

  // ── role decks ─────────────────────────────────────────────────────────────
  List<_TourStep> _stepsForRole(WebUserRole role, String name) {
    final first = name.split(' ').first;
    switch (role) {
      case WebUserRole.masterAdmin:
        return [
          _TourStep(Icons.rocket_launch_outlined, 'Welcome, $first — this is your command center',
              'Everything your business does — inventory, sales, POS, production, money — lives here, live across every branch. This 60-second tour shows you where things are.'),
          const _TourStep(Icons.account_tree_outlined, 'Start with branches & team',
              'Under Management, add your branches and invite your team. Each person gets a role and only sees what their role allows — you stay in control.'),
          const _TourStep(Icons.inventory_2_outlined, 'Load your products',
              'Inventory → Products is your catalogue. Add items one by one or import hundreds from CSV. Group them with Main Group / Group / Sub Group so reports slice cleanly.'),
          const _TourStep(Icons.playlist_add_check_outlined, 'Opening stock & balances',
              'Enter what you physically own today — opening stock and account balances — so day one in Opstation matches reality. The onboarding guide walks this step-by-step.'),
          const _TourStep(Icons.shopping_cart_outlined, 'Purchases: PO → GRN → Invoice',
              'Order with a Purchase Order, receive with a GRN (stock moves in), and the supplier\'s Purchase Invoice prices it. Costing and the ledger update themselves.'),
          const _TourStep(Icons.point_of_sale_outlined, 'Sales & POS',
              'Invoice customers from Sales, or ring up walk-ins on the POS. Every sale posts to stock and the books automatically — profit is always current.'),
          const _TourStep(Icons.precision_manufacturing_outlined, 'Manufacturing',
              'Define recipes (BOMs), run Job Cards on the shop floor, and post production batches — materials out, finished goods in, costs absorbed. All automatic.'),
          const _TourStep(Icons.account_balance_outlined, 'Financials, always reconciled',
              'Vouchers, ledgers, trial balance, P&L, balance sheet — posted in real time from your operations. The Inventory Integrity check guards your stock valuation.'),
          const _TourStep(Icons.notifications_active_outlined, 'Approvals find you',
              'Red badges on the menus count what awaits your approval — POs, invoices, GRNs, new customers — and update live. A ping sounds when a new PO lands.'),
          const _TourStep(Icons.menu_book_outlined, 'You\'re never on your own',
              'The Onboarding Guide (also in your welcome email) explains every module in order. Stuck? Reply to any of our emails and a human answers. Let\'s go build.'),
        ];
      case WebUserRole.admin:
        return [
          _TourStep(Icons.rocket_launch_outlined, 'Welcome, $first',
              'You\'re an admin — you run the day-to-day here. This quick tour shows you the rooms of the house.'),
          const _TourStep(Icons.inventory_2_outlined, 'Inventory',
              'Products, stock levels, transfers and adjustments live under Inventory. The Inventory Ledger shows every movement of any product, with running balances.'),
          const _TourStep(Icons.shopping_cart_outlined, 'Purchases',
              'PO → GRN → Purchase Invoice. Receive goods with a GRN and stock updates instantly; the invoice sets the real cost.'),
          const _TourStep(Icons.point_of_sale_outlined, 'Sales & POS',
              'Quotations, sales invoices, returns, and the POS for walk-in counters. Everything posts to the books by itself.'),
          const _TourStep(Icons.notifications_active_outlined, 'Your approval queue',
              'Red badges count documents waiting on you — they refresh live, and a ping sounds when a new PO arrives. Clear them from each module\'s screen.'),
          const _TourStep(Icons.summarize_outlined, 'Reports',
              'Sales, purchases, stock, aging, margins — under Reports and inside each module. Most print to PDF in one tap.'),
          const _TourStep(Icons.menu_book_outlined, 'Need a map?',
              'The Onboarding Guide covers every screen in plain language. You can finish this tour now — the app is yours.'),
        ];
      case WebUserRole.accountant:
        return [
          _TourStep(Icons.rocket_launch_outlined, 'Welcome, $first',
              'Your workspace is tuned for the books. Here\'s where everything financial lives.'),
          const _TourStep(Icons.receipt_long_outlined, 'Vouchers',
              'Cash receipts (CRV), payments (CPV), bank vouchers, PDCs and journal vouchers — all under Financials, all posting straight to the ledger.'),
          const _TourStep(Icons.account_balance_outlined, 'Ledgers & statements',
              'Customer, supplier and account ledgers with running balances; trial balance, P&L and balance sheet always up to the minute.'),
          const _TourStep(Icons.fact_check_outlined, 'Reconciliation guards',
              'The Inventory Integrity check and GL reconciliation flag anything where the books and stock disagree — worth a glance every week.'),
          const _TourStep(Icons.summarize_outlined, 'Reports & aging',
              'Customer/supplier balances, aging, cash book, and printable statements — everything exports to PDF or Excel.'),
          const _TourStep(Icons.menu_book_outlined, 'That\'s the lay of the land',
              'The Onboarding Guide details every voucher type. Finish the tour and dive in.'),
        ];
      case WebUserRole.dispatchManager:
        return [
          _TourStep(Icons.rocket_launch_outlined, 'Welcome, $first',
              'Your day runs through deliveries and dispatch. Here\'s the short version.'),
          const _TourStep(Icons.local_shipping_outlined, 'Deliveries',
              'See every delivery, assign drivers, and track status from picked to delivered.'),
          const _TourStep(Icons.assignment_outlined, 'Dispatch orders',
              'Bulk-assign orders to teams and routes; each driver sees their own run.'),
          const _TourStep(Icons.map_outlined, 'Live map',
              'Watch the fleet in real time — where everyone is, and what\'s done.'),
          const _TourStep(Icons.menu_book_outlined, 'Ready',
              'That\'s all you need to start. The Onboarding Guide has more if you want it.'),
        ];
      case WebUserRole.erpUser:
        return [
          _TourStep(Icons.rocket_launch_outlined, 'Welcome, $first',
              'Your workspace covers the operational side — a one-minute orientation.'),
          const _TourStep(Icons.inventory_2_outlined, 'Inventory',
              'Products, stock levels and the Inventory Ledger — every movement, always current.'),
          const _TourStep(Icons.shopping_cart_outlined, 'Purchase & Sales flows',
              'POs, GRNs and invoices on the buy side; quotations, invoices and returns on the sell side. Posting is automatic.'),
          const _TourStep(Icons.precision_manufacturing_outlined, 'Production',
              'If your role includes manufacturing: job cards, batches and QC live under Manufacturing.'),
          const _TourStep(Icons.summarize_outlined, 'Reports',
              'Each module has its reports, printable to PDF. Reports Center collects the big ones.'),
          const _TourStep(Icons.menu_book_outlined, 'Off you go',
              'The Onboarding Guide explains every screen. Finish the tour and get to work.'),
        ];
      default:
        return const [];
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_visible || _steps.isEmpty) return const SizedBox.shrink();
    final step = _steps[_index];
    final last = _index == _steps.length - 1;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withOpacity(0.45),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 40, offset: const Offset(0, 12))],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 26, height: 26,
                      decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(7)),
                      alignment: Alignment.center,
                      child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                    ),
                    const SizedBox(width: 10),
                    Text('WELCOME TOUR',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6,
                            color: AppTheme.textSecondary.withOpacity(0.9))),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: AppTheme.textSecondary),
                      onPressed: _close, tooltip: 'Skip tour',
                      visualDensity: VisualDensity.compact,
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                          color: AppTheme.primary.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(step.icon, size: 22, color: AppTheme.primary),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(step.title,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.25, color: Color(0xFF0F172A))),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(step.body,
                      style: const TextStyle(fontSize: 13.5, height: 1.6, color: AppTheme.textSecondary)),
                  const SizedBox(height: 18),
                  // progress dots
                  Row(children: [
                    for (var i = 0; i < _steps.length; i++)
                      Container(
                        width: i == _index ? 18 : 7, height: 7,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                          color: i <= _index ? AppTheme.primary : AppTheme.border,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    if (_index > 0)
                      TextButton(
                        onPressed: () => setState(() => _index--),
                        child: const Text('‹ Back', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                      ),
                    const Spacer(),
                    Text('${_index + 1} / ${_steps.length}',
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    const SizedBox(width: 14),
                    ElevatedButton(
                      onPressed: () {
                        if (last) { _close(); } else { setState(() => _index++); }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary, foregroundColor: Colors.white, elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                      ),
                      child: Text(last ? 'Finish ✓' : 'Next ›',
                          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
