import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';
import '../../../core/sync/sync_controller.dart';
import '../data/field_order_repository.dart';

/// Salesperson order entry. Opened two ways (both already wired in the app):
///  - home FAB:      OrderCreateModal.show(context)                      -> search customer
///  - customer tile: OrderCreateModal.show(context, customerId:…, …)     -> customer preset
/// Adds products (price read-only) + quantities and submits a field order
/// (status 'submitted') for admin review on web. Online-only write.
class OrderCreateModal {
  static Future<void> show(
    BuildContext context, {
    String? customerId,
    String? customerName,
    String? customerCode,
  }) {
    return Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _OrderCreatePage(
        presetCustomerId: customerId,
        presetCustomerName: customerName,
        presetCustomerCode: customerCode,
      ),
    ));
  }
}

class _OrderCreatePage extends ConsumerStatefulWidget {
  final String? presetCustomerId, presetCustomerName, presetCustomerCode;
  const _OrderCreatePage({this.presetCustomerId, this.presetCustomerName, this.presetCustomerCode});
  @override
  ConsumerState<_OrderCreatePage> createState() => _OrderCreatePageState();
}

class _OrderCreatePageState extends ConsumerState<_OrderCreatePage> {
  Map<String, dynamic>? _customer; // {id, shop_name, code}
  final List<Map<String, dynamic>> _lines = [];
  bool _offersLoading = false;
  final _notesCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.presetCustomerId != null) {
      _customer = {
        'id': widget.presetCustomerId,
        'shop_name': widget.presetCustomerName ?? '—',
        'code': widget.presetCustomerCode,
      };
    }
  }

  @override
  void dispose() { _notesCtrl.dispose(); super.dispose(); }

  bool get _preset => widget.presetCustomerId != null;
  String? get _orgId => ref.read(authControllerProvider).valueOrNull?.organizationId;
  double get _total => _lines.fold(0.0, (s, l) => s + (l['qty'] as double) * (l['price'] as double));

  Future<void> _pickCustomer() async {
    final orgId = _orgId; if (orgId == null) return;
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _SearchSheet(
        title: 'Select customer', hint: 'Search shop name…',
        onSearch: (q) async {
          final rows =
              await ref.read(fieldOrderRepositoryProvider).searchCustomers(q);
          return rows
              .map((c) => {
                    'id': c.id,
                    'shop_name': c.shopName,
                    'code': c.code,
                  })
              .toList();
        },
        titleOf: (r) => r['shop_name'] as String? ?? '—',
        subtitleOf: (r) => (r['code'] as String?) ?? '',
      ),
    );
    if (chosen != null) setState(() => _customer = chosen);
  }

  Future<void> _addProduct() async {
    final orgId = _orgId; if (orgId == null) return;
    // Step 1: pick a brand (product_sub_group). Step 2: pick a product within it.
    final brandRow = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _SearchSheet(
        title: 'Select brand', hint: 'Search brand…',
        onSearch: (q) async {
          final brands =
              await ref.read(fieldOrderRepositoryProvider).searchBrands(q);
          return brands.map((b) => {'brand': b}).toList();
        },
        titleOf: (r) => r['brand'] as String,
        subtitleOf: (_) => '',
      ),
    );
    if (brandRow == null) return;
    await _pickProductInBrand(orgId, brandRow['brand'] as String);
  }

  Future<void> _pickProductInBrand(String orgId, String brand) async {
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _SearchSheet(
        title: brand, hint: 'Search name or SKU…',
        onSearch: (q) async {
          final rows = await ref
              .read(fieldOrderRepositoryProvider)
              .searchProducts(brand: brand, query: q);
          return rows
              .map((p) => {
                    'id': p.id,
                    'name': p.name,
                    'sku': p.sku,
                    'selling_price': p.sellingPrice,
                    'base_uom_id': p.baseUomId,
                  })
              .toList();
        },
        titleOf: (r) => r['name'] as String? ?? '—',
        subtitleOf: (r) => '${r['sku'] ?? ''}   Rs. ${((r['selling_price'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
        disabledIf: (r) => _lines.any((l) => l['product_id'] == r['id']),
      ),
    );
    if (chosen != null) {
      setState(() => _lines.add({
        'product_id': chosen['id'], 'name': chosen['name'],
        'price': (chosen['selling_price'] as num?)?.toDouble() ?? 0,
        'uom_id': chosen['base_uom_id'], 'qty': 1.0,
      }));
    }
  }

  Future<void> _submit() async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final orgId = user?.organizationId;
    if (_customer == null) { _snack('Select a customer first'); return; }
    if (_lines.isEmpty) { _snack('Add at least one product'); return; }
    if (orgId == null || user == null) { _snack('Session error — please sign in again'); return; }
    setState(() => _submitting = true);
    try {
      await ref.read(fieldOrderRepositoryProvider).createLocal(
            customerId: _customer!['id'] as String,
            salespersonId: user.id,
            notes: _notesCtrl.text.trim().isEmpty
                ? null
                : _notesCtrl.text.trim(),
            lines: _lines
                .map((l) => OrderLineInput(
                      productId: l['product_id'] as String,
                      name: (l['name'] as String?) ?? '',
                      uomId: l['uom_id'] as String?,
                      qty: (l['qty'] as num).toDouble(),
                      price: (l['price'] as num).toDouble(),
                    ))
                .toList(),
          );
      // Kick the sync: online it pushes within milliseconds; offline it stays
      // pending and drains on reconnect. The order is saved locally either way.
      ref.read(syncControllerProvider.notifier).flushPending();
      if (!mounted) return;
      _snack('Order submitted for review');
      Navigator.of(context).pop();
    } catch (e) {
      _snack('Could not save order: $e');
      setState(() => _submitting = false);
    }
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

  Future<void> _editQty(Map<String, dynamic> line) async {
    final ctrl = TextEditingController(text: (line['qty'] as double).toStringAsFixed(0));
    final v = await showDialog<double>(context: context, builder: (ctx) => AlertDialog(
      title: Text(line['name'] as String, style: const TextStyle(fontSize: 15)),
      content: TextField(
        controller: ctrl, autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Quantity'),
        onSubmitted: (_) => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim())), child: const Text('Set')),
      ],
    ));
    if (v != null && v > 0) setState(() => line['qty'] = v);
  }

  /// Suggests the offers this cart qualifies for — same scheme_suggest engine
  /// the web Sales Order and the retailer app use, so a salesperson can upsell
  /// to the threshold. Informational: staff apply the benefit on the SO.
  Future<void> _showOffers() async {
    final orgId = _orgId;
    final cust = _customer;
    if (orgId == null || cust == null || _lines.isEmpty || _offersLoading) return;
    setState(() => _offersLoading = true);
    List<Map<String, dynamic>> offers = [];
    try {
      final items = [
        for (final l in _lines)
          {
            'product_id': l['product_id'],
            'qty': (l['qty'] as num).toDouble(),
            'unit_price': (l['price'] as num).toDouble(),
          },
      ];
      final res = await Supabase.instance.client.rpc('scheme_suggest', params: {
        'p_org': orgId,
        'p_branch': null,
        'p_customer': cust['id'],
        'p_lines': items,
      });
      if (res is List) {
        offers = [for (final s in res) Map<String, dynamic>.from(s as Map)];
      }
    } catch (_) {
      // Engine off / not eligible — treat as no offers.
    }
    if (!mounted) return;
    setState(() => _offersLoading = false);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SalesOffersSheet(offers: offers),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(title: const Text('New Order'), backgroundColor: Colors.white, foregroundColor: AppColors.textPrimaryLight, elevation: 0.5),
      body: Column(children: [
        Container(width: double.infinity, color: Colors.white, padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('CUSTOMER', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textTertiaryLight, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            if (_customer == null)
              OutlinedButton.icon(icon: const Icon(Icons.person_search, size: 18), label: const Text('Select customer'), onPressed: _pickCustomer)
            else
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_customer!['shop_name'] as String? ?? '—', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  if ((_customer!['code'] as String?)?.isNotEmpty == true)
                    Text('#${_customer!['code']}', style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
                ])),
                if (!_preset) TextButton(onPressed: _pickCustomer, child: const Text('Change')),
              ]),
          ])),
        const SizedBox(height: 8),
        Expanded(child: _lines.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_shopping_cart_outlined, size: 40, color: AppColors.textTertiaryLight),
              const SizedBox(height: 8),
              Text('No products yet', style: TextStyle(color: AppColors.textSecondaryLight)),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _lines.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) {
                final l = _lines[i];
                final qty = l['qty'] as double;
                final price = l['price'] as double;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.borderLight)),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l['name'] as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      Text('Rs. ${price.toStringAsFixed(2)} each', style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
                    ])),
                    IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: qty <= 1 ? null : () => setState(() => l['qty'] = qty - 1)),
                    GestureDetector(
                      onTap: () => _editQty(l),
                      child: Container(
                        width: 44, padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(border: Border.all(color: AppColors.borderLight), borderRadius: BorderRadius.circular(6)),
                        child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() => l['qty'] = qty + 1)),
                    IconButton(icon: const Icon(Icons.close, size: 18, color: Colors.redAccent), onPressed: () => setState(() => _lines.removeAt(i))),
                  ]),
                );
              },
            )),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(width: double.infinity, child: OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Add Product'), onPressed: _addProduct))),
        Container(color: Colors.white, padding: EdgeInsets.fromLTRB(16, 10, 16, 10 + MediaQuery.of(context).padding.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _notesCtrl, decoration: const InputDecoration(hintText: 'Notes (optional)', isDense: true), maxLines: 1),
            const SizedBox(height: 10),
            if (_customer != null && _lines.isNotEmpty) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: _offersLoading
                      ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.local_offer_outlined, size: 18),
                  label: const Text('Available offers'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _offersLoading ? null : _showOffers,
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_lines.length} item${_lines.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
                Text('Rs. ${_total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ]),
              const Spacer(),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14)),
                onPressed: _submitting ? null : _submit,
                child: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Submit Order', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ])),
      ]),
    );
  }
}

