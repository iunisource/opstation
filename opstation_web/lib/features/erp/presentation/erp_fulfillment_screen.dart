// ignore_for_file: deprecated_member_use
import 'dart:async';
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
import 'shop_product_matching.dart';

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
              .select('id, name, sku, barcode, base_uom_id, product_main_group').eq('org_id', org).eq('is_active', true).order('name').limit(10000));
          _prodById = {for (final p in _products) p['id'] as String: p};
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _stores = List<Map<String, dynamic>>.from(stores);
        _orders = List<Map<String, dynamic>>.from(orders);
        _loading = false;
      });
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
    return _orders.where((o) {
      final st = o['status'] as String? ?? 'new';
      final okF = switch (_filter) {
        'open' => st == 'new' || st == 'picking' || st == 'packed',
        'all' => true,
        _ => st == _filter,
      };
      if (!okF) return false;
      if (_storeFilter != 'all' && o['store_id'] != _storeFilter) return false;
      if (q.isEmpty) return true;
      return '${o['order_no']} ${o['customer_name']} ${o['phone']} ${o['email']}'.toLowerCase().contains(q);
    }).toList();
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

  Future<void> _syncNow() async {
    final stores = _stores.where((s) => s['is_active'] == true && (_storeFilter == 'all' || s['id'] == _storeFilter)).toList();
    if (stores.isEmpty) { _snack('No connected store.'); return; }
    setState(() => _busy = true);
    var total = 0;
    final problems = <String>[];
    for (final s in stores) {
      try {
        final r = await _call({'action': 'sync', 'store_id': s['id']});
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
    setState(() {
      o['lines'] = lines;
      if (status != null) o['status'] = status;
    });
    await Supabase.instance.client.from('shop_orders').update(upd).eq('id', o['id']);
  }

  bool _prodMatches(String? pid, String c) {
    final p = _prodById[pid];
    if (p == null || c.isEmpty) return false;
    for (final v in [p['barcode'], p['sku']]) {
      if ('${v ?? ''}'.trim().toLowerCase() == c) return true;
    }
    return false;
  }

  bool _lineMatches(Map<String, dynamic> l, String code) {
    final c = code.trim().toLowerCase();
    if (c.isEmpty) return false;
    if (_prodMatches(l['product_id'] as String?, c)) return true;
    return [l['barcode'], l['sku']].any((v) => '${v ?? ''}'.trim().toLowerCase() == c);
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
      } else if (_lineMatches(lines[i], code)) {
        targets.add((i, null));
      }
    }
    if (targets.isEmpty) return ScanOutcome(false, 'Not on this order: $code');
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
    final lines = _lines(o);
    if (comp != null) {
      final cs = _comps(lines[i]);
      cs[comp]['picked'] = v.clamp(0, _num(cs[comp]['qty']));
      lines[i]['components'] = cs;
    } else {
      lines[i]['picked'] = v.clamp(0, _num(lines[i]['qty']));
    }
    await _saveLines(o, lines, status: (o['status'] == 'new' && v > 0) ? 'picking' : null);
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
          ? 'Auto-fulfil ON — an order is packed and fulfilled in the store as soon as its last item is scanned'
          : 'Auto-fulfil OFF — press Packed / Fulfil yourself');
    } catch (e) {
      setState(() { for (final s in scope) { s['auto_fulfil'] = !on; } });
      _snack('Could not change it: $e');
    }
  }

  /// Every item scanned right + auto-fulfil on → pack and fulfil in the store.
  Future<void> _autoFulfil(Map<String, dynamic> o) async {
    final id = o['id'] as String;
    if (_autoBusy.contains(id) || !mounted) return;
    setState(() => _autoBusy.add(id));
    final me = ref.read(currentUserProvider);
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await Supabase.instance.client.from('shop_orders').update({
        'status': 'packed', 'packed_at': now, 'packed_by_name': me?.name, 'updated_at': now,
      }).eq('id', id);
      final r = await _call({'action': 'fulfill', 'order_id': id, 'notify': true});
      ScanFeedback.done();
      _snack('✓ ${o['order_no'] ?? 'Order'} fulfilled automatically${r['already'] == true ? ' (it was already fulfilled in the store)' : ''}');
    } catch (e) {
      if (mounted) ScanFeedback.wrong(context);
      _snack('${o['order_no'] ?? 'Order'} was NOT fulfilled: $e');
    } finally {
      if (mounted) setState(() => _autoBusy.remove(id));
      await _load(quiet: true);
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

  Future<void> _fulfil(Map<String, dynamic> o) async {
    final company = TextEditingController(text: o['tracking_company'] as String? ?? '');
    final number = TextEditingController(text: o['tracking_number'] as String? ?? '');
    final url = TextEditingController(text: o['tracking_url'] as String? ?? '');
    var notify = true;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, setD) => AlertDialog(
      title: Text('Fulfil ${o['order_no'] ?? ''}'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('The order is marked fulfilled in the store. With tracking filled in, the customer gets it by email.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 12),
        Autocomplete<String>(
          initialValue: TextEditingValue(text: company.text),
          optionsBuilder: (v) => const ['TCS', 'Leopards', 'PostEx', 'M&P', 'Trax', 'BlueEx', 'Call Courier', 'Rider', 'DHL', 'Pakistan Post']
              .where((c) => c.toLowerCase().contains(v.text.toLowerCase())),
          onSelected: (v) => company.text = v,
          fieldViewBuilder: (ctx, c, f, _) => TextField(controller: c, focusNode: f,
              onChanged: (v) => company.text = v,
              decoration: const InputDecoration(labelText: 'Courier', isDense: true, border: OutlineInputBorder())),
        ),
        const SizedBox(height: 10),
        TextField(controller: number, decoration: const InputDecoration(labelText: 'Tracking number', isDense: true, border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: url, decoration: const InputDecoration(labelText: 'Tracking link (optional)', isDense: true, border: OutlineInputBorder())),
        SwitchListTile(
          contentPadding: EdgeInsets.zero, dense: true,
          title: const Text('Email the customer', style: TextStyle(fontSize: 13)),
          value: notify, onChanged: (v) => setD(() => notify = v),
        ),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.of(d, rootNavigator: true).pop(false), child: const Text('Cancel')),
        FilledButton.icon(icon: const Icon(Icons.local_shipping_outlined, size: 18),
            onPressed: () => Navigator.of(d, rootNavigator: true).pop(true), label: const Text('Fulfil')),
      ],
    )));
    if (ok != true) return;
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
    } catch (e) {
      _snack('Not fulfilled: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load(quiet: true);
    }
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

  // ── UI ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 900;
    final sel = _sel;
    final showDetail = narrow && sel != null;
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(narrow ? 10 : 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (showDetail)
            IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _selId = null)),
          const Expanded(child: Text('Fulfillment', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800))),
          IconButton(
            tooltip: 'Sync orders now',
            onPressed: _busy ? null : _syncNow,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          if (_scopeStores.isNotEmpty) ...[
            Tooltip(
              message: 'When on, an order is packed and fulfilled in the store automatically '
                  'as soon as every item has been scanned right.',
              child: Container(
                padding: const EdgeInsets.only(left: 10, right: 2),
                decoration: BoxDecoration(
                  color: _scopeStores.every((s) => s['auto_fulfil'] == true) ? Colors.green.withOpacity(0.08) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _scopeStores.every((s) => s['auto_fulfil'] == true) ? Colors.green : AppTheme.border),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.bolt, size: 16),
                  if (!narrow) ...[
                    const SizedBox(width: 4),
                    const Text('Auto-fulfil', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                  Switch(
                    value: _scopeStores.every((s) => s['auto_fulfil'] == true),
                    onChanged: _setAuto,
                  ),
                ]),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (_stores.any((s) => s['is_active'] == true)) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Match products'),
              onPressed: _openMatching,
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.storefront_outlined, size: 18),
            label: Text(_stores.isEmpty ? 'Connect store' : 'Stores (${_stores.where((s) => s['is_active'] == true).length})'),
            onPressed: () => _stores.isEmpty && _isAdmin ? _connectDialog() : _storesDialog(),
          ),
        ]),
        const Text('Orders from your online store(s): scan to pick, pack, and fulfil with tracking.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 14),
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
                  : narrow
                      ? (showDetail ? _detail(sel) : _list())
                      : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          SizedBox(width: 380, child: _list()),
                          const SizedBox(width: 16),
                          Expanded(child: sel == null
                              ? Container(
                                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: AppTheme.border)),
                                  child: const Center(child: Text('Select an order', style: TextStyle(color: AppTheme.textSecondary))))
                              : _detail(sel)),
                        ]),
        ),
      ]),
    );
  }

  Widget _list() {
    final rows = _visible;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Search order no, customer, phone…', prefixIcon: Icon(Icons.search), isDense: true),
              onChanged: (v) => setState(() => _search = v),
            ),
            const SizedBox(height: 8),
            if (_stores.length > 1)
              DropdownButtonFormField<String>(
                value: _storeFilter, isExpanded: true,
                decoration: const InputDecoration(labelText: 'Store', isDense: true),
                items: [
                  const DropdownMenuItem(value: 'all', child: Text('All stores')),
                  for (final s in _stores) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name'] ?? s['shop_domain']}')),
                ],
                onChanged: (v) => setState(() => _storeFilter = v ?? 'all'),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final f in const ['open', 'new', 'picking', 'packed', 'fulfilled', 'cancelled', 'all'])
                ChoiceChip(
                  label: Text(f == 'open' ? 'To do (${_count('open')})'
                      : f == 'all' ? 'All' : '${_statusLabels[f]} (${_count(f)})', style: const TextStyle(fontSize: 12)),
                  selected: _filter == f,
                  onSelected: (_) => setState(() => _filter = f),
                ),
            ]),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('No orders here.', style: TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final o = rows[i];
                    final st = o['status'] as String? ?? 'new';
                    final lines = _lines(o);
                    final unmapped = lines.where((l) => !_lineMapped(l)).length;
                    final placed = DateTime.tryParse('${o['placed_at'] ?? ''}')?.toLocal();
                    return ListTile(
                      selected: o['id'] == _selId,
                      selectedTileColor: AppTheme.primary.withOpacity(0.06),
                      onTap: () => setState(() => _selId = o['id'] as String),
                      title: Row(children: [
                        Text('${o['order_no'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        _chip(st),
                        if (unmapped > 0) ...[
                          const SizedBox(width: 6),
                          const Tooltip(message: 'Has items not matched to a product',
                              child: Icon(Icons.link_off, size: 15, color: Colors.orange)),
                        ],
                        const Spacer(),
                        Text(_money(o), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                      ]),
                      subtitle: Text([
                        '${o['customer_name'] ?? '—'}',
                        '${lines.length} item${lines.length == 1 ? '' : 's'}',
                        if (placed != null) DateFormat('d MMM, HH:mm').format(placed),
                        if (_stores.length > 1) _storeName(o['store_id'] as String?),
                      ].join(' · '), style: const TextStyle(fontSize: 11.5)),
                    );
                  }),
        ),
      ]),
    );
  }

  Widget _detail(Map<String, dynamic> o) {
    final st = o['status'] as String? ?? 'new';
    final lines = _lines(o);
    final ship = Map<String, dynamic>.from((o['ship_to'] as Map?) ?? const {});
    final address = [ship['address1'], ship['address2'], ship['city'], ship['province'], ship['zip'], ship['country']]
        .where((x) => x != null && '$x'.trim().isNotEmpty).join(', ');
    final placed = DateTime.tryParse('${o['placed_at'] ?? ''}')?.toLocal();
    final pickedAll = lines.isNotEmpty && lines.every(_lineDone);
    final canWork = st != 'fulfilled' && st != 'cancelled';
    final paid = '${o['financial_status'] ?? ''}'.toUpperCase();
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.border)),
      child: ListView(padding: const EdgeInsets.all(18), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${o['order_no'] ?? ''}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
              _chip(st),
            ]),
            Text([
              _storeName(o['store_id'] as String?),
              if (placed != null) DateFormat('d MMM yyyy, HH:mm').format(placed),
            ].join(' · '), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ])),
          IconButton(tooltip: 'Refresh from the store', icon: const Icon(Icons.refresh),
              onPressed: _busy ? null : () async {
                try { await _call({'action': 'refresh_order', 'order_id': o['id']}); await _load(quiet: true); }
                catch (e) { _snack('$e'); }
              }),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 24, runSpacing: 10, children: [
          _kv('Customer', '${o['customer_name'] ?? '—'}'),
          _kv('Phone', '${o['phone'] ?? '—'}'),
          if ((o['email'] as String?)?.isNotEmpty == true) _kv('Email', '${o['email']}'),
          _kv('Payment', [
            paid == 'PAID' ? 'Paid' : (paid == 'PENDING' ? 'Not paid (COD?)' : (paid.isEmpty ? '—' : paid[0] + paid.substring(1).toLowerCase())),
            if ((o['payment_methods'] as String?)?.isNotEmpty == true) '${o['payment_methods']}',
          ].join(' · ')),
          _kv('Total', _money(o)),
        ]),
        if (address.isNotEmpty) ...[const SizedBox(height: 10), _kv('Ship to', address)],
        if ((o['note'] as String?)?.isNotEmpty == true) ...[const SizedBox(height: 10), _kv('Customer note', '${o['note']}')],
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
        const SizedBox(height: 16),
        if (canWork) ...[
          ScanBar(onScan: _onScan, hint: 'Scan each item to pick it', strongFeedback: true),
          if (_autoBusy.contains(o['id']))
            _banner(Colors.blue, Icons.local_shipping_outlined, 'All items scanned — fulfilling in the store…'),
          const SizedBox(height: 12),
        ],
        const Text('Items', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        for (var i = 0; i < lines.length; i++) _lineRow(o, lines, i, canWork),
        const SizedBox(height: 16),
        if (canWork)
          Wrap(spacing: 10, runSpacing: 10, children: [
            if (st != 'packed')
              OutlinedButton.icon(
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Mark packed'),
                onPressed: _busy || !pickedAll ? null : () => _markPacked(o),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.local_shipping_outlined, size: 18),
              label: const Text('Fulfil in store'),
              onPressed: _busy || !pickedAll ? null : () => _fulfil(o),
            ),
            if (!pickedAll)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_autoOn(o['store_id'] as String?)
                    ? 'Auto-fulfil is on: the order is fulfilled as soon as the last item is scanned.'
                    : 'Scan every item to enable Packed and Fulfil.',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              ),
            if (st == 'picking' || st == 'packed')
              TextButton(
                onPressed: _busy ? null : () async {
                  final ls = _lines(o);
                  for (final l in ls) {
                    l['picked'] = 0;
                    if (_isBundle(l)) l['components'] = [for (final c in _comps(l)) {...c, 'picked': 0}];
                  }
                  await _saveLines(o, ls, status: 'new');
                },
                child: const Text('Restart picking'),
              ),
          ]),
        if (o['packed_at'] != null)
          Padding(padding: const EdgeInsets.only(top: 10),
              child: Text('Packed ${o['packed_by_name'] != null ? 'by ${o['packed_by_name']} ' : ''}'
                  '${DateFormat('d MMM, HH:mm').format(DateTime.parse(o['packed_at'] as String).toLocal())}',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
      ]),
    );
  }

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      ]);

  Widget _banner(Color c, IconData icon, String text) => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: c.withOpacity(0.07), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.35))),
        child: Row(children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.withOpacity(0.95)))),
        ]),
      );

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
              // Picking is by scanning; adding by hand is an admin override.
              if (_isAdmin)
                IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline, size: 18),
                    tooltip: 'Admin: count one without scanning',
                    onPressed: done ? null : () => _setPicked(o, i, picked + 1)),
            ] else
              Text('× ${_q(qty)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
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
                Expanded(child: Text('${p?['name'] ?? 'Product'}',
                    style: TextStyle(fontSize: 12.5, color: cd ? Colors.green.shade800 : null))),
                if (canWork) ...[
                  IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove_circle_outline, size: 16),
                      onPressed: cp <= 0 ? null : () => _setPicked(o, i, cp - 1, comp: j)),
                  Text('${_q(cp)} / ${_q(cq)}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: cd ? Colors.green.shade700 : null)),
                  if (_isAdmin)
                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add_circle_outline, size: 16),
                        tooltip: 'Admin: count one without scanning',
                        onPressed: cd ? null : () => _setPicked(o, i, cp + 1, comp: j)),
                ] else
                  Text('× ${_q(cq)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5)),
              ]),
            );
          }),
      ]),
    );
  }
}
