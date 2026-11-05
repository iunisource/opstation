import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/app_database_provider.dart';
import '../../../core/services/device_gps_service.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/survey_audit_service.dart';
import '../services/survey_feedback.dart';
import 'feedbacks_tab.dart';
import 'shop_lists_data.dart';

/// Auditor: active shops (in their customer groups) with no survey yet,
/// nearest first. Tap a shop for its details and to give feedback.
class NonSurveyedShopsScreen extends ConsumerStatefulWidget {
  const NonSurveyedShopsScreen({super.key});
  @override
  ConsumerState<NonSurveyedShopsScreen> createState() => _NonSurveyedShopsScreenState();
}

class _NonSurveyedShopsScreenState extends ConsumerState<NonSurveyedShopsScreen> {
  ShopListData? _data;
  bool _fetching = false;
  String _q = '';
  String _sort = 'near'; // near | az | noloc
  (double, double)? _here;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _fetch());
    _locate();
  }

  Future<void> _locate() async {
    if (_locating) return;
    try {
      if (!await ref.read(auditLocationOnProvider.future)) return; // tracking off
    } catch (_) {}
    if (!mounted) return;
    setState(() => _locating = true);
    try {
      final r = await ref.read(deviceGpsServiceProvider).getFixResult(timeout: const Duration(seconds: 15));
      if (r.ok && mounted) setState(() => _here = (r.fix!.lat, r.fix!.lng));
    } catch (_) {}
    if (mounted) setState(() => _locating = false);
  }

  Future<void> _fetch() async {
    if (_fetching) return;
    if (mounted) setState(() => _fetching = true);
    await refreshSurveys(ref);
    try {
      await SurveyAuditService(ref.read(appDatabaseProvider)).flush();
    } catch (_) {}
    await _load();
    if (mounted) setState(() => _fetching = false);
  }

  Future<void> _load() async {
    final d = await loadShopLists(ref);
    if (mounted) setState(() => _data = d);
  }

  /// Admin Settings → Auditor location tracking. OFF: no distances, A–Z only.
  bool get _track => ref.watch(auditLocationOnProvider).valueOrNull ?? true;

  double? _dist(CustomersData s) => (!_track || _here == null) ? null : distanceTo(s, _here!.$1, _here!.$2);

  String _distText(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c)),
      );

  Future<void> _open(CustomersData s, ShopListData d) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ShopSheet(shop: s, audits: [for (final a in d.audits) if (a['customer_id'] == s.id) a]),
    );
    if (saved == true) _load();
  }

  Widget _shops(ShopListData d) {
    final hint = Theme.of(context).hintColor;
    final q = _q.trim().toLowerCase();
    final list = [
      for (final s in d.shops.values)
        if (!d.lastSurvey.containsKey(s.id) &&
            (q.isEmpty || s.shopName.toLowerCase().contains(q) || s.code.toLowerCase().contains(q)) &&
            (_sort != 'noloc' || s.latitude == null || s.longitude == null))
          s
    ];
    final noLoc = d.shops.values.where((s) => !d.lastSurvey.containsKey(s.id) && (s.latitude == null || s.longitude == null)).length;
    int az(CustomersData a, CustomersData b) => a.shopName.toLowerCase().compareTo(b.shopName.toLowerCase());
    if (_track && _sort == 'near' && _here != null) {
      list.sort((a, b) {
        final da = _dist(a), db = _dist(b);
        if (da == null && db == null) return az(a, b);
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
    } else {
      list.sort(az);
    }
    const blue = Color(0xFF1D4ED8);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          if (_track) ...[
            ChoiceChip(
              label: const Text('Nearest first'),
              selected: _sort == 'near',
              onSelected: (_) {
                setState(() => _sort = 'near');
                if (_here == null) _locate();
              },
            ),
            const SizedBox(width: 6),
          ],
          ChoiceChip(
              label: const Text('A–Z'),
              selected: _sort == 'az' || (!_track && _sort == 'near'),
              onSelected: (_) => setState(() => _sort = 'az')),
          const SizedBox(width: 6),
          ChoiceChip(
              label: Text('No location $noLoc'),
              selected: _sort == 'noloc',
              onSelected: (_) => setState(() => _sort = 'noloc')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '${list.length} shop${list.length == 1 ? '' : 's'} not surveyed yet'
            '${_track && _sort == 'near' && _here == null ? (_locating ? ' · finding your location…' : ' · location not available') : ''}',
            style: TextStyle(fontSize: 12.5, color: hint),
          ),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async {
            _locate();
            await _fetch();
          },
          child: list.isEmpty
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(child: Text(_fetching ? 'Loading…' : 'No shops here.')),
                  ),
                ])
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final s = list[i];
                    final dm = _dist(s);
                    final fb = d.feedbackCount[s.id] ?? 0;
                    final noShopLoc = s.latitude == null || s.longitude == null;
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _open(s, d),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(
                                child: Text(s.shopName,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 8),
                              if (_track)
                                Text(
                                noShopLoc ? 'no location' : (dm == null ? '' : _distText(dm)),
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w700, color: noShopLoc ? hint : blue),
                              ),
                            ]),
                            const SizedBox(height: 2),
                            Text(
                              [
                                s.code,
                                if ((s.groupName ?? '').trim().isNotEmpty) s.groupName!.trim(),
                                if (s.address.trim().isNotEmpty) s.address.trim(),
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                            if (fb > 0) ...[
                              const SizedBox(height: 6),
                              _badge('$fb 💬', blue),
                            ],
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final user = ref.read(authControllerProvider).valueOrNull;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Non-surveyed shops'),
          actions: [
            _fetching
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () {
                    _locate();
                    _fetch();
                  }),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Shops'), Tab(text: 'Feedbacks')]),
        ),
        body: d == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                _shops(d),
                FeedbacksTab(
                  audits: d.audits,
                  shops: {for (final s in d.shops.values) if (!d.lastSurvey.containsKey(s.id)) s.id: s},
                  surveyed: d.surveyed,
                  myId: user?.id,
                  orgName: user?.organizationName ?? '',
                  title: 'Non-surveyed shops',
                  onRefresh: _fetch,
                  showLocation: ref.watch(auditLocationOnProvider).valueOrNull ?? true,
                ),
              ]),
      ),
    );
  }
}

