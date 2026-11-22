import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Which side of the books the price check reads: what we SOLD to a customer, or what we BOUGHT from a supplier.
enum PriceCheckMode { sale, purchase }

/// "Price check": pick one product and see what it was sold to this customer for (or bought from this
/// supplier for). Read-only; it only looks at existing posted invoices.
Future<void> showPriceCheck(BuildContext context,
    {required PriceCheckMode mode, required String partyId, required String partyName}) {
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: PriceCheckPanel(mode: mode, partyId: partyId, partyName: partyName),
      ),
    ),
  );
}

/// The Price check button used in both ledgers.
class PriceCheckButton extends StatelessWidget {
  const PriceCheckButton({super.key, required this.mode, required this.partyId, required this.partyName});
  final PriceCheckMode mode;
  final String partyId;
  final String partyName;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        icon: const Icon(Icons.bolt, size: 16),
        label: const Text('Price check', style: TextStyle(fontSize: 12)),
        onPressed: () => showPriceCheck(context, mode: mode, partyId: partyId, partyName: partyName),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          foregroundColor: AppTheme.primary,
          side: const BorderSide(color: AppTheme.primary),
        ),
      );
}

class _Hit {
  _Hit(this.date, this.voucher, this.qty, this.rate, this.disc);
  final DateTime? date;
  final String voucher;
  final double qty;
  final double rate;
  final double? disc; // % (sales only)
}

class PriceCheckPanel extends ConsumerStatefulWidget {
  const PriceCheckPanel({super.key, required this.mode, required this.partyId, required this.partyName});
  final PriceCheckMode mode;
  final String partyId;
  final String partyName;
  @override
  ConsumerState<PriceCheckPanel> createState() => _PriceCheckPanelState();
}

class _PriceCheckPanelState extends ConsumerState<PriceCheckPanel> {
  final _q = TextEditingController();
  final _focus = FocusNode();
  Timer? _deb;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  Map<String, dynamic>? _picked;
  bool _loading = false;
  String? _error;
  List<_Hit> _hits = [];
  int _hi = 0;

  bool get _sale => widget.mode == PriceCheckMode.sale;
  final _n = NumberFormat('#,##0.##');
  final _d = DateFormat('dd MMM yyyy');
  String _money(num v) => _n.format(v);

  @override
  void dispose() {
    _deb?.cancel();
    _q.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onType(String v) {
    _deb?.cancel();
    if (v.trim().length < 2) {
      setState(() { _results = []; _searching = false; _hi = 0; });
      return;
    }
    _deb = Timer(const Duration(milliseconds: 250), () => _search(v.trim()));
  }

  Future<void> _search(String raw) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    final s = raw.replaceAll(RegExp(r'[%_,()\\*]'), ' ').trim();
    if (s.isEmpty) return;
    setState(() => _searching = true);
    try {
      final rows = await Supabase.instance.client
          .from('products')
          .select('id, name, sku, selling_price, cost_price')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .or('name.ilike.%$s%,sku.ilike.%$s%')
          .order('name')
          .limit(12);
      if (!mounted || _q.text.trim() != raw) return;
      setState(() { _results = List<Map<String, dynamic>>.from(rows as List); _searching = false; _hi = 0; });
    } catch (e) {
      if (mounted) setState(() { _searching = false; _error = 'Search failed: $e'; });
    }
  }

