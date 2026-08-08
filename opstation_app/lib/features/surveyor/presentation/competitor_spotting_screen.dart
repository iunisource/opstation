import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/sync/sync_controller.dart';
import 'package:drift/drift.dart' show Value, OrderingTerm;
import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../auth/providers/auth_controller.dart';

class CompetitorSpottingScreen extends ConsumerStatefulWidget {
  const CompetitorSpottingScreen({super.key});
  @override
  ConsumerState<CompetitorSpottingScreen> createState() => _CompetitorSpottingScreenState();
}

class _CompetitorSpottingScreenState extends ConsumerState<CompetitorSpottingScreen> {
  CustomersData? _selectedCustomer;
  CompetitorCategoryRow? _selectedCategory;
  List<CustomersData> _allCustomers = [];
  List<CustomersData> _filteredCustomers = [];
  List<CompetitorCategoryRow> _categories = [];

  final _searchCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _specsCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _searchCtrl.addListener(_filter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _brandCtrl.dispose();
    _priceCtrl.dispose();
    _specsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    final customers = await (db.select(db.customers)
          ..where((c) => c.isActive.equals(true))
          ..orderBy([(c) => OrderingTerm.asc(c.shopName)]))
        .get();
    final categories = await (db.select(db.competitorCategories)
          ..where((c) => c.isActive.equals(true))
          ..orderBy([
            (c) => OrderingTerm.asc(c.position),
            (c) => OrderingTerm.asc(c.name),
          ]))
        .get();
    if (!mounted) return;
    setState(() {
      _allCustomers = orgId == null ? customers : customers.where((c) => c.orgId == orgId).toList();
      _filteredCustomers = _allCustomers;
      _categories = orgId == null ? categories : categories.where((c) => c.orgId == orgId).toList();
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

  Future<void> _selectCategory(CompetitorCategoryRow cat) async {
    final db = ref.read(appDatabaseProvider);
    final latest = await (db.select(db.competitorSpottings)
          ..where((cs) => cs.customerId.equals(_selectedCustomer!.id))
      ..where((cs) => cs.categoryId.equals(cat.id))
          ..orderBy([(cs) => OrderingTerm.desc(cs.surveyedAt)])
          ..limit(1))
        .getSingleOrNull();
    setState(() {
      _selectedCategory = cat;
      _brandCtrl.text = latest?.brandName ?? '';
      _priceCtrl.text = latest?.price?.toString() ?? '';
      _specsCtrl.text = latest?.specs ?? '';
    });
  }

  /// Guard against accidental double-saves: if this shop + category was
  /// spotted within the last 15 minutes, ask before writing another row.
  Future<bool> _confirmRecentSave() async {
    final db = ref.read(appDatabaseProvider);
    final recent = await (db.select(db.competitorSpottings)
          ..where((cs) => cs.customerId.equals(_selectedCustomer!.id))
          ..where((cs) => cs.categoryId.equals(_selectedCategory!.id))
          ..orderBy([(cs) => OrderingTerm.desc(cs.surveyedAt)])
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
        title: const Text('Spotted recently'),
        content: Text(
            '${_selectedCategory!.name} at this shop was already recorded $ago ago. Save a new spotting anyway?'),
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
    if (_selectedCustomer == null || _selectedCategory == null) return;
    if (_brandCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Brand name is required')),
      );
      return;
    }
    if (!await _confirmRecentSave()) return;
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final db = ref.read(appDatabaseProvider);
      final user = ref.read(authControllerProvider).valueOrNull;
      final orgId = user?.organizationId;
      if (orgId == null) throw Exception('No org context');
      final now = DateTime.now();
      final priceTxt = _priceCtrl.text.trim();
      final specsTxt = _specsCtrl.text.trim();
      await db.into(db.competitorSpottings).insert(CompetitorSpottingsCompanion.insert(
        id: 'cs_${now.millisecondsSinceEpoch}',
        orgId: orgId,
        customerId: _selectedCustomer!.id,
        categoryId: _selectedCategory!.id,
        brandName: _brandCtrl.text.trim(),
        price: Value(priceTxt.isEmpty ? null : int.tryParse(priceTxt)),
        specs: Value(specsTxt.isEmpty ? null : specsTxt),
        surveyedByUserId: Value(user!.id),
        surveyedAt: now,
        createdAt: now,
        syncStatus: const Value('pending'),
      ));
      print('SURVEYOR SAVE [competitor]: triggering sync');
      ref.read(syncControllerProvider.notifier).noteNewPendingVisit();
      _auditedIds.add(_selectedCustomer!.id);
      _auditedIdsInitialized = true;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: ${_selectedCategory!.name} @ ${_selectedCustomer!.shopName}')),
      );
      setState(() {
        _selectedCategory = null;
        _brandCtrl.clear();
        _priceCtrl.clear();
        _specsCtrl.clear();
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
    final rows = await db.select(db.competitorSpottings).get();
    if (!mounted) return;
    setState(() {
      _auditedIds = rows.map((r) => r.customerId).toSet();
      _auditedIdsInitialized = true;
    });
  }

  List<CustomersData> _applyFilter(List<CustomersData> base) {
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
        appBar: AppBar(title: const Text('Competitor Spotting')),
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
              return ListView.separated(
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
                    onTap: () => setState(() => _selectedCustomer = c),
                  );
                },
              );
            }),
          ),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Competitor Spotting'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() {
            _selectedCustomer = null;
            _selectedCategory = null;
            _brandCtrl.clear();
            _priceCtrl.clear();
            _specsCtrl.clear();
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
          ]),
        ),
        if (_categories.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'No competitor categories configured. Ask your admin to add categories via the web admin.',
              textAlign: TextAlign.center,
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Category', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _categories.map((cat) {
                    final selected = _selectedCategory?.id == cat.id;
                    return ChoiceChip(
                      label: Text(cat.name),
                      selected: selected,
                      onSelected: (v) {
                        if (v) _selectCategory(cat);
                      },
                    );
                  }).toList(),
                ),
                if (_selectedCategory != null) ...[
                  const SizedBox(height: 24),
                  TextField(
                    controller: _brandCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Brand name *',
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _priceCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Price (PKR)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _specsCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Specs / notes',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: Text(_saving ? 'Saving...' : 'Save spotting'),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ]),
    );
  }
}
