// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/auth_controller.dart';
import '../theme/app_theme.dart';
import '../permissions/access_control.dart';
import '../permissions/permission_registry.dart';
import '../notifications/notifications_menu_tile.dart';
import '../notifications/notification_bell.dart';
import '../notifications/global_job_alert.dart';
import '../notifications/global_transfer_alert.dart';
import '../notifications/user_reminders.dart';
import '../notifications/global_badge_sync.dart';
import '../onboarding/first_login_tour.dart';
import '../station_master/station_master.dart';
import '../../features/support/presentation/request_callback_button.dart';
import '../../features/support/presentation/support_buttons.dart';
import '../../features/billing/presentation/trial_banner.dart';
import 'erp_global_search.dart';

// ─── Providers ────────────────────────────────────────────────────────────────

final orgModulesProvider = FutureProvider<Set<String>>((ref) async {
  // Await full auth resolution so the restored session's JWT is attached before
  // querying; otherwise a cold-start refresh races and returns empty modules,
  // blanking the whole menu.
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return {};
  final client = Supabase.instance.client;
  Future<Set<String>> fetch() async {
    final res = await client
        .from('org_modules')
        .select('module')
        .eq('org_id', user.orgId!)
        .eq('is_enabled', true);
    return {for (final row in res as List) row['module'] as String};
  }
  try {
    var mods = await fetch();
    // Empty = likely the session race (every active org has modules) — retry once.
    if (mods.isEmpty) {
      await Future.delayed(const Duration(milliseconds: 400));
      mods = await fetch();
    }
    return mods;
  } catch (_) {
    return {};
  }
});

// Currently selected branch (global ERP context)
final selectedBranchProvider = StateProvider<Map<String, dynamic>?>((ref) => null);

// Branches available to this user
final userBranchesProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.orgId == null) return [];
  try {
    final client = Supabase.instance.client;
    if (user.role == WebUserRole.erpUser) {
      final res = await client
          .from('erp_user_branches')
          .select('branches(*)')
          .eq('user_id', user.id);
      return (res as List)
          .where((r) => r['branches'] != null)
          .map((r) => Map<String, dynamic>.from(r['branches'] as Map))
          .toList();
    } else {
      final orgId = user.orgId!;
      return List<Map<String, dynamic>>.from(
          await client.from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name'));
    }
  } catch (_) {
    return [];
  }
});

// Count of overdue open CRM follow-ups for the current org (sidebar badge).
final crmOverdueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('customer_activities')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'open')
        .not('due_date', 'is', null)
        .lt('due_date', today);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of pending SUPPLIER items — open/in-progress supplier tasks plus open
// supplier complaints — for the current org. Badges CRM → Suppliers and rolls
// into the CRM nav, mirroring the customer follow-ups badge.
final supplierPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  int n = 0;
  try {
    final t = await client
        .from('customer_activities')
        .select('id')
        .eq('org_id', user.orgId!)
        .not('supplier_id', 'is', null)
        .inFilter('status', ['open', 'in_progress']);
    n += (t as List).length;
  } catch (_) {}
  try {
    final c = await client
        .from('crm_complaints')
        .select('id')
        .eq('org_id', user.orgId!)
        .not('supplier_id', 'is', null)
        .inFilter('status', ['open', 'in_progress']);
    n += (c as List).length;
  } catch (_) {}
  return n;
});

// Whether the customer sales-targets feature is enabled for this org. Gates the
// Intelligence → Performance menu item (and target widgets elsewhere). Mirrors
// the org.customer_targets_enabled flag read by the targets screens.
final customerTargetsEnabledProvider = FutureProvider<bool>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return false;
  final client = Supabase.instance.client;
  try {
    final res = await client
        .from('app_config')
        .select('value')
        .eq('org_id', user.orgId!)
        .eq('key', 'org.customer_targets_enabled')
        .maybeSingle();
    return (res?['value'] as String?) == 'true';
  } catch (_) {
    return false;
  }
});

// Count of assets with maintenance overdue for the current org (nav badge).
final assetsDueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cutoff = DateTime.now().add(const Duration(days: 14));
    final c =
        '${cutoff.year.toString().padLeft(4, '0')}-${cutoff.month.toString().padLeft(2, '0')}-${cutoff.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('assets')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('is_active', true)
        .not('next_maintenance_due', 'is', null)
        .lte('next_maintenance_due', c);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of facility tasks open & overdue for the current org (nav badge).
final facilityDueCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final now = DateTime.now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final res = await client
        .from('facility_tasks')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'open')
        .lt('due_date', today);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of purchase orders awaiting approval for the current org (nav badge).
final poPendingApprovalCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client
        .from('app_config')
        .select('value')
        .eq('org_id', user.orgId!)
        .eq('key', 'org.po_approval_required')
        .maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final res = await client
        .from('purchase_orders')
        .select('id')
        .eq('org_id', user.orgId!)
        .filter('approved_at', 'is', null)
        .filter('voided_at', 'is', null)
        .neq('status', 'received')
        .eq('is_locked', true);
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

/// Invoices awaiting admin review (review_status = 'pending'), gated by the
/// org.doc_review_flow toggle. One provider per invoice type so each menu item
/// gets its own badge; the parent menu sums them. Invalidated by the invoice
/// screens on send/approve/reject.
FutureProvider<int> _reviewPendingProvider(String table, String configKey) => FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', configKey).maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final res = await client.from(table).select('id')
        .eq('org_id', user.orgId!).eq('review_status', 'pending');
    return (res as List).length;
  } catch (_) { return 0; }
});
final piReviewPendingProvider  = _reviewPendingProvider('purchase_invoices', 'org.doc_review_flow_pi');
final priReviewPendingProvider = _reviewPendingProvider('purchase_return_invoices', 'org.doc_review_flow_pri');
final siReviewPendingProvider  = _reviewPendingProvider('sales_invoices', 'org.doc_review_flow_si');

// Count of confirmed GRNs that are RECEIVED but not yet invoiced — i.e. awaiting
// a Purchase Invoice. Drives a pendency badge on Purchase Invoices (and the
// Purchase top-nav) so nobody forgets to invoice a received GRN.
//
// This deliberately mirrors the PI "New" picker query exactly (locked +
// received/partial/saved + branch scope) so the menu badge and the picker modal
// always agree. When a branch is selected we scope to it; with no branch we
// fall back to an org-wide count so the badge still means something.
final grnPendingInvoiceCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final branchId = ref.watch(selectedBranchProvider)?['id'] as String?;
  try {
    var q = Supabase.instance.client
        .from('purchase_grns')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('is_locked', true)
        .inFilter('status', ['received', 'partially_received', 'saved']);
    if (branchId != null) q = q.eq('branch_id', branchId);
    final res = await q;
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// Count of received GRNs still awaiting admin supervision (non-blocking review
// layer), gated by org.grn_supervise_flow. Drives the GRN menu pendency badge.
final grnSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.grn_supervise_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    if (!isAdmin) return 0;
    final res = await client.from('purchase_grns').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null)
        .neq('status', 'draft');
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of newly-created customers still awaiting admin supervision, gated by
// org.customer_supervise_flow. Drives the Customers menu pendency badge.
final customerSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.customer_supervise_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    if (!isAdmin) return 0;
    final res = await client.from('customers').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of newly-created products still awaiting admin supervision, gated by
// org.product_supervise_flow. Drives the Inventory → Products pendency badge.
final productSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.product_supervise_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    if (!isAdmin) return 0;
    final res = await client.from('products').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of Sales Invoices still awaiting admin supervision (non-blocking review
// layer), gated by org.si_supervise_flow. Drives the Sales Invoice menu badge.
final siSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfgRows = await client.from('app_config').select('key,value')
        .eq('org_id', user.orgId!)
        .inFilter('key', ['org.si_supervise_flow', 'org.si_supervisor_users']);
    final cfgM = {for (final r in cfgRows as List) r['key'] as String: (r['value'] as String? ?? '')};
    if (cfgM['org.si_supervise_flow'] != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    final extraIds = (cfgM['org.si_supervisor_users'] ?? '')
        .split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (!isAdmin && !extraIds.contains(user.id)) return 0;
    final res = await client.from('sales_invoices').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null)
        .neq('is_voided', true);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of Delivery Orders still awaiting supervision (non-blocking review
// layer), gated by org.do_supervise_flow. Drives the Delivery Orders menu badge.
final doSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfgRows = await client.from('app_config').select('key,value')
        .eq('org_id', user.orgId!)
        .inFilter('key', ['org.do_supervise_flow', 'org.do_supervisor_users']);
    final cfgM = {for (final r in cfgRows as List) r['key'] as String: (r['value'] as String? ?? '')};
    if (cfgM['org.do_supervise_flow'] != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    final extraIds = (cfgM['org.do_supervisor_users'] ?? '')
        .split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (!isAdmin && !extraIds.contains(user.id)) return 0;
    final res = await client.from('delivery_orders').select('id,is_voided')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null);
    return (res as List).where((r) => r['is_voided'] != true).length;
  } catch (_) { return 0; }
});

