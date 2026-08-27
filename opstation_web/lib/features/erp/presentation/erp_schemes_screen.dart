import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

/// Trade Schemes / Offers management. Create and manage FOC (buy X get Y free)
/// and quantity-slab discount schemes. Execution (suggest + confirm) lives on
/// the Sales Order (FOC) and Sales Invoice (discount) screens. The whole tool
/// is gated by the org.schemes_enabled admin toggle.
class ErpSchemesScreen extends ConsumerStatefulWidget {
  const ErpSchemesScreen({super.key});
  @override
  ConsumerState<ErpSchemesScreen> createState() => _ErpSchemesScreenState();
}

class _ErpSchemesScreenState extends ConsumerState<ErpSchemesScreen> {
  bool _loading = true;
  bool _enabled = false; // org.schemes_enabled
  bool _focEnabled = false; // org.foc_enabled — free units land in the FOC section
  List<Map<String, dynamic>> _schemes = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _branches = [];
  String _search = '';
  String _typeFilter = 'all'; // all | foc | qty_slab

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait([
        client.from('app_config').select('key,value').eq('org_id', orgId).inFilter('key', ['org.schemes_enabled', 'org.foc_enabled']),
        client.from('schemes').select('*, scheme_slabs(*), scheme_products(product_id), scheme_customers(customer_id), scheme_branches(branch_id)').eq('org_id', orgId).order('priority').order('name'),
        client.from('products').select('id, name, sku, base_uom_id').eq('org_id', orgId).eq('is_active', true).order('name').limit(10000),
        client.from('customers').select('id, shop_name, code').eq('org_id', orgId).order('shop_name').limit(10000),
        client.from('branches').select('id, name').eq('org_id', orgId).eq('is_active', true).order('name'),
      ]);
      if (!mounted) return;
      final cfg = {for (final r in results[0] as List) r['key'] as String: (r['value'] as String? ?? '')};
      setState(() {
        _enabled = cfg['org.schemes_enabled'] == 'true';
        _focEnabled = cfg['org.foc_enabled'] == 'true';
        _schemes = List<Map<String, dynamic>>.from(results[1] as List);
        _products = List<Map<String, dynamic>>.from(results[2] as List);
        _customers = List<Map<String, dynamic>>.from(results[3] as List);
        _branches = List<Map<String, dynamic>>.from(results[4] as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _snack(friendlyError('Could not load schemes', e));
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  List<Map<String, dynamic>> get _filtered => _schemes.where((s) {
        if (_typeFilter != 'all' && s['scheme_type'] != _typeFilter) return false;
        if (_search.trim().isEmpty) return true;
        final q = _search.toLowerCase();
        return '${s['name'] ?? ''} ${s['description'] ?? ''}'.toLowerCase().contains(q);
      }).toList();

  Future<void> _openForm([Map<String, dynamic>? scheme]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SchemeFormDialog(
        orgId: _orgId!,
        scheme: scheme,
        products: _products,
        customers: _customers,
        branches: _branches,
        createdBy: ref.read(currentUserProvider)?.id,
        focFlowEnabled: _focEnabled,
        onEnableFocFlow: _enableFocFlow,
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _toggleActive(Map<String, dynamic> s) async {
    final next = !(s['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client.from('schemes').update({'is_active': next, 'updated_at': DateTime.now().toUtc().toIso8601String()}).eq('id', s['id']);
      setState(() => s['is_active'] = next);
    } catch (e) { _snack(friendlyError('That did not save', e)); }
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Delete scheme?'),
      content: Text('Delete "${s['name']}"? Past redemptions are kept for reporting; the scheme just stops being offered.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger), onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    try {
      await Supabase.instance.client.from('schemes').delete().eq('id', s['id']);
      setState(() => _schemes.removeWhere((x) => x['id'] == s['id']));
    } catch (e) { _snack(friendlyError('Could not delete', e)); }
  }

  Future<void> _setEnabled(bool v) async {
    final orgId = _orgId; if (orgId == null) return;
    setState(() => _enabled = v);
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': 'org.schemes_enabled', 'value': v ? 'true' : 'false', 'org_id': orgId,
      }, onConflict: 'key,org_id,branch_id');
    } catch (e) {
      setState(() => _enabled = !v);
      _snack(friendlyError('Could not change the switch', e));
    }
  }

  // Enable org.foc_enabled so free units from Buy-X-Get-Y schemes are visible
  // in the FOC section of the Sales Order.
  Future<bool> _enableFocFlow() async {
    final orgId = _orgId; if (orgId == null) return false;
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': 'org.foc_enabled', 'value': 'true', 'org_id': orgId,
      }, onConflict: 'key,org_id,branch_id');
      if (mounted) setState(() => _focEnabled = true);
      return true;
    } catch (e) {
      _snack(friendlyError('Could not enable the FOC section', e));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: BrandSpinner());
    return Container(
      color: AppTheme.background,
      child: Column(children: [
        // Header
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const Icon(Icons.local_offer_outlined, color: AppTheme.primary),
            const SizedBox(width: 10),
            const Text('Schemes & Offers', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(width: 16),
            // Global live/off switch
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: (_enabled ? AppTheme.success : AppTheme.textSecondary).withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: (_enabled ? AppTheme.success : AppTheme.border)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_enabled ? 'LIVE' : 'OFF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _enabled ? AppTheme.success : AppTheme.textSecondary)),
                Switch(value: _enabled, onChanged: _setEnabled, activeColor: AppTheme.success),
              ]),
            ),
            const Spacer(),
            ElevatedButton.icon(onPressed: () => _openForm(), icon: const Icon(Icons.add, size: 18), label: const Text('New Scheme')),
          ]),
        ),
        if (!_enabled)
          Container(
            width: double.infinity,
            color: Colors.orange.withOpacity(0.08),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: const Text('Schemes are OFF. They will not be suggested on Sales Orders or Invoices until you switch this LIVE. You can still create and edit them here.',
                style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
          ),
        // Filters
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Row(children: [
            Expanded(child: TextField(
              decoration: const InputDecoration(hintText: 'Search schemes...', prefixIcon: Icon(Icons.search, size: 18), isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _search = v),
            )),
            const SizedBox(width: 12),
            _typeChip('all', 'All'),
            const SizedBox(width: 6),
            _typeChip('foc', 'FOC'),
            const SizedBox(width: 6),
            _typeChip('qty_slab', 'Slab discount'),
          ]),
        ),
        Expanded(
          child: _filtered.isEmpty
              ? Center(child: Text(_schemes.isEmpty ? 'No schemes yet — create your first one.' : 'No schemes match.', style: const TextStyle(color: AppTheme.textSecondary)))
              : ListView.separated(
                  padding: const EdgeInsets.all(20),
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _schemeCard(_filtered[i]),
                ),
        ),
      ]),
    );
  }

  Widget _typeChip(String value, String label) {
    final active = _typeFilter == value;
    return GestureDetector(
      onTap: () => setState(() => _typeFilter = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? Colors.white : AppTheme.textSecondary)),
      ),
    );
  }

  Widget _schemeCard(Map<String, dynamic> s) {
    final type = s['scheme_type'] as String? ?? 'foc';
    final active = s['is_active'] as bool? ?? true;
    final slabs = List<Map<String, dynamic>>.from(s['scheme_slabs'] as List? ?? const []);
    final nProd = (s['scheme_products'] as List? ?? const []).length;
    final nCust = (s['scheme_customers'] as List? ?? const []).length;
    final nBranch = (s['scheme_branches'] as List? ?? const []).length;
    final validFrom = s['valid_from'] as String?;
    final validTo = s['valid_to'] as String?;
    String benefit;
    if (type == 'foc') {
      final buy = _numText(s['foc_buy_qty']);
      final free = _numText(s['foc_free_qty']);
      final fp = s['foc_free_product_id'] as String?;
      final fpName = fp == null ? 'same product' : (_products.firstWhere((p) => p['id'] == fp, orElse: () => const {})['name'] ?? 'reward product');
      benefit = 'Buy $buy → get $free free ($fpName)${(s['foc_repeat'] as bool? ?? true) ? ', repeating' : ''}';
    } else {
      benefit = slabs.isEmpty
          ? 'No slabs defined'
          : (slabs..sort((a, b) => ((a['min_qty'] as num?) ?? 0).compareTo((b['min_qty'] as num?) ?? 0)))
              .map((sl) => '${_numText(sl['min_qty'])}${sl['max_qty'] == null ? '+' : '–${_numText(sl['max_qty'])}'} = ${_numText(sl['discount_value'])}${sl['discount_type'] == 'percent' ? '%' : '/unit'}')
              .join('   ·   ');
    }
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _pill(type == 'foc' ? 'FOC' : 'SLAB', type == 'foc' ? Colors.teal : Colors.indigo),
            const SizedBox(width: 8),
            Expanded(child: Text(s['name'] as String? ?? '-', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))),
            _pill(active ? 'ACTIVE' : 'PAUSED', active ? AppTheme.success : AppTheme.textSecondary),
            const SizedBox(width: 8),
            Text('Priority ${s['priority'] ?? 100}', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          if ((s['description'] as String?)?.trim().isNotEmpty ?? false) ...[
            const SizedBox(height: 4),
            Text(s['description'] as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ],
          const SizedBox(height: 8),
          Text(benefit, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primary)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _tag(Icons.inventory_2_outlined, nProd == 0 ? 'All products' : '$nProd product(s)'),
            _tag(Icons.store_outlined, nCust == 0 ? 'All customers' : '$nCust customer(s)'),
            _tag(Icons.apartment_outlined, nBranch == 0 ? 'All branches' : '$nBranch branch(es)'),
            if (validFrom != null || validTo != null)
              _tag(Icons.event_outlined, '${validFrom ?? '…'} → ${validTo ?? '…'}'),
          ]),
          const Divider(height: 20),
          Row(children: [
            TextButton.icon(onPressed: () => _toggleActive(s), icon: Icon(active ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 18), label: Text(active ? 'Pause' : 'Activate')),
            const Spacer(),
            TextButton.icon(onPressed: () => _openForm(s), icon: const Icon(Icons.edit_outlined, size: 18), label: const Text('Edit')),
            TextButton.icon(onPressed: () => _delete(s), icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), label: const Text('Delete', style: TextStyle(color: AppTheme.danger))),
          ]),
        ]),
      ),
    );
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
        child: Text(t, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: c)),
      );

  Widget _tag(IconData ic, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ic, size: 14, color: AppTheme.textSecondary),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]);

  static String _numText(Object? v) {
    if (v == null) return '0';
    final n = (v as num).toDouble();
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Create / edit form
// ─────────────────────────────────────────────────────────────────────────
class _SchemeFormDialog extends StatefulWidget {
  const _SchemeFormDialog({
    required this.orgId,
    required this.scheme,
    required this.products,
    required this.customers,
    required this.branches,
    required this.createdBy,
    required this.focFlowEnabled,
    required this.onEnableFocFlow,
  });
  final String orgId;
  final Map<String, dynamic>? scheme;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> branches;
  final String? createdBy;
  final bool focFlowEnabled;
  final Future<bool> Function() onEnableFocFlow;

  @override
  State<_SchemeFormDialog> createState() => _SchemeFormDialogState();
}

class _SchemeFormDialogState extends State<_SchemeFormDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priorityCtrl = TextEditingController(text: '100');
  String _type = 'foc';
  bool _active = true;
  DateTime? _validFrom;
  DateTime? _validTo;

  // scope
  bool _allProducts = true;
  bool _allCustomers = true;
  bool _allBranches = true;
  final Set<String> _prodIds = {};
  final Set<String> _custIds = {};
  final Set<String> _branchIds = {};

  // FOC
  final _buyQtyCtrl = TextEditingController();
  final _freeQtyCtrl = TextEditingController();
  String? _freeProductId; // null = same as purchased
  bool _focRepeat = true;
  final _maxFreeCtrl = TextEditingController();

  // slabs
  final List<_SlabRow> _slabs = [];

  bool _saving = false;
  late bool _focFlow; // local mirror of org.foc_enabled

  @override
  void initState() {
    super.initState();
    _focFlow = widget.focFlowEnabled;
    final s = widget.scheme;
    if (s != null) {
      _nameCtrl.text = s['name'] as String? ?? '';
      _descCtrl.text = s['description'] as String? ?? '';
      _priorityCtrl.text = '${s['priority'] ?? 100}';
      _type = s['scheme_type'] as String? ?? 'foc';
      _active = s['is_active'] as bool? ?? true;
      _validFrom = s['valid_from'] != null ? DateTime.tryParse(s['valid_from'] as String) : null;
      _validTo = s['valid_to'] != null ? DateTime.tryParse(s['valid_to'] as String) : null;
      _allProducts = s['all_products'] as bool? ?? true;
      _allCustomers = s['all_customers'] as bool? ?? true;
      _allBranches = s['all_branches'] as bool? ?? true;
      for (final r in (s['scheme_products'] as List? ?? const [])) { _prodIds.add(r['product_id'] as String); }
      for (final r in (s['scheme_customers'] as List? ?? const [])) { _custIds.add(r['customer_id'] as String); }
      for (final r in (s['scheme_branches'] as List? ?? const [])) { _branchIds.add(r['branch_id'] as String); }
      _buyQtyCtrl.text = _plain(s['foc_buy_qty']);
      _freeQtyCtrl.text = _plain(s['foc_free_qty']);
      _freeProductId = s['foc_free_product_id'] as String?;
      _focRepeat = s['foc_repeat'] as bool? ?? true;
      _maxFreeCtrl.text = _plain(s['foc_max_free_qty']);
      for (final sl in (s['scheme_slabs'] as List? ?? const [])) {
        _slabs.add(_SlabRow(
          min: _plain(sl['min_qty']),
          max: _plain(sl['max_qty']),
          type: sl['discount_type'] as String? ?? 'percent',
          value: _plain(sl['discount_value']),
        ));
      }
    }
    if (_slabs.isEmpty) _slabs.add(_SlabRow());
  }

  static String _plain(Object? v) {
    if (v == null) return '';
    final n = (v as num).toDouble();
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  @override
  void dispose() {
    _nameCtrl.dispose(); _descCtrl.dispose(); _priorityCtrl.dispose();
    _buyQtyCtrl.dispose(); _freeQtyCtrl.dispose(); _maxFreeCtrl.dispose();
    for (final s in _slabs) { s.dispose(); }
    super.dispose();
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  Future<void> _pickDate(bool from) async {
    final init = (from ? _validFrom : _validTo) ?? DateTime.now();
    final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d == null) return;
    setState(() { if (from) { _validFrom = d; } else { _validTo = d; } });
  }

  Future<void> _pickMulti({required String title, required List<Map<String, dynamic>> items, required Set<String> selected, required String Function(Map<String, dynamic>) label}) async {
    final tmp = Set<String>.from(selected);
    String q = '';
    final result = await showDialog<bool>(context: context, builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setLocal) {
        final filtered = items.where((it) => q.isEmpty || label(it).toLowerCase().contains(q.toLowerCase())).take(400).toList();
        return AlertDialog(
          title: Text(title),
          content: SizedBox(width: 420, height: 460, child: Column(children: [
            TextField(
              decoration: const InputDecoration(hintText: 'Search...', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
              onChanged: (v) => setLocal(() => q = v),
            ),
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
              Text('${tmp.length} selected', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const Spacer(),
              TextButton(onPressed: () => setLocal(() => tmp.clear()), child: const Text('Clear all')),
            ])),
            Expanded(child: ListView.builder(itemCount: filtered.length, itemBuilder: (_, i) {
              final it = filtered[i];
              final id = it['id'] as String;
              final on = tmp.contains(id);
              return CheckboxListTile(
                dense: true,
                value: on,
                title: Text(label(it), style: const TextStyle(fontSize: 13)),
                onChanged: (v) => setLocal(() { if (v == true) { tmp.add(id); } else { tmp.remove(id); } }),
              );
            })),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Done')),
          ],
        );
      });
    });
    if (result == true) setState(() { selected..clear()..addAll(tmp); });
  }

  Future<void> _save() async {
    // Validate
    if (_nameCtrl.text.trim().isEmpty) { _snack('Give the scheme a name'); return; }
    final priority = int.tryParse(_priorityCtrl.text.trim()) ?? 100;
    if (_type == 'foc') {
      final buy = double.tryParse(_buyQtyCtrl.text.trim()) ?? 0;
      final free = double.tryParse(_freeQtyCtrl.text.trim()) ?? 0;
      if (buy <= 0 || free <= 0) { _snack('FOC needs a buy quantity and a free quantity greater than 0'); return; }
    } else {
      final valid = _slabs.where((s) => s.isFilled).toList();
      if (valid.isEmpty) { _snack('Add at least one quantity slab'); return; }
      for (final s in valid) {
        if ((double.tryParse(s.value.text.trim()) ?? 0) <= 0) { _snack('Each slab needs a discount value greater than 0'); return; }
      }
    }
    if (!_allProducts && _prodIds.isEmpty) { _snack('Pick at least one product, or switch to All products'); return; }
    if (!_allCustomers && _custIds.isEmpty) { _snack('Pick at least one customer, or switch to All customers'); return; }
    if (!_allBranches && _branchIds.isEmpty) { _snack('Pick at least one branch, or switch to All branches'); return; }

    // A Buy-X-Get-Y scheme puts free units in the FOC section — which is only
    // visible when the FOC products flow is on. Offer to enable it now.
    if (_type == 'foc' && !_focFlow) {
      final choice = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Enable FOC section?'),
        content: const Text('This is a Buy X get Y free scheme. Free units are added to the FOC section of the Sales Order, which is currently OFF for this org — the free goods would not appear there.\n\nEnable the FOC products flow so they show up?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: const Text('Save without it')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'enable'), child: const Text('Enable & save')),
        ],
      ));
      if (choice == null || choice == 'cancel') return;
      if (choice == 'enable') {
        final ok = await widget.onEnableFocFlow();
        if (ok && mounted) setState(() => _focFlow = true);
      }
    }

    setState(() => _saving = true);
    final client = Supabase.instance.client;
    final isEdit = widget.scheme != null;
    final id = isEdit ? widget.scheme!['id'] as String : 'schm_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toUtc().toIso8601String();
    final fmt = DateFormat('yyyy-MM-dd');
    try {
      final header = {
        'id': id,
        'org_id': widget.orgId,
        'name': _nameCtrl.text.trim(),
        'description': _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
        'scheme_type': _type,
        'is_active': _active,
        'priority': priority,
        'valid_from': _validFrom != null ? fmt.format(_validFrom!) : null,
        'valid_to': _validTo != null ? fmt.format(_validTo!) : null,
        'all_products': _allProducts,
        'all_customers': _allCustomers,
        'all_branches': _allBranches,
        'foc_buy_qty': _type == 'foc' ? double.tryParse(_buyQtyCtrl.text.trim()) : null,
        'foc_free_qty': _type == 'foc' ? double.tryParse(_freeQtyCtrl.text.trim()) : null,
        'foc_free_product_id': _type == 'foc' ? _freeProductId : null,
        'foc_repeat': _focRepeat,
        'foc_max_free_qty': _type == 'foc' && _maxFreeCtrl.text.trim().isNotEmpty ? double.tryParse(_maxFreeCtrl.text.trim()) : null,
        'updated_at': now,
        if (!isEdit) 'created_by': widget.createdBy,
      };
      if (isEdit) {
        await client.from('schemes').update(header).eq('id', id);
      } else {
        await client.from('schemes').insert(header);
      }

      // Replace children (delete then insert).
      await client.from('scheme_slabs').delete().eq('scheme_id', id);
      await client.from('scheme_products').delete().eq('scheme_id', id);
      await client.from('scheme_customers').delete().eq('scheme_id', id);
      await client.from('scheme_branches').delete().eq('scheme_id', id);

      if (_type == 'qty_slab') {
        final rows = _slabs.where((s) => s.isFilled).map((s) => {
              'id': 'slab_${DateTime.now().microsecondsSinceEpoch}_${_slabs.indexOf(s)}',
              'org_id': widget.orgId,
              'scheme_id': id,
              'min_qty': double.tryParse(s.min.text.trim()) ?? 0,
              'max_qty': s.max.text.trim().isEmpty ? null : double.tryParse(s.max.text.trim()),
              'discount_type': s.type,
              'discount_value': double.tryParse(s.value.text.trim()) ?? 0,
            }).toList();
        if (rows.isNotEmpty) await client.from('scheme_slabs').insert(rows);
      }
      if (!_allProducts && _prodIds.isNotEmpty) {
        await client.from('scheme_products').insert(_prodIds.map((p) => {'org_id': widget.orgId, 'scheme_id': id, 'product_id': p}).toList());
      }
      if (!_allCustomers && _custIds.isNotEmpty) {
        await client.from('scheme_customers').insert(_custIds.map((c) => {'org_id': widget.orgId, 'scheme_id': id, 'customer_id': c}).toList());
      }
      if (!_allBranches && _branchIds.isNotEmpty) {
        await client.from('scheme_branches').insert(_branchIds.map((b) => {'org_id': widget.orgId, 'scheme_id': id, 'branch_id': b}).toList());
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _snack(friendlyError('Could not save the scheme', e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Title bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
            child: Row(children: [
              const Icon(Icons.local_offer_outlined, color: AppTheme.primary),
              const SizedBox(width: 10),
              Text(widget.scheme == null ? 'New Scheme' : 'Edit Scheme', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const Spacer(),
              IconButton(onPressed: _saving ? null : () => Navigator.pop(context, false), icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Name + priority
              Row(children: [
                Expanded(flex: 3, child: TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Scheme name *', isDense: true, border: OutlineInputBorder()))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: _priorityCtrl, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'Priority', helperText: 'lower first', isDense: true, border: OutlineInputBorder()))),
                const SizedBox(width: 12),
                Column(children: [
                  const Text('Active', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                  Switch(value: _active, onChanged: (v) => setState(() => _active = v), activeColor: AppTheme.success),
                ]),
              ]),
              const SizedBox(height: 12),
              TextField(controller: _descCtrl, maxLines: 2, decoration: const InputDecoration(labelText: 'Description (optional)', isDense: true, border: OutlineInputBorder())),
              const SizedBox(height: 16),
              // Type
              const Text('Scheme type', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Row(children: [
                _typeOption('foc', 'Buy X get Y free', Icons.redeem_outlined),
                const SizedBox(width: 10),
                _typeOption('qty_slab', 'Quantity-slab discount', Icons.percent_outlined),
              ]),
              const SizedBox(height: 16),
              if (_type == 'foc') _focSection() else _slabSection(),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              // Validity
              const Text('Validity (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _dateField('From', _validFrom, () => _pickDate(true), () => setState(() => _validFrom = null))),
                const SizedBox(width: 12),
                Expanded(child: _dateField('To', _validTo, () => _pickDate(false), () => setState(() => _validTo = null))),
              ]),
              const SizedBox(height: 16),
              // Scope
              const Text('Who / where it applies', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
              const SizedBox(height: 6),
              _scopeRow(
                label: 'Products',
                all: _allProducts,
                count: _prodIds.length,
                onAll: (v) => setState(() => _allProducts = v),
                onPick: () => _pickMulti(title: 'Products in this scheme', items: widget.products, selected: _prodIds, label: (p) => '${p['name']}${p['sku'] != null ? '  ·  ${p['sku']}' : ''}'),
                hint: _type == 'foc' ? 'the products that trigger the free goods' : 'the products the discount applies to',
              ),
              _scopeRow(
                label: 'Customers',
                all: _allCustomers,
                count: _custIds.length,
                onAll: (v) => setState(() => _allCustomers = v),
                onPick: () => _pickMulti(title: 'Customers eligible', items: widget.customers, selected: _custIds, label: (c) => '${c['shop_name']}${c['code'] != null ? '  ·  ${c['code']}' : ''}'),
                hint: 'leave as All to offer it to everyone',
              ),
              _scopeRow(
                label: 'Branches',
                all: _allBranches,
                count: _branchIds.length,
                onAll: (v) => setState(() => _allBranches = v),
                onPick: () => _pickMulti(title: 'Branches', items: widget.branches, selected: _branchIds, label: (b) => b['name'] as String? ?? '-'),
                hint: 'restrict to specific branches if needed',
              ),
            ]),
          )),
          // Footer
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
            child: Row(children: [
              const Spacer(),
              TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check, size: 18),
                label: Text(_saving ? 'Saving...' : 'Save scheme'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _typeOption(String value, String label, IconData ic) {
    final active = _type == value;
    return Expanded(child: GestureDetector(
      onTap: () => setState(() => _type = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? AppTheme.primary : AppTheme.border, width: active ? 1.5 : 1),
        ),
        child: Row(children: [
          Icon(ic, size: 18, color: active ? AppTheme.primary : AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: active ? AppTheme.primary : Colors.black87))),
          if (active) const Icon(Icons.check_circle, size: 16, color: AppTheme.primary),
        ]),
      ),
    ));
  }

  Widget _focSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.teal.withOpacity(0.04), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.teal.withOpacity(0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextField(controller: _buyQtyCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Buy quantity (X) *', isDense: true, border: OutlineInputBorder()))),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('→', style: TextStyle(fontSize: 18))),
          Expanded(child: TextField(controller: _freeQtyCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Free quantity (Y) *', isDense: true, border: OutlineInputBorder()))),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          value: _freeProductId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Free product', isDense: true, border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Same as the purchased product', style: TextStyle(fontSize: 13))),
            ...widget.products.map((p) => DropdownMenuItem<String?>(value: p['id'] as String, child: Text('${p['name']}', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis))),
          ],
          onChanged: (v) => setState(() => _freeProductId = v),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _focRepeat,
            onChanged: (v) => setState(() => _focRepeat = v),
            title: const Text('Repeat per multiple', style: TextStyle(fontSize: 13)),
            subtitle: const Text('e.g. buy 10 get 1 → 25 gives 2 free', style: TextStyle(fontSize: 11)),
          )),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _maxFreeCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Max free / line', helperText: 'blank = no cap', isDense: true, border: OutlineInputBorder()))),
        ]),
        const SizedBox(height: 6),
        const Text('FOC schemes are suggested on the Sales Order (free goods are added as FOC lines and flow to the invoice).', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        if (!_focFlow) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.orange.withOpacity(0.10), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.orange.withOpacity(0.4))),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.deepOrange),
              const SizedBox(width: 8),
              const Expanded(child: Text('The FOC section is currently OFF on Sales Orders, so free units would not be shown. Enable the FOC products flow to place them there.', style: TextStyle(fontSize: 11.5, color: Colors.deepOrange))),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async { final ok = await widget.onEnableFocFlow(); if (ok && mounted) setState(() => _focFlow = true); },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, visualDensity: VisualDensity.compact),
                child: const Text('Enable FOC', style: TextStyle(fontSize: 12)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _slabSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.indigo.withOpacity(0.04), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.indigo.withOpacity(0.2))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: const [
          Expanded(flex: 3, child: Text('Min qty', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Max qty (blank = & above)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Discount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          SizedBox(width: 40),
        ]),
        const SizedBox(height: 6),
        ..._slabs.asMap().entries.map((e) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(flex: 3, child: TextField(controller: e.value.min, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'e.g. 5'))),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: TextField(controller: e.value.max, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'e.g. 19'))),
            const SizedBox(width: 8),
            Expanded(flex: 2, child: TextField(controller: e.value.value, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'value'))),
            const SizedBox(width: 4),
            Expanded(flex: 1, child: DropdownButtonFormField<String>(
              value: e.value.type,
              isDense: true,
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 12)),
              items: const [
                DropdownMenuItem(value: 'percent', child: Text('%', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'amount', child: Text('Rs', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) => setState(() => e.value.type = v ?? 'percent'),
            )),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20, color: AppTheme.danger),
              onPressed: _slabs.length == 1 ? null : () => setState(() { _slabs.removeAt(e.key).dispose(); }),
            ),
          ]),
        )),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => setState(() => _slabs.add(_SlabRow())), icon: const Icon(Icons.add, size: 18), label: const Text('Add slab')),
        ),
        const Text('% is a percent off the line. Rs is a per-unit amount off. Slab discounts are suggested on the Sales Invoice (where prices are set).', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
      ]),
    );
  }

  Widget _dateField(String label, DateTime? value, VoidCallback onPick, VoidCallback onClear) {
    return InkWell(
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder(), suffixIcon: value == null ? const Icon(Icons.event, size: 18) : IconButton(icon: const Icon(Icons.clear, size: 16), onPressed: onClear)),
        child: Text(value == null ? 'Any' : DateFormat('d MMM yyyy').format(value), style: const TextStyle(fontSize: 13)),
      ),
    );
  }

  Widget _scopeRow({required String label, required bool all, required int count, required ValueChanged<bool> onAll, required VoidCallback onPick, required String hint}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        const SizedBox(width: 8),
        ChoiceChip(label: const Text('All', style: TextStyle(fontSize: 12)), selected: all, onSelected: (_) => onAll(true)),
        const SizedBox(width: 6),
        ChoiceChip(label: Text(all ? 'Specific' : '$count selected', style: const TextStyle(fontSize: 12)), selected: !all, onSelected: (_) { onAll(false); onPick(); }),
        const SizedBox(width: 10),
        if (!all)
          TextButton(onPressed: onPick, child: const Text('Choose', style: TextStyle(fontSize: 12)))
        else
          Expanded(child: Text(hint, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

class _SlabRow {
  _SlabRow({String? min, String? max, String? type, String? value})
      : min = TextEditingController(text: min ?? ''),
        max = TextEditingController(text: max ?? ''),
        value = TextEditingController(text: value ?? ''),
        type = (type == null || type.isEmpty) ? 'percent' : type;
  final TextEditingController min;
  final TextEditingController max;
  final TextEditingController value;
  String type;
  bool get isFilled => min.text.trim().isNotEmpty && value.text.trim().isNotEmpty;
  void dispose() { min.dispose(); max.dispose(); value.dispose(); }
}
