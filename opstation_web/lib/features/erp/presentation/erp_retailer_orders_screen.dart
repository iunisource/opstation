import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'dart:js_util' as js_util;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// Retailer Orders review queue.
///
/// Retailers submit from the app (`retailer_place_order`), which writes a REAL
/// sales_orders row — source='retailer', status='draft', voucher_number NULL.
/// Unlike Field Orders (which converts from its own table), this screen reviews
/// draft SOs in place. Confirming mints the voucher number and moves the order
/// into the normal SO → DO → SI pipeline.
///
/// Full parity with Field Orders: live nav badge, realtime arrival, new-order
/// chime, and editable lines before confirmation.
class ErpRetailerOrdersScreen extends ConsumerStatefulWidget {
  const ErpRetailerOrdersScreen({super.key});
  @override
  ConsumerState<ErpRetailerOrdersScreen> createState() =>
      _ErpRetailerOrdersScreenState();
}

class _ErpRetailerOrdersScreenState
    extends ConsumerState<ErpRetailerOrdersScreen> {
  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  final _client = Supabase.instance.client;
  final _money = NumberFormat('#,##0.00');
  final _df = DateFormat('d MMM yyyy');

  String _filter = 'draft';
  bool _loading = true, _saving = false;
  List<Map<String, dynamic>> _orders = [];
  final Map<String, String> _custNames = {};
  final Map<String, String> _branchNames = {};
  final Map<String, Map<String, dynamic>> _products = {};

  Map<String, dynamic>? _selected;
  List<Map<String, dynamic>> _lines = [];
  List<Map<String, dynamic>> _branches = [];
  String? _confirmBranchId;

  RealtimeChannel? _channel;
  int _newWhileAway = 0;
  bool _soundOn = true;
  bool _audioHintShown = false;

  @override
  void initState() {
    super.initState();
    _installAudio();
    _restoreSoundPref();
    _loadProducts();
    _loadBranches();
    _loadOrders();
    _subscribe();
  }

  @override
  void dispose() {
    final ch = _channel;
    if (ch != null) _client.removeChannel(ch);
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  double _d(dynamic v) => (v as num?)?.toDouble() ?? 0;

  // ── Realtime ───────────────────────────────────────────────────────────────
  // PostgresChangeFilter allows exactly one eq, so we filter on org_id and
  // screen for source/status inside the callback.
  void _subscribe() {
    final orgId = _orgId;
    if (orgId == null) return;
    _channel = _client
        .channel('retailer_orders_$orgId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'sales_orders',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'org_id',
              value: orgId),
          callback: (payload) => _onNewOrder(payload.newRecord),
        )
        .subscribe();
  }

  Future<void> _onNewOrder(Map<String, dynamic> row) async {
    if ((row['source'] as String?) != 'retailer') return;
    if ((row['status'] as String?) != 'draft') return;
    _playNewOrderTone();
    _maybeWarnAudioBlocked();
    ref.invalidate(retailerOrderPendingCountProvider);
    if (_filter == 'draft') {
      // The header row arrives before its lines are written, so a prepend would
      // render Rs. 0.00 and then silently correct itself. Reload instead.
      _loadOrders();
    } else {
      if (!mounted) return;
      setState(() => _newWhileAway += 1);
    }
  }

  // ── New-order chime (web) ──────────────────────────────────────────────────
  // Shares the single cached AudioContext that Field Orders installs
  // (window.__foAudio). Creating a second context would count against the
  // browser's ~6-per-page cap and eventually kill sound on BOTH screens. Own
  // localStorage key, so the two toggles stay independent.
  static const String _audioBootstrapJs =
      '(function(){'
      'if(window.__foAudio2)return;'
      'var F=window.AudioContext||window.webkitAudioContext;var ctx=null;'
      'function get(){if(!ctx){try{ctx=new F();}catch(e){return null;}}return ctx;}'
      'function unlock(){var c=get();if(c&&c.state==="suspended"){try{c.resume();}catch(e){}}}'
      'function beep(freq,dur,type,when,gain){var c=get();if(!c)return;'
      'if(c.state==="suspended"){try{c.resume();}catch(e){}}'
      'try{var t0=c.currentTime+(when||0);var o=c.createOscillator();var g=c.createGain();'
      'o.connect(g);g.connect(c.destination);o.type=type||"sine";o.frequency.value=freq;'
      'g.gain.setValueAtTime(gain||0.3,t0);g.gain.exponentialRampToValueAtTime(0.001,t0+dur);'
      'o.start(t0);o.stop(t0+dur);}catch(e){}}'
      'function state(){var c=get();return c?c.state:"none";}'
      '["pointerdown","keydown","touchstart","mousedown"].forEach(function(ev){'
      'window.addEventListener(ev,unlock,{passive:true});});'
      'window.__foAudio2={unlock:unlock,beep:beep,state:state};window.__foAudio=window.__foAudio2;'
      '})();';

  void _installAudio() {
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [_audioBootstrapJs]);
    } catch (_) {}
  }

  void _unlockAudio() {
    try {
      js_util.callMethod(js_util.globalThis, 'eval',
          ['window.__foAudio&&window.__foAudio.unlock()']);
    } catch (_) {}
  }

  void _restoreSoundPref() {
    try {
      final v = js_util.callMethod(js_util.globalThis, 'eval',
          ['window.localStorage.getItem("ro_sound")']);
      if (v == 'off') _soundOn = false;
    } catch (_) {}
  }

  void _toggleSound() {
    setState(() => _soundOn = !_soundOn);
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [
        'window.localStorage.setItem("ro_sound","${_soundOn ? 'on' : 'off'}")'
      ]);
    } catch (_) {}
    if (_soundOn) {
      _audioHintShown = true; // arming IS the user gesture
      _unlockAudio();
      try {
        js_util.callMethod(js_util.globalThis, 'eval',
            ['window.__foAudio&&window.__foAudio.beep(880,0.12,"sine",0)']);
      } catch (_) {}
    }
  }

  /// Rising two-tone — deliberately distinct from the Field Orders ding-dong and
  /// the POS chime, so whoever is watching can tell WHICH queue moved without
  /// looking at the screen.
  void _playNewOrderTone() {
    if (!_soundOn) return;
    try {
      js_util.callMethod(js_util.globalThis, 'eval', [
        'if(window.__foAudio){window.__foAudio.beep(523.25,0.45,"triangle",0,0.9);'
        'window.__foAudio.beep(783.99,0.75,"triangle",0.26,0.9);}'
      ]);
    } catch (_) {}
  }

  void _maybeWarnAudioBlocked() {
    if (_audioHintShown || !_soundOn) return;
    try {
      final s = js_util.callMethod(js_util.globalThis, 'eval', [
        '(window.__foAudio&&window.__foAudio.state&&window.__foAudio.state())||"none"'
      ]);
      if (s == 'suspended' || s == 'none') {
        _audioHintShown = true;
        if (mounted) {
          _snack('🔔 Click anywhere on the page once to enable the new-order sound.');
        }
      }
    } catch (_) {}
  }

  // ── Loads ──────────────────────────────────────────────────────────────────
  Future<void> _loadBranches() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final b = await _client
          .from('branches')
          .select('id, name')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        _branches = List<Map<String, dynamic>>.from(b);
        for (final br in _branches) {
          _branchNames[br['id'] as String] = '${br['name'] ?? '—'}';
        }
      });
    } catch (_) {}
  }

  Future<void> _loadProducts() async {
    final orgId = _orgId;
    if (orgId == null) return;
    try {
      final p = await _client
          .from('products')
          .select('id, name, sku, selling_price, base_uom_id')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        for (final r in p as List) {
          _products[r['id'] as String] = Map<String, dynamic>.from(r as Map);
        }
      });
    } catch (_) {}
  }

  Future<void> _loadOrders() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      var q = _client
          .from('sales_orders')
          .select()
          .eq('org_id', orgId)
          .eq('source', 'retailer');
      if (_filter != 'all') q = q.eq('status', _filter);

      final rows = List<Map<String, dynamic>>.from(
          await q.order('created_at', ascending: false));

      final custIds = <String>{
        for (final o in rows)
          if (o['customer_id'] != null) o['customer_id'] as String
      };
      if (custIds.isNotEmpty) {
        final cs = await _client
            .from('customers')
            .select('id, shop_name')
            .inFilter('id', custIds.toList());
        for (final c in cs as List) {
          _custNames[c['id'] as String] = '${c['shop_name'] ?? '—'}';
        }
      }

      // sales_orders has NO total column anywhere in this system — order value
      // is always derived from its lines.
      final ids = [for (final o in rows) o['id'] as String];
      final totals = <String, double>{};
      final counts = <String, int>{};
      if (ids.isNotEmpty) {
        final items = await _client
            .from('sales_order_items')
            .select('sales_order_id, quantity, unit_price, discount')
            .inFilter('sales_order_id', ids);
        for (final it in items as List) {
          final id = it['sales_order_id'] as String?;
          if (id == null) continue;
          totals[id] = (totals[id] ?? 0) +
              (_d(it['quantity']) * _d(it['unit_price']) - _d(it['discount']));
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }
      for (final o in rows) {
        o['_total'] = totals[o['id'] as String] ?? 0;
        o['_lines'] = counts[o['id'] as String] ?? 0;
      }

      if (!mounted) return;
      setState(() {
        _orders = rows;
        _loading = false;
        if (_filter == 'draft') _newWhileAway = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _snack('Load failed: $e');
    }
  }

  Future<void> _openOrder(Map<String, dynamic> o) async {
    setState(() {
      _selected = o;
      _lines = [];
      _confirmBranchId = o['branch_id'] as String?;
    });
    try {
      final items = await _client
          .from('sales_order_items')
          .select('id, product_id, quantity, unit_price, discount, uom_id')
          .eq('sales_order_id', o['id']);
      if (!mounted) return;
      setState(() => _lines = List<Map<String, dynamic>>.from(items));
    } catch (e) {
      _snack('Could not load lines: $e');
    }
  }

  double get _selTotal => _lines.fold<double>(
      0,
      (s, l) =>
          s + (_d(l['quantity']) * _d(l['unit_price']) - _d(l['discount'])));

  // ── Line editing ───────────────────────────────────────────────────────────
  void _addLine() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (c) => StatefulBuilder(builder: (c, setS) {
        final q = ctrl.text.trim().toLowerCase();
        final matches = _products.values
            .where((p) =>
                q.isEmpty ||
                '${p['name']}'.toLowerCase().contains(q) ||
                '${p['sku'] ?? ''}'.toLowerCase().contains(q))
            .take(50)
            .toList();
        return AlertDialog(
          title: const Text('Add product'),
          content: SizedBox(
            width: 460,
            height: 420,
            child: Column(children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Search name or SKU…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true),
                onChanged: (_) => setS(() {}),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (_, i) {
                    final p = matches[i];
                    return ListTile(
                      dense: true,
                      title: Text('${p['name']}',
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                          'Rs. ${_money.format(_d(p['selling_price']))}',
                          style: const TextStyle(fontSize: 11)),
                      onTap: () {
                        setState(() {
                          _lines.add({
                            'id': null,
                            'product_id': p['id'],
                            'quantity': 1.0,
                            'unit_price': _d(p['selling_price']),
                            'discount': 0.0,
                            'uom_id': p['base_uom_id'],
                          });
                        });
                        Navigator.pop(c);
                      },
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('Close')),
          ],
        );
      }),
    );
  }

  // ── Confirm / Reject ───────────────────────────────────────────────────────
  /// Rewrites the lines (they may have been edited), preserves the retailer's
  /// ORIGINAL request in `remarks`, mints the voucher number (the BEFORE INSERT
  /// trigger cannot — these rows were deliberately created with a NULL number),
  /// and confirms into the normal SO flow.
  ///
  /// The remarks note matters: a shopkeeper who asks for 10 and is confirmed for
  /// 6 otherwise has no record of what they actually requested, and nothing in
  /// the system would show the order was changed.
  Future<void> _confirm() async {
    final o = _selected;
    final orgId = _orgId;
    if (o == null || orgId == null) return;
    if (_lines.isEmpty) {
      _snack('An order must have at least one line.');
      return;
    }
    for (final l in _lines) {
      if (_d(l['quantity']) <= 0) {
        _snack('Quantities must be greater than zero.');
        return;
      }
      if (l['uom_id'] == null) {
        _snack('A line is missing its unit of measure.');
        return;
      }
    }
    setState(() => _saving = true);
    final soId = o['id'] as String;
    try {
      final orig = await _client
          .from('sales_order_items')
          .select('product_id, quantity, unit_price')
          .eq('sales_order_id', soId);
      final origNote = [
        for (final l in orig as List)
          '${_products[l['product_id']]?['name'] ?? l['product_id']}'
              ' x${_d(l['quantity']).toStringAsFixed(0)}'
              ' @${_money.format(_d(l['unit_price']))}'
      ].join('; ');

      await _client
          .from('sales_order_items')
          .delete()
          .eq('sales_order_id', soId);
      await _client.from('sales_order_items').insert([
        for (final l in _lines)
          {
            'sales_order_id': soId,
            'product_id': l['product_id'],
            'uom_id': l['uom_id'],
            'quantity': _d(l['quantity']),
            'unit_price': _d(l['unit_price']),
            'discount': _d(l['discount']),
          }
      ]);

      final patch = <String, dynamic>{
        'status': 'confirmed',
        'branch_id': _confirmBranchId ?? o['branch_id'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      final existing = (o['remarks'] as String?)?.trim() ?? '';
      if (origNote.isNotEmpty && !existing.contains('Retailer requested')) {
        patch['remarks'] = [
          if (existing.isNotEmpty) existing,
          'Retailer requested: $origNote',
        ].join('\n');
      }

      final hasVoucher = (o['voucher_number'] as String?)?.isNotEmpty == true;
      if (!hasVoucher) {
        try {
          final vnum = await _client.rpc('next_voucher_number', params: {
            'p_org_id': orgId,
            'p_branch_id': patch['branch_id'],
            'p_type': 'SO',
            'p_year': DateTime.now().year,
          });
          if (vnum != null) patch['voucher_number'] = vnum.toString();
        } catch (e) {
          _snack('Could not assign a voucher number: $e');
          setState(() => _saving = false);
          return;
        }
      }

      await _client.from('sales_orders').update(patch).eq('id', soId);
      ref.invalidate(retailerOrderPendingCountProvider);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _selected = null;
      });
      final v = patch['voucher_number'];
      _snack(v != null ? 'Order confirmed — $v' : 'Order confirmed.');
      _loadOrders();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Confirm failed: $e');
    }
  }

  Future<void> _reject() async {
    final o = _selected;
    if (o == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reject order'),
        content: Text(
            'Reject this order from ${_custNames[o['customer_id']] ?? '—'}?\n\n'
            'It stays visible to the retailer, marked rejected. Nothing is posted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await _client.from('sales_orders').update({
        'status': 'rejected',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', o['id']);
      ref.invalidate(retailerOrderPendingCountProvider);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _selected = null;
      });
      _snack('Order rejected.');
      _loadOrders();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Reject failed: $e');
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Retailer Orders',
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4)),
          const SizedBox(width: 18),
          _chip('draft', 'Pending'),
          const SizedBox(width: 8),
          _chip('confirmed', 'Confirmed'),
          const SizedBox(width: 8),
          _chip('rejected', 'Rejected'),
          const SizedBox(width: 8),
          _chip('all', 'All'),
          const Spacer(),
          IconButton(
            tooltip: _soundOn ? 'New-order sound: on' : 'New-order sound: off',
            icon: Icon(_soundOn ? Icons.volume_up : Icons.volume_off,
                color: _soundOn ? AppTheme.primary : AppTheme.textSecondary),
            onPressed: _toggleSound,
          ),
          IconButton(
              onPressed: _loadOrders,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh'),
        ]),
        const SizedBox(height: 2),
        const Text(
            'Orders placed by retailers from the app. Review, adjust if needed, then confirm to move into the Sales Order flow.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        const SizedBox(height: 20),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 5, child: _list()),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: _detail()),
                ]),
        ),
      ]),
    );
  }

  Widget _chip(String value, String label) {
    final on = _filter == value;
    final badge = value == 'draft' && _newWhileAway > 0 && !on;
    return InkWell(
      onTap: () {
        setState(() {
          _filter = value;
          _selected = null;
          if (value == 'draft') _newWhileAway = 0;
        });
        _loadOrders();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: on ? AppTheme.primary : Colors.transparent,
          border: Border.all(color: on ? AppTheme.primary : AppTheme.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: on ? Colors.white : AppTheme.textSecondary)),
          if (badge) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                  color: AppTheme.danger,
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$_newWhileAway',
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w800)),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _list() {
    if (_orders.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inbox_outlined,
              size: 34, color: AppTheme.textSecondary),
          const SizedBox(height: 8),
          Text(
            _filter == 'draft'
                ? 'No retailer orders awaiting review.'
                : 'Nothing here.',
            style: const TextStyle(color: AppTheme.textSecondary),
          ),
        ]),
      );
    }
    return ListView.separated(
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final o = _orders[i];
        final sel = _selected?['id'] == o['id'];
        return InkWell(
          onTap: () => _openOrder(o),
          child: Container(
            color: sel ? AppTheme.primary.withValues(alpha: 0.06) : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_custNames[o['customer_id']] ?? '—'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        o['voucher_number'] ?? 'unnumbered',
                        _branchNames[o['branch_id']] ?? '—',
                        if (o['voucher_date'] != null)
                          _df.format(DateTime.parse('${o['voucher_date']}')),
                      ].join('  •  '),
                      style: const TextStyle(
                          fontSize: 11.5, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text('${o['_lines']} lines',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ),
              Expanded(
                flex: 2,
                child: Text('Rs. ${_money.format(o['_total'])}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 12),
              _statusChip('${o['status'] ?? ''}'),
            ]),
          ),
        );
      },
    );
  }

  Widget _statusChip(String s) {
    Color c;
    String label = s;
    switch (s.toLowerCase()) {
      case 'draft':
        c = Colors.orange;
        label = 'pending';
        break;
      case 'rejected':
        c = AppTheme.danger;
        break;
      case 'confirmed':
        c = AppTheme.primary;
        break;
      default:
        c = Colors.teal;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: c.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style:
              TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _detail() {
    final o = _selected;
    if (o == null) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: const Center(
          child: Text('Select an order to review',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }
    final pending = '${o['status']}' == 'draft';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_custNames[o['customer_id']] ?? '—'}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('${o['voucher_number'] ?? 'unnumbered'}',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ),
            _statusChip('${o['status']}'),
          ]),
        ),
        if (pending && _branches.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: DropdownButtonFormField<String>(
              value: _confirmBranchId,
              isExpanded: true,
              decoration:
                  const InputDecoration(labelText: 'Branch', isDense: true),
              items: [
                for (final b in _branches)
                  DropdownMenuItem(
                      value: b['id'] as String, child: Text('${b['name']}')),
              ],
              onChanged: (v) => setState(() => _confirmBranchId = v),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _lines.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _lines.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final l = _lines[i];
                    final p = _products[l['product_id']];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Row(children: [
                        Expanded(
                          flex: 4,
                          child: Text('${p?['name'] ?? l['product_id']}',
                              style: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w600)),
                        ),
                        SizedBox(
                          width: 60,
                          child: TextFormField(
                            key: ValueKey('q${l['id'] ?? i}'),
                            initialValue: _d(l['quantity']).toStringAsFixed(0),
                            enabled: pending,
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5),
                            decoration: const InputDecoration(
                                isDense: true, labelText: 'Qty'),
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setState(
                                () => l['quantity'] = double.tryParse(v) ?? 0),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 86,
                          child: TextFormField(
                            key: ValueKey('p${l['id'] ?? i}'),
                            initialValue: _d(l['unit_price']).toStringAsFixed(2),
                            enabled: pending,
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12.5),
                            decoration: const InputDecoration(
                                isDense: true, labelText: 'Price'),
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setState(() =>
                                l['unit_price'] = double.tryParse(v) ?? 0),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 90,
                          child: Text(
                            'Rs. ${_money.format(_d(l['quantity']) * _d(l['unit_price']) - _d(l['discount']))}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (pending)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close,
                                size: 16, color: AppTheme.textSecondary),
                            onPressed: () => setState(() => _lines.removeAt(i)),
                          ),
                      ]),
                    );
                  },
                ),
        ),
        if (pending)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 17),
                label:
                    const Text('Add product', style: TextStyle(fontSize: 12.5)),
                onPressed: _addLine,
              ),
            ),
          ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text('Rs. ${_money.format(_selTotal)}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
              ],
            ),
            if (pending) ...[
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.close, size: 17),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      side: BorderSide(
                          color: AppTheme.danger.withValues(alpha: 0.4)),
                      minimumSize: const Size(0, 44),
                    ),
                    onPressed: _saving ? null : _reject,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(_saving ? 'Working…' : 'Confirm Order'),
                    style:
                        ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: _saving ? null : _confirm,
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                "Confirming assigns a voucher number and moves this into the Sales Order flow. If you change the lines, the retailer's original request is kept in the order remarks.",
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}