/// Reusable search bottom-sheet; taps return the chosen row.
class _SearchSheet extends StatefulWidget {
  final String title, hint;
  final Future<List<Map<String, dynamic>>> Function(String q) onSearch;
  final String Function(Map<String, dynamic>) titleOf;
  final String Function(Map<String, dynamic>) subtitleOf;
  final bool Function(Map<String, dynamic>)? disabledIf;
  const _SearchSheet({required this.title, required this.hint, required this.onSearch, required this.titleOf, required this.subtitleOf, this.disabledIf});
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _run(''); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _run(String q) async {
    setState(() { _loading = true; _error = null; });
    try {
      final r = await widget.onSearch(q);
      if (!mounted) return;
      setState(() { _results = r; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      final s = e.toString().toLowerCase();
      setState(() { _loading = false; _error = (s.contains('connection') || s.contains('socket') || s.contains('network')) ? 'No connection' : 'Search failed'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(height: MediaQuery.of(context).size.height * 0.75, child: Column(children: [
        const SizedBox(height: 10),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.borderLight, borderRadius: BorderRadius.circular(2))),
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextField(
          controller: _ctrl, autofocus: true,
          decoration: InputDecoration(hintText: widget.hint, prefixIcon: const Icon(Icons.search), isDense: true, border: const OutlineInputBorder()),
          textInputAction: TextInputAction.search,
          onSubmitted: _run,
          onChanged: (v) { if (v.isEmpty || v.length >= 2) _run(v); },
        )),
        const SizedBox(height: 8),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
            ? Center(child: Text(_error!, style: TextStyle(color: AppColors.textSecondaryLight)))
            : _results.isEmpty
              ? Center(child: Text('No results', style: TextStyle(color: AppColors.textSecondaryLight)))
              : ListView.builder(itemCount: _results.length, itemBuilder: (_, i) {
                  final r = _results[i];
                  final disabled = widget.disabledIf?.call(r) ?? false;
                  return ListTile(
                    title: Text(widget.titleOf(r), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(widget.subtitleOf(r), style: const TextStyle(fontSize: 12)),
                    trailing: disabled ? const Icon(Icons.check, color: Colors.green, size: 18) : const Icon(Icons.chevron_right),
                    onTap: disabled ? null : () => Navigator.pop(context, r),
                  );
                })),
      ])),
    );
  }
}

/// Read-only list of offers the current order qualifies for (scheme_suggest).
class _SalesOffersSheet extends StatelessWidget {
  final List<Map<String, dynamic>> offers;
  const _SalesOffersSheet({required this.offers});

