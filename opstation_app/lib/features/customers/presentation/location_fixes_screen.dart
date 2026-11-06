import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/utils/location_check.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/field_location_capture.dart';

/// Surveyor: shops whose location needs fixing — saved at the same spot as a
/// different shop (copied / imported wrongly), or with no location at all.
/// Tap one to set its location; it leaves the list once fixed.
class LocationFixesScreen extends ConsumerStatefulWidget {
  const LocationFixesScreen({super.key});
  @override
  ConsumerState<LocationFixesScreen> createState() => _LocationFixesScreenState();
}

class _LocationFixesScreenState extends ConsumerState<LocationFixesScreen> {
  List<CustomersData> _wrong = [];
  List<CustomersData> _missing = [];
  Map<String, List<CustomersData>> _same = {};
  bool _loading = true;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    final db = ref.read(appDatabaseProvider);
    final orgId = ref.read(authControllerProvider).valueOrNull?.organizationId;
    if (refresh && orgId != null) await refreshSuspectLocations(db, orgId);
    ref.invalidate(suspectLocationIdsProvider);
    final ids = await ref.read(suspectLocationIdsProvider.future);
    final all = [
      for (final c in await (db.select(db.customers)..where((c) => c.isActive.equals(true))).get())
        if (orgId == null || c.orgId == null || c.orgId == orgId) c
    ]..sort((a, b) => a.shopName.toLowerCase().compareTo(b.shopName.toLowerCase()));
    final wrong = [for (final c in all) if (ids.contains(c.id) && c.latitude != null && c.longitude != null) c];
    final same = <String, List<CustomersData>>{};
    for (final c in wrong) {
      same[c.id] = await otherShopsAtSpot(db, lat: c.latitude!, lng: c.longitude!, customerId: c.id);
    }
    if (!mounted) return;
    setState(() {
      _wrong = wrong;
      _missing = [for (final c in all) if (c.latitude == null || c.longitude == null) c];
      _same = same;
      _loading = false;
    });
  }

  /// At the shop: photo + GPS, stamped and sent for review (as salespeople do).
  Future<void> _open(CustomersData c) async {
    final ok = await FieldLocationCapture.runForShop(context, ref,
        customerId: c.id, shopName: c.shopName, shopCode: c.code);
    if (ok) _load();
  }

  Widget _list(List<CustomersData> rows, {required bool wrong}) {
    final hint = Theme.of(context).hintColor;
    final q = _q.trim().toLowerCase();
    final shown = [
      for (final c in rows)
        if (q.isEmpty || c.shopName.toLowerCase().contains(q) || c.code.toLowerCase().contains(q)) c
    ];
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: shown.isEmpty
          ? ListView(children: [
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(child: Text(wrong ? 'No shop locations to fix.' : 'Every shop has a location.')),
              ),
            ])
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: shown.length,
              itemBuilder: (_, i) {
                final c = shown[i];
                final others = _same[c.id] ?? const <CustomersData>[];
                return Card(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                  child: ListTile(
                    onTap: () => _open(c),
                    title: Text(c.shopName, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      [
                        c.code,
                        if (c.address.trim().isNotEmpty) c.address.trim(),
                        if (wrong && others.isNotEmpty)
                          'same spot as ${others.first.shopName}${others.length > 1 ? ' +${others.length - 1}' : ''}',
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: hint),
                    ),
                    trailing: Icon(wrong ? Icons.wrong_location_outlined : Icons.location_off,
                        color: wrong ? const Color(0xFFD97706) : const Color(0xFFDC2626)),
                  ),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Location fixes'),
          bottom: TabBar(tabs: [
            Tab(text: 'Wrong location (${_wrong.length})'),
            Tab(text: 'No location (${_missing.length})'),
          ]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    onChanged: (v) => setState(() => _q = v),
                    decoration: InputDecoration(
                      hintText: 'Search shop or code',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                  child: Text('At the shop, tap it to take a photo — the location is saved with it and sent for review. '
                      'It leaves this list once fixed.',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                ),
                Expanded(
                  child: TabBarView(children: [
                    _list(_wrong, wrong: true),
                    _list(_missing, wrong: false),
                  ]),
                ),
              ]),
      ),
    );
  }
}
