// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../layout/main_layout.dart';
import '../../features/auth/auth_controller.dart';

/// Headless controller mounted once in the shell. It listens to realtime
/// changes on every table that drives an approval / supervision badge and
/// invalidates the matching count providers, so the sidebar counters refresh
/// the instant a voucher lands for approval or is supervised/approved — no page
/// reload needed. Renders nothing (SizedBox.shrink).
///
/// Requires the source tables to be in the `supabase_realtime` publication
/// (see the accompanying SQL migration). A 90s safety poll and resubscribe-on-
/// error keep counters correct even if a realtime event is dropped.
class GlobalBadgeSync extends ConsumerStatefulWidget {
  const GlobalBadgeSync({super.key});

  @override
  ConsumerState<GlobalBadgeSync> createState() => _GlobalBadgeSyncState();
}

class _GlobalBadgeSyncState extends ConsumerState<GlobalBadgeSync> {
  RealtimeChannel? _channel;
  Timer? _debounce;
  Timer? _safety;
  StreamSubscription<html.Event>? _visSub;
  bool _resubscribing = false;
  bool _booted = false;

  // Every table whose rows change an approval / supervision counter.
  static const _tables = <String>[
    'purchase_invoices', // piReviewPendingProvider
    'purchase_return_invoices', // priReviewPendingProvider
    'sales_invoices', // siReviewPendingProvider
    'purchase_grns', // grnPendingInvoiceCountProvider + grnSupervisePendingProvider
    'purchase_orders', // poPendingApprovalCountProvider
    'customers', // customerSupervisePendingProvider
    'suppliers', // supplierPendingCountProvider
    'field_orders', // fieldOrderPendingCountProvider
    'retailer_orders', // retailerOrderPendingCountProvider
    'products', // productSupervisePendingProvider
  ];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
    // Instantly catch up when the tab is un-minimised / refocused.
    _visSub = html.document.onVisibilityChange.listen((_) {
      if (html.document.visibilityState == 'visible') {
        final o = _orgId;
        if (o != null) _subscribe(o);
        _refresh();
      }
    });
  }

  Future<void> _boot() async {
    if (_booted) return;
    final orgId = _orgId;
    if (orgId == null) {
      Future.delayed(const Duration(seconds: 1), _boot);
      return;
    }
    _booted = true;
    _subscribe(orgId);
    // Safety net: re-check every 90s even if a realtime event is missed.
    _safety = Timer.periodic(const Duration(seconds: 90), (_) => _refresh());
  }

  void _subscribe(String orgId) {
    if (_channel != null) return;
    var ch = Supabase.instance.client.channel('global_badge_sync_$orgId');
    for (final t in _tables) {
      ch = ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t,
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq, column: 'org_id', value: orgId),
        callback: (_) => _scheduleRefresh(),
      );
    }
    _channel = ch.subscribe((status, [error]) {
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut ||
          status == RealtimeSubscribeStatus.closed) {
        _scheduleResubscribe();
      }
    });
  }

  void _scheduleResubscribe() {
    if (_resubscribing) return;
    _resubscribing = true;
    Future.delayed(const Duration(seconds: 2), () {
      _resubscribing = false;
      if (!mounted) return;
      final ch = _channel;
      if (ch != null) {
        Supabase.instance.client.removeChannel(ch);
        _channel = null;
      }
      final orgId = _orgId;
      if (orgId != null) {
        _subscribe(orgId);
        _refresh();
      }
    });
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _refresh);
  }

  void _refresh() {
    if (!mounted) return;
    ref.invalidate(piReviewPendingProvider);
    ref.invalidate(priReviewPendingProvider);
    ref.invalidate(siReviewPendingProvider);
    ref.invalidate(grnPendingInvoiceCountProvider);
    ref.invalidate(grnSupervisePendingProvider);
    ref.invalidate(customerSupervisePendingProvider);
    ref.invalidate(poPendingApprovalCountProvider);
    ref.invalidate(supplierPendingCountProvider);
    ref.invalidate(fieldOrderPendingCountProvider);
    ref.invalidate(retailerOrderPendingCountProvider);
    ref.invalidate(productSupervisePendingProvider);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _safety?.cancel();
    _visSub?.cancel();
    final ch = _channel;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