// Count of Purchase Invoices still awaiting admin supervision, gated by
// org.pi_supervise_flow. Drives the Purchase Invoices menu badge.
final piSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.pi_supervise_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    if (!isAdmin) return 0;
    final res = await client.from('purchase_invoices').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of Sales Return Invoices still awaiting admin supervision, gated by
// org.sri_supervise_flow. Drives the Sales Return Invoice menu badge.
final sriSupervisePendingProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.sri_supervise_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final isAdmin = user.role == WebUserRole.admin || user.role == WebUserRole.masterAdmin;
    if (!isAdmin) return 0;
    final res = await client.from('sales_return_invoices').select('id')
        .eq('org_id', user.orgId!)
        .filter('supervised_at', 'is', null)
        .neq('is_voided', true);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Count of job cards awaiting acknowledgement (queued & not yet noted) for the
// current org, gated by org.job_ack_flow. Drives the Manufacturing → Job Card
// pendency badge. Invalidated by the Job Card screen on acknowledge + realtime.
final jobAckPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final cfg = await client.from('app_config').select('value')
        .eq('org_id', user.orgId!).eq('key', 'org.job_ack_flow').maybeSingle();
    if ((cfg?['value'] as String?) != 'true') return 0;
    final res = await client.from('job_cards').select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'queued')
        .filter('acknowledged_at', 'is', null);
    return (res as List).length;
  } catch (_) { return 0; }
});

// Accessible branch ids for the current user: erpUsers are limited to their
// assigned branches (erp_user_branches); every other role sees the whole org.
// Returns null to mean "all branches" (no scoping).
final userBranchIdsProvider = FutureProvider<Set<String>?>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return <String>{};
  if (user.role != WebUserRole.erpUser) return null; // all branches
  try {
    final res = await Supabase.instance.client
        .from('erp_user_branches')
        .select('branch_id')
        .eq('user_id', user.id);
    return {for (final r in res as List) r['branch_id'] as String};
  } catch (_) {
    return <String>{};
  }
});

// Count of stock transfers awaiting acceptance (status 'in_transit') that touch
// a branch this user can see — either endpoint on the transfer. Drives the
// Inventory -> Stock Transfers pendency badge.
final transferPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final branchIds = await ref.watch(userBranchIdsProvider.future);
  final client = Supabase.instance.client;
  try {
    final res = await client
        .from('stock_transfers')
        .select('id, from_branch_id, to_branch_id')
        .eq('org_id', user.orgId!)
        .eq('status', 'in_transit');
    if (branchIds == null) return (res as List).length; // sees all
    var n = 0;
    for (final t in res as List) {
      if (branchIds.contains(t['from_branch_id']) ||
          branchIds.contains(t['to_branch_id'])) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
});

// Count of products flagged by the Inventory Integrity check (missing cost,
// stock<>layers, negative or zero-cost layers). Drives the badge on the
// Inventory -> Inventory Integrity menu item so anyone with access can see at a
// glance that there are items to fix, without opening the report.
final inventoryIntegrityCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  try {
    final client = Supabase.instance.client;
    final res = await client
        .rpc('rpc_inventory_integrity', params: {'p_org': user.orgId});
    var rows = List<Map<String, dynamic>>.from(res as List);

    // Match the Integrity screen: a STOCK <> LAYERS gap fully explained by
    // in-transit transfers OR saved-but-not-invoiced purchase returns is a
    // normal timing window, not a real issue, so don't count it in the badge.
    try {
      final expected = <String, double>{};
      // (a) in-transit stock transfers (dispatched, not yet received)
      final trs = await client
          .from('stock_transfers')
          .select('id')
          .eq('org_id', user.orgId!)
          .eq('status', 'in_transit');
      final ids = (trs as List).map((e) => e['id'] as String).toList();
      if (ids.isNotEmpty) {
        final items = await client
            .from('stock_transfer_items')
            .select('product_id, quantity')
            .inFilter('transfer_id', ids);
        for (final r in (items as List)) {
          final pid = r['product_id'] as String?;
          if (pid == null) continue;
          expected[pid] = (expected[pid] ?? 0) + ((r['quantity'] as num?)?.toDouble() ?? 0);
        }
      }
      // (b) purchase returns saved but not yet invoiced (layer consumed at PRI)
      try {
        final pr = await client
            .rpc('rpc_pending_purchase_return_qty', params: {'p_org': user.orgId});
        for (final r in (pr as List)) {
          final pid = r['product_id'] as String?;
          if (pid == null) continue;
          expected[pid] = (expected[pid] ?? 0) + ((r['qty'] as num?)?.toDouble() ?? 0);
        }
      } catch (_) {/* ignore if the helper RPC is unavailable */}

      if (expected.isNotEmpty) {
        rows = rows.where((r) {
          if (r['issue'] != 'STOCK <> LAYERS') return true;
          if (((r['neg_layers'] as num?)?.toInt() ?? 0) != 0) return true;
          final pid = r['product_id'] as String?;
          final it = pid != null ? (expected[pid] ?? 0) : 0;
          if (it == 0) return true;
          final stock = (r['stock_qty'] as num?)?.toDouble() ?? 0;
          final layer = (r['layer_qty'] as num?)?.toDouble() ?? 0;
          return (stock + it - layer).abs() > 0.001;
        }).toList();
      }
    } catch (_) {/* fall back to the raw count */}

    return rows.length;
  } catch (_) {
    return 0;
  }
});

/// Count of field orders awaiting review (status 'submitted') for the org.
/// Drives the live nav badge on the Field Orders menu item. Invalidated by
/// erp_field_orders_screen on approve/reject and realtime arrival.
final fieldOrderPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final res = await client
        .from('field_orders')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'submitted');
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

/// Delivery-Order remark pendency: how many DOs have an unread internal remark
/// written by SOMEONE ELSE. It lights up the Delivery Orders menu + the Sales
/// nav badge so a colleague comes, reads the comment, and clicks "Read" (which
/// marks the DO's remarks read and clears this count). A user's own remark
/// never counts against them.
final doRemarkPendingProvider = FutureProvider<int>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.orgId == null) return 0;
  try {
    final res = await Supabase.instance.client
        .from('voucher_remarks')
        .select('voucher_id, user_id')
        .eq('org_id', user.orgId!)
        .eq('voucher_type', 'DO')
        .eq('is_read', false);
    final dos = <String>{};
    for (final r in res as List) {
      if (r['user_id'] == user.id) continue; // don't nag the author
      final v = r['voucher_id'];
      if (v != null) dos.add(v as String);
    }
    return dos.length;
  } catch (_) {
    return 0;
  }
});

/// Count of retailer orders awaiting review. A retailer order is a REQUEST in
/// its own table — nothing exists in sales_orders until staff approve it, which
/// is what stops a pending request being confirmed by accident from the Sales
/// Orders screen. Invalidated on approve/reject and on realtime arrival.
final retailerOrderPendingCountProvider = FutureProvider<int>((ref) async {
  final user = await ref.watch(authControllerProvider.future);
  if (user == null || user.orgId == null) return 0;
  final client = Supabase.instance.client;
  try {
    final res = await client
        .from('retailer_orders')
        .select('id')
        .eq('org_id', user.orgId!)
        .eq('status', 'submitted');
    return (res as List).length;
  } catch (_) {
    return 0;
  }
});

// ─── MainLayout ───────────────────────────────────────────────────────────────

// ─── Nav layout mode (top bar ↔ sidebar) ───────────────────────

enum NavLayout { top, side }

final navLayoutProvider = StateProvider<NavLayout>((ref) {
  final saved = html.window.localStorage['op_nav_layout'];
  return saved == 'side' ? NavLayout.side : NavLayout.top;
});

void _setNavLayout(WidgetRef ref, NavLayout layout) {
  ref.read(navLayoutProvider.notifier).state = layout;
  html.window.localStorage['op_nav_layout'] = layout == NavLayout.side ? 'side' : 'top';
}

Widget _navLayoutToggle(WidgetRef ref, NavLayout current) {
  final goingSide = current == NavLayout.top;
  return IconButton(
    tooltip: goingSide ? 'Switch to sidebar menu' : 'Switch to top bar menu',
    icon: Icon(goingSide ? Icons.view_sidebar_outlined : Icons.view_day_outlined,
        color: Colors.white70, size: 20),
    onPressed: () => _setNavLayout(ref, goingSide ? NavLayout.side : NavLayout.top),
  );
}

class MainLayout extends ConsumerStatefulWidget {
  final Widget child;
  const MainLayout({super.key, required this.child});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  bool _fullscreen = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _lastLoc;

  static const double kMobileBreakpoint = 768;

  @override
  void initState() {
    super.initState();
    html.document.addEventListener('fullscreenchange', _onFsChange);
  }

