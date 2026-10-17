// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart' show userBranchesProvider, shopNewOrdersCountProvider;
import '../../../core/widgets/product_picker.dart';
import '../../../core/widgets/scan_bar.dart';
import '../../../core/widgets/scan_feedback.dart';
import '../../auth/auth_controller.dart';
import '../../../core/pdf/pdf_output.dart';
import '../services/packing_slip_pdf.dart';
import 'shop_product_matching.dart';
import 'shop_fulfilled_summary.dart';
import 'shop_dispatch.dart';
import '../../../core/layout/collapsible_list_pane.dart';

/// Sales → Fulfillment: orders from connected online stores (Shopify).
/// New → Picking (scan each item) → Packed → Fulfilled (sent back to the
/// store with the courier + tracking number; the store emails the customer).
class ErpFulfillmentScreen extends ConsumerStatefulWidget {
  const ErpFulfillmentScreen({super.key, this.focusId});
  final String? focusId;
  @override
  ConsumerState<ErpFulfillmentScreen> createState() => _ErpFulfillmentScreenState();
}

const _statusLabels = {
  'new': 'New',
  'picking': 'Picking',
  'packed': 'Packed',
  'fulfilled': 'Fulfilled',
  'cancelled': 'Cancelled',
};

class _ErpFulfillmentScreenState extends ConsumerState<ErpFulfillmentScreen> {
  List<Map<String, dynamic>> _stores = [];
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _products = [];
  Map<String, Map<String, dynamic>> _prodById = {};
  String _filter = 'open'; // open | new | picking | packed | fulfilled | cancelled | all
  String _storeFilter = 'all';
  String _search = '';
  String? _selId;
  bool _loading = true;
  bool _busy = false;
  RealtimeChannel? _channel;
  final Set<String> _autoBusy = {}; // orders being auto-fulfilled right now
  final Set<String> _fresh = {};    // arrived while this screen is open ("JUST IN")
  Set<String>? _known;              // order ids seen so far (null until first load)
  final _searchCtrl = TextEditingController();
  String _view = 'queue';           // queue | summary
  bool _fullscreen = false;         // browser full screen (focus mode)
  bool _infoOpen = false;           // customer strip expanded
  final _scanKey = GlobalKey<ScanBarState>();