  Future<void> _pick(Map<String, dynamic> p) async {
    setState(() { _picked = p; _results = []; _loading = true; _error = null; _hits = []; });
    _q.text = '${p['name']}';
    try {
      final c = Supabase.instance.client;
      final out = <_Hit>[];
      if (_sale) {
        final rows = await c
            .from('sales_invoice_items')
            .select('qty_delivered, unit_price, discount, is_foc, sales_invoices!inner(voucher_number, voucher_date, customer_id, is_voided)')
            .eq('product_id', p['id'] as String)
            .eq('sales_invoices.customer_id', widget.partyId)
            .limit(400);
        for (final r in rows as List) {
          final h = r['sales_invoices'] as Map?;
          if (h == null || h['is_voided'] == true || r['is_foc'] == true) continue;
          final rate = (r['unit_price'] as num?)?.toDouble() ?? 0;
          if (rate <= 0) continue;
          out.add(_Hit(DateTime.tryParse('${h['voucher_date']}'), '${h['voucher_number'] ?? ''}',
              (r['qty_delivered'] as num?)?.toDouble() ?? 0, rate, (r['discount'] as num?)?.toDouble() ?? 0));
        }
      } else {
        final rows = await c
            .from('purchase_invoice_items')
            .select('qty_received, unit_cost, purchase_invoices!inner(voucher_number, voucher_date, supplier_id, is_voided, is_locked)')
            .eq('product_id', p['id'] as String)
            .eq('purchase_invoices.supplier_id', widget.partyId)
            .limit(400);
        for (final r in rows as List) {
          final h = r['purchase_invoices'] as Map?;
          // posted invoices only, like the supplier ledger itself
          if (h == null || h['is_voided'] == true || h['is_locked'] != true) continue;
          final rate = (r['unit_cost'] as num?)?.toDouble() ?? 0;
          if (rate <= 0) continue;
          out.add(_Hit(DateTime.tryParse('${h['voucher_date']}'), '${h['voucher_number'] ?? ''}',
              (r['qty_received'] as num?)?.toDouble() ?? 0, rate, null));
        }
      }
      out.sort((a, b) => (b.date ?? DateTime(2000)).compareTo(a.date ?? DateTime(2000)));
      if (!mounted) return;
      setState(() { _hits = out; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load the history: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _sale ? 'What we sold this product to this customer for' : 'What we bought this product from this supplier for';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Price check · ${widget.partyName}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(title, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            ]),
          ),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        ]),
        const SizedBox(height: 14),
        Focus(
          onKeyEvent: (_, e) {
            if (e is! KeyDownEvent || _results.isEmpty) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) { setState(() => _hi = (_hi + 1) % _results.length); return KeyEventResult.handled; }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) { setState(() => _hi = (_hi - 1 + _results.length) % _results.length); return KeyEventResult.handled; }
            if (e.logicalKey == LogicalKeyboardKey.enter) { _pick(_results[_hi]); return KeyEventResult.handled; }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _q,
            focusNode: _focus,
            autofocus: true,
            onChanged: _onType,
            decoration: InputDecoration(
              hintText: 'Search product name or SKU',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searching
                  ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  : (_picked != null
                      ? TextButton(onPressed: () { setState(() { _picked = null; _hits = []; _q.clear(); }); _focus.requestFocus(); }, child: const Text('Change'))
                      : null),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(11)),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (_results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(11)),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final p = _results[i];
                return InkWell(
                  onTap: () => _pick(p),
                  child: Container(
                    color: i == _hi ? AppTheme.primary.withOpacity(0.08) : null,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Expanded(child: Text('${p['name']}', style: const TextStyle(fontSize: 13.5), overflow: TextOverflow.ellipsis)),
                      if ((p['sku'] ?? '').toString().isNotEmpty)
                        Text('${p['sku']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                    ]),
                  ),
                );
              },
            ),
          ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 12.5))),
        if (_loading) const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
        if (_picked != null && !_loading && _error == null) Flexible(child: SingleChildScrollView(child: _result())),
        if (_picked == null && _results.isEmpty && !_searching)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text('Type at least two letters of the product name or SKU.',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
          ),
      ]),
    );
  }

  Widget _result() {
    final p = _picked!;
    final unit = _sale ? 'sold' : 'bought';
    if (_hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Text('This product has not been $unit ${_sale ? 'to' : 'from'} ${widget.partyName} yet (posted, non-voided invoices only).',
            style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary)),
      );
    }
    final last = _hits.first;
    final prev = _hits.length > 1 ? _hits[1] : null;
    final five = _hits.take(5).toList();
    final avg = five.fold<double>(0, (a, h) => a + h.rate) / five.length;
    final myList = ((p['selling_price']) as num?)?.toDouble();
    Widget kpi(String label, String value, String? sub, {bool big = false, Color? subColor}) => Expanded(
          flex: big ? 3 : 2,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: big ? AppTheme.primary.withOpacity(0.07) : null,
              border: Border.all(color: big ? AppTheme.primary.withOpacity(0.35) : AppTheme.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.4)),
              const SizedBox(height: 4),
              FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                  child: Text(value, style: TextStyle(fontSize: big ? 30 : 22, fontWeight: FontWeight.w800, color: big ? AppTheme.primary : null))),
              if (sub != null) Text(sub, style: TextStyle(fontSize: 12, color: subColor ?? AppTheme.textSecondary)),
            ]),
          ),
        );
    String? chg;
    Color? chgCol;
    if (prev != null && prev.rate != 0) {
      final pct = (avg - prev.rate) / prev.rate * 100;
      chg = last.rate == prev.rate ? 'Same as previous' : '${last.rate > prev.rate ? '▲' : '▼'} ${_money((last.rate - prev.rate).abs())} vs previous (${_money(prev.rate)})';
      chgCol = last.rate > prev.rate ? Colors.red.shade700 : (last.rate < prev.rate ? Colors.green.shade700 : null);
      if (pct.isNaN) chg = null;
    }
    final k3 = _sale
        ? kpi('Current list price', myList == null ? '—' : 'Rs ${_money(myList)}',
            myList == null ? null : (last.rate == myList ? 'Same as last rate' : 'Last rate Rs ${_money((myList - last.rate).abs())} ${last.rate < myList ? 'below' : 'above'} list'))
        : kpi('Our sale price', myList == null ? '—' : 'Rs ${_money(myList)}',
            (myList != null && last.rate > 0) ? 'Margin ${_money((myList - last.rate) / myList * 100)}% at last cost' : null,
            subColor: Colors.green.shade700);
    final copy = 'Rs ${_money(last.rate)}';
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          kpi(_sale ? 'Last rate' : 'Last purchase rate', 'Rs ${_money(last.rate)}',
              '${last.date == null ? '' : _d.format(last.date!)} · qty ${_money(last.qty)} · ${last.voucher}', big: true),
          const SizedBox(width: 10),
          kpi(prev == null ? 'Only one sale' : (_sale ? 'Average (last ${five.length})' : 'Previous'),
              prev == null ? '—' : 'Rs ${_money(_sale ? avg : prev.rate)}', chg, subColor: chgCol),
          const SizedBox(width: 10),
          k3,
        ])),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(12)),
          child: Table(
            columnWidths: const {0: FlexColumnWidth(2.2), 1: FlexColumnWidth(2), 2: FlexColumnWidth(1.2), 3: FlexColumnWidth(1.4), 4: FlexColumnWidth(1.2)},
            children: [
              TableRow(decoration: BoxDecoration(color: Colors.grey.shade100), children: [
                _th('Date'), _th(_sale ? 'Invoice' : 'Bill'), _th('Qty', r: true), _th('Rate', r: true), _th(_sale ? 'Disc.' : '', r: true),
              ]),
              for (var i = 0; i < _hits.length && i < 6; i++)
                TableRow(children: [
                  _td(_hits[i].date == null ? '' : _d.format(_hits[i].date!)),
                  _td(_hits[i].voucher),
                  _td(_money(_hits[i].qty), r: true),
                  _td(_money(_hits[i].rate), r: true, bold: i == 0),
                  _td(_hits[i].disc == null ? '' : '${_money(_hits[i].disc!)}%', r: true),
                ]),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: Text('Showing the last ${_hits.length < 6 ? _hits.length : 6} of ${_hits.length} · excludes voided${_sale ? '' : ' and unposted'} invoices',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 14),
            label: Text('Copy “$copy”', style: const TextStyle(fontSize: 12)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copy));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $copy')));
            },
          ),
        ]),
      ]),
    );
  }

  Widget _th(String t, {bool r = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Text(t.toUpperCase(), textAlign: r ? TextAlign.right : TextAlign.left,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary, letterSpacing: 0.3)));
  Widget _td(String t, {bool r = false, bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Text(t, textAlign: r ? TextAlign.right : TextAlign.left,
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w800 : FontWeight.w400)));
}