  @override
  void dispose() {
    html.document.removeEventListener('fullscreenchange', _onFsChange);
    super.dispose();
  }

  void _onFsChange(html.Event _) {
    final fs = html.document.fullscreenElement != null;
    if (mounted && fs != _fullscreen) setState(() => _fullscreen = fs);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final user = auth.valueOrNull;

    // In browser full-screen, drop the app chrome (top bar / sidebar) entirely
    // so a wall display (e.g. the Attendance Board) shows only its own content.
    if (_fullscreen) {
      return Scaffold(body: widget.child);
    }

    // ── Mobile: hamburger AppBar + slide-in Drawer (nav as inline expanders) ──
    final width = MediaQuery.of(context).size.width;
    if (width < kMobileBreakpoint) {
      // Close the drawer automatically after navigating to a new route.
      final loc = GoRouterState.of(context).matchedLocation;
      if (_lastLoc != null && _lastLoc != loc) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scaffoldKey.currentState?.closeDrawer());
      }
      _lastLoc = loc;
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          backgroundColor: AppTheme.sidebar,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          titleSpacing: 0,
          title: InkWell(
            onTap: () => GoRouter.of(context).go('/dashboard'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 26, height: 26, alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
                child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14))),
              const SizedBox(width: 8),
              const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
            ]),
          ),
          actions: [
            _searchButton(context, user, _showFn(ref, user)),
            const NotificationBell(), _userMenu(ref, user, const Offset(0, 8)),
            const SizedBox(width: 6),
          ],
        ),
        drawer: Drawer(
          backgroundColor: AppTheme.sidebar,
          child: SafeArea(child: _mobileDrawer(user)),
        ),
        body: Stack(children: [Column(children: [const TrialBanner(), Expanded(child: widget.child)]), const GlobalJobAlert(), const GlobalTransferAlert(), const UserRemindersEngine(), const GlobalBadgeSync(), const FirstLoginTour(), const StationMaster(), const SupportButtons()]),
      );
    }

    final layout = ref.watch(navLayoutProvider);
    if (layout == NavLayout.side) {
      return Scaffold(
        body: Stack(children: [
          Row(children: [
            _SideNav(user: user),
            Expanded(child: Column(children: [const TrialBanner(), Expanded(child: widget.child)])),
          ]),
          const GlobalJobAlert(),
          const GlobalTransferAlert(), const UserRemindersEngine(),
          const GlobalBadgeSync(),
          const FirstLoginTour(),
          const StationMaster(),
          const SupportButtons(),
        ]),
      );
    }
    return Scaffold(
      body: Stack(children: [
        Column(children: [
          _TopNav(user: user),
          const TrialBanner(),
          Expanded(child: widget.child),
        ]),
        const GlobalJobAlert(),
        const GlobalTransferAlert(), const UserRemindersEngine(),
        const GlobalBadgeSync(),
        const FirstLoginTour(),
        const StationMaster(),
        const SupportButtons(),
      ]),
    );
  }

  // Drawer body — reuses the shared nav builder, so there is a single source of
  // truth for routes/permissions across top-bar, sidebar and mobile drawer.
  Widget _mobileDrawer(WebUser? user) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if ((user?.orgName ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
          child: Row(children: [
            const Icon(Icons.apartment_rounded, size: 14, color: Colors.white54),
            const SizedBox(width: 6),
            Expanded(child: Text(user?.orgName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13))),
          ]),
        ),
      const Divider(height: 1, color: Colors.white12),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: navItems),
        ),
      ),
      const Divider(height: 1, color: Colors.white12),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Align(alignment: Alignment.centerLeft, child: _branchSelector(ref, modules)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
        child: Row(children: [
          const Spacer(),
          const NotificationBell(), _userMenu(ref, user, const Offset(0, 8)),
        ]),
      ),
    ]);
  }
}

// ─── Shared role-based nav builders (single source for both layouts) ───────

bool Function(String) _showFn(WidgetRef ref, WebUser? user) {
  final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
  final access = ref.watch(accessSyncProvider);
  // Menus follow the ACTIVE branch: only grants valid at the selected branch
  // (or global grants) light up their menu items. Switching branch reshapes
  // the nav immediately.
  final branchId = ref.watch(selectedBranchProvider)?['id'] as String?;
  return (String route) {
    if (route == '/erp/onboarding') return true; // onboarding guide: visible to all
    final mod = kRouteToModule[route];
    if (mod != null && !modules.contains(mod)) return false;
    final r = user?.role;
    final isAdminTier2 = r == WebUserRole.admin ||
        r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
    if (isAdminTier2) return true;
    if (access == null) return false;
    return access.canAccessRouteAt(route, branchId);
  };
}

