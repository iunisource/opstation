import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import 'dart:html' as html;
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';


import 'customer_history_screen.dart';
import 'erp_customer_360_screen.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  final bool crmMode;
  const CustomersScreen({super.key, this.crmMode = false});
  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  List<Map<String, dynamic>> _customers = [];
  List<Map<String, dynamic>> _filtered = [];
  List<String> _categories = [];
  List<String> _groups = [];
  bool _loading = true;
  final _searchCtrl = TextEditingController();
  String _missingFilter = 'all'; // all | contact | phone | either

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    try {
      final client = Supabase.instance.client;

      // Load customers — paginate past PostgREST's 1000-row default cap
      final List<Map<String, dynamic>> rows = [];
      const pageSize = 1000;
      var offset = 0;
      while (true) {
        final page = await client
            .from('customers')
            .select()
            .eq('org_id', orgId)
            .order('shop_name')
            .range(offset, offset + pageSize - 1);
        rows.addAll(List<Map<String, dynamic>>.from(page));
        if (page.length < pageSize) break;
        offset += pageSize;
      }

      // Load categories from app_config
      final catRow = await client
          .from('app_config')
          .select('value')
          .eq('key', 'org.categories')
          .eq('org_id', orgId)
          .maybeSingle();

      List<String> cats = [];
      if (catRow != null && catRow['value'] != null) {
        try {
          final decoded = jsonDecode(catRow['value'] as String);
          if (decoded is List) cats = List<String>.from(decoded);
        } catch (_) {}
      }

      // Load groups from app_config
      final grpRow = await client
          .from('app_config')
          .select('value')
          .eq('key', 'org.groups')
          .eq('org_id', orgId)
          .maybeSingle();

      List<String> grps = [];
      if (grpRow != null && grpRow['value'] != null) {
        try {
          final decoded = jsonDecode(grpRow['value'] as String);
          if (decoded is List) grps = List<String>.from(decoded);
        } catch (_) {}
      }

      setState(() {
        _customers = List<Map<String, dynamic>>.from(rows);
        _filtered = _customers;
        _categories = cats;
        _groups = grps;
        _loading = false;
      });
    } catch (_) { setState(() => _loading = false); }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _customers.where((c) {
        final matchesSearch = q.isEmpty ||
            (c['shop_name'] as String? ?? '').toLowerCase().contains(q) ||
            (c['code'] as String? ?? '').toLowerCase().contains(q) ||
            (c['phone'] as String? ?? '').toLowerCase().contains(q);
        if (!matchesSearch) return false;
        final noContact =
            (c['contact_person'] as String? ?? '').trim().isEmpty;
        final noPhone = (c['phone'] as String? ?? '').trim().isEmpty;
        final hasLoc = c['latitude'] != null && c['longitude'] != null;
        switch (_missingFilter) {
          case 'contact':
            return noContact;
          case 'phone':
            return noPhone;
          case 'either':
            return noContact || noPhone;
          case 'no_location':
            return !hasLoc;
          case 'has_location':
            return hasLoc;
          default:
            return true;
        }
      }).toList();
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// Opens Google Maps (new browser tab) centered on the customer's coords.
  void _openLocation(double lat, double lng) {
    html.window.open(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
      '_blank',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Customers', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (!widget.crmMode) ...[
              OutlinedButton.icon(
                onPressed: () => context.push('/customers/import'),
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Bulk Import'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _showDialog(context, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Customer'),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          Text('${_filtered.length} customers', style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: 'Search by name, code or phone...',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                value: _missingFilter,
                decoration: const InputDecoration(
                  labelText: 'Filter',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'all', child: Text('All customers')),
                  DropdownMenuItem(
                      value: 'contact',
                      child: Text('Missing: Contact Person')),
                  DropdownMenuItem(
                      value: 'phone', child: Text('Missing: Phone')),
                  DropdownMenuItem(
                      value: 'either',
                      child: Text('Missing: Contact or Phone')),
                  DropdownMenuItem(
                      value: 'no_location',
                      child: Text('Missing: Location')),
                  DropdownMenuItem(
                      value: 'has_location',
                      child: Text('Has Location')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _missingFilter = v);
                  _filter();
                },
              ),
            ),
          ]),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                      ),
                      child: const Row(children: [
                        Expanded(flex: 1, child: Text('Code', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 3, child: Text('Shop Name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Contact', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Phone', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        Expanded(flex: 2, child: Text('Category', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.textSecondary))),
                        SizedBox(width: 80),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final c = _filtered[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(children: [
                              Expanded(flex: 1, child: Text(c['code'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600, color: AppTheme.primary))),
                              Expanded(flex: 3, child: Row(children: [
                                Flexible(child: Text(c['shop_name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                                if (c['latitude'] != null && c['longitude'] != null)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 6),
                                    child: Icon(Icons.location_on, size: 14, color: AppTheme.success),
                                  ),
                              ])),
                              Expanded(flex: 2, child: Text(c['contact_person'] as String? ?? '-', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
                              Expanded(flex: 2, child: Text(c['phone'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                              Expanded(flex: 2, child: Text(c['category'] as String? ?? '-', style: const TextStyle(fontSize: 13))),
                              SizedBox(width: widget.crmMode ? 56 : 264, child: Row(children: [
                                if (!widget.crmMode && c['latitude'] != null && c['longitude'] != null)
                                  IconButton(
                                    icon: const Icon(Icons.place, size: 18, color: AppTheme.primary),
                                    tooltip: 'Show location',
                                    onPressed: () => _openLocation(
                                      (c['latitude'] as num).toDouble(),
                                      (c['longitude'] as num).toDouble(),
                                    ),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.account_circle_outlined, size: 18, color: AppTheme.primary),
                                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => Customer360Screen(customer: c),
                                  )),
                                  tooltip: 'Customer 360',
                                ),
                                if (!widget.crmMode)
                                  IconButton(
                                    icon: const Icon(Icons.history, size: 18, color: AppTheme.success),
                                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                                      builder: (_) => CustomerHistoryScreen(
                                        customerId: c['id'] as String,
                                        customerName: c['shop_name'] as String? ?? '',
                                        customerCode: c['code'] as String?,
                                      ),
                                    )),
                                    tooltip: 'View History',
                                  ),
                                if (!widget.crmMode)
                                  IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _showDialog(context, c)),
                                if (!widget.crmMode && _canDeactivateCustomer(ref.watch(currentUserProvider)?.role))
                                  IconButton(
                                    icon: Icon(
                                      (c['is_active'] as bool? ?? true)
                                          ? Icons.block
                                          : Icons.check_circle_outline,
                                      size: 18,
                                      color: (c['is_active'] as bool? ?? true)
                                          ? AppTheme.danger
                                          : AppTheme.success,
                                    ),
                                    onPressed: () => _toggleCustomerActive(c),
                                    tooltip: (c['is_active'] as bool? ?? true)
                                        ? 'Deactivate'
                                        : 'Activate',
                                  ),
                                if (!widget.crmMode && _canDeleteCustomer(ref.watch(currentUserProvider)?.role))
                                  IconButton(icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger), onPressed: () => _delete(c['id'] as String)),
                              ])),
                            ]),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _canDeleteCustomer(WebUserRole? role) =>
      role == WebUserRole.masterAdmin;

  bool _canDeactivateCustomer(WebUserRole? role) =>
      role == WebUserRole.masterAdmin || role == WebUserRole.admin;

  Future<void> _toggleCustomerActive(Map<String, dynamic> c) async {
    final newVal = !(c['is_active'] as bool? ?? true);
    try {
      await Supabase.instance.client
          .from('customers')
          .update({'is_active': newVal}).eq('id', c['id']);
      _showSnack(newVal ? 'Customer activated' : 'Customer deactivated');
      _load();
    } catch (e) {
      _showSnack('Failed: ${e.toString().split('\n').first}');
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Customer'),
        content: const Text('Are you sure you want to delete this customer?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await Supabase.instance.client.from('customers').delete().eq('id', id);
      _showSnack('Customer deleted');
      _load();
    }
  }

  String _norm(dynamic v) {
    if (v == null) return '';
    if (v is num) return v.toString();
    return v.toString().trim();
  }

  /// Logs a customer edit into the shared voucher_audit_log (voucher_type
  /// 'CUSTOMER'), recording which fields changed. Best-effort; never blocks
  /// the save.
  Future<void> _logCustomerEdit(
      Map<String, dynamic> oldC, Map<String, dynamic> newC) async {
    const labels = {
      'shop_name': 'shop name',
      'code': 'code',
      'contact_person': 'contact',
      'phone': 'phone',
      'address': 'address',
      'category': 'category',
      'group_name': 'group',
      'credit_limit': 'credit limit',
      'ntn_gst': 'NTN',
    };
    String disp(dynamic v) {
      final s = v?.toString().trim() ?? '';
      return s.isEmpty ? '—' : s;
    }

    final changed = <String>[];
    final changeTrail = <Map<String, String>>[];
    void track(String label, dynamic oldV, dynamic newV) {
      changed.add(label);
      changeTrail
          .add({'field': label, 'from': disp(oldV), 'to': disp(newV)});
    }

    labels.forEach((k, label) {
      if (_norm(oldC[k]) != _norm(newC[k])) track(label, oldC[k], newC[k]);
    });
    if (_norm(oldC['latitude']) != _norm(newC['latitude']) ||
        _norm(oldC['longitude']) != _norm(newC['longitude'])) {
      track(
        'location',
        '${disp(oldC['latitude'])}, ${disp(oldC['longitude'])}',
        '${disp(newC['latitude'])}, ${disp(newC['longitude'])}',
      );
    }
    if (changed.isEmpty) return;
    try {
      await Supabase.instance.client.from('voucher_audit_log').insert({
        'id': 'al_${DateTime.now().microsecondsSinceEpoch}',
        'org_id': ref.read(currentUserProvider)?.orgId,
        'voucher_id': oldC['id'],
        'voucher_type': 'CUSTOMER',
        'action': 'edited',
        'details':
            '${newC['shop_name'] ?? oldC['shop_name']}: changed ${changed.join(', ')}',
        'user_id': ref.read(currentUserProvider)?.id,
        'performed_by': Supabase.instance.client.auth.currentUser?.email,
      });
    } catch (_) {/* audit is best-effort */}

    // Optional email alert — the Edge Function decides whether to actually
    // send, based on the org's Admin Settings toggle + recipient list.
    try {
      await Supabase.instance.client.functions.invoke(
        'notify-customer-edit',
        body: {
          'customerName': newC['shop_name'] ?? oldC['shop_name'],
          'changes': changeTrail,
        },
      );
    } catch (_) {/* alert is best-effort */}
  }

  void _showDialog(BuildContext context, Map<String, dynamic>? customer) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    final allBranches = orgId != null ? await Supabase.instance.client
        .from('branches').select().eq('org_id', orgId).eq('is_active', true).order('name') : [];
    Set<String> selectedBranches = {};
    if (customer != null && orgId != null) {
      final existing = await Supabase.instance.client
          .from('customer_branches').select('branch_id').eq('customer_id', customer['id']);
      selectedBranches = (existing as List).map((b) => b['branch_id'] as String).toSet();
    }
    if (!mounted) return;
    final shopCtrl = TextEditingController(text: customer?['shop_name'] ?? '');
    final codeCtrl = TextEditingController(text: customer?['code'] ?? '');
    final contactCtrl = TextEditingController(text: customer?['contact_person'] ?? '');
    final phoneCtrl = TextEditingController(text: customer?['phone'] ?? '');
    final addressCtrl = TextEditingController(text: customer?['address'] ?? '');
    final latCtrl = TextEditingController(text: customer?['latitude']?.toString() ?? '');
    final lngCtrl = TextEditingController(text: customer?['longitude']?.toString() ?? '');
    final creditLimitCtrl = TextEditingController(text: customer?['credit_limit']?.toString() ?? '');
    final ntnCtrl = TextEditingController(text: customer?['ntn_gst'] ?? '');
    String? category = customer?['category'] as String?;
       String? group = customer?['group_name'] as String?;
       // Build dropdown lists that include any orphan values from the
       // existing customer — otherwise opening then saving would silently
       // wipe categories/groups set up via the mobile app (which uses a
       // separate local store; see app_config sync gap).
       final categoryItems = {
         ..._categories,
         if (category != null && category.isNotEmpty) category,
       }.toList();
       final groupItems = {
         ..._groups,
         if (group != null && group.isNotEmpty) group,
       }.toList();

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(customer == null ? 'Add Customer' : 'Edit Customer'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Basic info
                const Align(alignment: Alignment.centerLeft,
                  child: Text('Basic Info', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: shopCtrl, decoration: const InputDecoration(labelText: 'Shop Name *'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'Customer Code *'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(controller: contactCtrl, decoration: const InputDecoration(labelText: 'Contact Person'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone'), keyboardType: TextInputType.phone)),
                ]),
                const SizedBox(height: 12),
                // Category & Group dropdowns side-by-side
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: category,
                      decoration: const InputDecoration(labelText: 'Category'),
                      hint: const Text('Select category'),
                      items: categoryItems.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                      onChanged: (v) => setS(() => category = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: group,
                      decoration: const InputDecoration(labelText: 'Group'),
                      hint: const Text('Select group'),
                      items: groupItems.map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
                      onChanged: (v) => setS(() => group = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                // Credit Limit
                const Align(alignment: Alignment.centerLeft,
                  child: Text('Credit Limit', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: creditLimitCtrl,
                      decoration: const InputDecoration(labelText: 'Credit Limit (optional)', hintText: 'Leave blank for no limit'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))])),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(controller: ntnCtrl,
                      decoration: const InputDecoration(labelText: 'NTN'))),
                ]),
                const SizedBox(height: 16),
                // Address
                const Align(alignment: Alignment.centerLeft,
                  child: Text('Address', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Street Address'), maxLines: 2),
                const SizedBox(height: 16),
                // Branch assignment
                if ((allBranches as List).isNotEmpty)
                  StatefulBuilder(builder: (ctx2, setSB) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Align(alignment: Alignment.centerLeft,
                        child: Text('Branch Assignment', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(8)),
                        child: Column(children: (allBranches as List).map((b) => CheckboxListTile(
                          dense: true,
                          title: Text(b['name'] as String, style: const TextStyle(fontSize: 13)),
                          value: selectedBranches.contains(b['id'] as String),
                          onChanged: (v) => setSB(() {
                            if (v == true) selectedBranches.add(b['id'] as String);
                            else selectedBranches.remove(b['id'] as String);
                          }),
                        )).toList()),
                      ),
                    ],
                  )),
                const SizedBox(height: 16),
                // Location
                const Align(alignment: Alignment.centerLeft,
                  child: Text('Location Coordinates', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppTheme.textSecondary))),
                const SizedBox(height: 4),
                const Align(alignment: Alignment.centerLeft,
                  child: Text('Enter GPS coordinates manually or use the mobile app to set location on-site.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(
                    controller: latCtrl,
                    decoration: const InputDecoration(labelText: 'Latitude', hintText: 'e.g. 31.5204'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: TextField(
                    controller: lngCtrl,
                    decoration: const InputDecoration(labelText: 'Longitude', hintText: 'e.g. 74.3587'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  )),
                ]),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.map_outlined, size: 16),
                    label: const Text('Open Google Maps to find coordinates', style: TextStyle(fontSize: 12)),
                    onPressed: () {
                      final lat = double.tryParse(latCtrl.text.trim());
                      final lng = double.tryParse(lngCtrl.text.trim());
                      final q = (lat != null && lng != null) ? '$lat,$lng' : '';
                      html.window.open(
                        'https://www.google.com/maps/search/?api=1&query=$q',
                        '_blank',
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                if (shopCtrl.text.trim().isEmpty || codeCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Shop name and code are required')));
                  return;
                }
                final orgId = ref.read(currentUserProvider)?.orgId;
                final lat = double.tryParse(latCtrl.text.trim());
                final lng = double.tryParse(lngCtrl.text.trim());
                final data = {
                  'shop_name': shopCtrl.text.trim(),
                  'code': codeCtrl.text.trim(),
                  'contact_person': contactCtrl.text.trim(),
                  'phone': phoneCtrl.text.trim(),
                  'address': addressCtrl.text.trim(),
                  'category': category,
                  'group_name': group,
                  'latitude': lat,
                  'longitude': lng,
                  'credit_limit': creditLimitCtrl.text.trim().isEmpty ? null : double.tryParse(creditLimitCtrl.text.trim()),
                  'ntn_gst': ntnCtrl.text.trim().isEmpty ? null : ntnCtrl.text.trim(),
                  'org_id': orgId,
                  'is_active': true,
                };
                final isNew = customer == null;
                try {
                  if (isNew) {
                    final id = 'cust_${DateTime.now().millisecondsSinceEpoch}';
                    await Supabase.instance.client.from('customers').insert({...data, 'id': id, 'updated_at': DateTime.now().toIso8601String()});
                  } else {
                    await Supabase.instance.client.from('customers').update(data).eq('id', customer['id']);
                    await _logCustomerEdit(customer, data);
                  }
                  if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
                  _showSnack(isNew ? 'Customer added' : 'Customer updated');
                  _load();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text('Failed: ${e.toString().split('\n').first}'),
                    ));
                  }
                }
              },
              child: Text(customer == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}