  IconData _icon(String? type) {
    switch (type) {
      case 'foc':
      case 'combo':
        return Icons.card_giftcard_outlined;
      case 'promo_price':
        return Icons.sell_outlined;
      default:
        return Icons.percent_outlined;
    }
  }

  String _benefit(Map<String, dynamic> s) {
    double d(dynamic v) => (v as num?)?.toDouble() ?? 0;
    switch (s['type'] as String?) {
      case 'foc':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        final fq = d(s['free_total']);
        return ft.isNotEmpty
            ? 'Get ${fq.toStringAsFixed(0)} free • $ft'
            : 'Get ${fq.toStringAsFixed(0)} free';
      case 'combo':
        final ft = (s['free_text'] as String?)?.trim() ?? '';
        return ft.isNotEmpty ? 'Combo: $ft' : 'Combo offer';
      case 'qty_slab':
        return 'Discount Rs. ${d(s['discount_total']).toStringAsFixed(2)}';
      case 'invoice_discount':
        final p = d(s['invoice_percent']);
        return '${p.toStringAsFixed(p % 1 == 0 ? 0 : 1)}% off invoice';
      case 'promo_price':
        return 'Special promo price';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      builder: (_, scroll) => Column(children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 2, 20, 10),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text('Available offers',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: offers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.local_offer_outlined,
                          size: 40, color: AppColors.textSecondaryLight),
                      const SizedBox(height: 12),
                      Text('No offers for this order yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondaryLight)),
                    ]),
                  ),
                )
              : ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    for (final s in offers)
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.borderLight),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: AppColors.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(_icon(s['type'] as String?),
                                  color: AppColors.primary, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text((s['name'] as String?) ?? '',
                                      style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800)),
                                  if (((s['description'] as String?) ?? '')
                                      .trim()
                                      .isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text((s['description'] as String).trim(),
                                        style: TextStyle(
                                            fontSize: 12.5,
                                            height: 1.3,
                                            color: AppColors.textSecondaryLight)),
                                  ],
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 9, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppColors.success.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(_benefit(s),
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.successDark)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text('Offers are applied by our team when the order is processed.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: AppColors.textSecondaryLight)),
                    const SizedBox(height: 8),
                  ],
                ),
        ),
      ]),
    );
  }
}