List<Widget> _buildNavItems(BuildContext context, WidgetRef ref, WebUser? user, String location) {
  final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
  final crmOverdue = ref.watch(crmOverdueCountProvider).valueOrNull ?? 0;
  final supplierPending = ref.watch(supplierPendingCountProvider).valueOrNull ?? 0;
  final assetsDue = ref.watch(assetsDueCountProvider).valueOrNull ?? 0;
  final facilityDue = ref.watch(facilityDueCountProvider).valueOrNull ?? 0;
  final poPending = ref.watch(poPendingApprovalCountProvider).valueOrNull ?? 0;
  final piReviewPending = ref.watch(piReviewPendingProvider).valueOrNull ?? 0;
  final grnPendingInvoice = ref.watch(grnPendingInvoiceCountProvider).valueOrNull ?? 0;
  final priReviewPending = ref.watch(priReviewPendingProvider).valueOrNull ?? 0;
  final siReviewPending = ref.watch(siReviewPendingProvider).valueOrNull ?? 0;
  final fieldOrdersPending = ref.watch(fieldOrderPendingCountProvider).valueOrNull ?? 0;
  final retailerOrdersPending = ref.watch(retailerOrderPendingCountProvider).valueOrNull ?? 0;
  final doRemarkPending = ref.watch(doRemarkPendingProvider).valueOrNull ?? 0;
  final doSupervisePending = ref.watch(doSupervisePendingProvider).valueOrNull ?? 0;
  final grnSupervisePending = ref.watch(grnSupervisePendingProvider).valueOrNull ?? 0;
  final customerSupervisePending = ref.watch(customerSupervisePendingProvider).valueOrNull ?? 0;
  final productSupervisePending = ref.watch(productSupervisePendingProvider).valueOrNull ?? 0;
  final siSupervisePending = ref.watch(siSupervisePendingProvider).valueOrNull ?? 0;
  final sriSupervisePending = ref.watch(sriSupervisePendingProvider).valueOrNull ?? 0;
  final piSupervisePending = ref.watch(piSupervisePendingProvider).valueOrNull ?? 0;
  final jobAckPending = ref.watch(jobAckPendingCountProvider).valueOrNull ?? 0;
  final transferPending = ref.watch(transferPendingCountProvider).valueOrNull ?? 0;
  final integrityCount = ref.watch(inventoryIntegrityCountProvider).valueOrNull ?? 0;
  final targetsOn = ref.watch(customerTargetsEnabledProvider).valueOrNull ?? false;
  final show = _showFn(ref, user);

  final isAdminTier = user?.role == WebUserRole.admin || user?.role == WebUserRole.masterAdmin;
  final isDispatch = user?.role == WebUserRole.dispatchManager;
  final isAccountant = user?.role == WebUserRole.accountant;
  final isErpUser = user?.role == WebUserRole.erpUser;

    // ── ERP Inventory submenu ─────────────────────────────────────────────
    final invManage = <Widget>[
      if (show('/erp/products')) _menuItem(context, 'Products', Icons.inventory_2_outlined, '/erp/products', location, badge: productSupervisePending),
      if (show('/erp/product-classifications')) _menuItem(context, 'Product Classifications', Icons.label_outline, '/erp/product-classifications', location),
      if (show('/erp/stock')) _menuItem(context, 'Stock Levels', Icons.stacked_bar_chart_outlined, '/erp/stock', location),
      if (show('/erp/inventory-ledger')) _menuItem(context, 'Inventory Ledger', Icons.inventory_2_outlined, '/erp/inventory-ledger', location),
    ];
    final invMovements = <Widget>[
      if (show('/erp/opening-stock')) _menuItem(context, 'Opening Stock', Icons.open_in_new_outlined, '/erp/opening-stock', location),
      if (show('/erp/stock-transfers')) _menuItem(context, 'Stock Transfers', Icons.swap_horiz_outlined, '/erp/stock-transfers', location, badge: transferPending),
      if (show('/erp/stock-adjustment')) _menuItem(context, 'Stock Adjustment', Icons.tune_outlined, '/erp/stock-adjustment', location),
    ];
    final invReports = <Widget>[
      if (show('/erp/low-stock-report')) _menuItem(context, 'Low Stock Report', Icons.warning_amber_outlined, '/erp/low-stock-report', location),
      if (show('/erp/stock-value-report')) _menuItem(context, 'Stock Value Report', Icons.payments_outlined, '/erp/stock-value-report', location),
      if (show('/erp/stock-balance-report')) _menuItem(context, 'Stock Balance Report', Icons.inventory_outlined, '/erp/stock-balance-report', location),
      if (show('/erp/stock-aging-report')) _menuItem(context, 'Stock Aging Report', Icons.hourglass_bottom_outlined, '/erp/stock-aging-report', location),
      if (show('/erp/inventory-integrity')) _menuItem(context, 'Inventory Integrity', Icons.rule_outlined, '/erp/inventory-integrity', location, badge: integrityCount),
      if (show('/erp/purchase-variance')) _menuItem(context, 'Purchase Price Variance', Icons.trending_up_outlined, '/erp/purchase-variance', location),
      if (show('/erp/demand-plan')) _menuItem(context, 'Demand Planner', Icons.insights_outlined, '/erp/demand-plan', location),
      if (show('/erp/price-list')) _menuItem(context, 'Price List Generator', Icons.sell_outlined, '/erp/price-list', location),
    ];
    final inventoryItems = <Widget>[
      if (modules.contains('inventory')) ...[
        ...invManage,
        if (invMovements.isNotEmpty) _menuLabel('Movements'),
        ...invMovements,
        if (invReports.isNotEmpty) _menuLabel('Reports'),
        ...invReports,
      ],
    ];

    // ── Per-section item lists ───────────────────────────────────────────
    final purDocs = <Widget>[
      if (show('/erp/suppliers')) _menuItem(context, 'Suppliers',               Icons.people_outline,            '/erp/suppliers',                location),
      if (show('/erp/purchase')) _menuItem(context, 'Purchase Orders',          Icons.shopping_cart_outlined,     '/erp/purchase',                 location, badge: poPending),
      if (show('/erp/grn')) _menuItem(context, 'Goods Receipt Note (GRN)', Icons.move_to_inbox_outlined,     '/erp/grn',                      location, badge: grnSupervisePending),
      if (show('/erp/purchase-invoices')) _menuItem(context, 'Purchase Invoices',        Icons.receipt_outlined,           '/erp/purchase-invoices',        location, badge: piReviewPending + grnPendingInvoice + piSupervisePending),
    ];
    final purReturns = <Widget>[
      if (show('/erp/purchase-returns')) _menuItem(context, 'Purchase Return Notes',    Icons.assignment_return_outlined, '/erp/purchase-returns',         location),
      if (show('/erp/purchase-return-vouchers')) _menuItem(context, 'Purchase Return Invoices', Icons.description_outlined,       '/erp/purchase-return-vouchers', location, badge: priReviewPending),
    ];
    final purLedgersReports = <Widget>[
      if (show('/erp/supplier-ledger')) _menuItem(context, 'Supplier Ledger', Icons.people_outline, '/erp/supplier-ledger', location),
      if (show('/erp/supplier-aging')) _menuItem(context, 'Supplier Aging', Icons.hourglass_bottom_outlined, '/erp/supplier-aging', location),
      if (show('/erp/purchase-report')) _menuItem(context, 'Purchase Report', Icons.summarize_outlined, '/erp/purchase-report', location),
    ];
    final purchaseItems = <Widget>[
      if (modules.contains('purchase')) ...[
        if (show('/erp/purchase-dashboard')) _menuItem(context, 'Purchase Dashboard', Icons.dashboard_outlined, '/erp/purchase-dashboard', location, emphasize: true),
        ...purDocs,
        if (purReturns.isNotEmpty) _menuLabel('Returns'),
        ...purReturns,
        if (purLedgersReports.isNotEmpty) _menuLabel('Ledgers & Reports'),
        ...purLedgersReports,
      ],
    ];

    final salesDocs = <Widget>[
      if (show('/customers')) _menuItem(context, 'Customers',             Icons.store_outlined,             '/customers',                 location, badge: customerSupervisePending),
      if (show('/erp/quotation')) _menuItem(context, 'Quotation',            Icons.request_quote_outlined,     '/erp/quotation',             location),
      if (show('/erp/sales')) _menuItem(context, 'Sales Orders',         Icons.receipt_long_outlined,      '/erp/sales',                 location),
      if (show('/erp/field-orders')) _menuItem(context, 'Field Orders',         Icons.tablet_android_outlined,    '/erp/field-orders',          location, badge: fieldOrdersPending),
      if (show('/erp/retailer-orders')) _menuItem(context, 'Retailer Orders',      Icons.storefront_outlined,        '/erp/retailer-orders',       location, badge: retailerOrdersPending),
      if (show('/erp/delivery-orders')) _menuItem(context, 'Delivery Orders',       Icons.local_shipping_outlined,    '/erp/delivery-orders',       location, badge: doRemarkPending + doSupervisePending),
      if (show('/erp/sales-invoices')) _menuItem(context, 'Sales Invoices',        Icons.receipt_outlined,           '/erp/sales-invoices',        location, badge: siReviewPending + siSupervisePending),
      if (show('/erp/schemes')) _menuItem(context, 'Schemes & Offers',      Icons.local_offer_outlined,       '/erp/schemes',               location),
    ];
    final salesReturns = <Widget>[
      if (show('/erp/sales-returns')) _menuItem(context, 'Sales Return Notes',    Icons.assignment_return_outlined, '/erp/sales-returns',         location),
      if (show('/erp/sales-return-invoices')) _menuItem(context, 'Sales Return Invoices', Icons.receipt_long_outlined,      '/erp/sales-return-invoices', location, badge: sriSupervisePending),
    ];
    final salesLedgersReports = <Widget>[
      if (show('/erp/customer-ledger')) _menuItem(context, 'Customer Ledger', Icons.store_outlined, '/erp/customer-ledger', location),
      if (show('/erp/customer-aging')) _menuItem(context, 'Customer Aging', Icons.hourglass_bottom_outlined, '/erp/customer-aging', location),
      if (show('/erp/sales-report')) _menuItem(context, 'Sales Report',         Icons.assessment_outlined,        '/erp/sales-report',          location),
      if (show('/erp/sales-return-report')) _menuItem(context, 'Sales Return Report',  Icons.summarize_outlined,         '/erp/sales-return-report',    location),
      if (show('/erp/schemes-report')) _menuItem(context, 'Scheme Performance',   Icons.local_offer_outlined,       '/erp/schemes-report',         location),
    ];
    final salesItems = <Widget>[
      if (modules.contains('sales')) ...[
        if (show('/erp/sales-dashboard')) _menuItem(context, 'Sales Dashboard', Icons.dashboard_outlined, '/erp/sales-dashboard', location, emphasize: true),
        ...salesDocs,
        if (salesReturns.isNotEmpty) _menuLabel('Returns'),
        ...salesReturns,
        if (salesLedgersReports.isNotEmpty) _menuLabel('Ledgers & Reports'),
        ...salesLedgersReports,
      ],
    ];

    final posMain = <Widget>[
      if (show('/erp/pos')) _menuItem(context, 'POS',         Icons.storefront_outlined, '/erp/pos',         location),
      if (show('/erp/pos-catalog')) _menuItem(context, 'POS Catalog',    Icons.list_alt_outlined,     '/erp/pos-catalog',           location),
    ];
    final posSetup = <Widget>[
      if (show('/erp/pos-config')) _menuItem(context, 'Configuration', Icons.tune_outlined, '/erp/pos-config', location),
      if (show('/erp/promoters')) _menuItem(context, 'Promoters', Icons.badge_outlined, '/erp/promoters', location),
      if (show('/erp/promoter-ledger')) _menuItem(context, 'Promoter Ledger', Icons.account_balance_wallet_outlined, '/erp/promoter-ledger', location),
      if (show('/erp/pos-expense-management')) _menuItem(context, 'Expense Management',  Icons.receipt_outlined,          '/erp/pos-expense-management',  location),
    ];
    final posReports = <Widget>[
      if (show('/erp/pos-customer-history')) _menuItem(context, 'Customer History', Icons.manage_accounts_outlined, '/erp/pos-customer-history', location),
      if (show('/erp/pos-held-bills')) _menuItem(context, 'Bills on Hold',       Icons.pause_circle_outlined,    '/erp/pos-held-bills',          location),
    ];
    final posItems = <Widget>[
      if (modules.contains('pos')) ...[
        ...posMain,
        if (posSetup.isNotEmpty) _menuLabel('Setup'),
        ...posSetup,
        if (posReports.isNotEmpty) _menuLabel('Reports'),
        ...posReports,
      ],
    ];

    // Reports section items — gated per-user via show() like every other menu.
    final repBalances = <Widget>[
      if (show('/reports/customer-balance')) _menuItem(context, 'Customer Balance Report', Icons.account_balance_wallet_outlined, '/reports/customer-balance', location),
      if (show('/reports/supplier-balance')) _menuItem(context, 'Supplier Balance Report', Icons.account_balance_outlined, '/reports/supplier-balance', location),
    ];
    final repAnalysis = <Widget>[
      if (show('/reports/margin')) _menuItem(context, 'Margin Report', Icons.trending_up, '/reports/margin', location),
      if (show('/reports/skipped-receipts')) _menuItem(context, 'Skipped Receipts Report', Icons.receipt_long_outlined, '/reports/skipped-receipts', location),
    ];
    final reportItems = <Widget>[
      if (show('/reports/center')) _menuItem(context, 'Reports Center', Icons.grid_view_outlined, '/reports/center', location),
      if (repBalances.isNotEmpty) _menuLabel('Balances'),
      ...repBalances,
      if (repAnalysis.isNotEmpty) _menuLabel('Analysis'),
      ...repAnalysis,
    ];

    // Top-level production items (non-voucher)
    final mfgTopItems = <Widget>[
      if (show('/manufacturing/production-floor')) _menuItem(context, 'Production Floor', Icons.dashboard_outlined, '/manufacturing/production-floor', location),
      if (show('/manufacturing/production-plan')) _menuItem(context, 'Production Material Planner', Icons.account_tree_outlined, '/manufacturing/production-plan', location),
      if (show('/manufacturing/job-card')) _menuItem(context, 'Job Card', Icons.assignment_outlined, '/manufacturing/job-card', location, badge: jobAckPending),
      if (show('/manufacturing/qc-checkpoints')) _menuItem(context, 'QC Checkpoints', Icons.fact_check_outlined, '/manufacturing/qc-checkpoints', location),
      if (show('/manufacturing/qc-station')) _menuItem(context, 'QC Station', Icons.checklist_outlined, '/manufacturing/qc-station', location),
      if (show('/manufacturing/job-kiosk')) _menuItem(context, 'Job Kiosk', Icons.qr_code_scanner_outlined, '/manufacturing/job-kiosk', location),
    ];
    final mfgVoucherItems = <Widget>[
      if (show('/manufacturing/product-assembly')) _menuItem(context, 'Product Assembly (BOM)', Icons.account_tree_outlined, '/manufacturing/product-assembly', location),
      if (show('/manufacturing/production-voucher')) _menuItem(context, 'Production Voucher', Icons.precision_manufacturing_outlined, '/manufacturing/production-voucher', location),
      if (show('/manufacturing/damage-stock-voucher')) _menuItem(context, 'Damage Stock Voucher', Icons.report_gmailerrorred_outlined, '/manufacturing/damage-stock-voucher', location),
      if (show('/manufacturing/production-inverse-voucher')) _menuItem(context, 'Production Inverse Voucher', Icons.undo_outlined, '/manufacturing/production-inverse-voucher', location),
      if (show('/manufacturing/claim-processing-voucher')) _menuItem(context, 'Claim Processing Voucher', Icons.assignment_return_outlined, '/manufacturing/claim-processing-voucher', location),
    ];
    final mfgReportItems = <Widget>[
      if (show('/manufacturing/production-waste-report')) _menuItem(context, 'Production Waste Report', Icons.recycling_outlined, '/manufacturing/production-waste-report', location),
      if (show('/manufacturing/overheads-summary')) _menuItem(context, 'Overheads Summary', Icons.summarize_outlined, '/manufacturing/overheads-summary', location),
      if (show('/erp/fg-without-bom')) _menuItem(context, 'Goods without BOM', Icons.account_tree_outlined, '/erp/fg-without-bom', location),
    ];
    final manufacturingItems = <Widget>[
      ...mfgTopItems,
      if (mfgVoucherItems.isNotEmpty) _menuLabel('Voucher'),
      ...mfgVoucherItems,
      if (mfgReportItems.isNotEmpty) _menuLabel('Reports'),
      ...mfgReportItems,
    ];

    final hrDirectory = <Widget>[
      if (show('/hr/employees')) _menuItem(context, 'Employee Directory', Icons.groups_outlined, '/hr/employees', location),
    ];
    final hrAttendance = <Widget>[
      if (show('/hr/attendance')) _menuItem(context, 'Attendance', Icons.fact_check_outlined, '/hr/attendance', location),
      if (show('/hr/attendance-kiosk')) _menuItem(context, 'Attendance Kiosk', Icons.qr_code_scanner_outlined, '/hr/attendance-kiosk', location),
      if (show('/hr/attendance-board')) _menuItem(context, 'Attendance Board', Icons.grid_view_outlined, '/hr/attendance-board', location),
    ];
    final hrLeave = <Widget>[
      if (show('/hr/leave')) _menuItem(context, 'Leave', Icons.beach_access_outlined, '/hr/leave', location),
    ];
    final hrItems = <Widget>[
      ...hrDirectory,
      if (hrAttendance.isNotEmpty) _menuLabel('Attendance'),
      ...hrAttendance,
      if (hrLeave.isNotEmpty) _menuLabel('Leave'),
      ...hrLeave,
    ];

    final finSetup = <Widget>[
      if (show('/erp/chart-of-accounts')) _menuItem(context, 'Chart of Accounts',  Icons.account_tree_outlined,    '/erp/chart-of-accounts',          location),
    ];
    final finVouchers = <Widget>[
      if (show('/financials/journal-vouchers')) _menuItem(context, 'Journal Vouchers',   Icons.edit_note_outlined,          '/financials/journal-vouchers',    location),
      if (show('/financials/opening-journal')) _menuItem(context, 'Opening Journal', Icons.flag_outlined, '/financials/opening-journal', location),
      if (show('/erp/payment-vouchers')) _menuItem(context, 'Payment Vouchers', Icons.receipt_long_outlined, '/erp/payment-vouchers', location),
      if (show('/erp/receipt-vouchers')) _menuItem(context, 'Receipt Vouchers', Icons.payments_outlined,     '/erp/receipt-vouchers',      location),
      if (show('/erp/pdc-voucher')) _menuItem(context, 'PDC Voucher', Icons.account_balance_wallet_outlined, '/erp/pdc-voucher', location),
    ];
    final finReports = <Widget>[
      if (show('/financials/trial-balance')) _menuItem(context, 'Trial Balance',    Icons.account_balance_outlined, '/financials/trial-balance',  location),
      if (show('/financials/account-activity')) _menuItem(context, 'Account Activity', Icons.receipt_long_outlined, '/financials/account-activity', location),
      if (show('/financials/cash-book')) _menuItem(context, 'Cash Book Report', Icons.menu_book_outlined, '/financials/cash-book', location),
      if (show('/financials/profit-loss')) _menuItem(context, 'Profit & Loss',    Icons.trending_up_outlined,     '/financials/profit-loss',    location),
      if (show('/financials/balance-sheet')) _menuItem(context, 'Balance Sheet',    Icons.balance_outlined,         '/financials/balance-sheet',  location),
    ];
    final financialItems = <Widget>[
      ...finSetup,
      if (finVouchers.isNotEmpty) _menuLabel('Vouchers'),
      ...finVouchers,
      if (finReports.isNotEmpty) _menuLabel('Reports'),
      ...finReports,
    ];

    final erpAdminItems = <Widget>[
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'Super Summary', Icons.summarize_outlined, '/erp/super-summary', location),
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'ERP Users', Icons.manage_accounts_outlined, '/erp/users', location),
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'Audit Trail', Icons.history_toggle_off_outlined, '/erp/audit-log', location),
      if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
        _menuItem(context, 'Admin Settings', Icons.admin_panel_settings_outlined, '/erp/admin-settings', location),
    ];

    // Legacy combined list (still used for isNotEmpty guards)
    // Everything an erpUser can possibly see — used to decide whether their nav
    // renders at all. MUST include every section splitErpMenus() can show:
    // reportItems was missing here, so a user whose only grant was a report
    // (e.g. report.skipped_receipts_report.view) got a completely empty menu.
    final erpMenuItems = <Widget>[
      ...inventoryItems, ...purchaseItems, ...salesItems, ...posItems,
      ...reportItems, ...financialItems, ...manufacturingItems, ...hrItems,
      ...erpAdminItems,
    ];

    List<Widget> splitErpMenus() => [
      if (_hasItems(inventoryItems))
        _navMenu(context, 'Inventory', Icons.inventory_2_outlined, location,
          ['/erp/products', '/erp/stock', '/erp/low-stock-report', '/erp/stock-value-report',
           '/erp/stock-balance-report', '/erp/stock-aging-report', '/erp/inventory-integrity', '/erp/purchase-variance',
           '/erp/product-classifications', '/erp/opening-stock', '/erp/stock-transfers', '/erp/stock-adjustment', '/erp/inventory-ledger', '/erp/demand-plan', '/erp/price-list'],
          _trimDividers(inventoryItems), badge: transferPending + integrityCount + productSupervisePending),
      if (_hasItems(purchaseItems))
        _navMenu(context, 'Purchase', Icons.shopping_cart_outlined, location,
          ['/erp/suppliers', '/erp/purchase', '/erp/grn', '/erp/purchase-invoices',
           '/erp/purchase-returns', '/erp/purchase-return-vouchers', '/erp/payment-vouchers', '/erp/purchase-report',
           '/erp/supplier-ledger', '/erp/supplier-aging'],
          _trimDividers(purchaseItems), badge: poPending + piReviewPending + priReviewPending + grnSupervisePending + grnPendingInvoice + piSupervisePending),
      if (_hasItems(salesItems))
        _navMenu(context, 'Sales', Icons.receipt_long_outlined, location,
          ['/customers', '/erp/quotation', '/erp/sales', '/erp/field-orders', '/erp/retailer-orders', '/erp/delivery-orders', '/erp/sales-invoices', '/erp/schemes',
           '/erp/sales-returns', '/erp/sales-return-invoices', '/erp/sales-report', '/erp/sales-return-report', '/erp/schemes-report',
           '/erp/customer-ledger', '/erp/customer-aging'],
          _trimDividers(salesItems), badge: fieldOrdersPending + retailerOrdersPending + siReviewPending + customerSupervisePending + doRemarkPending + doSupervisePending + siSupervisePending + sriSupervisePending),
      if (_hasItems(posItems))
        _navMenu(context, 'POS', Icons.storefront_outlined, location,
          ['/erp/pos', '/erp/pos-catalog', '/erp/pos-config', '/erp/pos-customer-history', '/erp/pos-held-bills', '/erp/pos-expense-management', '/erp/promoters', '/erp/promoter-ledger'], _trimDividers(posItems)),
      if (_hasItems(reportItems))
        _navMenu(context, 'Reports', Icons.summarize_outlined, location,
          ['/reports/margin', '/reports/customer-balance', '/reports/supplier-balance', '/reports/skipped-receipts', '/reports/center'],
          reportItems),
      if (_hasItems(manufacturingItems))
        _navMenu(context, 'Manufacturing', Icons.precision_manufacturing_outlined, location,
          ['/manufacturing/production-floor', '/manufacturing/production-plan', '/manufacturing/product-assembly', '/manufacturing/production-voucher', '/manufacturing/job-card', '/manufacturing/qc-checkpoints', '/manufacturing/qc-station', '/manufacturing/job-kiosk',
           '/manufacturing/production-inverse-voucher', '/manufacturing/damage-stock-voucher',
           '/manufacturing/claim-processing-voucher', '/manufacturing/production-waste-report', '/manufacturing/overheads-summary', '/erp/fg-without-bom'],
          _trimDividers(manufacturingItems), badge: jobAckPending),
      if (_hasItems(financialItems))
        _navMenu(context, 'Financials', Icons.account_balance_outlined, location,
          ['/erp/chart-of-accounts', '/erp/payment-vouchers', '/erp/receipt-vouchers', '/erp/pdc-voucher', '/financials/cash-book'],
          _trimDividers(financialItems)),
      if (_hasItems(hrItems))
        _navMenu(context, 'HR', Icons.badge_outlined, location,
          ['/hr/employees', '/hr/attendance', '/hr/attendance-kiosk', '/hr/attendance-board', '/hr/leave'], _trimDividers(hrItems)),
      // Management (Assets/Facility) — lives here so ERP users see it too, not
      // just admin-tier. Self-gated by the /assets and /facility grants.
      if (show('/assets') || show('/facility'))
        _navMenu(context, 'Management', Icons.domain_outlined, location,
          ['/assets', '/facility'],
          [
            if (show('/assets'))
              _menuItem(context, 'Assets', Icons.chair_outlined, '/assets', location, badge: assetsDue),
            if (show('/facility'))
              _menuItem(context, 'Facility', Icons.cleaning_services_outlined, '/facility', location, badge: facilityDue),
          ],
          badge: assetsDue + facilityDue,
        ),
      _navMenu(context, 'ERP', Icons.manage_accounts_outlined, location,
        ['/erp/onboarding', '/erp/branches', '/erp/files', '/billing', '/erp/super-summary', '/erp/users', '/erp/admin-settings', '/erp/audit-log'],
        [
          _menuItem(context, 'Onboarding Guide', Icons.menu_book_outlined, '/erp/onboarding', location),
          if (show('/erp/branches')) _menuItem(context, 'Branches', Icons.store_outlined, '/erp/branches', location),
          if (show('/erp/files')) _menuItem(context, 'Files', Icons.folder_shared_outlined, '/erp/files', location),
          if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
            _menuItem(context, 'Billing & Subscription', Icons.credit_card_outlined, '/billing', location),
          if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
            _menuAction(context, 'Request a call back', Icons.support_agent, () => showRequestCallbackDialog(context, ref)),
          if (user?.role == WebUserRole.masterAdmin || user?.role == WebUserRole.admin)
            _menuAction(context, 'Get the Android app', Icons.android, () => openAndroidApp(context)),
          if (_hasItems(erpAdminItems)) _menuLabel('Administration'),
          ..._trimDividers(erpAdminItems),
        ]),
    ];

  return <Widget>[
        if (user?.role == WebUserRole.superAdmin) ...[
          _navButton(context, 'Organizations', Icons.business, '/orgs', location),
          _navButton(context, 'Subscriptions', Icons.workspace_premium_outlined, '/subscriptions', location),
        ],

        if (isDispatch) ...[
          _navButton(context, 'Deliveries', Icons.local_shipping_outlined, '/deliveries', location),
          _navButton(context, 'Dispatch Orders', Icons.assignment_outlined, '/dispatch-orders', location),
        ],

        if (isAccountant)
          _navButton(context, 'Orders', Icons.receipt_long, '/orders', location),

        if (isAdminTier) ...[
          _navMenu(context, 'Operations', Icons.local_shipping_outlined, location,
            ['/dashboard', '/team', '/customers', '/routes', '/deliveries', '/live-map', '/reports', '/compliance', '/operations/files', '/operations/notifications', '/operations/retailers', '/settings'],
            [
              _menuItem(context, 'Dashboard', Icons.dashboard_outlined, '/dashboard', location),
              _menuItem(context, 'Team', Icons.people_outline, '/team', location),
              _menuItem(context, 'Customers', Icons.store_outlined, '/customers', location),
              _menuItem(context, 'Routes', Icons.route_outlined, '/routes', location),
              _menuItem(context, 'Deliveries', Icons.local_shipping_outlined, '/deliveries', location),
              _menuItem(context, 'Live Map', Icons.map_outlined, '/live-map', location),
              _menuItem(context, 'Retailers', Icons.storefront_outlined, '/operations/retailers', location),
              _menuLabel('Reports'),
              _menuItem(context, 'Reports', Icons.bar_chart_outlined, '/reports', location),
              _menuItem(context, 'Compliance', Icons.rule, '/compliance', location),
              _menuLabel('Setup'),
              _menuItem(context, 'Files', Icons.folder_shared_outlined, '/operations/files', location),
              _menuItem(context, 'Notifications', Icons.campaign_outlined, '/operations/notifications', location),
              if (user?.role == WebUserRole.masterAdmin)
                _menuItem(context, 'App Settings', Icons.settings_outlined, '/settings', location),
            ],
          ),
          _navMenu(context, 'CRM', Icons.contacts_outlined, location,
            ['/crm/customers', '/crm/follow-ups', '/crm/pipeline', '/crm/supplier-profile'],
            [
              _menuItem(context, 'Customers', Icons.store_outlined, '/crm/customers', location),
              _menuItem(context, 'Pipeline', Icons.view_kanban_outlined, '/crm/pipeline', location),
              _menuItem(context, 'Follow-ups', Icons.task_alt_outlined, '/crm/follow-ups', location, badge: crmOverdue),
              if (show('/crm/supplier-profile')) _menuItem(context, 'Suppliers', Icons.local_shipping_outlined, '/crm/supplier-profile', location, badge: supplierPending),
            ],
            badge: crmOverdue + supplierPending,
          ),
          _navMenu(context, 'Intelligence', Icons.insights_outlined, location,
            ['/intelligence/dashboard', '/products', '/competitor-categories', '/competitor-brand-aliases', '/intelligence/placement', '/intelligence/competitors',
             if (targetsOn) '/intelligence/performance'],
            [
              _menuItem(context, 'Dashboard', Icons.dashboard_outlined, '/intelligence/dashboard', location),
              if (targetsOn)
                _menuItem(context, 'Performance', Icons.leaderboard_outlined, '/intelligence/performance', location),
              _menuLabel('Field Data'),
              _menuItem(context, 'Placement Audit', Icons.checklist_outlined, '/intelligence/placement', location),
              _menuItem(context, 'Competitor Spotting', Icons.flag_outlined, '/intelligence/competitors', location),
              _menuLabel('Setup'),
              _menuItem(context, 'Products', Icons.inventory_2_outlined, '/products', location),
              _menuItem(context, 'Competitor Categories', Icons.category_outlined, '/competitor-categories', location),
              _menuItem(context, 'Competitor Brand Aliases', Icons.spellcheck_outlined, '/competitor-brand-aliases', location),
            ],
          ),
          ...splitErpMenus(),
        ],

        // Assets/Facility grants live outside erpMenuItems (their menu is built
        // inline from show()), so count them in the gate too.
        if (isErpUser &&
            (erpMenuItems.isNotEmpty || show('/assets') || show('/facility')))
          ...splitErpMenus(),
  ];
}

