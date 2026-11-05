import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/app_database_provider.dart';
import '../../auth/models/user_role.dart';
import '../../auth/providers/auth_controller.dart';
import '../services/survey_audit_service.dart';
import '../services/survey_feedback.dart' show auditLocationOnProvider;
import 'feedbacks_tab.dart';
import 'shop_lists_data.dart';
import 'survey_view_sheet.dart';

/// Shops that have a Placement Audit or Competitor Spotting, newest survey
/// first. Tap one to see its survey. Auditors also get feedback filters, a
/// Feedback button on each shop and a "Feedbacks" tab.
class SurveyedShopsScreen extends ConsumerStatefulWidget {
  const SurveyedShopsScreen({super.key});
  @override
  ConsumerState<SurveyedShopsScreen> createState() => _SurveyedShopsScreenState();
}

class _SurveyedShopsScreenState extends ConsumerState<SurveyedShopsScreen> {
  ShopListData? _data;
  bool _fetching = false;
  String _q = '';
  String _filter = 'all'; // all | none | with

  bool get _auditor => ref.read(authControllerProvider).valueOrNull?.role == UserRole.auditor;

  @override
  void initState() {
    super.initState();
    // What the phone has straight away, then the latest from the server.
    _load().then((_) => _fetch());
  }

  Future<void> _fetch() async {
    if (_fetching) return;
    if (mounted) setState(() => _fetching = true);
    await refreshSurveys(ref);
    if (_auditor) {
      try {
        await SurveyAuditService(ref.read(appDatabaseProvider)).flush();
      } catch (_) {}
    }
    await _load();
    if (mounted) setState(() => _fetching = false);
  }

  Future<void> _load() async {
    final d = await loadShopLists(ref, withAudits: _auditor);
    if (mounted) setState(() => _data = d);
  }

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withOpacity(0.10), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c)),
      );

  Widget _shops(ShopListData d) {
    final hint = Theme.of(context).hintColor;
    final q = _q.trim().toLowerCase();
    final ids = d.lastSurvey.keys.toList()..sort((a, b) => d.lastSurvey[b]!.compareTo(d.lastSurvey[a]!));
    final shown = [
      for (final id in ids)
        if ((q.isEmpty || d.shops[id]!.shopName.toLowerCase().contains(q) || d.shops[id]!.code.toLowerCase().contains(q)) &&
            switch (_filter) {
              'none' => (d.feedbackCount[id] ?? 0) == 0,
              'with' => (d.feedbackCount[id] ?? 0) > 0,
              _ => true,
            })
          d.shops[id]!
    ];
    const green = Color(0xFF047857), red = Color(0xFFB91C1C), amber = Color(0xFFB45309), grey = Color(0xFF475569);
    const blue = Color(0xFF1D4ED8);
    final df = DateFormat('d MMM');
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
      if (_auditor)
        SizedBox(
          height: 40,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
            for (final f in const [('all', 'All'), ('none', 'No feedback'), ('with', 'With feedback')]) ...[
              ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
              const SizedBox(width: 6),
            ],
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('${shown.length} shop${shown.length == 1 ? '' : 's'} · newest survey first',
              style: TextStyle(fontSize: 12.5, color: hint)),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _fetch,
          child: shown.isEmpty
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(child: Text(_fetching ? 'Fetching surveys…' : 'No surveyed shops here.')),
                  ),
                ])
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final s = shown[i];
                    final p = d.placement[s.id];
                    final c = d.competitor[s.id] ?? 0;
                    final fb = d.feedbackCount[s.id] ?? 0;
                    final by = d.lastBy[s.id] ?? '';
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          await SurveyViewSheet.show(context, s, showFeedback: _auditor);
                          if (_auditor) _load();
                        },
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
                              if (_auditor && fb > 0) ...[
                                const SizedBox(width: 8),
                                _badge('$fb 💬', blue),
                              ],
                            ]),
                            const SizedBox(height: 2),
                            Text(
                              [s.code, 'surveyed ${df.format(d.lastSurvey[s.id]!)}', if (by.isNotEmpty) by].join(' · '),
                              style: TextStyle(fontSize: 12, color: hint),
                            ),
                            const SizedBox(height: 8),
                            Wrap(spacing: 6, runSpacing: 4, children: [
                              if (p == null)
                                _badge('No placement', amber)
                              else
                                _badge('Placement ${p.$1}/${p.$2}', p.$2 > 0 && p.$1 * 2 >= p.$2 ? green : red),
                              c == 0 ? _badge('No competitor', amber) : _badge('Competitor $c', grey),
                            ]),
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
    final refreshBtn = _fetching
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
        : IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _fetch);
    if (!_auditor) {
      return Scaffold(
        appBar: AppBar(title: const Text('Surveyed shops'), actions: [refreshBtn]),
        body: d == null ? const Center(child: CircularProgressIndicator()) : _shops(d),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Surveyed shops'),
          actions: [refreshBtn],
          bottom: const TabBar(tabs: [Tab(text: 'Shops'), Tab(text: 'Feedbacks')]),
        ),
        body: d == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                _shops(d),
                FeedbacksTab(
                  audits: d.audits,
                  shops: {for (final id in d.surveyed) id: d.shops[id]!},
                  surveyed: d.surveyed,
                  myId: user?.id,
                  orgName: user?.organizationName ?? '',
                  title: 'Surveyed shops',
                  onRefresh: _fetch,
                  showLocation: ref.watch(auditLocationOnProvider).valueOrNull ?? true,
                ),
              ]),
      ),
    );
  }
}