  /// "Email the customer" in the Fulfil dialog — remembered on this computer.
  bool get _notifyPref {
    try { return html.window.localStorage['ff_notify'] != 'off'; } catch (_) { return true; }
  }
  set _notifyPref(bool v) {
    try { html.window.localStorage['ff_notify'] = v ? 'on' : 'off'; } catch (_) {}
  }
  Timer? _debounce;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin || r == WebUserRole.masterAdmin || r == WebUserRole.superAdmin;
  }

  @override
  void initState() {
    super.initState();
    _selId = widget.focusId;
    ScanFeedback.install();
    html.document.addEventListener('fullscreenchange', _onFsChange);
    _load();
    _subscribe();
    // Back from authorising in Shopify: show what happened.
    final connected = Uri.base.queryParameters['connected'];
    if (connected != null) {
      // Show it once, then drop it from the address so a reload doesn't repeat it.
      try { html.window.history.replaceState(null, '', '/erp/fulfillment'); } catch (_) {}
      WidgetsBinding.instance.addPostFrameCallback((_) => _snack('Store connected. $connected'));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    html.document.removeEventListener('fullscreenchange', _onFsChange);
    final c = _channel;
    if (c != null) Supabase.instance.client.removeChannel(c);
    super.dispose();
  }

  void _subscribe() {
    final org = _orgId;
    if (org == null) return;
    _channel = Supabase.instance.client.channel('shop_orders_$org')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all, schema: 'public', table: 'shop_orders',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'org_id', value: org),
        callback: (_) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 400), () => _load(quiet: true));
        },
      )
      ..subscribe();
  }

  Future<void> _load({bool quiet = false}) async {
    final org = _orgId;
    if (org == null) return;
    if (!quiet) setState(() => _loading = true);
    final client = Supabase.instance.client;
    try {
      final stores = await client.from('shop_stores').select().eq('org_id', org).order('created_at');
      final orders = await client.from('shop_orders').select().eq('org_id', org)
          .order('placed_at', ascending: false).limit(1000);
      if (_products.isEmpty) {
        try {
          _products = List<Map<String, dynamic>>.from(await client.from('products')
              .select('id, name, sku, barcode, base_uom_id, product_main_group, selling_price, image_url').eq('org_id', org).eq('is_active', true).order('name').limit(10000));
          _prodById = {for (final p in _products) p['id'] as String: p};
        } catch (_) {}
      }
      if (!mounted) return;
      final list = List<Map<String, dynamic>>.from(orders);
      final ids = {for (final o in list) o['id'] as String};
      // Announce only orders that land in the work queue — not older orders
      // brought in by a re-check that are already fulfilled / cancelled.
      final arrived = _known == null
          ? <Map<String, dynamic>>[]
          : list.where((o) => !_known!.contains(o['id']) && ['new', 'picking', 'packed'].contains(o['status'])).toList();
      setState(() {
        _stores = List<Map<String, dynamic>>.from(stores);
        _orders = list;
        _loading = false;
        _fresh.addAll(arrived.map((o) => o['id'] as String));
        _known = {...?_known, ...ids};
      });
      if (arrived.length == 1) {
        _snack('New order ${arrived.first['order_no'] ?? ''} from ${arrived.first['customer_name'] ?? 'a customer'}');
      } else if (arrived.length > 1) {
        _snack('${arrived.length} new orders');
      }
      ref.invalidate(shopNewOrdersCountProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      if (!quiet) _snack('Fulfillment isn\'t set up yet — please contact Opstation support.');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Map<String, dynamic>? get _sel {
    for (final o in _orders) {
      if (o['id'] == _selId) return o;
    }
    return null;
  }

  List<Map<String, dynamic>> _lines(Map<String, dynamic> o) =>
      [for (final l in (o['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];

  String _storeName(String? id) =>
      '${_stores.firstWhere((s) => s['id'] == id, orElse: () => const {'name': 'Store'})['name'] ?? 'Store'}';

  List<Map<String, dynamic>> get _visible {
    final q = _search.trim().toLowerCase();
    final list = _orders.where((o) {
      final st = o['status'] as String? ?? 'new';
      final okF = switch (_filter) {
        'open' => st == 'new' || st == 'picking' || st == 'packed',
        'unmatched' => (st == 'new' || st == 'picking' || st == 'packed') && _hasUnmatched(o),
        'today' => _shippedToday(o),
        'all' => true,
        _ => st == _filter,
      };
      if (!okF) return false;
      if (_storeFilter != 'all' && o['store_id'] != _storeFilter) return false;
      if (q.isEmpty) return true;
      return '${o['order_no']} ${o['customer_name']} ${o['phone']} ${o['email']} ${_city(o)}'.toLowerCase().contains(q);
    }).toList();
    // Work queues oldest first (first in, first out); history newest first.
    if (const ['open', 'new', 'picking', 'packed', 'unmatched'].contains(_filter)) {
      list.sort((a, b) => '${a['placed_at'] ?? ''}'.compareTo('${b['placed_at'] ?? ''}'));
    }
    return list;
  }

  int _count(String st) => _orders.where((o) =>
      (_storeFilter == 'all' || o['store_id'] == _storeFilter) &&
      (st == 'open' ? ['new', 'picking', 'packed'].contains(o['status']) : o['status'] == st)).length;

  // ── server actions ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final FunctionResponse r;
    try {
      r = await Supabase.instance.client.functions.invoke('shopify', body: body);
    } on FunctionException catch (e) {
      final d = e.details;
      final msg = d is Map ? d['error'] : null;
      if (e.status == 404) throw 'The store connection service isn\'t set up yet — please contact Opstation support.';
      throw '${msg ?? e.reasonPhrase ?? 'The store did not answer (${e.status}).'}';
    }
    final data = r.data is Map ? Map<String, dynamic>.from(r.data as Map) : <String, dynamic>{};
    if (r.status != 200 || data['error'] != null) {
      throw '${data['error'] ?? 'The store did not answer (${r.status}).'}';
    }
    return data;
  }

  /// Sync: changes since the last sync. [days]: re-check that many days back
  /// (from the ⋮ menu) — catches anything a missed notification left out.
  Future<void> _syncNow({int? days}) async {
    final stores = _stores.where((s) => s['is_active'] == true && (_storeFilter == 'all' || s['id'] == _storeFilter)).toList();
    if (stores.isEmpty) { _snack('No connected store.'); return; }
    setState(() => _busy = true);
    var total = 0;
    final problems = <String>[];
    for (final s in stores) {
      try {
        final r = await _call({'action': 'sync', 'store_id': s['id'], if (days != null) 'days': days});
        total += (r['synced'] as num?)?.toInt() ?? 0;
        if (r['webhook_warning'] != null) problems.add('${s['name']}: live updates not active');
      } catch (e) {
        problems.add('${s['name']}: $e');
      }
    }
    if (mounted) setState(() => _busy = false);
    await _load(quiet: true);
    _snack(problems.isEmpty ? 'Synced — $total order${total == 1 ? '' : 's'} updated' : problems.join('\n'));
  }

  Future<void> _saveLines(Map<String, dynamic> o, List<Map<String, dynamic>> lines, {String? status}) async {
    final upd = <String, dynamic>{'lines': lines, 'updated_at': DateTime.now().toUtc().toIso8601String()};
    if (status != null) upd['status'] = status;
    // Who started picking (printed on the packing slip).
    final picking = lines.any((l) => _num(l['picked']) > 0 || _comps(l).any((c) => _num(c['picked']) > 0));
    if (picking && o['picked_by_name'] == null) {
      upd['picked_by_name'] = ref.read(currentUserProvider)?.name;
      upd['picked_at'] = DateTime.now().toUtc().toIso8601String();
    }
    // Picking lock: this person is on it now (refreshed with every count).
    if (picking) {
      upd['picking_by'] = _meId;
      upd['picking_by_name'] = ref.read(currentUserProvider)?.name;
      upd['picking_at'] = DateTime.now().toUtc().toIso8601String();
    } else {
      upd['picking_by'] = null; upd['picking_by_name'] = null; upd['picking_at'] = null;
    }
    // Counts changed → the box must be checked again.
    if (o['slip_verified_at'] != null && status == 'new') { upd['slip_verified_at'] = null; upd['label_verified_at'] = null; }
    setState(() {
      o['lines'] = lines;
      if (status != null) o['status'] = status;
      if (upd.containsKey('picked_by_name')) { o['picked_by_name'] = upd['picked_by_name']; o['picked_at'] = upd['picked_at']; }
      for (final k in ['picking_by', 'picking_by_name', 'picking_at', 'slip_verified_at', 'label_verified_at']) {
        if (upd.containsKey(k)) o[k] = upd[k];
      }
    });
    await Supabase.instance.client.from('shop_orders').update(upd).eq('id', o['id']);
  }

  // ── checkpoints ───────────────────────────────────────────────────────────
  String? get _meId => ref.read(currentUserProvider)?.id;
  bool _slipRequired(String? storeId) =>
      _stores.any((s) => s['id'] == storeId && s['require_slip_scan'] == true);
  bool _labelRequired(String? storeId) =>
      _stores.any((s) => s['id'] == storeId && s['require_label_scan'] == true);
  /// Every check this store asks for has been done on this box.
  bool _checksDone(Map<String, dynamic> o) =>
      (!_slipRequired(o['store_id'] as String?) || o['slip_verified_at'] != null) &&
      (!_labelRequired(o['store_id'] as String?) || o['label_verified_at'] != null);
  /// What the packer has to scan next (null = nothing).
  String? _nextCheck(Map<String, dynamic> o) {
    if (_slipRequired(o['store_id'] as String?) && o['slip_verified_at'] == null) return 'the packing slip on the box';
    if (_labelRequired(o['store_id'] as String?) && o['label_verified_at'] == null) return 'the courier label on the box';
    return null;
  }
  String _normNo(Object? v) => '${v ?? ''}'.replaceAll('#', '').trim().toLowerCase();

  /// Someone else is picking this order right now (lock lapses after 60 min idle).
  bool _lockedByOther(Map<String, dynamic> o) {
    final by = o['picking_by'] as String?;
    if (by == null || by == _meId) return false;
    if (!['new', 'picking', 'packed'].contains(o['status'])) return false;
    final at = DateTime.tryParse('${o['picking_at'] ?? ''}');
    return at != null && DateTime.now().toUtc().difference(at.toUtc()).inMinutes < 60;
  }

  Future<void> _takeOver(Map<String, dynamic> o) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final me = ref.read(currentUserProvider);
    try {
      await Supabase.instance.client.from('shop_orders').update({
        'picking_by': me?.id, 'picking_by_name': me?.name, 'picking_at': now,
      }).eq('id', o['id']);
      setState(() { o['picking_by'] = me?.id; o['picking_by_name'] = me?.name; o['picking_at'] = now; });
      _snack('You are now picking ${o['order_no'] ?? 'this order'}');
    } catch (e) {
      _snack('Could not take over: $e');
    }
  }

  /// Pack check passed (the right slip scanned on the right box): pack it,
  /// then fulfil straight away if Auto-fulfil is on.
  Future<void> _slipVerified(Map<String, dynamic> o) async {
    final me = ref.read(currentUserProvider);
    final now = DateTime.now().toUtc().toIso8601String();
    await Supabase.instance.client.from('shop_orders').update({
      'status': 'packed', 'packed_at': o['packed_at'] ?? now, 'packed_by_name': o['packed_by_name'] ?? me?.name,
      'slip_verified_at': now, 'slip_verified_by': me?.name, 'updated_at': now,
    }).eq('id', o['id']);
    setState(() {
      o['status'] = 'packed'; o['slip_verified_at'] = now; o['slip_verified_by'] = me?.name;
      o['packed_at'] ??= now; o['packed_by_name'] ??= me?.name;
    });
    if (_autoOn(o['store_id'] as String?) && _checksDone(o)) {
      Future.delayed(const Duration(milliseconds: 250), () => _autoFulfil(o));
    } else {
      Future.delayed(const Duration(milliseconds: 150), ScanFeedback.done);
    }
  }

  /// The courier label on the box matches this order's booking.
  Future<void> _labelVerified(Map<String, dynamic> o) async {
    final me = ref.read(currentUserProvider);
    final now = DateTime.now().toUtc().toIso8601String();
    final upd = <String, dynamic>{'label_verified_at': now, 'updated_at': now};
    // Without the slip check, the label scan is what packs the box.
    if (o['status'] != 'packed') {
      upd['status'] = 'packed';
      upd['packed_at'] = o['packed_at'] ?? now;
      upd['packed_by_name'] = o['packed_by_name'] ?? me?.name;
    }
    await Supabase.instance.client.from('shop_orders').update(upd).eq('id', o['id']);
    setState(() { upd.forEach((k, v) => o[k] = v); });
    if (_autoOn(o['store_id'] as String?) && _checksDone(o)) {
      Future.delayed(const Duration(milliseconds: 250), () => _autoFulfil(o));
    } else {
      Future.delayed(const Duration(milliseconds: 150), ScanFeedback.done);
    }
  }

  /// Open the right scanner for the next check: camera on phones, the scan
  /// box (hardware scanner) on desktop.
  void _startNextScan(bool mobile) {
    final sb = _scanKey.currentState;
    if (sb == null) return;
    if (mobile) {
      sb.openCamera();
    } else {
      sb.focusInput();
      _snack('Ready — scan it now with the scanner (or use the camera icon in the scan box)');
    }
  }

  Widget _nextScanPrompt(Map<String, dynamic> o, bool mobile) {
    final what = _nextCheck(o) ?? '';
    final label = what.contains('label');
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.08), borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.indigo, width: 1.5)),
      child: Row(children: [
        Icon(label ? Icons.local_shipping_outlined : Icons.receipt_long_outlined, color: Colors.indigo),
        const SizedBox(width: 10),
        Expanded(child: Text('Next: scan $what', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.indigo))),
        TextButton.icon(
          icon: Icon(mobile ? Icons.photo_camera_outlined : Icons.qr_code_scanner, size: 18),
          label: Text(mobile ? 'Open camera' : 'Scan'),
          onPressed: () => _startNextScan(mobile),
        ),
      ]),
    );
  }

  /// A scan that is a packing slip (order number) or a courier label
  /// (tracking number) rather than a product. Null = not one of those.
  Future<ScanOutcome?> _checkpointScan(Map<String, dynamic> o, String code, bool allPicked) async {
    final c = _normNo(code);
    if (c.isEmpty) return null;
    final trk = (Map<String, dynamic> x) =>
        '${x['tracking_number'] ?? ((x['ship_info'] as Map?) ?? const {})['number'] ?? ''}'.trim().toLowerCase();
    // Courier label
    Future<ScanOutcome> labelOk() async {
      if (!allPicked) return const ScanOutcome(false, 'Pick every item first, then scan the courier label');
      if (o['slip_verified_at'] == null && _slipRequired(o['store_id'] as String?)) {
        return const ScanOutcome(false, 'Scan the packing slip first, then the courier label');
      }
      try {
        await _labelVerified(o);
      } catch (e) {
        return ScanOutcome(false, 'Could not save: $e');
      }
      return ScanOutcome(true, '✓ Courier label matches this order'
          '${_autoOn(o['store_id'] as String?) && _checksDone(o) ? ' — fulfilling…' : ''}');
    }
    if (labelMatches(code, trk(o))) return labelOk();
    for (final x in _orders) {
      if (x['id'] != o['id'] && labelMatches(code, trk(x))) {
        return ScanOutcome(false, 'WRONG LABEL — this courier label is for ${x['order_no']} (${x['customer_name'] ?? ''})');
      }
    }
    // Packing slip (order number)
    if (_normNo(o['order_no']) == c) {
      if (!allPicked) return const ScanOutcome(false, 'Pick every item first, then scan the packing slip');
      if (o['slip_verified_at'] != null) return const ScanOutcome(true, '✓ Slip already checked for this order');
      try {
        await _slipVerified(o);
      } catch (e) {
        return ScanOutcome(false, 'Could not save: $e');
      }
      final next = _nextCheck(o);
      return ScanOutcome(true, '✓ Slip matches — ${o['order_no']} packed'
          '${next != null ? ' — now scan $next' : _autoOn(o['store_id'] as String?) ? ', fulfilling…' : ''}');
    }
    for (final x in _orders) {
      if (x['id'] != o['id'] && _normNo(x['order_no']) == c) {
        return ScanOutcome(false, 'WRONG SLIP — this slip is for ${x['order_no']} (${x['customer_name'] ?? ''}), not ${o['order_no']}');
      }
    }
    // Label required but this order's booking isn't known here yet (booked a
    // moment ago): fetch it from the store and compare again.
    if (_labelRequired(o['store_id'] as String?) && allPicked && o['label_verified_at'] == null && trk(o).isEmpty) {
      try {
        await _call({'action': 'refresh_order', 'order_id': o['id']});
        final fresh = await Supabase.instance.client.from('shop_orders')
            .select('ship_info, tracking_number').eq('id', o['id']).single();
        o['ship_info'] = fresh['ship_info'];
        o['tracking_number'] ??= fresh['tracking_number'];
      } catch (_) {}
      if (trk(o).isEmpty) {
        return const ScanOutcome(false, 'No courier booking found for this order yet — book it, then scan the label');
      }
      if (labelMatches(code, trk(o))) return labelOk();
      return ScanOutcome(false, 'WRONG LABEL — this is not the courier label for ${o['order_no']}');
    }
    return null;
  }

  bool _prodMatches(String? pid, String c) {
    final p = _prodById[pid];
    if (p == null || c.isEmpty) return false;
    for (final v in [p['barcode'], p['sku']]) {
      if ('${v ?? ''}'.trim().toLowerCase() == c) return true;
    }
    return false;
  }

  /// Strict scanning (store setting): only the Opstation barcode / SKU code
  /// counts — a code typed on the Shopify product is not trusted.
  bool _strictScan(String? storeId) =>
      _stores.any((s) => s['id'] == storeId && s['scan_codes'] == 'system');

  bool _lineMatches(Map<String, dynamic> l, String code, {bool strict = false}) {
    final c = code.trim().toLowerCase();
    if (c.isEmpty) return false;
    if (_prodMatches(l['product_id'] as String?, c)) return true;
    if (strict) return false;
    return [l['barcode'], l['sku']].any((v) => '${v ?? ''}'.trim().toLowerCase() == c);
  }

  /// ⋮ → Scan settings (admins): per store, which codes count as a right scan.
  Future<void> _scanSettings() async {
    final active = _stores.where((s) => s['is_active'] == true).toList();
    if (active.isEmpty) return;
    final choice = {for (final s in active) s['id'] as String: (s['scan_codes'] as String?) == 'system' ? 'system' : 'any'};
    final slip = {for (final s in active) s['id'] as String: s['require_slip_scan'] == true};
    final label = {for (final s in active) s['id'] as String: s['require_label_scan'] == true};
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: const Text('Scan settings'),
      content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Which barcodes count as a right scan when picking. Products inside bundles always use the Opstation codes.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        for (final s in active) ...[
          const SizedBox(height: 12),
          if (active.length > 1) Text('${s['name'] ?? s['shop_domain']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          RadioListTile<String>(
            dense: true, contentPadding: EdgeInsets.zero,
            value: 'system', groupValue: choice[s['id']],
            onChanged: (v) => setD(() => choice[s['id'] as String] = v ?? 'system'),
            title: const Text('Opstation codes only (strict)'),
            subtitle: const Text('Only the product barcode / SKU code from Opstation — the labels you print. Safest.'),
          ),
          RadioListTile<String>(
            dense: true, contentPadding: EdgeInsets.zero,
            value: 'any', groupValue: choice[s['id']],
            onChanged: (v) => setD(() => choice[s['id'] as String] = v ?? 'any'),
            title: const Text('Opstation + Shopify codes'),
            subtitle: const Text('Also accepts the barcode / SKU typed on the Shopify product.'),
          ),
          SwitchListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            value: slip[s['id']] ?? false,
            onChanged: (v) => setD(() => slip[s['id'] as String] = v),
            title: const Text('Pack check: scan the packing slip before packing'),
            subtitle: const Text('After the last item, the slip going on the box must be scanned — a wrong slip is stopped. '
                'Auto-fulfil waits for it too.'),
          ),
          SwitchListTile(
            dense: true, contentPadding: EdgeInsets.zero,
            value: label[s['id']] ?? false,
            onChanged: (v) => setD(() => label[s['id'] as String] = v),
            title: const Text('Also scan the courier label before fulfilling'),
            subtitle: const Text('The label on the box must match the order\'s courier booking. Without a booking yet, '
                'the box waits in Ready to ship until it is booked and its label scanned.'),
          ),
        ],
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), child: const Text('Save')),
      ],
    )));
    if (ok != true) return;
    try {
      for (final s in active) {
        final v = choice[s['id']] == 'system' ? 'system' : 'any';
        final sl = slip[s['id']] ?? false;
        final lb = label[s['id']] ?? false;
        if ((s['scan_codes'] ?? 'any') == v && (s['require_slip_scan'] == true) == sl
            && (s['require_label_scan'] == true) == lb) { continue; }
        await Supabase.instance.client.from('shop_stores')
            .update({'scan_codes': v, 'require_slip_scan': sl, 'require_label_scan': lb}).eq('id', s['id']);
        s['scan_codes'] = v;
        s['require_slip_scan'] = sl;
        s['require_label_scan'] = lb;
      }
      if (mounted) setState(() {});
      _snack('Scan settings saved');
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  /// Bundle lines: one store item made of several products, each picked on its own.
  List<Map<String, dynamic>> _comps(Map<String, dynamic> l) =>
      [for (final c in (l['components'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
  bool _isBundle(Map<String, dynamic> l) => (l['components'] as List?)?.isNotEmpty == true;
  bool _lineDone(Map<String, dynamic> l) => _isBundle(l)
      ? _comps(l).every((c) => _num(c['picked']) >= _num(c['qty']))
      : _num(l['picked']) >= _num(l['qty']);
  bool _lineMapped(Map<String, dynamic> l) => l['product_id'] != null || _isBundle(l);

  Future<ScanOutcome> _onScan(String code, double qty) async {
    final o = _sel;
    if (o == null) return const ScanOutcome(false, 'Open an order first');
    final st = o['status'] as String? ?? 'new';
    if (st == 'fulfilled' || st == 'cancelled') return ScanOutcome(false, 'This order is ${_statusLabels[st]?.toLowerCase()}');
    if (_lockedByOther(o)) {
      return ScanOutcome(false, 'Being picked by ${o['picking_by_name'] ?? 'someone else'} — ask them, or take it over');
    }
    final c = code.trim().toLowerCase();
    final lines = _lines(o);
    // Every pickable thing: plain lines and the parts of bundle lines.
    final targets = <(int, int?)>[];
    for (var i = 0; i < lines.length; i++) {
      if (_isBundle(lines[i])) {
        final cs = _comps(lines[i]);
        for (var j = 0; j < cs.length; j++) {
          if (_prodMatches(cs[j]['product_id'] as String?, c)) targets.add((i, j));
        }
      } else if (_lineMatches(lines[i], code, strict: _strictScan(o['store_id'] as String?))) {
        targets.add((i, null));
      }
    }
    if (targets.isEmpty) {
      // Not a product here: maybe the packing slip / courier label (pack check).
      final cp = await _checkpointScan(o, code, lines.isNotEmpty && lines.every(_lineDone));
      return cp ?? ScanOutcome(false, 'Not on this order: $code');
    }
    // Prefer one that still needs items.
    (int, int?) t = targets.first;
    for (final x in targets) {
      final l = lines[x.$1];
      final rec = x.$2 == null ? l : _comps(l)[x.$2!];
      if (_num(rec['picked']) < _num(rec['qty'])) { t = x; break; }
    }
    final l = lines[t.$1];
    final cs = t.$2 == null ? null : _comps(l);
    final rec = cs == null ? l : cs[t.$2!];
    final name = cs == null ? _lineName(l) : '${_prodById[rec['product_id']]?['name'] ?? 'Item'} (in ${l['title']})';
    final need = _num(rec['qty']);
    final now = _num(rec['picked']) + qty;
    if (now > need) return ScanOutcome(false, '$name: only ${_q(need)} needed (already ${_q(_num(rec['picked']))})');
    rec['picked'] = now;
    if (cs != null) l['components'] = cs;
    final allDone = lines.every(_lineDone);
    try {
      await _saveLines(o, lines, status: st == 'new' ? 'picking' : null);
    } catch (e) {
      return ScanOutcome(false, 'Could not save: $e');
    }
    if (allDone && _nextCheck(o) != null) {
      Future.delayed(const Duration(milliseconds: 150), ScanFeedback.done);
      return ScanOutcome(true, '$name  ${_q(now)} / ${_q(need)}   ✓ all items picked — now scan ${_nextCheck(o)}');
    }
    if (allDone) {
      final auto = _autoOn(o['store_id'] as String?);
      if (auto) {
        // Let the beep play, then fulfil without anyone touching the screen.
        Future.delayed(const Duration(milliseconds: 250), () => _autoFulfil(o));
      } else {
        Future.delayed(const Duration(milliseconds: 150), ScanFeedback.done);
      }
      return ScanOutcome(true, '$name  ${_q(now)} / ${_q(need)}   ✓ all items picked'
          '${auto ? ' — fulfilling automatically…' : ' — press Packed / Fulfil'}');
    }
    return ScanOutcome(true, '$name  ${_q(now)} / ${_q(need)}');
  }

  Future<void> _setPicked(Map<String, dynamic> o, int i, double v, {int? comp}) async {
    if (_lockedByOther(o)) {
      _snack('Being picked by ${o['picking_by_name'] ?? 'someone else'} — ask them, or an admin can take it over.');
      return;
    }
    final lines = _lines(o);
    if (comp != null) {
      final cs = _comps(lines[i]);
      cs[comp]['picked'] = v.clamp(0, _num(cs[comp]['qty']));
      lines[i]['components'] = cs;
    } else {
      lines[i]['picked'] = v.clamp(0, _num(lines[i]['qty']));
    }
    final wasDone = _lines(o).every(_lineDone);
    await _saveLines(o, lines, status: (o['status'] == 'new' && v > 0) ? 'picking' : null);
    // Counted the last ones by hand → same as finishing by scan.
    if (!wasDone && lines.isNotEmpty && lines.every(_lineDone)) {
      if (_nextCheck(o) != null) {
        ScanFeedback.done();
        _snack('All items picked — now scan ${_nextCheck(o)}');
        // Open the scanner straight away for the box check.
        if (mounted) _startNextScan(MediaQuery.of(context).size.width < 700);
      } else if (_autoOn(o['store_id'] as String?)) {
        _autoFulfil(o);
      } else {
        ScanFeedback.done();
      }
    }
  }

  bool _autoOn(String? storeId) =>
      _stores.any((s) => s['id'] == storeId && s['auto_fulfil'] == true);

  /// Stores the header switch applies to (the store filter, or all connected).
  List<Map<String, dynamic>> get _scopeStores => _stores
      .where((s) => s['is_active'] == true && (_storeFilter == 'all' || s['id'] == _storeFilter))
      .toList();

  Future<void> _setAuto(bool on) async {
    final scope = _scopeStores;
    if (scope.isEmpty) return;
    setState(() { for (final s in scope) { s['auto_fulfil'] = on; } });
    try {
      await Supabase.instance.client.from('shop_stores').update({'auto_fulfil': on})
          .inFilter('id', [for (final s in scope) s['id']]);
      _snack(on
          ? 'Auto-fulfil ON — when the last item is scanned the order is fulfilled with its courier booking; '
            'without a booking yet it is packed and waits in Ready to ship'
          : 'Auto-fulfil OFF — press Packed / Fulfil yourself');
    } catch (e) {
      setState(() { for (final s in scope) { s['auto_fulfil'] = !on; } });
      _snack('Could not change it: $e');
    }
  }

  /// After an order is done, open the next one in the queue (oldest first):
  /// orders still to pick first, then packed ones waiting to ship.
  void _openNext(String doneId) {
    if (!mounted || _selId != doneId) return; // the user already moved on
    final queue = _orders.where((o) =>
        o['id'] != doneId && (_storeFilter == 'all' || o['store_id'] == _storeFilter) &&
        ['new', 'picking', 'packed'].contains(o['status'])).toList()
      ..sort((a, b) {
        int rank(Map<String, dynamic> o) => o['status'] == 'packed' ? 1 : 0;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : '${a['placed_at'] ?? ''}'.compareTo('${b['placed_at'] ?? ''}');
      });
    setState(() {
      if (queue.isEmpty) {
        _selId = null;
      } else {
        _selId = queue.first['id'] as String;
        _fresh.remove(_selId);
      }
    });
    if (queue.isNotEmpty) _snack('Next: ${queue.first['order_no'] ?? ''} · ${queue.first['customer_name'] ?? ''}');
  }

  /// Every item scanned right + auto-fulfil on → pack and fulfil in the store.
  Future<void> _autoFulfil(Map<String, dynamic> o) async {
    final id = o['id'] as String;
    if (_autoBusy.contains(id) || !mounted) return;
    if (!_checksDone(o)) return; // waits for the slip / label scan
    var done = false;
    setState(() => _autoBusy.add(id));
    final me = ref.read(currentUserProvider);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await Supabase.instance.client.from('shop_orders').update({
        'status': 'packed', 'packed_at': now, 'packed_by_name': me?.name, 'updated_at': now,
      }).eq('id', id);
      // Look for the courier booking now (it may have been made after the
      // order arrived). No booking yet → leave it packed in "Ready to ship",
      // so a label problem never sends the order out without tracking.
      var si = Map<String, dynamic>.from((o['ship_info'] as Map?) ?? const {});
      if ('${o['tracking_number'] ?? si['number'] ?? ''}'.isEmpty) {
        try {
          await _call({'action': 'refresh_order', 'order_id': id});
          final fresh = await Supabase.instance.client.from('shop_orders').select('ship_info').eq('id', id).single();
          si = Map<String, dynamic>.from((fresh['ship_info'] as Map?) ?? const {});
        } catch (_) {}
      }
      if ('${o['tracking_number'] ?? si['number'] ?? ''}'.isEmpty) {
        ScanFeedback.done();
        _snack('✓ ${o['order_no'] ?? 'Order'} packed — no courier booking yet, so it waits in "Ready to ship". '
            'Book it, then press Fulfil.');
        done = true; // picked and packed — move on to the next order
        return;
      }
      final r = await _call({
        'action': 'fulfill', 'order_id': id, 'notify': _notifyPref,
        'company': o['tracking_company'] ?? si['company'],
        'number': o['tracking_number'] ?? si['number'],
        'url': o['tracking_url'] ?? si['url'],
      });
      ScanFeedback.done();
      _snack('✓ ${o['order_no'] ?? 'Order'} fulfilled automatically${r['already'] == true ? ' (it was already fulfilled in the store)' : ''}');
      done = true;
    } catch (e) {
      if (mounted) ScanFeedback.wrong(context);
      _snack('${o['order_no'] ?? 'Order'} was NOT fulfilled: $e');
    } finally {
      if (mounted) setState(() => _autoBusy.remove(id));
      await _load(quiet: true);
      if (done) _openNext(id);
    }
  }

  Future<void> _mapProduct(Map<String, dynamic> o, int i) async {
    // Only the store's finished products (same groups as Match products).
    final store = _stores.firstWhere((x) => x['id'] == o['store_id'], orElse: () => const {});
    final chosen = [for (final g in (store['match_groups'] as List? ?? const [])) '$g'];
    bool inGroup(Map<String, dynamic> p) {
      final g = '${p['product_main_group'] ?? ''}'.trim();
      return chosen.isNotEmpty ? chosen.contains(g.isEmpty ? '(none)' : g) : g.toLowerCase().contains('finish');
    }
    final fin = _products.where(inGroup).toList();
    final p = await pickProduct(context, fin.isEmpty ? _products : fin, title: 'Which product is this?');
    if (p == null || p.isEmpty) return;
    final lines = _lines(o);
    final l = lines[i];
    l['product_id'] = p['id'];
    final key = (l['variant_id'] as String?)?.isNotEmpty == true ? l['variant_id'] as String : 'sku:${'${l['sku'] ?? ''}'.toLowerCase()}';
    try {
      await Supabase.instance.client.from('shop_product_map').upsert({
        'org_id': o['org_id'], 'store_id': o['store_id'], 'ext_key': key, 'product_id': p['id'],
      }, onConflict: 'store_id,ext_key');
      await _saveLines(o, lines);
      _snack('Matched to ${p['name']} — remembered for future orders');
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  Future<void> _markPacked(Map<String, dynamic> o) async {
    final lines = _lines(o);
    final short = lines.where((l) => !_lineDone(l)).toList();
    if (short.isNotEmpty) {
      // Only what was actually scanned can be packed and shipped.
      _snack('Scan every item first — ${short.length} item${short.length == 1 ? '' : 's'} still to pick: '
          '${short.take(3).map((l) => _isBundle(l) ? '${_lineName(l)} (bundle)' : '${_lineName(l)} (${_q(_num(l['picked']))}/${_q(_num(l['qty']))})').join(', ')}');
      return;
    }
    if (_slipRequired(o['store_id'] as String?) && o['slip_verified_at'] == null) {
      _snack('Scan the packing slip on the box to pack it (pack check is on for this store).');
      return;
    }
    final me = ref.read(currentUserProvider);
    try {
      await Supabase.instance.client.from('shop_orders').update({
        'status': 'packed', 'packed_at': DateTime.now().toUtc().toIso8601String(), 'packed_by_name': me?.name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', o['id']);
      await _load(quiet: true);
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  static const _couriers = ['DEX Logistics', 'PostEx', 'Leopards', 'TCS', 'M&P', 'Trax', 'BlueEx', 'Call Courier', 'Rider', 'Swyft', 'DHL', 'Pakistan Post'];

  /// The order in the Shopify admin (where the store's courier app books it).
  void _openInShopify(Map<String, dynamic> o) {
    final store = _stores.firstWhere((s) => s['id'] == o['store_id'], orElse: () => const {});
    final domain = '${store['shop_domain'] ?? ''}';
    final id = '${o['external_id'] ?? ''}'.split('/').last;
    if (domain.isEmpty || id.isEmpty) return;
    html.window.open('https://$domain/admin/orders/$id', '_blank');
  }

  Future<void> _fulfil(Map<String, dynamic> o) async {
    // Prefill: what was typed before, else a booking found on the store order.
    Map<String, dynamic> si() => Map<String, dynamic>.from((o['ship_info'] as Map?) ?? const {});
    final company = TextEditingController(text: '${o['tracking_company'] ?? si()['company'] ?? ''}');
    final number = TextEditingController(text: '${o['tracking_number'] ?? si()['number'] ?? ''}');
    final url = TextEditingController(text: '${o['tracking_url'] ?? si()['url'] ?? ''}');
    var notify = _notifyPref;
    var checking = false;
    String? checkMsg;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) {
      final found = si();
      final hasBooking = '${found['number'] ?? ''}'.isNotEmpty;
      return AlertDialog(
        title: Text('Fulfil ${o['order_no'] ?? ''}'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hasBooking)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.green.withOpacity(0.07), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withOpacity(0.4))),
              child: Row(children: [
                const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Booking found in the store (${found['source'] ?? 'courier app'}): '
                    '${found['company'] ?? 'courier'} ${found['number']}. Filled in below.',
                    style: const TextStyle(fontSize: 12.5))),
              ]),
            )
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.07), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.4))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('No courier booking found on this order yet.', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                const Text('Book it with your courier app in Shopify (or the courier portal), then press "Check again" — '
                    'the tracking number is picked up and filled in.', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Book in Shopify'),
                    onPressed: () => _openInShopify(o),
                  ),
                  OutlinedButton.icon(
                    icon: checking
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 16),
                    label: const Text('Check again'),
                    onPressed: checking ? null : () async {
                      setD(() { checking = true; checkMsg = null; });
                      try {
                        await _call({'action': 'refresh_order', 'order_id': o['id']});
                        final fresh = await Supabase.instance.client.from('shop_orders')
                            .select('ship_info, tracking_company, tracking_number, tracking_url').eq('id', o['id']).single();
                        o['ship_info'] = fresh['ship_info'];
                        final f = si();
                        if ('${f['number'] ?? ''}'.isNotEmpty) {
                          if (company.text.trim().isEmpty) company.text = '${f['company'] ?? ''}';
                          if (number.text.trim().isEmpty) number.text = '${f['number']}';
                          if (url.text.trim().isEmpty) url.text = '${f['url'] ?? ''}';
                        } else {
                          checkMsg = 'Still no booking on the store order. If your courier app keeps it only in its own '
                              'screen, type the tracking number below.';
                        }
                      } catch (e) {
                        checkMsg = '$e';
                      }
                      setD(() => checking = false);
                    },
                  ),
                ]),
                if (checkMsg != null) Padding(padding: const EdgeInsets.only(top: 6),
                    child: Text(checkMsg!, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
              ]),
            ),
          const SizedBox(height: 12),
          TextField(controller: company, decoration: InputDecoration(
            labelText: 'Courier', isDense: true, border: const OutlineInputBorder(),
            suffixIcon: PopupMenuButton<String>(
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (v) => setD(() => company.text = v),
              itemBuilder: (_) => [for (final c in _couriers) PopupMenuItem(value: c, child: Text(c))],
            ),
          )),
          const SizedBox(height: 10),
          TextField(controller: number, decoration: const InputDecoration(labelText: 'Tracking number', isDense: true, border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: url, decoration: const InputDecoration(labelText: 'Tracking link (optional)', isDense: true, border: OutlineInputBorder())),
          SwitchListTile(
            contentPadding: EdgeInsets.zero, dense: true,
            title: const Text('Email the customer', style: TextStyle(fontSize: 13)),
            value: notify, onChanged: (v) { setD(() => notify = v); _notifyPref = v; },
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
          FilledButton.icon(icon: const Icon(Icons.local_shipping_outlined, size: 18),
              onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), label: const Text('Fulfil')),
        ],
      );
    }));
    if (ok != true) return;
    var ok2 = false;
    setState(() => _busy = true);
    try {
      final r = await _call({
        'action': 'fulfill', 'order_id': o['id'],
        'company': company.text.trim().isEmpty ? null : company.text.trim(),
        'number': number.text.trim().isEmpty ? null : number.text.trim(),
        'url': url.text.trim().isEmpty ? null : url.text.trim(),
        'notify': notify,
      });
      _snack(r['already'] == true ? 'It was already fulfilled in the store — marked fulfilled here.' : 'Fulfilled in the store');
      ok2 = true;
    } catch (e) {
      _snack('Not fulfilled: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load(quiet: true);
      if (ok2) _openNext(o['id'] as String);
    }
  }

  // ── packing slips ────────────────────────────────────────────────────────
  Future<void> _printSlips(List<Map<String, dynamic>> orders) async {
    if (orders.isEmpty) return;
    final storeIds = orders.map((o) => o['store_id']).toSet();
    final store = _stores.firstWhere((s) => storeIds.contains(s['id']), orElse: () => const {});
    final note = TextEditingController(text: '${store['slip_note'] ?? ''}');
    var a5 = store['slip_size'] == 'a5';
    final go = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: Text(orders.length == 1 ? 'Packing slip · ${orders.first['order_no'] ?? ''}' : 'Packing slips · ${orders.length} orders'),
      content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Paper size', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('A4')), ButtonSegment(value: true, label: Text('A5'))],
          selected: {a5},
          onSelectionChanged: (v) => setD(() => a5 = v.first),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: note, minLines: 2, maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Your text on every slip (optional)',
            hintText: 'e.g. Thank you for shopping with us! For returns / warranty call 03xx-xxxxxxx',
            border: OutlineInputBorder()),
        ),
        const SizedBox(height: 6),
        const Text('Size and text are remembered for this store.', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton.icon(icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print'),
            onPressed: () => Navigator.of(d, rootNavigator: true).pop(true)),
      ],
    )));
    if (go != true) return;
    // Remember size + text for the store(s) printed.
    for (final s in _stores.where((s) => storeIds.contains(s['id']))) {
      if (s['slip_note'] != note.text.trim() || (s['slip_size'] == 'a5') != a5) {
        s['slip_note'] = note.text.trim();
        s['slip_size'] = a5 ? 'a5' : 'a4';
        try {
          await Supabase.instance.client.from('shop_stores')
              .update({'slip_note': s['slip_note'], 'slip_size': s['slip_size']}).eq('id', s['id']);
        } catch (_) {}
      }
    }
    // Product pictures, fetched by the server per store (skipped if it fails).
    final prodPics = <String, Uint8List>{};
    final linePics = <String, Uint8List>{};
    for (final sid in storeIds) {
      try {
        final r = await _call({
          'action': 'slip_images', 'store_id': sid,
          'order_ids': [for (final o in orders) if (o['store_id'] == sid) o['id']],
        });
        ((r['products'] as Map?) ?? const {}).forEach((k, v) { try { prodPics['$k'] = base64Decode('$v'); } catch (_) {} });
        ((r['lines'] as Map?) ?? const {}).forEach((k, v) { try { linePics['$k'] = base64Decode('$v'); } catch (_) {} });
      } catch (_) {}
    }
    try {
      final bytes = await PackingSlipPdf.build(
        productPictures: prodPics,
        linePictures: linePics,
        orders: orders,
        products: _prodById,
        storeName: _storeName,
        storeNote: (id) => _stores.firstWhere((s) => s['id'] == id, orElse: () => const {})['slip_note'] as String?,
        printedBy: ref.read(currentUserProvider)?.name ?? '',
        a5: a5,
      );
      await showPdf(bytes, orders.length == 1 ? 'Packing slip ${orders.first['order_no'] ?? ''}' : 'Packing slips');
    } catch (e) {
      _snack('Could not make the slip: $e');
    }
  }

  /// Pick several orders and print all their slips in one go.
  Future<void> _printSlipsPicker() async {
    final candidates = _visible.where((o) => o['status'] != 'cancelled').toList();
    if (candidates.isEmpty) { _snack('No orders in this list.'); return; }
    final sel = <String>{for (final o in candidates) if (o['status'] != 'fulfilled') o['id'] as String};
    final go = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: const Text('Print packing slips'),
      content: SizedBox(width: 460, height: 420, child: Column(children: [
        Row(children: [
          Text('${sel.length} selected', style: const TextStyle(fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton(onPressed: () => setD(() => sel..clear()..addAll(candidates.map((o) => o['id'] as String))), child: const Text('All')),
          TextButton(onPressed: () => setD(sel.clear), child: const Text('None')),
        ]),
        Expanded(child: ListView(children: [
          for (final o in candidates)
            CheckboxListTile(
              dense: true, controlAffinity: ListTileControlAffinity.leading,
              value: sel.contains(o['id']),
              onChanged: (v) => setD(() => v == true ? sel.add(o['id'] as String) : sel.remove(o['id'])),
              title: Text('${o['order_no'] ?? ''} · ${o['customer_name'] ?? ''}'),
              subtitle: Text('${_statusLabels[o['status']] ?? o['status']} · ${_money(o)}', style: const TextStyle(fontSize: 11.5)),
            ),
        ])),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), child: const Text('Next')),
      ],
    )));
    if (go != true || sel.isEmpty) return;
    await _printSlips(candidates.where((o) => sel.contains(o['id'])).toList());
  }

  // ── store connection ─────────────────────────────────────────────────────
  Future<void> _connectDialog({Map<String, dynamic>? store}) async {
    final org = _orgId;
    if (org == null) return;
    final domain = TextEditingController(text: store?['shop_domain'] as String? ?? '');
    final name = TextEditingController(text: store?['name'] as String? ?? '');
    final cid = TextEditingController();
    final secret = TextEditingController();
    final token = TextEditingController();
    final days = TextEditingController(text: '7');
    String? branch = store?['branch_id'] as String?;
    bool legacy = false;
    final branches = ref.read(userBranchesProvider).valueOrNull ?? const <Map<String, dynamic>>[];
    String? err;
    bool working = false;
    await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: Text(store == null ? 'Connect a Shopify store' : 'Reconnect ${store['name']}'),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('From the app you created for this store in Shopify\'s Dev Dashboard (Settings → Client ID / Secret). '
            'The keys are stored on the server and are never shown again.',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        TextField(controller: domain, enabled: store == null,
            decoration: const InputDecoration(labelText: 'Store address', hintText: 'mystore.myshopify.com', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name in Opstation (optional)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        DropdownButtonFormField<String?>(
          value: branches.any((b) => b['id'] == branch) ? branch : null, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Ships from branch', isDense: true, border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            for (final b in branches) DropdownMenuItem<String?>(value: b['id'] as String, child: Text('${b['name'] ?? ''}')),
          ],
          onChanged: (v) => setD(() => branch = v),
        ),
        const SizedBox(height: 10),
        if (!legacy) TextField(controller: cid, decoration: const InputDecoration(labelText: 'Client ID', isDense: true, border: OutlineInputBorder())),
        if (legacy) TextField(controller: token, decoration: const InputDecoration(labelText: 'Admin API access token (shpat_…)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: secret, obscureText: true,
            decoration: InputDecoration(labelText: legacy ? 'API secret key' : 'Client secret', isDense: true, border: const OutlineInputBorder())),
        CheckboxListTile(
          dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
          title: const Text('I have an older custom app with an access token (shpat_…)', style: TextStyle(fontSize: 12.5)),
          value: legacy, onChanged: (v) => setD(() => legacy = v ?? false),
        ),
        SizedBox(width: 200, child: TextField(controller: days, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Bring in orders from the last (days)', isDense: true, border: OutlineInputBorder()))),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
      ]))),
      actions: [
        TextButton(onPressed: working ? null : () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: working ? null : () async {
            setD(() { working = true; err = null; });
            try {
              final r = await _call({
                'action': 'connect', 'org_id': org, 'shop_domain': domain.text.trim(), 'name': name.text.trim().isEmpty ? null : name.text.trim(),
                'branch_id': branch, 'client_id': legacy ? null : cid.text.trim(), 'client_secret': secret.text.trim(),
                'access_token': legacy ? token.text.trim() : null, 'days': int.tryParse(days.text.trim()) ?? 7,
              });
              if (d.mounted) Navigator.of(d, rootNavigator: true).pop();
              if (r['pending'] == true) {
                await _authorizeDialog('${r['authorize_url']}');
                await _load();
                return;
              }
              _snack('Connected ${r['shop'] ?? ''} — ${r['imported'] ?? 0} order(s) brought in'
                  '${r['webhook_warning'] != null ? '. Live updates could not be switched on; the 10-minute sync still runs.' : ''}');
              await _load();
            } catch (e) {
              setD(() { working = false; err = '$e'; });
            }
          },
          child: working
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Connect'),
        ),
      ],
    )));
  }

  Future<void> _openMatching() async {
    final active = _stores.where((s) => s['is_active'] == true).toList();
    if (active.isEmpty) return;
    Map<String, dynamic>? store = active.length == 1
        ? active.first
        : active.firstWhere((s) => s['id'] == _storeFilter, orElse: () => const {});
    if (store == null || store.isEmpty) {
      store = await showDialog<Map<String, dynamic>>(context: context, builder: (d) => SimpleDialog(
        title: const Text('Which store?'),
        children: [for (final s in active)
          SimpleDialogOption(onPressed: () => Navigator.of(d, rootNavigator: true).pop(s), child: Text('${s['name'] ?? s['shop_domain']}'))],
      ));
    }
    if (store == null || !mounted) return;
    await showShopProductMatching(context, store: store, products: _products, call: _call);
    await _load(quiet: true);
  }

  /// Keys are saved, but Shopify still has to approve access for this store.
  Future<void> _authorizeDialog(String url) async {
    await showDialog(context: context, builder: (d) => AlertDialog(
      title: const Text('One more step: approve in Shopify'),
      content: const SizedBox(width: 440, child: Text(
          'The keys are saved. Now approve Opstation in your Shopify admin: press the button, '
          'sign in to the store if asked, and click Install / Approve. You will come straight back here '
          'and the recent orders will load.')),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Later')),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Approve in Shopify'),
          onPressed: () {
            Navigator.of(d, rootNavigator: true).pop();
            html.window.location.href = url;
          },
        ),
      ],
    ));
  }

  Future<void> _storesDialog() async {
    await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: const Text('Connected stores'),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_stores.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No store connected yet.')),
        for (final s in _stores)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.storefront, color: s['is_active'] == true ? Colors.green : AppTheme.textSecondary),
            title: Text('${s['name'] ?? s['shop_domain']}'),
            subtitle: Text([
              '${s['shop_domain']}',
              if (s['is_active'] != true) 'disconnected',
              if (s['is_active'] == true) (s['webhooks_ok'] == true ? 'live updates on' : 'live updates off (10-min sync)'),
              if (s['last_sync_at'] != null) 'synced ${DateFormat('d MMM, HH:mm').format(DateTime.parse(s['last_sync_at'] as String).toLocal())}',
              if ((s['last_error'] as String?)?.isNotEmpty == true) 'last problem: ${s['last_error']}',
            ].join(' · '), style: const TextStyle(fontSize: 11.5)),
            trailing: _isAdmin
                ? PopupMenuButton<String>(
                    onSelected: (v) async {
                      Navigator.of(d, rootNavigator: true).pop();
                      if (v == 'reconnect') await _connectDialog(store: s);
                      if (v == 'approve') {
                        try {
                          final r = await _call({'action': 'authorize_url', 'store_id': s['id']});
                          await _authorizeDialog('${r['authorize_url']}');
                        } catch (e) {
                          _snack('$e');
                        }
                      }
                      if (v == 'disconnect') {
                        try {
                          await _call({'action': 'disconnect', 'store_id': s['id']});
                          _snack('Disconnected');
                          await _load();
                        } catch (e) {
                          _snack('$e');
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'approve', child: Text('Approve again in Shopify (after adding permissions)')),
                      const PopupMenuItem(value: 'reconnect', child: Text('Reconnect / change keys')),
                      if (s['is_active'] == true) const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
                    ],
                  )
                : null,
          ),
      ])),
      actions: [
        if (_isAdmin)
          OutlinedButton.icon(icon: const Icon(Icons.add_link, size: 18), label: const Text('Connect a store'),
              onPressed: () { Navigator.of(d, rootNavigator: true).pop(); _connectDialog(); }),
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Close')),
      ],
    )));
  }

  // ── helpers ──────────────────────────────────────────────────────────────
  double _num(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);
  String _q(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);
  String _lineName(Map<String, dynamic> l) {
    final p = _prodById[l['product_id']];
    final base = p?['name'] as String? ?? '${l['title'] ?? 'Item'}';
    final vt = (l['variant_title'] as String?)?.trim() ?? '';
    return p == null && vt.isNotEmpty && vt != 'Default Title' ? '$base — $vt' : base;
  }
  String _money(Map<String, dynamic> o) => '${o['currency'] ?? ''} ${NumberFormat('#,##0.##').format(_num(o['total']))}'.trim();

  Color _statusColor(String st) => switch (st) {
        'new' => Colors.blue,
        'picking' => Colors.orange,
        'packed' => Colors.purple,
        'fulfilled' => Colors.green,
        'cancelled' => Colors.red,
        _ => Colors.grey,
      };

  Widget _chip(String st) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: _statusColor(st).withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Text(_statusLabels[st] ?? st,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _statusColor(st).withOpacity(0.9))),
      );

  // ── focus mode ───────────────────────────────────────────────────────────
  void _onFsChange(html.Event _) {
    final fs = html.document.fullscreenElement != null;
    if (mounted && fs != _fullscreen) setState(() => _fullscreen = fs);
  }

  /// Full screen: hides the browser bar and Opstation's menus — only this
  /// screen is shown (Esc or the button again to leave).
  void _toggleFullscreen() {
    try {
      if (html.document.fullscreenElement == null) {
        html.document.documentElement?.requestFullscreen();
      } else {
        html.document.exitFullscreen();
      }
    } catch (_) {}
  }

  // ── UI ───────────────────────────────────────────────────────────────────
  String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    return DateFormat('d MMM').format(t);
  }

  /// Units picked / needed across the order (bundles count each product inside).
  (double, double) _units(Map<String, dynamic> o) {
    var p = 0.0, n = 0.0;
    for (final l in _lines(o)) {
      if (_isBundle(l)) {
        for (final c in _comps(l)) { p += _num(c['picked']); n += _num(c['qty']); }
      } else {
        p += _num(l['picked']); n += _num(l['qty']);
      }
    }
    return (p, n);
  }

  /// Value of items cancelled here (at the price paid, after any discount) —
  /// taken off the COD amount.
  double _removedValue(Map<String, dynamic> o) =>
      _lines(o).fold<double>(0, (a, l) => a + _num(l['cancelled']) * (_num(l['price']) - _num(l['disc_each'])));

  double _collect(Map<String, dynamic> o) {
    final paid = '${o['financial_status'] ?? ''}'.toUpperCase() == 'PAID';
    final base = o['outstanding'] != null ? _num(o['outstanding']) : (paid ? 0.0 : _num(o['total']));
    if (base <= 0) return 0;
    final v = base - _removedValue(o);
    return v < 0 ? 0.0 : v;
  }

  String _city(Map<String, dynamic> o) => '${((o['ship_to'] as Map?) ?? const {})['city'] ?? ''}'.trim();

  bool _hasUnmatched(Map<String, dynamic> o) => _lines(o).any((l) => !_lineMapped(l));

  bool _shippedToday(Map<String, dynamic> o) {
    final t = DateTime.tryParse('${o['fulfilled_at'] ?? ''}')?.toLocal();
    final n = DateTime.now();
    return o['status'] == 'fulfilled' && t != null && t.year == n.year && t.month == n.month && t.day == n.day;
  }

  /// Order number typed / scanned (e.g. from a packing slip) → open it.
  void _openByNumber(String v) {
    final q = v.trim().replaceAll('#', '').toLowerCase();
    if (q.isEmpty) return;
    final hit = _orders.where((o) => '${o['order_no'] ?? ''}'.replaceAll('#', '').toLowerCase() == q).toList();
    if (hit.isNotEmpty) {
      setState(() { _selId = hit.first['id'] as String; _fresh.remove(_selId); _search = ''; _searchCtrl.clear(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 900;
    final sel = _sel;
    final showDetail = narrow && sel != null;
    final autoAll = _scopeStores.isNotEmpty && _scopeStores.every((s) => s['auto_fulfil'] == true);
    final viewSwitch = SegmentedButton<String>(
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 'queue', icon: Icon(Icons.checklist, size: 16), label: Text('Work queue')),
        ButtonSegment(value: 'dispatch', icon: Icon(Icons.local_shipping_outlined, size: 16), label: Text('Handover')),
        ButtonSegment(value: 'summary', icon: Icon(Icons.summarize_outlined, size: 16), label: Text('Fulfilled summary')),
      ],
      selected: {_view},
      onSelectionChanged: (v) => setState(() { _view = v.first; _selId = null; }),
    );
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 10 : 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── header ──
        Row(children: [
          if (showDetail)
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _selId = null)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Fulfillment', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: narrow ? 18 : 26, fontWeight: FontWeight.w800)),
            if (!narrow)
              const Text('Scan to pick, pack and ship online-store orders.',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ])),
          if (_stores.isNotEmpty && !narrow) ...[viewSwitch, const SizedBox(width: 8)],
          if (_scopeStores.isNotEmpty && _view == 'queue')
            Tooltip(
              message: 'When on, an order is packed and fulfilled in the store automatically '
                  'as soon as every item has been scanned right (when a courier booking exists — otherwise it is packed and waits).',
              child: Container(
                padding: const EdgeInsets.only(left: 10, right: 2),
                decoration: BoxDecoration(
                  color: autoAll ? Colors.green.withOpacity(0.08) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: autoAll ? Colors.green : AppTheme.border),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bolt, size: 16, color: autoAll ? Colors.green.shade700 : null),
                  if (!narrow) ...[
                    const SizedBox(width: 4),
                    const Text('Auto-fulfil', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                  Switch(value: autoAll, onChanged: _setAuto),
                ]),
              ),
            ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Sync orders now',
            onPressed: _busy ? null : _syncNow,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          if (_orders.isNotEmpty && _view == 'queue')
            IconButton(tooltip: 'Print packing slips', icon: const Icon(Icons.print_outlined), onPressed: _printSlipsPicker),
          if (!narrow) IconButton(
            tooltip: _fullscreen ? 'Exit full screen (Esc)' : 'Full screen — focus mode',
            icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
            onPressed: _toggleFullscreen,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'match') _openMatching();
              if (v == 'recheck' && !_busy) _syncNow(days: 14);
              if (v == 'scan') _scanSettings();
              if (v == 'pin') _pinDialog();
              if (v == 'stores') _stores.isEmpty && _isAdmin ? _connectDialog() : _storesDialog();
            },
            itemBuilder: (_) => [
              if (_stores.any((s) => s['is_active'] == true))
                const PopupMenuItem(value: 'match', child: ListTile(dense: true, leading: Icon(Icons.link), title: Text('Match products'))),
              if (_stores.any((s) => s['is_active'] == true))
                const PopupMenuItem(value: 'recheck', child: ListTile(dense: true, leading: Icon(Icons.manage_history),
                    title: Text('Re-check last 14 days'), subtitle: Text('Picks up changes made in Shopify that were missed'))),
              if (_isAdmin && _stores.any((s) => s['is_active'] == true))
                const PopupMenuItem(value: 'scan', child: ListTile(dense: true, leading: Icon(Icons.qr_code_scanner),
                    title: Text('Scan settings'), subtitle: Text('Which barcodes count when picking'))),
              if (_isAdmin && _stores.any((s) => s['is_active'] == true))
                const PopupMenuItem(value: 'pin', child: ListTile(dense: true, leading: Icon(Icons.password),
                    title: Text('Item cancel passcode'), subtitle: Text('Needed to cancel an item while picking'))),
              PopupMenuItem(value: 'stores', child: ListTile(dense: true, leading: const Icon(Icons.storefront_outlined),
                  title: Text(_stores.isEmpty ? 'Connect store' : 'Stores (${_stores.where((s) => s['is_active'] == true).length})'))),
            ],
          ),
        ]),
        if (narrow && _stores.isNotEmpty && !showDetail) ...[const SizedBox(height: 8), viewSwitch],
        const SizedBox(height: 12),
        if (!_loading && _stores.isNotEmpty && !showDetail && _view == 'queue') ...[
          _statsStrip(narrow),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _stores.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.storefront_outlined, size: 48, color: AppTheme.textSecondary),
                      const SizedBox(height: 10),
                      Text(_isAdmin ? 'Connect your Shopify store to start receiving orders here.'
                          : 'No online store is connected yet — ask an admin to connect one.',
                          style: const TextStyle(color: AppTheme.textSecondary)),
                      if (_isAdmin) ...[
                        const SizedBox(height: 12),
                        FilledButton.icon(icon: const Icon(Icons.add_link), label: const Text('Connect a Shopify store'),
                            onPressed: _connectDialog),
                      ],
                    ]))
                  : _view == 'dispatch'
                      ? ShopDispatch(
                          key: const ValueKey('handover'),
                          orgId: _orgId ?? '',
                          userId: ref.read(currentUserProvider)?.id,
                          userName: ref.read(currentUserProvider)?.name ?? '',
                          stores: _stores,
                          onDone: () => _load(quiet: true),
                        )
                  : _view == 'summary'
                      ? ShopFulfilledSummary(
                          key: const ValueKey('fulfilled-summary'),
                          orgId: _orgId ?? '',
                          userId: ref.read(currentUserProvider)?.id,
                          userName: ref.read(currentUserProvider)?.name ?? '',
                          stores: _stores,
                          products: _prodById,
                          branches: ref.read(userBranchesProvider).valueOrNull ?? const [],
                        )
                      : narrow
                      ? (showDetail ? _detail(sel) : _list())
                      // The order list folds away (strip in the middle) for a wider work area.
                      : CollapsibleListPane(
                          paneWidth: 400,
                          listChild: OverflowBox(
                            alignment: Alignment.topLeft, minWidth: 400, maxWidth: 400,
                            child: Padding(padding: const EdgeInsets.only(right: 8), child: _list()),
                          ),
                          detailChild: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: sel == null ? _emptyDetail() : _detail(sel),
                          ),
                        ),
        ),
      ]),
    );
  }

  Widget _statsStrip(bool narrow) {
    final scoped = _orders.where((o) => _storeFilter == 'all' || o['store_id'] == _storeFilter).toList();
    final unmatched = scoped.where((o) => ['new', 'picking', 'packed'].contains(o['status']) && _hasUnmatched(o)).length;
    final tiles = <(String, String, int, Color, IconData)>[
      ('new', 'To pick', _count('new'), Colors.blue, Icons.inbox_outlined),
      ('picking', 'Picking', _count('picking'), Colors.orange, Icons.qr_code_scanner),
      ('packed', 'Ready to ship', _count('packed'), Colors.purple, Icons.inventory_2_outlined),
      ('today', 'Shipped today', scoped.where(_shippedToday).length, Colors.green, Icons.local_shipping_outlined),
      if (unmatched > 0) ('unmatched', 'Need matching', unmatched, Colors.deepOrange, Icons.link_off),
    ];
    Widget tile((String, String, int, Color, IconData) t) {
      final on = _filter == t.$1;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _filter = on ? 'open' : t.$1),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: narrow ? 8 : 12),
          decoration: BoxDecoration(
            color: on ? t.$4.withOpacity(0.10) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? t.$4 : AppTheme.border, width: on ? 1.5 : 1),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(color: t.$4.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
              child: Icon(t.$5, size: 18, color: t.$4),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('${t.$3}', style: TextStyle(fontSize: narrow ? 18 : 22, fontWeight: FontWeight.w800, height: 1.1)),
              Text(t.$2, style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            ]),
          ]),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final t in tiles) ...[tile(t), const SizedBox(width: 10)],
      ]),
    );
  }

  Widget _emptyDetail() => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
        child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.qr_code_scanner, size: 44, color: AppTheme.textSecondary.withOpacity(0.6)),
          const SizedBox(height: 10),
          const Text('Pick an order from the list', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('or scan the order barcode on its packing slip into the search box.',
              style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        ])),
      );

  Widget _list() {
    final rows = _visible;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(children: [
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search or scan order no, customer, phone…',
                prefixIcon: const Icon(Icons.search), isDense: true,
                suffixIcon: _search.isEmpty ? null : IconButton(icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() { _search = ''; _searchCtrl.clear(); })),
              ),
              onChanged: (v) => setState(() => _search = v),
              onSubmitted: _openByNumber,
            ),
            if (_stores.length > 1) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _storeFilter, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Store', isDense: true),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All stores')),
                  for (final s in _stores) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name'] ?? s['shop_domain']}')),
                ],
                onChanged: (v) => setState(() => _storeFilter = v ?? 'all'),
              ),
            ],
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final f in const [('open', 'To do'), ('fulfilled', 'Fulfilled'), ('cancelled', 'Cancelled'), ('all', 'All')]) ...[
                  ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(f.$1 == 'all' ? f.$2 : '${f.$2} (${_count(f.$1)})', style: const TextStyle(fontSize: 12)),
                    selected: _filter == f.$1,
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
                  const SizedBox(width: 6),
                ],
              ]),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_filter == 'open' || _filter == 'new' ? Icons.celebration_outlined : Icons.inbox_outlined,
                      size: 36, color: AppTheme.textSecondary.withOpacity(0.6)),
                  const SizedBox(height: 8),
                  Text(_filter == 'open' || _filter == 'new' ? 'All caught up — no orders waiting.' : 'No orders here.',
                      style: const TextStyle(color: AppTheme.textSecondary)),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _orderCard(rows[i]),
                ),
        ),
      ]),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final st = o['status'] as String? ?? 'new';
    final c = _statusColor(st);
    final selected = o['id'] == _selId;
    final placed = DateTime.tryParse('${o['placed_at'] ?? ''}')?.toLocal();
    final (p, n) = _units(o);
    final collect = _collect(o);
    final fresh = _fresh.contains(o['id']);
    final city = _city(o);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? AppTheme.primary.withOpacity(0.06) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() { _selId = o['id'] as String; _fresh.remove(o['id']); }),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? AppTheme.primary : (fresh ? Colors.blue.shade300 : AppTheme.border),
                  width: selected || fresh ? 1.5 : 1),
            ),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Container(width: 4, decoration: BoxDecoration(color: c,
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)))),
                Expanded(child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('${o['order_no'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                      const SizedBox(width: 6),
                      _chip(st),
                      if (fresh) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(8)),
                          child: const Text('JUST IN', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Colors.white)),
                        ),
                      ],
                      if (o['reopened_at'] != null && st != 'fulfilled' && st != 'cancelled') ...[
                        const SizedBox(width: 6),
                        const Tooltip(message: 'Un-fulfilled in Shopify — back in the queue',
                            child: Icon(Icons.undo, size: 15, color: Colors.deepPurple)),
                      ],
                      if (_hasUnmatched(o)) ...[
                        const SizedBox(width: 6),
                        const Tooltip(message: 'Has items not matched to a product',
                            child: Icon(Icons.link_off, size: 15, color: Colors.deepOrange)),
                      ],
                      const Spacer(),
                      Text(_money(o), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 3),
                    Row(children: [
                      Expanded(child: Text([
                        '${o['customer_name'] ?? '—'}',
                        if (city.isNotEmpty) city,
                        if (_stores.length > 1) _storeName(o['store_id'] as String?),
                      ].join(' · '), overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                      const SizedBox(width: 6),
                      Text(_ago(placed), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                    ]),
                    const SizedBox(height: 6),
                    Row(children: [
                      if (st != 'fulfilled' && st != 'cancelled') ...[
                        Expanded(child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: n == 0 ? 0.0 : (p / n).clamp(0, 1).toDouble(), minHeight: 5,
                            backgroundColor: AppTheme.border.withOpacity(0.6),
                            valueColor: AlwaysStoppedAnimation(p >= n && n > 0 ? Colors.green : c),
                          ),
                        )),
                        const SizedBox(width: 8),
                        Text('${_q(p)}/${_q(n)}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                      ] else
                        Expanded(child: Text(
                          st == 'fulfilled'
                              ? [if (o['tracking_company'] != null) '${o['tracking_company']}', if (o['tracking_number'] != null) '${o['tracking_number']}']
                                  .join(' · ')
                              : 'Cancelled in the store',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
                      _payPill(collect),
                    ]),
                  ]),
                )),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _payPill(double collect) {
    final cod = collect > 0;
    final c = cod ? Colors.orange.shade800 : Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
      child: Text(cod ? 'COD' : 'PAID', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: c)),
    );
  }

  Widget _stepper(String st) {
    const steps = [('new', 'New'), ('picking', 'Picking'), ('packed', 'Packed'), ('fulfilled', 'Fulfilled')];
    final idx = steps.indexWhere((s) => s.$1 == st);
    return Row(children: [
      for (var i = 0; i < steps.length; i++) ...[
        Container(
          width: 22, height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < idx || st == 'fulfilled' ? Colors.green : (i == idx ? _statusColor(st) : Colors.white),
            border: Border.all(color: i <= idx ? Colors.transparent : AppTheme.border, width: 1.5),
          ),
          child: Center(child: i < idx || st == 'fulfilled'
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : Text('${i + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800,
                  color: i == idx ? Colors.white : AppTheme.textSecondary))),
        ),
        const SizedBox(width: 6),
        Text(steps[i].$2, style: TextStyle(fontSize: 12.5,
            fontWeight: i == idx ? FontWeight.w800 : FontWeight.w500,
            color: i <= idx ? null : AppTheme.textSecondary)),
        if (i < steps.length - 1)
          Expanded(child: Container(height: 2, margin: const EdgeInsets.symmetric(horizontal: 8),
              color: i < idx ? Colors.green : AppTheme.border)),
      ],
    ]);
  }

  Widget _infoCard(IconData icon, String title, List<Widget> body, {Color? accent}) => Container(
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 340),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent?.withOpacity(0.06) ?? AppTheme.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent?.withOpacity(0.5) ?? AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 15, color: accent ?? AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(title.toUpperCase(), style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.4,
                color: accent ?? AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 6),
          ...body,
        ]),
      );

  Widget _detail(Map<String, dynamic> o) {
    final st = o['status'] as String? ?? 'new';
    final lines = _lines(o);
    final ship = Map<String, dynamic>.from((o['ship_to'] as Map?) ?? const {});
    final address = [ship['address1'], ship['address2'], ship['city'], ship['province'], ship['zip'], ship['country']]
        .where((x) => x != null && '$x'.trim().isNotEmpty).join(', ');
    final placed = DateTime.tryParse('${o['placed_at'] ?? ''}')?.toLocal();
    final pickedAll = lines.isNotEmpty && lines.every(_lineDone);
    final canWork = st != 'fulfilled' && st != 'cancelled';
    final collect = _collect(o);
    final (p, n) = _units(o);
    final auto = _autoOn(o['store_id'] as String?);
    final slipNeeded = _slipRequired(o['store_id'] as String?) && o['slip_verified_at'] == null;
    final checksNeeded = !_checksDone(o);
    // Notes kept behind the ⓘ (count shown on it).
    final infoCount = [
      (o['note'] as String?)?.isNotEmpty == true,
      canWork && o['slip_verified_at'] != null,
      canWork && o['reopened_at'] != null,
      canWork && '${o['ext_fulfillment'] ?? ''}'.toUpperCase() == 'FULFILLED',
    ].where((x) => x).length;
    final phone = '${o['phone'] ?? ''}'.trim();
    // Phone / tablet: picking mode — the scan bar and a big camera button stay
    // at the top while the item list scrolls, no keyboard popping up.
    final mobile = MediaQuery.of(context).size.width < 700;
    final scanBar = ScanBar(
      key: _scanKey, onScan: _onScan, hint: mobile ? 'Scan or type code' : 'Scan each item to pick it',
      strongFeedback: true, camera: true, autofocus: !mobile,
    );
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        if (mobile && canWork)
          Container(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Column(children: [
              Row(children: [
                Text('${o['order_no'] ?? ''}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                _chip(st),
                const Spacer(),
                Text('${_q(p)} / ${_q(n)}', style: TextStyle(fontWeight: FontWeight.w800,
                    color: pickedAll ? Colors.green.shade700 : null)),
              ]),
              const SizedBox(height: 8),
              scanBar,
              if (pickedAll && checksNeeded) _nextScanPrompt(o, mobile),
            ]),
          ),
        Expanded(child: ListView(padding: EdgeInsets.all(mobile ? 12 : 18), children: [
          // One compact header line; everything else opens on tap (ⓘ).
          Row(children: [
            Text('${o['order_no'] ?? ''}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            _chip(st),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: (collect > 0 ? Colors.orange.shade800 : Colors.green.shade700).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8)),
              child: Text(collect > 0 ? 'COD ${NumberFormat('#,##0.##').format(collect)}' : 'Paid',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800,
                      color: collect > 0 ? Colors.orange.shade800 : Colors.green.shade700)),
            ),
            const SizedBox(width: 10),
            Expanded(child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _infoOpen = !_infoOpen),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(children: [
                  Flexible(child: Text(
                    [ '${o['customer_name'] ?? '—'}', if (_city(o).isNotEmpty) _city(o) ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  if ((o['note'] as String?)?.isNotEmpty == true) ...[
                    const SizedBox(width: 6),
                    Tooltip(message: 'Customer note: ${o['note']}',
                        child: Icon(Icons.sticky_note_2, size: 16, color: Colors.amber.shade800)),
                  ],
                  if (infoCount > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text('$infoCount', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.indigo)),
                    ),
                  ],
                  Icon(_infoOpen ? Icons.expand_less : Icons.info_outline, size: 17, color: AppTheme.textSecondary),
                ]),
              ),
            )),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Print packing slip',
                icon: const Icon(Icons.print_outlined, size: 20), onPressed: () => _printSlips([o])),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Open in Shopify',
                icon: const Icon(Icons.open_in_new, size: 20), onPressed: () => _openInShopify(o)),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'Refresh from the store',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _busy ? null : () async {
                  try { await _call({'action': 'refresh_order', 'order_id': o['id']}); await _load(quiet: true); }
                  catch (e) { _snack('$e'); }
                }),
          ]),
          // Details on tap: customer, address, payment, and the order's notes.
          if (_infoOpen)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${o['customer_name'] ?? '—'}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  if (phone.isNotEmpty)
                    InkWell(
                      onTap: () => html.window.open('tel:${phone.replaceAll(' ', '')}', '_self'),
                      child: Text(phone, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primary)),
                    ),
                  if ((o['email'] as String?)?.isNotEmpty == true)
                    Text('${o['email']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 3),
                Text(address.isEmpty ? 'No address' : address, style: const TextStyle(fontSize: 12.5)),
                const SizedBox(height: 3),
                Text([
                  _storeName(o['store_id'] as String?),
                  if (placed != null) 'placed ${DateFormat('d MMM yyyy, HH:mm').format(placed)} (${_ago(placed)})',
                  if ((o['payment_methods'] as String?)?.isNotEmpty == true) '${o['payment_methods']}',
                  'total ${_money(o)}',
                ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                if ((o['note'] as String?)?.isNotEmpty == true)
                  _banner(Colors.amber.shade800, Icons.sticky_note_2_outlined, 'Customer note: ${o['note']}'),
                if (canWork && o['slip_verified_at'] != null)
                  _banner(Colors.green, Icons.verified_outlined, 'Box checked — slip scanned by ${o['slip_verified_by'] ?? ''}'
                      '${o['label_verified_at'] != null ? ' · courier label matches' : ''}'),
                if (canWork && o['reopened_at'] != null)
                  _banner(Colors.deepPurple, Icons.undo, 'Un-fulfilled in Shopify '
                      '${DateFormat('d MMM, HH:mm').format(DateTime.parse('${o['reopened_at']}').toLocal())} — back in the queue. '
                      'Picked items were kept; use Restart to count again.'),
                if (canWork && '${o['ext_fulfillment'] ?? ''}'.toUpperCase() == 'FULFILLED')
                  _bookedBanner(o),
              ]),
            ),
          // Always visible: only what stops or changes the work.
          if (st == 'cancelled')
            _banner(Colors.red, Icons.cancel_outlined, 'This order was cancelled in the store. Do not ship it.'),
          if (st == 'fulfilled')
            _banner(Colors.green, Icons.check_circle_outline, [
              'Fulfilled',
              if (o['fulfilled_by_name'] != null) 'by ${o['fulfilled_by_name']}',
              if (o['tracking_company'] != null) '· ${o['tracking_company']}',
              if (o['tracking_number'] != null) '${o['tracking_number']}',
            ].join(' ')),
          if ((o['fulfil_error'] as String?)?.isNotEmpty == true && st != 'fulfilled')
            _banner(Colors.red, Icons.error_outline, 'Last fulfil attempt failed: ${o['fulfil_error']}'),
          if (canWork && _lockedByOther(o))
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.06), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.4))),
              child: Row(children: [
                const Icon(Icons.lock_outline, size: 16, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(child: Text('Being picked by ${o['picking_by_name'] ?? 'someone else'} — scanning blocked.',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.red))),
                if (_isAdmin) TextButton(onPressed: () => _takeOver(o), child: const Text('Take over')),
              ]),
            ),
          if (_hasUnmatched(o) && canWork)
            _banner(Colors.deepOrange, Icons.link_off, 'Some items are not matched to a product yet — match them before picking.'),
          const SizedBox(height: 12),
          // picking
          Row(children: [
            const Text('Items', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(width: 10),
            Expanded(child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: n == 0 ? 0.0 : (p / n).clamp(0, 1).toDouble(), minHeight: 6,
                backgroundColor: AppTheme.border.withOpacity(0.6),
                valueColor: AlwaysStoppedAnimation(pickedAll ? Colors.green : _statusColor(st)),
              ),
            )),
            const SizedBox(width: 10),
            Text('${_q(p)} of ${_q(n)} picked', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                color: pickedAll ? Colors.green.shade700 : null)),
          ]),
          const SizedBox(height: 10),
          if (canWork && pickedAll && checksNeeded) _nextScanPrompt(o, mobile),
          if (canWork) ...[
            if (!mobile) scanBar,
            if (_autoBusy.contains(o['id']))
              _banner(Colors.blue, Icons.local_shipping_outlined, 'All items scanned — fulfilling in the store…'),
            const SizedBox(height: 10),
          ],
          for (var i = 0; i < lines.length; i++) _lineRow(o, lines, i, canWork),
          const SizedBox(height: 8),
          Text([
            if (o['picked_by_name'] != null) 'Picked by ${o['picked_by_name']}',
            if (o['packed_at'] != null)
              'Packed ${o['packed_by_name'] != null ? 'by ${o['packed_by_name']} ' : ''}'
                  '${DateFormat('d MMM, HH:mm').format(DateTime.parse(o['packed_at'] as String).toLocal())}',
          ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        ])),
        // sticky action bar
        if (canWork)
          Container(
            padding: EdgeInsets.symmetric(horizontal: mobile ? 10 : 16, vertical: mobile ? 8 : 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppTheme.border)),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
              color: Colors.white,
            ),
            child: () {
              final msg = Text(
                pickedAll
                    ? (checksNeeded
                        ? 'All picked — scan ${_nextCheck(o)}.'
                        : st == 'packed' ? 'Packed — fulfil it with the courier details.' : 'All picked — pack it and fulfil.')
                    : auto
                        ? (mobile
                            ? '${_q(n - p)} left · Auto-fulfil on'
                            : 'Auto-fulfil is on: it ships when the last item is scanned (or waits packed if not booked yet).')
                        : '${_q(n - p)} item${n - p == 1 ? '' : 's'} left to scan.',
                maxLines: mobile ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600,
                    color: pickedAll ? Colors.green.shade800 : AppTheme.textSecondary),
              );
              Future<void> restart() async {
                final ls = _lines(o);
                for (final l in ls) {
                  l['picked'] = 0;
                  if (_isBundle(l)) l['components'] = [for (final c in _comps(l)) {...c, 'picked': 0}];
                }
                await _saveLines(o, ls, status: 'new');
              }
              final canRestart = st == 'picking' || st == 'packed';
              final packedBtn = st != 'packed'
                  ? OutlinedButton.icon(
                      icon: const Icon(Icons.inventory_2_outlined, size: 18),
                      label: const Text('Packed'),
                      onPressed: _busy || !pickedAll || slipNeeded ? null : () => _markPacked(o),
                    )
                  : null;
              final mainBtn = (pickedAll && checksNeeded)
                  ? FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.indigo),
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: Text(_nextCheck(o)!.contains('label') ? 'Scan label' : 'Scan slip'),
                      onPressed: () => _startNextScan(mobile),
                    )
                  : FilledButton.icon(
                      icon: const Icon(Icons.local_shipping_outlined, size: 18),
                      label: const Text('Fulfil'),
                      onPressed: _busy || !pickedAll ? null : () => _fulfil(o),
                    );
              if (mobile) {
                // Phone: short status line on top, buttons on one row below.
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  msg,
                  const SizedBox(height: 8),
                  Row(children: [
                    if (canRestart)
                      IconButton(
                        tooltip: 'Restart picking',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: _busy ? null : restart,
                      ),
                    if (packedBtn != null) ...[Expanded(child: packedBtn), const SizedBox(width: 8)],
                    Expanded(child: mainBtn),
                  ]),
                ]);
              }
              return Row(children: [
                Expanded(child: msg),
                if (canRestart)
                  TextButton(onPressed: _busy ? null : restart, child: const Text('Restart')),
                const SizedBox(width: 6),
                if (packedBtn != null) packedBtn,
                const SizedBox(width: 8),
                mainBtn,
              ]);
            }(),
          ),
      ]),
    );
  }

  /// Booked (and fulfilled) in Shopify by the courier app, but not packed here yet.
  Widget _bookedBanner(Map<String, dynamic> o) {
    final si = Map<String, dynamic>.from((o['ship_info'] as Map?) ?? const {});
    final what = [si['company'], si['number']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.06), borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.indigo.withOpacity(0.35))),
      child: Row(children: [
        const Icon(Icons.local_shipping_outlined, size: 18, color: Colors.indigo),
        const SizedBox(width: 8),
        Expanded(child: Text(
            'Already booked in Shopify${what.isEmpty ? '' : ' ($what)'}. Pick and pack it as usual — '
            'Fulfil just closes it here, nothing is sent to the store again.',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.indigo))),
        TextButton(
          onPressed: _busy ? null : () => _markShippedOutside(o),
          child: const Text('Already shipped'),
        ),
      ]),
    );
  }

  /// Shipped without picking here (e.g. packed before Opstation) — close it.
  Future<void> _markShippedOutside(Map<String, dynamic> o) async {
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      title: Text('Close ${o['order_no'] ?? ''} without picking?'),
      content: const Text('Use this only if the parcel has already left. It is marked fulfilled here without scanning.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), child: const Text('Mark fulfilled')),
      ],
    ));
    if (ok != true) return;
    final si = Map<String, dynamic>.from((o['ship_info'] as Map?) ?? const {});
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await Supabase.instance.client.from('shop_orders').update({
        'status': 'fulfilled', 'fulfilled_at': now, 'fulfilled_by_name': ref.read(currentUserProvider)?.name,
        'tracking_company': o['tracking_company'] ?? si['company'], 'tracking_number': o['tracking_number'] ?? si['number'],
        'tracking_url': o['tracking_url'] ?? si['url'], 'updated_at': now,
      }).eq('id', o['id']);
      await _load(quiet: true);
      _openNext(o['id'] as String);
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      ]);

  Widget _banner(Color c, IconData icon, String text) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: c.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.35))),
        child: Row(children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.withOpacity(0.95)))),
        ]),
      );

  /// "+N": after one good scan, count the rest of that product in one tap.
  Widget _fillBtn(VoidCallback onTap, double rest) => TextButton(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 28), foregroundColor: Colors.green.shade800),
        onPressed: onTap,
        child: Text('+${_q(rest)} all', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      );

  String _cancelReason(Map<String, dynamic> l) {
    final log = (l['cancel_log'] as List?) ?? const [];
    if (log.isEmpty) return '';
    final r = '${(log.last as Map)['reason'] ?? ''}'.trim();
    return r.isEmpty ? '' : ' — $r';
  }

  Widget _cancelBtn(VoidCallback onTap) => IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Cancel this item (passcode)',
        icon: Icon(Icons.close, size: 17, color: Colors.red.shade400),
        onPressed: _busy ? null : onTap,
      );

  /// Cancel an item (or part of it) that isn't available / was changed —
  /// needs the passcode the admins set in ⋮ → Item cancel passcode.
  Future<void> _cancelItem(Map<String, dynamic> o, Map<String, dynamic> l, String kind, double max,
      {int? comp, String? name}) async {
    final store = _stores.firstWhere((s) => s['id'] == o['store_id'], orElse: () => const {});
    if (store['cancel_pin_set'] != true) {
      _snack('No cancel passcode is set yet — an admin can set it in ⋮ → Item cancel passcode. '
          'Or edit the order in Shopify and press refresh.');
      return;
    }
    var qty = max;
    var reason = 'Not available';
    final note = TextEditingController();
    final pin = TextEditingController();
    String? err;
    var working = false;
    await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: Text('Cancel ${kind == 'bundle' ? 'bundle' : 'item'}'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name ?? _lineName(l), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          const Text('How many:'),
          IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: qty <= 1 ? null : () => setD(() => qty -= 1)),
          Text(_q(qty), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: qty >= max ? null : () => setD(() => qty += 1)),
          Text('of ${_q(max)}', style: const TextStyle(color: AppTheme.textSecondary)),
        ]),
        DropdownButtonFormField<String>(
          value: reason, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Reason', isDense: true, border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'Not available', child: Text('Not available / out of stock')),
            DropdownMenuItem(value: 'Customer changed', child: Text('Customer asked to change / remove')),
            DropdownMenuItem(value: 'Damaged', child: Text('Damaged')),
            DropdownMenuItem(value: 'Other', child: Text('Other')),
          ],
          onChanged: (v) => setD(() => reason = v ?? 'Other'),
        ),
        const SizedBox(height: 8),
        TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional)', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(
          controller: pin, obscureText: true, keyboardType: TextInputType.number, autofocus: true,
          decoration: const InputDecoration(labelText: 'Passcode', isDense: true, border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Text(kind == 'part'
            ? 'Removed from this bundle here only — the bundle still ships from the store.'
            : 'Left out when fulfilling (stays unfulfilled in Shopify) and taken off the amount to collect. '
              'Refund / edit it in Shopify as usual.',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
      ])),
      actions: [
        TextButton(onPressed: working ? null : () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Back')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
          onPressed: working ? null : () async {
            setD(() { working = true; err = null; });
            try {
              await _call({
                'action': 'cancel_item', 'order_id': o['id'], 'line_id': l['line_id'],
                if (comp != null) 'comp': comp,
                'qty': qty, 'pin': pin.text.trim(),
                'reason': note.text.trim().isEmpty ? reason : '$reason: ${note.text.trim()}',
              });
              if (d.mounted) Navigator.of(d, rootNavigator: true).pop();
              _snack('${_q(qty)} cancelled');
              await _load(quiet: true);
            } catch (e) {
              setD(() { working = false; err = '$e'; });
            }
          },
          child: const Text('Cancel item'),
        ),
      ],
    )));
  }

  /// ⋮ → Item cancel passcode (admins), per store.
  Future<void> _pinDialog() async {
    final active = _scopeStores.isNotEmpty ? _scopeStores : _stores.where((s) => s['is_active'] == true).toList();
    if (active.isEmpty) return;
    var store = active.first;
    final pin = TextEditingController();
    String? err;
    await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: const Text('Item cancel passcode'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Needed to cancel an item while picking (not available / changed). Share it only with the people allowed to do that.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        if (active.length > 1) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: store['id'] as String, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Store', isDense: true, border: OutlineInputBorder()),
            items: [for (final s in active) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name'] ?? s['shop_domain']}'))],
            onChanged: (v) => setD(() => store = active.firstWhere((s) => s['id'] == v)),
          ),
        ],
        const SizedBox(height: 10),
        Text(store['cancel_pin_set'] == true ? 'A passcode is set. Enter a new one to change it.' : 'No passcode set yet.',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'New passcode (4–8 digits)', isDense: true, border: OutlineInputBorder())),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(err!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5))),
      ])),
      actions: [
        if (store['cancel_pin_set'] == true)
          TextButton(
            onPressed: () async {
              try {
                await _call({'action': 'set_cancel_pin', 'store_id': store['id'], 'pin': ''});
                store['cancel_pin_set'] = false;
                if (d.mounted) Navigator.of(d, rootNavigator: true).pop();
                _snack('Passcode removed — items can no longer be cancelled here');
              } catch (e) { setD(() => err = '$e'); }
            },
            child: const Text('Remove passcode', style: TextStyle(color: Colors.red)),
          ),
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(), child: const Text('Close')),
        FilledButton(
          onPressed: () async {
            final v = pin.text.trim();
            if (!RegExp(r'^\d{4,8}$').hasMatch(v)) { setD(() => err = 'Use 4 to 8 digits.'); return; }
            try {
              await _call({'action': 'set_cancel_pin', 'store_id': store['id'], 'pin': v});
              store['cancel_pin_set'] = true;
              if (d.mounted) Navigator.of(d, rootNavigator: true).pop();
              _snack('Passcode saved');
            } catch (e) { setD(() => err = '$e'); }
          },
          child: const Text('Save'),
        ),
      ],
    )));
    if (mounted) setState(() {});
  }

  Widget _lineRow(Map<String, dynamic> o, List<Map<String, dynamic>> lines, int i, bool canWork) {
    final l = lines[i];
    final qty = _num(l['qty']);
    final picked = _num(l['picked']);
    final bundle = _isBundle(l);
    final done = _lineDone(l);
    final mapped = _lineMapped(l);
    final codes = [l['sku'], l['barcode']].where((x) => x != null && '$x'.trim().isNotEmpty).join(' · ');
    final comps = bundle ? _comps(l) : const <Map<String, dynamic>>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: done ? Colors.green.withOpacity(0.05) : AppTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: done ? Colors.green.withOpacity(0.4) : AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: done ? Colors.green : AppTheme.textSecondary),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(_lineName(l), style: const TextStyle(fontWeight: FontWeight.w600))),
              if (bundle) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text('Bundle × ${_q(qty)}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.indigo)),
                ),
              ],
            ]),
            Text([
              if (mapped && !bundle && '${l['title']}' != _lineName(l)) 'Store: ${l['title']}${(l['variant_title'] ?? '') != '' && l['variant_title'] != 'Default Title' ? ' — ${l['variant_title']}' : ''}',
              if (codes.isNotEmpty) codes,
              '@ ${NumberFormat('#,##0.##').format(_num(l['price']))}',
            ].join(' · '), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            if (_num(l['cancelled']) > 0)
              Text('${_q(_num(l['cancelled']))} cancelled${_cancelReason(l)}',
                  style: const TextStyle(fontSize: 11.5, color: Colors.red, fontWeight: FontWeight.w700)),
            if (!mapped)
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact, foregroundColor: Colors.orange.shade800),
                onPressed: () => _mapProduct(o, i),
                icon: const Icon(Icons.link, size: 16),
                label: const Text('Match to a product'),
              ),
          ])),
          if (!bundle) ...[
            if (canWork) ...[
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: picked <= 0 ? null : () => _setPicked(o, i, picked - 1)),
              Text('${_q(picked)} / ${_q(qty)}', style: TextStyle(fontWeight: FontWeight.w800, color: done ? Colors.green.shade700 : null)),
              // Scan the product once to prove it's the right one; then the rest of
              // the quantity can be counted by hand. Before any scan: admins only.
              if (_isAdmin || picked >= 1)
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline, size: 18),
                    tooltip: picked >= 1 ? 'Count one more' : 'Admin: count one without scanning',
                    onPressed: done ? null : () => _setPicked(o, i, picked + 1)),
              if (picked >= 1 && !done) _fillBtn(() => _setPicked(o, i, qty), qty - picked),
            ] else
              Text('× ${_q(qty)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
          if (canWork && qty > 0) _cancelBtn(() => _cancelItem(o, l, bundle ? 'bundle' : 'item', qty)),
        ]),
        // Bundle: each product inside is scanned on its own.
        for (var j = 0; j < comps.length; j++)
          Builder(builder: (_) {
            final c = comps[j];
            final cq = _num(c['qty']);
            final cp = _num(c['picked']);
            final cd = cp >= cq;
            final p = _prodById[c['product_id']];
            return Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: Row(children: [
                Icon(cd ? Icons.check : Icons.subdirectory_arrow_right, size: 15, color: cd ? Colors.green : AppTheme.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${p?['name'] ?? 'Product'}',
                      style: TextStyle(fontSize: 12.5, color: cd ? Colors.green.shade800 : null,
                          decoration: cq == 0 ? TextDecoration.lineThrough : null)),
                  if (_num(c['cancelled']) > 0)
                    TextSpan(text: '   ${_q(_num(c['cancelled']))} cancelled',
                        style: const TextStyle(fontSize: 11.5, color: Colors.red, fontWeight: FontWeight.w700)),
                ]))),
                if (canWork) ...[
                  IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline, size: 16),
                      onPressed: cp <= 0 ? null : () => _setPicked(o, i, cp - 1, comp: j)),
                  Text('${_q(cp)} / ${_q(cq)}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: cd ? Colors.green.shade700 : null)),
                  if (_isAdmin || cp >= 1)
                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline, size: 16),
                        tooltip: cp >= 1 ? 'Count one more' : 'Admin: count one without scanning',
                        onPressed: cd ? null : () => _setPicked(o, i, cp + 1, comp: j)),
                  if (cp >= 1 && !cd) _fillBtn(() => _setPicked(o, i, cq, comp: j), cq - cp),
                  if (cq > 0) _cancelBtn(() => _cancelItem(o, l, 'part', cq, comp: j, name: '${p?['name'] ?? 'Product'}')),
                ] else
                  Text('× ${_q(cq)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
              ]),
            );
          }),
      ]),
    );
  }
}
