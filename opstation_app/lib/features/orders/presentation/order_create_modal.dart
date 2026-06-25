import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';
import '../../auth/providers/auth_controller.dart';

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
          var query = Supabase.instance.client.from('customers')
              .select('id, shop_name, code').eq('org_id', orgId).eq('is_active', true);
          if (q.isNotEmpty) query = query.ilike('shop_name', '%$q%');
          final rows = await query.order('shop_name').limit(30);
          return List<Map<String, dynamic>>.from(rows);
        },
        titleOf: (r) => r['shop_name'] as String? ?? '—',
        subtitleOf: (r) => (r['code'] as String?) ?? '',
      ),
    );
    if (chosen != null) setState(() => _customer = chosen);
  }

  Future<void> _addProduct() async {
    final orgId = _orgId; if (orgId == null) return;
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _SearchSheet(
        title: 'Add product', hint: 'Search name or SKU…',
        onSearch: (q) async {
          var query = Supabase.instance.client.from('products')
              .select('id, name, sku, selling_price, base_uom_id').eq('org_id', orgId).eq('is_active', true);
          if (q.isNotEmpty) query = query.or('name.ilike.%$q%,sku.ilike.%$q%');
          final rows = await query.order('name').limit(30);
          return List<Map<String, dynamic>>.from(rows);
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
      final client = Supabase.instance.client;
      final now = DateTime.now().microsecondsSinceEpoch;
      final foId = 'fo_$now';
      await client.from('field_orders').insert({
        'id': foId, 'org_id': orgId, 'customer_id': _customer!['id'],
        'salesperson_id': user.id, 'status': 'submitted',
        'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      });
      int i = 0;
      await client.from('field_order_items').insert(_lines.map((l) => {
        'id': 'foi_${now}_${i++}', 'field_order_id': foId,
        'product_id': l['product_id'], 'uom_id': l['uom_id'],
        'quantity': l['qty'], 'price_at_submit': l['price'],
      }).toList());
      if (!mounted) return;
      _snack('Order submitted for review');
      Navigator.of(context).pop();
    } catch (e) {
      final s = e.toString().toLowerCase();
      final msg = (s.contains('socket') || s.contains('network') || s.contains('connection') || s.contains('failed host'))
          ? 'No connection — order not submitted. Try again when online.'
          : 'Could not submit: $e';
      _snack(msg);
      setState(() => _submitting = false);
    }
  }

  void _snack(String m) { if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating)); }

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
                    SizedBox(width: 32, child: Text(qty.toStringAsFixed(0), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
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