// ─── Shared chrome (logo/search/branch/user reused by both layouts) ───────

Widget _searchButton(BuildContext context, WebUser? user, bool Function(String) show) {
  return         IconButton(
          tooltip: 'Search products, customers, suppliers, vouchers, entries',
          icon: const Icon(Icons.search, color: Colors.white70, size: 20),
          onPressed: () {
            final oid = user?.orgId;
            if (oid != null) showGlobalSearch(context, orgId: oid, can: show);
          },
        );
}

Widget _branchSelector(WidgetRef ref, Set<String> modules) {
  return         Builder(builder: (ctx) {
          final hasErp = modules.any((m) => ['inventory', 'purchase', 'sales', 'pos'].contains(m));
          if (!hasErp) return const SizedBox.shrink();
          final branches = ref.watch(userBranchesProvider).valueOrNull ?? [];
          final selected = ref.watch(selectedBranchProvider);
          if (branches.isEmpty) return const SizedBox.shrink();

          // The selected branch must belong to the CURRENT org. Previously this
          // only restored when nothing was selected, so switching org left the
          // old org's branch sitting in the provider: screens kept reporting
          // "Branch: <other org's branch>", and the dropdown rendered blank
          // because its value was not among the items. Worse, that stale id was
          // being passed into queries. So re-validate on every build.
          final selectedId = selected?['id'] as String?;
          final stillValid = selectedId != null && branches.any((b) => b['id'] == selectedId);
          if (!stillValid) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final cur = ref.read(selectedBranchProvider)?['id'] as String?;
              if (cur != null && branches.any((b) => b['id'] == cur)) return;
              final savedId = html.window.localStorage['op_selected_branch_id'];
              Map<String, dynamic>? restored;
              if (savedId != null) {
                for (final b in branches) {
                  if (b['id'] == savedId) { restored = Map<String, dynamic>.from(b); break; }
                }
              }
              final next = restored ?? Map<String, dynamic>.from(branches.first);
              ref.read(selectedBranchProvider.notifier).state = next;
              html.window.localStorage['op_selected_branch_id'] = next['id'] as String;
            });
          }
          return Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                // Guard: an id not present in items makes the dropdown render
                // empty. During the frame after an org switch, that is exactly
                // what the stale value was.
                value: stillValid ? selectedId : null,
                dropdownColor: AppTheme.sidebarPanel,
                icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 14),
                isDense: true,
                items: branches.map((b) => DropdownMenuItem<String>(
                  value: b['id'] as String,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.store_outlined, color: Colors.white70, size: 13),
                    const SizedBox(width: 6),
                    Text(b['name'] as String, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ]),
                )).toList(),
                onChanged: (id) {
                  if (id == null) return;
                  final branch = branches.firstWhere((b) => b['id'] == id);
                  ref.read(selectedBranchProvider.notifier).state = branch;
                  html.window.localStorage['op_selected_branch_id'] = id;
                  // If the screen we're on isn't granted at the new branch,
                  // bounce to home rather than leaving a forbidden screen up.
                  final access = ref.read(accessSyncProvider);
                  if (access != null && !access.isAdmin) {
                    try {
                      final loc = GoRouterState.of(ctx).uri.path;
                      if (!access.canAccessRouteAt(loc, id)) {
                        GoRouter.of(ctx).go('/erp/home');
                      }
                    } catch (_) {}
                  }
                  ScaffoldMessenger.of(ctx)
                    ..clearSnackBars()
                    ..showSnackBar(SnackBar(
                      content: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check_circle, color: Colors.white, size: 18),
                        const SizedBox(width: 10),
                        Text('Switched to ${branch['name']}'),
                      ]),
                      duration: const Duration(milliseconds: 1500),
                      behavior: SnackBarBehavior.floating,
                      width: 280,
                      backgroundColor: AppTheme.success,
                    ));
                },
              ),
            ),
          );
        });
}

