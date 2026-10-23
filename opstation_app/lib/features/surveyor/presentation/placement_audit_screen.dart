import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/sync/sync_controller.dart';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';
import '../../../core/supabase/supabase_pull_service.dart';
import 'survey_customer_filter.dart';

class PlacementAuditScreen extends ConsumerStatefulWidget {
  const PlacementAuditScreen({super.key});
  @override
  ConsumerState<PlacementAuditScreen> createState() => _PlacementAuditScreenState();
}

class _PlacementAuditScreenState extends ConsumerState<PlacementAuditScreen> {
  CustomersData? _selectedCustomer;
  List<CustomersData> _allCustomers = [];
  List<CustomersData> _filteredCustomers = [];
  List<ProductRow> _products = [];
  final Map<String, bool> _toggleState = {};
  final _searchCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _refreshing = false;

  /// Fetch the latest categories / SKUs / customers from the server, then
  /// reload this screen from the phone's copy. Runs every time the screen
  /// opens (in the background — the saved list shows straight away) and on
  /// pull-to-refresh.
  Future<void> _refresh({bool manual = false}) async {
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (orgId == null || _refreshing) return;
    setState(() => _refreshing = true);
    final ok = await ref.read(supabasePullServiceProvider).refreshSurveyReference(orgId);
    if (!mounted) return;
    await _loadCustomers();
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (manual) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Up to date' : 'No internet — showing the data saved on this phone'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  Future<void> _openFilter() async {
    final changed = await SurveyCustomerFilter.open(context, _allCustomers);
    if (changed && mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadCustomers().then((_) { if (mounted) _refresh(); });
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCustomers() async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    final rows = await (db.select(db.customers)
          ..where((c) => c.isActive.equals(true))
          ..orderBy([(c) => OrderingTerm.asc(c.shopName)]))
        .get();
    if (!mounted) return;
    setState(() {
      _allCustomers = orgId == null ? rows : rows.where((c) => c.orgId == orgId).toList();
      _filteredCustomers = _allCustomers;
      _loading = false;
    });
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredCustomers = _allCustomers.where((c) {
        if (q.isEmpty) return true;
        return c.shopName.toLowerCase().contains(q) || c.code.toLowerCase().contains(q);
      }).toList();
    });
  }

  Future<void> _selectCustomer(CustomersData customer) async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    final allProducts = await (db.select(db.products)
          ..where((p) => p.isActive.equals(true))
          ..orderBy([
            (p) => OrderingTerm.asc(p.position),
            (p) => OrderingTerm.asc(p.name),
          ]))
        .get();
    final orgProducts = orgId == null ? allProducts : allProducts.where((p) => p.orgId == orgId).toList();

    // Pre-fill toggles from last known is_present per product
    final history = await (db.select(db.placementAudits)
          ..where((p) => p.customerId.equals(customer.id))
          ..orderBy([(p) => OrderingTerm.desc(p.surveyedAt)]))
        .get();
    final latest = <String, bool>{};
    for (final r in history) {
      latest.putIfAbsent(r.productId, () => r.isPresent);
    }

    if (!mounted) return;
    setState(() {
      _selectedCustomer = customer;
      _products = orgProducts;
      _toggleState.clear();
      for (final p in orgProducts) {
        _toggleState[p.id] = latest[p.id] ?? false;
      }
    });
  }

  /// Guard against accidental double-saves: if this shop was audited within
  /// the last 15 minutes, ask before writing another full set of rows. A
  /// deliberate re-audit is one extra tap; a double-tap gets caught.
  Future<bool> _confirmRecentSave() async {
    final db = ref.read(appDatabaseProvider);
    final recent = await (db.select(db.placementAudits)
          ..where((p) => p.customerId.equals(_selectedCustomer!.id))
          ..orderBy([(p) => OrderingTerm.desc(p.surveyedAt)])
          ..limit(1))
        .getSingleOrNull();
    if (recent == null) return true;
    final mins = DateTime.now().difference(recent.surveyedAt).inMinutes;
    if (mins >= 15) return true;
    if (!mounted) return false;
    final ago = mins <= 0 ? 'less than a minute' : '$mins min';
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Audited recently'),
        content: Text(
            'This shop was already audited $ago ago. Save a new audit anyway?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save anyway')),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _save() async {
    if (_selectedCustomer == null) return;
    if (!await _confirmRecentSave()) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final db = ref.read(appDatabaseProvider);
      final user = ref.read(authControllerProvider).valueOrNull;
      final orgId = user?.organizationId;
      if (orgId == null) throw Exception('No org context');
      final now = DateTime.now();
      await db.transaction(() async {
        for (int i = 0; i < _products.length; i++) {
          final p = _products[i];
          await db.into(db.placementAudits).insert(PlacementAuditsCompanion.insert(
            id: 'pa_${now.millisecondsSinceEpoch}_$i',
            orgId: orgId,
            customerId: _selectedCustomer!.id,
            productId: p.id,
            isPresent: _toggleState[p.id] ?? false,
            surveyedByUserId: Value(user!.id),
            surveyedAt: now,
            createdAt: now,
            syncStatus: const Value('pending'),
          ));
        }
      });
      print('SURVEYOR SAVE [placement]: inserted ${_products.length} rows, triggering sync');
      ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
      _auditedIds.add(_selectedCustomer!.id);
      _auditedIdsInitialized = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved audit for ${_selectedCustomer!.shopName}')),
      );
      setState(() {
        _selectedCustomer = null;
        _products = [];
        _toggleState.clear();
        _searchCtrl.clear();
        _filteredCustomers = _allCustomers;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _filterMode = 'all'; // 'all' | 'audited' | 'empty'
  Set<String> _auditedIds = {};
  bool _auditedIdsInitialized = false;
  bool _loadingAudited = false;

  Future<void> _loadAuditedIds() async {
    final db = ref.read(appDatabaseProvider);
    final rows = await db.select(db.placementAudits).get();
    if (!mounted) return;
    setState(() {
      _auditedIds = rows.map((r) => r.customerId).toSet();
      _auditedIdsInitialized = true;
    });
  }

  List<CustomersData> _applyFilter(List<CustomersData> base) {
    base = base.where(SurveyCustomerFilter.matches).toList();
    if (_filterMode == 'audited') return base.where((c) => _auditedIds.contains(c.id)).toList();
    if (_filterMode == 'empty') return base.where((c) => !_auditedIds.contains(c.id)).toList();
    return base;
  }

  @override
  Widget build(BuildContext context) {
    if (!_auditedIdsInitialized && !_loadingAudited) {
      _loadingAudited = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAuditedIds());
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_selectedCustomer == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Placement Audit'), actions: [
          SurveyCustomerFilter.button(onPressed: _openFilter),
          _refreshing
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _refresh(manual: true)),
        ]),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(label: const Text('All'), selected: _filterMode == 'all', onSelected: (_) => setState(() => _filterMode = 'all')),
                ChoiceChip(label: const Text('Audited'), selected: _filterMode == 'audited', onSelected: (_) => setState(() => _filterMode = 'audited')),
                ChoiceChip(label: const Text('Empty'), selected: _filterMode == 'empty', onSelected: (_) => setState(() => _filterMode = 'empty')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search customer by name or code',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: Builder(builder: (context) {
              final displayed = _applyFilter(_filteredCustomers);
              final list = ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: displayed.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = displayed[i];
                  final audited = _auditedIds.contains(c.id);
                  return ListTile(
                    title: Text(c.shopName),
                    subtitle: Text(c.code),
                    trailing: audited
                        ? const Icon(Icons.check_circle, color: Colors.green, size: 18)
                        : null,
                    onTap: () => _selectCustomer(c),
                  );
                },
              );
              return RefreshIndicator(
                onRefresh: () => _refresh(manual: true),
                child: Column(children: [
                  if (SurveyCustomerFilter.count > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Row(children: [
                        Expanded(child: Text('Showing ${displayed.length} of ${_allCustomers.length} shops (filtered)',
                            style: const TextStyle(fontSize: 12, color: Colors.grey))),
                        TextButton(
                          onPressed: () => setState(() {
                            SurveyCustomerFilter.mainGroups.clear();
                            SurveyCustomerFilter.groups.clear();
                          }),
                          child: const Text('Clear filter'),
                        ),
                      ]),
                    ),
                  Expanded(child: list),
                ]),
              );
            }),
          ),
        ]),
      );
    }
    final presentCount = _toggleState.values.where((v) => v).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Placement Audit'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _selectedCustomer = null;
            _products = [];
            _toggleState.clear();
          }),
        ),
      ),
      body: Column(children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(children: [
            const Icon(Icons.store, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_selectedCustomer!.shopName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(_selectedCustomer!.code, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
            Text('$presentCount / ${_products.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
        Expanded(
          child: _products.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No active products in catalog. Ask your admin to add products via the web admin.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: _products.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final p = _products[i];
                    return CheckboxListTile(
                      value: _toggleState[p.id] ?? false,
                      title: Text(p.name),
                      subtitle: p.skuCode != null && p.skuCode!.isNotEmpty ? Text(p.skuCode!) : null,
                      onChanged: (v) => setState(() => _toggleState[p.id] = v ?? false),
                    );
                  },
                ),
        ),
        if (_products.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(_saving ? 'Saving...' : 'Save audit'),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