/// Shop details + its feedback + the Feedback button.
class _ShopSheet extends ConsumerWidget {
  final CustomersData shop;
  final List<Map<String, dynamic>> audits;
  const _ShopSheet({required this.shop, required this.audits});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hint = Theme.of(context).hintColor;
    final df = DateFormat('d MMM yyyy, h:mm a');
    Widget line(IconData i, String t) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 16, color: hint),
            const SizedBox(width: 8),
            Expanded(child: Text(t, style: const TextStyle(fontSize: 13.5))),
          ]),
        );
    final hasLoc = shop.latitude != null && shop.longitude != null;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(16, 10, 16, 24), children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: Theme.of(context).dividerColor, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        const SizedBox(height: 12),
        Text(shop.shopName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        Text([shop.code, if ((shop.groupName ?? '').trim().isNotEmpty) shop.groupName!.trim()].join(' · '),
            style: TextStyle(color: hint)),
        const SizedBox(height: 4),
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFFB45309).withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
          child: const Text('Not surveyed yet',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFB45309))),
        ),
        if (shop.address.trim().isNotEmpty) line(Icons.place_outlined, shop.address.trim()),
        if (shop.contactPerson.trim().isNotEmpty) line(Icons.person_outline, shop.contactPerson.trim()),
        if (shop.phone.trim().isNotEmpty) line(Icons.phone_outlined, shop.phone.trim()),
        const SizedBox(height: 10),
        Row(children: [
          if (hasLoc)
            OutlinedButton.icon(
              icon: const Icon(Icons.directions_outlined, size: 18),
              label: const Text('Directions'),
              onPressed: () => launchUrl(
                Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${shop.latitude},${shop.longitude}'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          if (hasLoc && shop.phone.trim().isNotEmpty) const SizedBox(width: 8),
          if (shop.phone.trim().isNotEmpty)
            OutlinedButton.icon(
              icon: const Icon(Icons.call_outlined, size: 18),
              label: const Text('Call'),
              onPressed: () => launchUrl(Uri.parse('tel:${shop.phone.trim()}')),
            ),
        ]),
        const Divider(height: 28),
        Text('Feedback', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        if (audits.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('No feedback yet.', style: TextStyle(color: hint))),
        for (final a in audits)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                [
                  '${a['auditor_name'] ?? ''}',
                  if (DateTime.tryParse('${a['audited_at']}') != null) df.format(DateTime.parse('${a['audited_at']}').toLocal()),
                  if (a['_pending'] == true) 'not sent yet',
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: hint),
              ),
              Text('${a['comment'] ?? ''}', style: const TextStyle(fontSize: 13.5)),
              if ((a['photo_path'] ?? a['local_photo']) != null)
                TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: () => showFeedbackPhoto(context, a),
                  icon: const Icon(Icons.photo_outlined, size: 16),
                  label: const Text('View photo'),
                ),
            ]),
          ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Feedback')),
            onPressed: () async {
              final ok = await giveFeedback(context, ref, shop);
              if (ok && context.mounted) Navigator.pop(context, true);
            },
          ),
        ),
      ]),
    );
  }
}