Widget _userMenu(WidgetRef ref, WebUser? user, Offset offset) {
  return         PopupMenuButton<String>(
          offset: offset,
          color: AppTheme.sidebarPanel,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Colors.white12),
          ),
          onSelected: (v) {
            if (v == 'logout') ref.read(authControllerProvider.notifier).signOut();
            if (v == 'tour') ref.read(tourReplayProvider.notifier).state++;
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(user?.name ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                Text(user?.role.name ?? '', style: const TextStyle(color: AppTheme.sidebarText, fontSize: 11)),
              ]),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: const NotificationsMenuTile(),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'tour',
              child: Row(children: [
                Icon(Icons.tour_outlined, size: 15, color: AppTheme.sidebarText),
                SizedBox(width: 8),
                Text('Replay welcome tour', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
            const PopupMenuItem(
              value: 'logout',
              child: Row(children: [
                Icon(Icons.logout, size: 15, color: AppTheme.sidebarText),
                SizedBox(width: 8),
                Text('Sign out', style: TextStyle(color: Colors.white70, fontSize: 13)),
              ]),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: AppTheme.primary,
                child: Text(
                  user?.name.substring(0, 1).toUpperCase() ?? 'U',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                user?.name.split(' ').first ?? '',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 14),
            ]),
          ),
        );
}

// ─── Top Navigation Bar ────────────────────────────────────────

class _TopNav extends ConsumerWidget {
  final WebUser? user;
  const _TopNav({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    final show = _showFn(ref, user);

    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: AppTheme.sidebar,
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(children: [
        // ── Logo ────────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Tooltip(
            message: 'Go to Dashboard',
            child: InkWell(
              onTap: () => GoRouter.of(context).go('/dashboard'),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
                    alignment: Alignment.center,
                    child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                  const SizedBox(width: 8),
                  const Text('Opstation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                ]),
              ),
            ),
          ),
        ),
        if ((user?.orgName ?? '').isNotEmpty) ...[
          Container(width: 1, height: 28, color: Colors.white12),
          const SizedBox(width: 10),
          const Icon(Icons.apartment_rounded, size: 15, color: Colors.white54),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(user?.orgName ?? '',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          const SizedBox(width: 6),
        ],
        Container(width: 1, height: 28, color: Colors.white12),
        const SizedBox(width: 4),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: navItems),
          ),
        ),
        _searchButton(context, user, show),
        _navLayoutToggle(ref, NavLayout.top),
        const SizedBox(width: 4),
        _branchSelector(ref, modules),
        Container(width: 1, height: 28, color: Colors.white12),
        const NotificationBell(), _userMenu(ref, user, const Offset(0, 52)),
      ]),
    );
  }
}

// ─── Side Navigation Bar ──────────────────────────────────────

class _SideNav extends ConsumerWidget {
  final WebUser? user;
  const _SideNav({this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final modules = ref.watch(orgModulesProvider).valueOrNull ?? {};
    final navItems = _buildNavItems(context, ref, user, location);
    final show = _showFn(ref, user);

    return Container(
      width: 232,
      decoration: const BoxDecoration(
        color: AppTheme.sidebar,
        border: Border(right: BorderSide(color: Colors.white12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
          child: Row(children: [
            Expanded(
              child: Tooltip(
                message: 'Go to Dashboard',
                child: InkWell(
                  onTap: () => GoRouter.of(context).go('/dashboard'),
                  borderRadius: BorderRadius.circular(6),
                  child: Row(children: [
                    Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(6)),
                      alignment: Alignment.center,
                      child: const Text('O', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(child: Text('Opstation', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14))),
                  ]),
                ),
              ),
            ),
            _navLayoutToggle(ref, NavLayout.side),
          ]),
        ),
        if ((user?.orgName ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 10),
            child: Row(children: [
              const Icon(Icons.apartment_rounded, size: 14, color: Colors.white54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(user?.orgName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12)),
              ),
            ]),
          ),
        const Divider(height: 1, color: Colors.white12),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: navItems),
          ),
        ),
        const Divider(height: 1, color: Colors.white12),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(children: [
            _searchButton(context, user, show),
            const Spacer(),
            const NotificationBell(), _userMenu(ref, user, const Offset(0, 8)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Align(alignment: Alignment.centerLeft, child: _branchSelector(ref, modules)),
        ),
      ]),
    );
  }
}


// ─── Nav helpers ──────────────────────────────────────────────────────────────

Widget _navButton(BuildContext context, String label, IconData icon, String path, String location, {int badge = 0}) {
  final isActive = location == path || location.startsWith('$path/');
  return InkWell(
    onTap: () => GoRouter.of(context).go(path),
    borderRadius: BorderRadius.circular(6),
    hoverColor: Colors.white10,
    child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: isActive
          ? BoxDecoration(color: AppTheme.primary.withOpacity(0.3), borderRadius: BorderRadius.circular(6))
          : null,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: isActive ? Colors.white : AppTheme.sidebarText),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(
          color: isActive ? Colors.white : AppTheme.sidebarText,
          fontSize: 13,
          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
        )),
        if (badge > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: AppTheme.danger,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(badge > 99 ? '99+' : '$badge',
                style: const TextStyle(
                    color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
          ),
        ],
      ]),
    ),
  );
}

Widget _navMenu(
  BuildContext context,
  String label,
  IconData icon,
  String location,
  List<String> activePaths,
  List<Widget> items, {
  int badge = 0,
}) {
  // On phones the nav lives in a Drawer, where a hover/click popup is poor UX.
  // Render an inline expand/collapse section instead.
  if (MediaQuery.of(context).size.width < _MainLayoutState.kMobileBreakpoint) {
    return _DrawerNavMenu(
      label: label, icon: icon, location: location,
      activePaths: activePaths, items: items, badge: badge,
    );
  }
  return _HoverNavMenu(
    label: label,
    icon: icon,
    location: location,
    activePaths: activePaths,
    items: items,
    badge: badge,
  );
}

/// Inline expand/collapse nav section used inside the mobile Drawer. Expands by
/// default when one of its routes is active.
class _DrawerNavMenu extends StatefulWidget {
  final String label;
  final IconData icon;
  final String location;
  final List<String> activePaths;
  final List<Widget> items;
  final int badge;
  const _DrawerNavMenu({
    required this.label,
    required this.icon,
    required this.location,
    required this.activePaths,
    required this.items,
    this.badge = 0,
  });
  @override
  State<_DrawerNavMenu> createState() => _DrawerNavMenuState();
}

class _DrawerNavMenuState extends State<_DrawerNavMenu> {
  late bool _open;
  @override
  void initState() {
    super.initState();
    _open = widget.activePaths.any((p) => widget.location.startsWith(p));
  }

  @override
  Widget build(BuildContext context) {
    final isActive = widget.activePaths.any((p) => widget.location.startsWith(p));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: isActive
              ? BoxDecoration(color: AppTheme.primary.withOpacity(0.18), borderRadius: BorderRadius.circular(6))
              : null,
          child: Row(children: [
            Icon(widget.icon, size: 16, color: isActive ? Colors.white : AppTheme.sidebarText),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.label, style: TextStyle(
              color: isActive ? Colors.white : AppTheme.sidebarText,
              fontSize: 14, fontWeight: FontWeight.w600))),
            if (widget.badge > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(8)),
                child: Text('${widget.badge}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 6),
            ],
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18, color: AppTheme.sidebarText),
          ]),
        ),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(left: 14, bottom: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.items),
        ),
    ]);
  }
}

/// Top-nav dropdown that opens on hover and closes shortly after the pointer
/// leaves both the trigger and the panel. Click still toggles it.
class _HoverNavMenu extends StatefulWidget {
  final String label;
  final IconData icon;
  final String location;
  final List<String> activePaths;
  final List<Widget> items;
  final int badge;
  const _HoverNavMenu({
    required this.label,
    required this.icon,
    required this.location,
    required this.activePaths,
    required this.items,
    this.badge = 0,
  });
  @override
  State<_HoverNavMenu> createState() => _HoverNavMenuState();
}

class _HoverNavMenuState extends State<_HoverNavMenu> {
  final MenuController _controller = MenuController();
  Timer? _closeTimer;

  void _openNow() {
    _closeTimer?.cancel();
    if (!_controller.isOpen) _controller.open();
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted && _controller.isOpen) _controller.close();
    });
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final isActive = widget.activePaths.any((p) => location.startsWith(p));
    return MenuAnchor(
      controller: _controller,
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(AppTheme.sidebarPanel),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(Colors.black54),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Colors.white12),
        )),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        // Keep the menu open while the pointer is over the panel.
        MouseRegion(
          onEnter: (_) => _closeTimer?.cancel(),
          onExit: (_) => _scheduleClose(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.items,
          ),
        ),
      ],
      builder: (ctx, controller, _) {
        return MouseRegion(
          onEnter: (_) => _openNow(),
          onExit: (_) => _scheduleClose(),
          child: InkWell(
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            borderRadius: BorderRadius.circular(6),
            hoverColor: Colors.white10,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: isActive
                  ? BoxDecoration(color: AppTheme.primary.withOpacity(0.3), borderRadius: BorderRadius.circular(6))
                  : null,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.icon, size: 14, color: isActive ? Colors.white : AppTheme.sidebarText),
                const SizedBox(width: 5),
                Text(widget.label, style: TextStyle(
                  color: isActive ? Colors.white : AppTheme.sidebarText,
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                )),
                if (widget.badge > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppTheme.danger,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(widget.badge > 99 ? '99+' : '${widget.badge}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
                const SizedBox(width: 3),
                Icon(
                  controller.isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 13,
                  color: isActive ? Colors.white70 : AppTheme.sidebarText,
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

void _openInNewTab(BuildContext context, String path, Offset pos) {
  final href = html.window.location.href;
  final hashIdx = href.indexOf('#');
  final origin = hashIdx != -1 ? href.substring(0, hashIdx) : href;
  final url = '${origin}#${path}';
  showMenu(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
    color: Colors.white,
    items: [
      PopupMenuItem(
        onTap: () => html.window.open(url, '_blank'),
        child: Row(children: [
          const Icon(Icons.open_in_new, size: 15, color: Colors.grey),
          const SizedBox(width: 10),
          const Text('Open in new tab', style: TextStyle(fontSize: 13)),
        ]),
      ),
    ],
  );
}

// Menu entry that runs an action (opens a dialog / link) instead of navigating.
Widget _menuAction(BuildContext context, String label, IconData icon, VoidCallback onPressed) {
  return MenuItemButton(
    style: ButtonStyle(
      foregroundColor: const WidgetStatePropertyAll(Colors.white70),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      minimumSize: const WidgetStatePropertyAll(Size(220, 38)),
      backgroundColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.hovered) ? Colors.white.withOpacity(0.08) : Colors.transparent),
    ),
    leadingIcon: Icon(icon, size: 15, color: Colors.white54),
    onPressed: onPressed,
    child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400)),
  );
}

Widget _menuItem(BuildContext context, String label, IconData icon, String path, String location, {int badge = 0, bool emphasize = false}) {
  final isActive = location == path;
  final strong = isActive || emphasize;
  return GestureDetector(
    onSecondaryTapDown: (d) => _openInNewTab(context, path, d.globalPosition),
    child: MenuItemButton(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (isActive) return AppTheme.primary.withOpacity(0.2);
          if (states.contains(WidgetState.hovered)) return Colors.white.withOpacity(0.08);
          if (emphasize) return Colors.white.withOpacity(0.06); // persistent highlight
          return Colors.transparent;
        }),
        foregroundColor: WidgetStatePropertyAll(strong ? Colors.white : Colors.white70),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
        minimumSize: const WidgetStatePropertyAll(Size(220, 38)),
      ),
      leadingIcon: Icon(icon, size: 15, color: strong ? Colors.white : Colors.white54),
      trailingIcon: badge > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.danger,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            )
          : null,
      onPressed: () => GoRouter.of(context).go(path),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: strong ? FontWeight.w700 : FontWeight.w400)),
    ),
  );
}

Widget _subMenu(
  BuildContext context,
  String label,
  IconData icon,
  String location,
  List<Widget> items,
  List<String> paths,
) {
  final isActive = paths.any((p) => location == p);
  return SubmenuButton(
    style: ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (isActive) return AppTheme.primary.withOpacity(0.2);
        if (states.contains(WidgetState.hovered)) return Colors.white.withOpacity(0.08);
        return Colors.transparent;
      }),
      foregroundColor: WidgetStatePropertyAll(isActive ? Colors.white : Colors.white70),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
      minimumSize: const WidgetStatePropertyAll(Size(220, 38)),
    ),
    menuStyle: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(AppTheme.sidebarPanel),
      elevation: const WidgetStatePropertyAll(12),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Colors.white12),
      )),
    ),
    leadingIcon: Icon(icon, size: 15, color: isActive ? Colors.white : Colors.white54),
    menuChildren: items,
    child: Text(label, style: TextStyle(fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
  );
}

bool _hasItems(List<Widget> items) => items.any((w) => w is! Divider);

List<Widget> _trimDividers(List<Widget> items) {
  final out = <Widget>[];
  for (final w in items) {
    if (w is Divider && (out.isEmpty || out.last is Divider)) continue;
    out.add(w);
  }
  while (out.isNotEmpty && out.last is Divider) {
    out.removeLast();
  }
  return out;
}

Widget _menuDivider() => const Divider(height: 1, color: Colors.white12, indent: 12, endIndent: 12);

Widget _menuLabel(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
  child: Text(text.toUpperCase(), style: const TextStyle(
    color: AppTheme.sidebarText,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
  )),
);

