// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'customer_history_screen.dart';

/// Customer 360 — a unified view of a single shop:
///  • Overview     : profile, location, credit vs current outstanding
///  • Receivables  : GL-true aging buckets + open items
///  • Visits       : recent field visits (+ link into full history)
///
/// Receivables are wired to the SAME backend as the Customer Aging report
/// (`rpc_customer_aging` / `rpc_customer_aging_detail`, all-branches so the
/// total ties to the GL 1210 balance). We call those org-wide RPCs and filter
/// to this one customer client-side rather than inventing a parallel calc.
class Customer360Screen extends ConsumerStatefulWidget {
  final Map<String, dynamic> customer;
  const Customer360Screen({super.key, required this.customer});

  @override
  ConsumerState<Customer360Screen> createState() => _Customer360ScreenState();
}

class _Customer360ScreenState extends ConsumerState<Customer360Screen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  bool _loadingAr = true;
  String? _arError;

  // GL-true aging. current = total - b1 - b2 - b3 - b4 (so credit/overpaid
  // balances, which carry no open debits, are reflected in `current`).
  double _current = 0, _b1 = 0, _b2 = 0, _b3 = 0, _b4 = 0, _arTotal = 0;
  final List<Map<String, dynamic>> _openItems = [];

  bool _loadingVisits = true;
  List<Map<String, dynamic>> _visits = [];

  bool _loadingIntel = true;
  List<Map<String, dynamic>> _placement = [];
  List<Map<String, dynamic>> _competitors = [];

  bool _loadingActs = true;
  List<Map<String, dynamic>> _activities = [];
  List<Map<String, dynamic>> _orgUsers = [];
  Map<String, String> _userNames = {};

  bool _loadingComplaints = true;
  List<Map<String, dynamic>> _complaints = [];

  bool _targetsEnabled = false;
  bool _loadingTarget = true;
  double _target = 0;
  double _achieved = 0;

  final _money = NumberFormat('#,##0');
  final _money2 = NumberFormat('#,##0.00');

  String get _customerId => widget.customer['id'] as String;
  String get _shopName => (widget.customer['shop_name'] as String?) ?? '';
  String? get _code => widget.customer['code'] as String?;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 6, vsync: this);
    _loadAr();
    _loadVisits();
    _loadIntel();
    _loadActivities();
    _loadComplaints();
    _loadTarget();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() {
    _loadAr();
    _loadVisits();
    _loadIntel();
    _loadActivities();
    _loadComplaints();
    _loadTarget();
  }

  Future<void> _loadTarget() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loadingTarget = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final tgl = await client.from('app_config').select('value')
          .eq('org_id', orgId)
          .eq('key', 'org.customer_targets_enabled').maybeSingle();
      final on = (tgl?['value'] as String?) == 'true';
      if (!on) {
        if (mounted) setState(() {
          _targetsEnabled = false;
          _loadingTarget = false;
        });
        return;
      }
      final rows = await client.rpc('rpc_customer_target_achievement',
          params: {'p_org_id': orgId, 'p_customer_id': _customerId}) as List;
      double target = 0, achieved = 0;
      if (rows.isNotEmpty) {
        final r = rows.first as Map;
        target = (r['monthly_sale_target'] as num?)?.toDouble() ?? 0;
        achieved = (r['achieved'] as num?)?.toDouble() ?? 0;
      }
      if (!mounted) return;
      setState(() {
        _targetsEnabled = true;
        _target = target;
        _achieved = achieved;
        _loadingTarget = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingTarget = false);
    }
  }

  Future<void> _loadComplaints() async {
    setState(() => _loadingComplaints = true);
    try {
      final rows = await Supabase.instance.client
          .from('crm_complaints')
          .select()
          .eq('customer_id', _customerId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _complaints = List<Map<String, dynamic>>.from(rows);
        _loadingComplaints = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _complaints = [];
        _loadingComplaints = false;
      });
    }
  }

  int get _openComplaints => _complaints
      .where((c) => (c['status'] as String?) == 'open' || (c['status'] as String?) == 'in_progress')
      .length;

  Widget _complaintsTab() {
    if (_loadingComplaints) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_complaints.isEmpty) {
      return const Center(
          child: Text('No complaints logged.',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _complaints.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final c = _complaints[i];
        final status = (c['status'] as String?) ?? 'open';
        final open = status == 'open' || status == 'in_progress';
        final created = DateTime.tryParse('${c['created_at']}');
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.border),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(c['subject'] as String? ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (open ? AppTheme.warning : AppTheme.success).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: open ? AppTheme.warning : AppTheme.success)),
                ),
              ]),
              if ((c['description'] as String?)?.isNotEmpty == true) ...[
                const SizedBox(height: 6),
                Text(c['description'] as String,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ],
              const SizedBox(height: 8),
              Row(children: [
                Text(
                    created == null
                        ? ''
                        : DateFormat('d MMM y, h:mm a').format(created.toLocal()),
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                const Spacer(),
                if (open)
                  TextButton(
                    onPressed: () => _resolveComplaint(c),
                    child: const Text('Mark resolved'),
                  ),
              ]),
            ],
          ),
        );
      },
    );
  }

  Future<void> _resolveComplaint(Map<String, dynamic> c) async {
    final noteCtrl = TextEditingController();
    Uint8List? bytes;
    String? fileName;
    bool saving = false;
    const bucket = 'retailer-files';

    void pick(StateSetter setS) {
      final input = html.FileUploadInputElement()
        ..accept = 'image/png,image/jpeg,image/webp,application/pdf';
      input.click();
      input.onChange.listen((_) {
        final files = input.files;
        if (files == null || files.isEmpty) return;
        final f = files[0];
        if (f.size > 10 * 1024 * 1024) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File too large — max 10 MB')));
          return;
        }
        final reader = html.FileReader();
        reader.readAsArrayBuffer(f);
        reader.onLoad.listen((_) {
          final r = reader.result;
          final data = r is ByteBuffer ? r.asUint8List() : r as Uint8List;
          setS(() {
            bytes = data;
            fileName = f.name;
          });
        });
      });
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> save() async {
            setS(() => saving = true);
            try {
              final client = Supabase.instance.client;
              String? path;
              if (bytes != null && fileName != null) {
                final orgId = ref.read(currentUserProvider)?.orgId ?? 'org';
                final safe =
                    fileName!.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
                path =
                    'complaints/$orgId/${DateTime.now().millisecondsSinceEpoch}_$safe';
                await client.storage.from(bucket).uploadBinary(path, bytes!,
                    fileOptions: const FileOptions(upsert: false));
              }
              await client.from('crm_complaints').update({
                'status': 'resolved',
                'resolved_at': DateTime.now().toIso8601String(),
                'resolution_note': noteCtrl.text.trim().isEmpty
                    ? null
                    : noteCtrl.text.trim(),
                'resolution_file_path': path,
              }).eq('id', c['id']);
              if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
              _loadComplaints();
              _loadActivities(); // linked follow-up auto-closes via trigger
            } catch (e) {
              setS(() => saving = false);
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content:
                        Text('Failed: ${e.toString().split('\n').first}')));
              }
            }
          }

          return AlertDialog(
            title: const Text('Resolve complaint'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c['subject'] as String? ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Resolution note (optional)',
                        alignLabelWithHint: true),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: Text(
                        fileName == null ? 'Attach file (optional)' : 'Change file'),
                    onPressed: saving ? null : () => pick(setS),
                  ),
                  if (fileName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(fileName!,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis),
                    ),
                  const SizedBox(height: 6),
                  const Text(
                    'The retailer is notified when you resolve. Your note rides along.',
                    style:
                        TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(ctx, rootNavigator: true).pop(),
                  child: const Text('Cancel')),
              ElevatedButton(
                onPressed: saving ? null : save,
                child: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Resolve'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _loadAr() async {
    setState(() {
      _loadingAr = true;
      _arError = null;
    });
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() {
        _loadingAr = false;
        _arError = 'No organization';
      });
      return;
    }
    try {
      final client = Supabase.instance.client;
      final asOf = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final params = {'p_org_id': orgId, 'p_as_of': asOf};

      // Aggregate buckets + GL-true net per customer (ties to 1210).
      final agg = await client.rpc('rpc_customer_aging', params: params) as List;
      Map mine = const {};
      for (final a in agg) {
        if ((a as Map)['customer_id'] == _customerId) {
          mine = a;
          break;
        }
      }
      final b1 = (mine['b1'] as num?)?.toDouble() ?? 0;
      final b2 = (mine['b2'] as num?)?.toDouble() ?? 0;
      final b3 = (mine['b3'] as num?)?.toDouble() ?? 0;
      final b4 = (mine['b4'] as num?)?.toDouble() ?? 0;
      final net = (mine['total'] as num?)?.toDouble() ?? 0;

      // Open GL lines for the drill-down (best-effort; optional RPC).
      final items = <Map<String, dynamic>>[];
      try {
        final det =
            await client.rpc('rpc_customer_aging_detail', params: params)
                as List;
        for (final d in det) {
          final m = d as Map;
          if (m['customer_id'] != _customerId) continue;
          items.add({
            'voucher_number': (m['reference_number'] as String?) ?? '-',
            'voucher_date':
                DateTime.tryParse('${m['ref_date']}') ?? DateTime.now(),
            'outstanding': (m['open_amt'] as num?)?.toDouble() ?? 0,
            'ageDays': (m['age_days'] as num?)?.toInt() ?? 0,
          });
        }
      } catch (_) {/* detail is optional */}

      items.sort((a, b) => (a['voucher_date'] as DateTime)
          .compareTo(b['voucher_date'] as DateTime));

      setState(() {
        _b1 = b1;
        _b2 = b2;
        _b3 = b3;
        _b4 = b4;
        _arTotal = net;
        _current = net - b1 - b2 - b3 - b4;
        _openItems
          ..clear()
          ..addAll(items);
        _loadingAr = false;
      });
    } catch (e) {
      setState(() {
        _arError = e.toString();
        _loadingAr = false;
      });
    }
  }

  Future<void> _loadVisits() async {
    setState(() => _loadingVisits = true);
    try {
      final res = await Supabase.instance.client
          .from('visits')
          .select()
          .eq('customer_id', _customerId)
          .order('timestamp', ascending: false)
          .limit(10);
      setState(() {
        _visits = List<Map<String, dynamic>>.from(res);
        _loadingVisits = false;
      });
    } catch (_) {
      setState(() {
        _visits = [];
        _loadingVisits = false;
      });
    }
  }

  Future<void> _loadIntel() async {
    setState(() => _loadingIntel = true);
    try {
      final client = Supabase.instance.client;

      // --- Our product placement (latest per product) ---
      final pa = await client
          .from('placement_audit')
          .select('product_id, is_present, surveyed_at')
          .eq('customer_id', _customerId)
          .order('surveyed_at', ascending: false);
      final seenP = <String>{};
      final placement = <Map<String, dynamic>>[];
      for (final r in pa) {
        final pid = r['product_id'] as String?;
        if (pid == null || !seenP.add(pid)) continue;
        placement.add({
          'product_id': pid,
          'present': r['is_present'] as bool? ?? false,
          'surveyed_at': r['surveyed_at'] as String?,
        });
      }
      if (placement.isNotEmpty) {
        final pids = placement.map((e) => e['product_id'] as String).toList();
        final prod = await client
            .from('intelligence_products')
            .select('id, name, sku_code')
            .inFilter('id', pids);
        final names = <String, String>{};
        final skus = <String, String?>{};
        for (final p in prod) {
          names[p['id'] as String] = (p['name'] as String?) ?? '—';
          skus[p['id'] as String] = p['sku_code'] as String?;
        }
        for (final e in placement) {
          e['name'] = names[e['product_id']] ?? '(removed product)';
          e['sku'] = skus[e['product_id']];
        }
      }

      // --- Competitor presence (latest per category) ---
      final cs = await client
          .from('competitor_spotting')
          .select('category_id, brand_name, price, specs, surveyed_at')
          .eq('customer_id', _customerId)
          .order('surveyed_at', ascending: false);
      final seenC = <String>{};
      final comps = <Map<String, dynamic>>[];
      for (final r in cs) {
        final cid = r['category_id'] as String?;
        if (cid == null || !seenC.add(cid)) continue;
        comps.add({
          'category_id': cid,
          'brand': r['brand_name'] as String? ?? '—',
          'price': r['price'],
          'specs': r['specs'] as String?,
          'surveyed_at': r['surveyed_at'] as String?,
        });
      }
      if (comps.isNotEmpty) {
        final cids = comps.map((e) => e['category_id'] as String).toList();
        final cats = await client
            .from('competitor_categories')
            .select('id, name')
            .inFilter('id', cids);
        final cnames = <String, String>{};
        for (final c in cats) {
          cnames[c['id'] as String] = (c['name'] as String?) ?? '—';
        }
        for (final e in comps) {
          e['category'] = cnames[e['category_id']] ?? '(category)';
        }
      }

      if (!mounted) return;
      setState(() {
        _placement = placement;
        _competitors = comps;
        _loadingIntel = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _placement = [];
        _competitors = [];
        _loadingIntel = false;
      });
    }
  }

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openMaps(double lat, double lng) async {
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Container(
              color: Colors.white,
              child: TabBar(
                controller: _tabs,
                labelColor: AppTheme.primary,
                unselectedLabelColor: AppTheme.textSecondary,
                indicatorColor: AppTheme.primary,
                labelStyle:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                tabs: [
                  const Tab(text: 'Overview'),
                  const Tab(text: 'Receivables'),
                  const Tab(text: 'Visits'),
                  const Tab(text: 'Intel'),
                  const Tab(text: 'Activities'),
                  Tab(
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Complaints'),
                      if (_openComplaints > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppTheme.danger,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('$_openComplaints',
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ]),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _overviewTab(),
                  _receivablesTab(),
                  _visitsTab(),
                  _intelTab(),
                  _activitiesTab(),
                  _complaintsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 16, 32, 16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Back',
          ),
          const SizedBox(width: 4),
          CircleAvatar(
            radius: 20,
            backgroundColor: AppTheme.primary.withOpacity(0.12),
            child: Text(
              _shopName.isNotEmpty ? _shopName[0].toUpperCase() : '?',
              style: const TextStyle(
                  color: AppTheme.primary, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_shopName,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  [
                    if (_code != null && _code!.isNotEmpty) _code,
                    if ((widget.customer['category'] as String?)
                            ?.isNotEmpty ??
                        false)
                      widget.customer['category'],
                    if ((widget.customer['group_name'] as String?)
                            ?.isNotEmpty ??
                        false)
                      widget.customer['group_name'],
                  ].whereType<String>().join('  ·  '),
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- Overview

  Widget _overviewTab() {
    final c = widget.customer;
    final lat = (c['latitude'] as num?)?.toDouble();
    final lng = (c['longitude'] as num?)?.toDouble();
    final creditLimit = (c['credit_limit'] as num?)?.toDouble();

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
      children: [
        // Credit vs outstanding — the headline.
        _creditCard(creditLimit),
        if (_targetsEnabled) ...[
          const SizedBox(height: 16),
          _targetCard(),
        ],
        const SizedBox(height: 16),
        _card(
          title: 'Profile',
          icon: Icons.storefront_outlined,
          child: Column(
            children: [
              _infoRow(Icons.person_outline, 'Contact',
                  (c['contact_person'] as String?)?.trim().isNotEmpty == true
                      ? c['contact_person'] as String
                      : '—'),
              _infoRow(
                Icons.phone_outlined,
                'Phone',
                (c['phone'] as String?)?.trim().isNotEmpty == true
                    ? c['phone'] as String
                    : '—',
                onTap: (c['phone'] as String?)?.trim().isNotEmpty == true
                    ? () => _copy(c['phone'] as String, 'Phone')
                    : null,
              ),
              _infoRow(Icons.badge_outlined, 'NTN / GST',
                  (c['ntn_gst'] as String?)?.trim().isNotEmpty == true
                      ? c['ntn_gst'] as String
                      : '—'),
              _infoRow(Icons.home_outlined, 'Address',
                  (c['address'] as String?)?.trim().isNotEmpty == true
                      ? c['address'] as String
                      : '—'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Location',
          icon: Icons.location_on_outlined,
          child: (lat != null && lng != null)
              ? Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 15),
                      label: const Text('Copy'),
                      onPressed: () => _copy(
                          '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                          'Coordinates'),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.map_outlined, size: 15),
                      label: const Text('Open in Maps'),
                      onPressed: () => _openMaps(lat, lng),
                    ),
                  ],
                )
              : const Text('No location set for this shop.',
                  style:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        ),
      ],
    );
  }

  Widget _targetCard() {
    final pct = _target > 0 ? (_achieved / _target).clamp(0.0, 1.0) : 0.0;
    final pctLabel = _target > 0 ? (_achieved / _target * 100).round() : 0;
    final met = _target > 0 && _achieved >= _target - 0.005;
    final barColor = met
        ? AppTheme.success
        : (pct >= 0.5 ? AppTheme.primary : Colors.orange);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined,
                  size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Text('Sales target — this month',
                  style:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              if (_loadingTarget)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (_target > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: barColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('$pctLabel%',
                      style: TextStyle(
                          color: barColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_target <= 0)
            const Text('No target set for this customer.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary))
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('Rs ${_money.format(_achieved)}',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: barColor)),
                const SizedBox(width: 6),
                Text('/ Rs ${_money.format(_target)}',
                    style: const TextStyle(
                        fontSize: 14, color: AppTheme.textSecondary)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 10,
                backgroundColor: AppTheme.border.withOpacity(0.4),
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              met
                  ? 'Target met'
                  : 'Rs ${_money.format(_target - _achieved)} to go',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: met ? AppTheme.success : AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _creditCard(double? creditLimit) {
    final owed = _arTotal; // positive = receivable, negative = credit balance
    final isCredit = owed < -0.005;
    final overLimit =
        creditLimit != null && creditLimit > 0 && owed > creditLimit + 0.005;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: overLimit ? AppTheme.danger : AppTheme.border,
            width: overLimit ? 1.4 : 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined,
                  size: 18, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              const Text('Outstanding',
                  style:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              if (_loadingAr)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isCredit
                ? 'Rs ${_money2.format(owed.abs())} CR'
                : 'Rs ${_money2.format(owed)}',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: isCredit
                  ? AppTheme.success
                  : (overLimit ? AppTheme.danger : AppTheme.primary),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _miniStat(
                  'Credit limit',
                  creditLimit == null || creditLimit == 0
                      ? 'No limit'
                      : 'Rs ${_money.format(creditLimit)}'),
              const SizedBox(width: 24),
              if (creditLimit != null && creditLimit > 0)
                _miniStat(
                  'Available',
                  'Rs ${_money.format(creditLimit - owed)}',
                  color: overLimit ? AppTheme.danger : AppTheme.success,
                ),
              const SizedBox(width: 24),
              _miniStat('Open items', '${_openItems.length}'),
            ],
          ),
          if (overLimit) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.danger.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppTheme.danger),
                  const SizedBox(width: 6),
                  Text(
                    'Over credit limit by Rs ${_money.format(owed - creditLimit)}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.danger,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          if (!_loadingAr && !isCredit && creditLimit != null && creditLimit > 0) ...[
            const SizedBox(height: 14),
            _creditUtilizationBar(creditLimit),
          ],
        ],
      ),
    );
  }

  /// Credit-limit utilization: how much of the customer's credit limit the
  /// current outstanding consumes. Green < 75%, amber 75–90%, deep-orange
  /// 90–100%, red over limit (bar caps full). Only shown when a positive
  /// limit is set and the customer isn't in a credit balance.
  Widget _creditUtilizationBar(double creditLimit) {
    final owed = _arTotal;
    final ratio = owed / creditLimit;
    final filled = (ratio.clamp(0.0, 1.0)).toDouble();
    final over = ratio > 1.0 + 1e-6;
    final color = over
        ? AppTheme.danger
        : (ratio >= 0.9
            ? Colors.deepOrange
            : (ratio >= 0.75 ? AppTheme.warning : AppTheme.success));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Credit used',
                style:
                    TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const Spacer(),
            Text('${(ratio * 100).round()}%',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: filled,
            minHeight: 8,
            backgroundColor: AppTheme.border,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- Receivables

  Widget _receivablesTab() {
    if (_loadingAr) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_arError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Failed to load receivables: $_arError',
              style: const TextStyle(color: AppTheme.danger)),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
      children: [
        Row(
          children: [
            _bucketCard('Current (0-30)', _current, AppTheme.success),
            const SizedBox(width: 10),
            _bucketCard('31-60', _b1, AppTheme.warning),
            const SizedBox(width: 10),
            _bucketCard('61-90', _b2, Colors.orange),
            const SizedBox(width: 10),
            _bucketCard('91-120', _b3, Colors.deepOrange),
            const SizedBox(width: 10),
            _bucketCard('120+', _b4, AppTheme.danger),
            const SizedBox(width: 10),
            _bucketCard('Total', _arTotal, AppTheme.primary, bold: true),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Open items',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        _openItemsTable(),
      ],
    );
  }

  Widget _openItemsTable() {
    if (_openItems.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: const Center(
          child: Text('No open items — nothing outstanding.',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.background,
            child: Row(children: const [
              Expanded(
                  flex: 3,
                  child: Text('Voucher #',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary))),
              Expanded(
                  flex: 3,
                  child: Text('Date',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary))),
              Expanded(
                  flex: 2,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('Days',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary)))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.center,
                      child: Text('Bucket',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary)))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('Outstanding',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary)))),
            ]),
          ),
          const Divider(height: 1),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _openItems.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final inv = _openItems[i];
              final age = inv['ageDays'] as int;
              final (label, color) = _bucketOf(age);
              final df = DateFormat('d MMM yyyy');
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                child: Row(children: [
                  Expanded(
                      flex: 3,
                      child: Text(inv['voucher_number'] as String,
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600))),
                  Expanded(
                      flex: 3,
                      child: Text(df.format(inv['voucher_date'] as DateTime),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textSecondary))),
                  Expanded(
                      flex: 2,
                      child: Align(
                          alignment: Alignment.centerRight,
                          child: Text('$age',
                              style: const TextStyle(fontSize: 12)))),
                  Expanded(
                      flex: 3,
                      child: Align(
                          alignment: Alignment.center,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                                color: color.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10)),
                            child: Text(label,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: color)),
                          ))),
                  Expanded(
                      flex: 3,
                      child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                              _money2.format(inv['outstanding'] as double),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primary)))),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- Visits

  Widget _visitsTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
          child: Row(
            children: [
              Text('${_visits.length} recent visit${_visits.length == 1 ? "" : "s"}',
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
              const Spacer(),
              OutlinedButton.icon(
                icon: const Icon(Icons.history, size: 16),
                label: const Text('Full visit history'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CustomerHistoryScreen(
                      customerId: _customerId,
                      customerName: _shopName,
                      customerCode: _code,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingVisits
              ? const Center(child: CircularProgressIndicator())
              : _visits.isEmpty
                  ? const Center(
                      child: Text('No visits recorded yet',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
                      itemCount: _visits.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _visitCard(_visits[i]),
                    ),
        ),
      ],
    );
  }

  Widget _visitCard(Map<String, dynamic> v) {
    final status = v['status'] as String? ?? '';
    final ts = v['timestamp'] != null
        ? DateTime.tryParse(v['timestamp'] as String)?.toLocal()
        : null;
    final salesperson = v['user_name'] as String? ?? '—';
    final role = v['user_role'] as String? ?? '';
    final amount = (v['amount'] as int?) ?? 0;
    final receipt = v['receipt_number'] as String?;
    final notes = v['notes'] as String?;
    final (icon, color, label) = _statusOf(status);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 10,
                            color: color,
                            fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  if (ts != null)
                    Text(DateFormat('d MMM y · HH:mm').format(ts),
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                ]),
                const SizedBox(height: 6),
                Text(role.isEmpty ? salesperson : '$salesperson · $role',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary)),
                if (notes != null && notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(notes,
                      style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: AppTheme.textSecondary)),
                ],
              ],
            ),
          ),
          if (amount > 0) ...[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Rs $amount',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800)),
                if (receipt != null && receipt.isNotEmpty)
                  Text('#$receipt',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- Intel

  Widget _intelTab() {
    if (_loadingIntel) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_placement.isEmpty && _competitors.isEmpty) {
      return const Center(
        child: Text('No survey intel recorded for this shop yet',
            style: TextStyle(color: AppTheme.textSecondary)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 32),
      children: [
        _card(
          title: 'Our product placement',
          icon: Icons.inventory_2_outlined,
          child: _placement.isEmpty
              ? const Text('No placement audits yet.',
                  style:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary))
              : Column(children: [for (final p in _placement) _placementRow(p)]),
        ),
        const SizedBox(height: 16),
        _card(
          title: 'Competitor presence',
          icon: Icons.groups_2_outlined,
          child: _competitors.isEmpty
              ? const Text('No competitor spottings yet.',
                  style:
                      TextStyle(fontSize: 13, color: AppTheme.textSecondary))
              : Column(
                  children: [for (final c in _competitors) _competitorRow(c)]),
        ),
      ],
    );
  }

  Widget _placementRow(Map<String, dynamic> p) {
    final present = p['present'] as bool? ?? false;
    final sku = p['sku'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(present ? Icons.check_circle : Icons.cancel,
              size: 16, color: present ? AppTheme.success : AppTheme.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p['name'] as String? ?? '—',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                if (sku != null && sku.isNotEmpty)
                  Text(sku,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          Text(present ? 'Present' : 'Absent',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: present ? AppTheme.success : AppTheme.danger)),
          const SizedBox(width: 10),
          Text(_intelDate(p['surveyed_at'] as String?),
              style: const TextStyle(
                  fontSize: 11, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  Widget _competitorRow(Map<String, dynamic> c) {
    final price = c['price'];
    final specs = c['specs'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(c['category'] as String? ?? '—',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ),
            Text(_intelDate(c['surveyed_at'] as String?),
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
          ]),
          const SizedBox(height: 2),
          Row(children: [
            Expanded(
              child: Text(c['brand'] as String? ?? '—',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ),
            if (price != null)
              Text('PKR $price',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary)),
          ]),
          if (specs != null && specs.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(specs,
                style: const TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: AppTheme.textSecondary)),
          ],
        ],
      ),
    );
  }

  String _intelDate(String? iso) {
    if (iso == null) return '—';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '—';
    return DateFormat('d MMM y').format(dt);
  }

  // -------------------------------------------------------------- Activities

  Future<void> _loadActivities() async {
    setState(() => _loadingActs = true);
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) {
      setState(() => _loadingActs = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final users = await client
          .from('users')
          .select('id, name, role')
          .eq('org_id', orgId)
          .order('name');
      final names = <String, String>{};
      for (final u in users) {
        names[u['id'] as String] = (u['name'] as String?) ?? 'Unknown';
      }
      final rows = await client
          .from('customer_activities')
          .select()
          .eq('customer_id', _customerId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _orgUsers = List<Map<String, dynamic>>.from(users);
        _userNames = names;
        _activities = List<Map<String, dynamic>>.from(rows);
        _loadingActs = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _activities = [];
        _loadingActs = false;
      });
    }
  }

  Future<void> _toggleActivityDone(Map<String, dynamic> a) async {
    final done = (a['status'] as String?) == 'done';
    try {
      await Supabase.instance.client.from('customer_activities').update({
        'status': done ? 'open' : 'done',
        'completed_at': done ? null : DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', a['id']);
      _loadActivities();
    } catch (_) {/* ignore */}
  }

  Future<void> _deleteActivity(String id) async {
    try {
      await Supabase.instance.client
          .from('customer_activities')
          .delete()
          .eq('id', id);
      _loadActivities();
    } catch (_) {/* ignore */}
  }

  Future<void> _editFollowUp(Map<String, dynamic> a) async {
    String type = (a['type'] as String?) ?? 'call';
    const types = ['note', 'call', 'visit', 'collection', 'other'];
    if (!types.contains(type)) type = 'other';
    final noteCtrl = TextEditingController(text: a['note'] as String? ?? '');
    DateTime? due = DateTime.tryParse('${a['due_date']}');
    String? assignee = a['assigned_to'] as String?;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Edit follow-up'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: type,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: const [
                      DropdownMenuItem(value: 'note', child: Text('Note')),
                      DropdownMenuItem(value: 'call', child: Text('Call')),
                      DropdownMenuItem(value: 'visit', child: Text('Visit')),
                      DropdownMenuItem(
                          value: 'collection', child: Text('Collection')),
                      DropdownMenuItem(value: 'other', child: Text('Other')),
                    ],
                    onChanged: (v) => setS(() => type = v ?? type),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'What needs doing?',
                        alignLabelWithHint: true),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: due ?? DateTime.now(),
                        firstDate:
                            DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (picked != null) setS(() => due = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Due date'),
                      child: Text(due == null
                          ? 'Pick a date'
                          : DateFormat('d MMM y').format(due!)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    value: assignee,
                    decoration: const InputDecoration(labelText: 'Assign to'),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Unassigned')),
                      for (final u in _orgUsers)
                        DropdownMenuItem<String?>(
                          value: u['id'] as String,
                          child: Text(
                            (u['role'] != null &&
                                    (u['role'] as String).isNotEmpty)
                                ? '${u['name'] ?? 'Unknown'}  ·  ${u['role']}'
                                : '${u['name'] ?? 'Unknown'}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setS(() => assignee = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (noteCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Add a note first')));
                  return;
                }
                try {
                  await Supabase.instance.client
                      .from('customer_activities')
                      .update({
                    'type': type,
                    'note': noteCtrl.text.trim(),
                    'due_date': due != null
                        ? DateFormat('yyyy-MM-dd').format(due!)
                        : null,
                    'assigned_to': assignee,
                    'updated_at': DateTime.now().toIso8601String(),
                  }).eq('id', a['id']);
                  if (ctx.mounted) {
                    Navigator.of(ctx, rootNavigator: true).pop();
                  }
                  _loadActivities();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            'Failed: ${e.toString().split('\n').first}')));
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _activityDialog(bool isFollowup) async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    String type = isFollowup ? 'call' : 'note';
    final noteCtrl = TextEditingController();
    DateTime? due =
        isFollowup ? DateTime.now().add(const Duration(days: 1)) : null;
    String? assignee;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isFollowup ? 'Add follow-up' : 'Log activity'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: type,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: const [
                      DropdownMenuItem(value: 'note', child: Text('Note')),
                      DropdownMenuItem(value: 'call', child: Text('Call')),
                      DropdownMenuItem(value: 'visit', child: Text('Visit')),
                      DropdownMenuItem(
                          value: 'collection', child: Text('Collection')),
                      DropdownMenuItem(value: 'other', child: Text('Other')),
                    ],
                    onChanged: (v) => setS(() => type = v ?? type),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: isFollowup ? 'What needs doing?' : 'Note',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (isFollowup) ...[
                    InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: due ?? DateTime.now(),
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 1)),
                          lastDate:
                              DateTime.now().add(const Duration(days: 365)),
                        );
                        if (picked != null) setS(() => due = picked);
                      },
                      child: InputDecorator(
                        decoration:
                            const InputDecoration(labelText: 'Due date'),
                        child: Text(
                          due == null
                              ? 'Pick a date'
                              : DateFormat('d MMM y').format(due!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  DropdownButtonFormField<String?>(
                    value: assignee,
                    decoration: const InputDecoration(labelText: 'Assign to'),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Unassigned')),
                      for (final u in _orgUsers)
                        DropdownMenuItem<String?>(
                          value: u['id'] as String,
                          child: Text(
                            (u['role'] != null &&
                                    (u['role'] as String).isNotEmpty)
                                ? '${u['name'] ?? 'Unknown'}  ·  ${u['role']}'
                                : '${u['name'] ?? 'Unknown'}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setS(() => assignee = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (noteCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('Add a note first')));
                  return;
                }
                try {
                  await Supabase.instance.client
                      .from('customer_activities')
                      .insert({
                    'id': 'act_${DateTime.now().millisecondsSinceEpoch}',
                    'org_id': orgId,
                    'customer_id': _customerId,
                    'type': type,
                    'note': noteCtrl.text.trim(),
                    'due_date': (isFollowup && due != null)
                        ? DateFormat('yyyy-MM-dd').format(due!)
                        : null,
                    'assigned_to': assignee,
                    'status': 'open',
                    'created_by':
                        Supabase.instance.client.auth.currentUser?.id,
                  });
                  if (ctx.mounted) {
                    Navigator.of(ctx, rootNavigator: true).pop();
                  }
                  _loadActivities();
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(
                            'Failed: ${e.toString().split('\n').first}')));
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activitiesTab() {
    if (_loadingActs) {
      return const Center(child: CircularProgressIndicator());
    }
    final open = _activities
        .where((a) =>
            a['due_date'] != null && (a['status'] as String?) == 'open')
        .toList()
      ..sort((a, b) =>
          (a['due_date'] as String).compareTo(b['due_date'] as String));
    final log = _activities
        .where((a) =>
            !(a['due_date'] != null && (a['status'] as String?) == 'open'))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 8),
          child: Row(
            children: [
              const Text('Activities & follow-ups',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const Spacer(),
              OutlinedButton.icon(
                icon: const Icon(Icons.note_add_outlined, size: 16),
                label: const Text('Log activity'),
                onPressed: () => _activityDialog(false),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.add_task, size: 16),
                label: const Text('Add follow-up'),
                onPressed: () => _activityDialog(true),
              ),
            ],
          ),
        ),
        Expanded(
          child: (open.isEmpty && log.isEmpty)
              ? const Center(
                  child: Text(
                      'No activities yet — log a note or add a follow-up',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
                  children: [
                    if (open.isNotEmpty) ...[
                      const Text('Open follow-ups',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      for (final a in open) _followupCard(a),
                      const SizedBox(height: 20),
                    ],
                    if (log.isNotEmpty) ...[
                      const Text('Activity log',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      for (final a in log) _activityCard(a),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _followupCard(Map<String, dynamic> a) {
    final due = DateTime.tryParse('${a['due_date']}');
    final now = DateTime.now();
    final overdue =
        due != null && due.isBefore(DateTime(now.year, now.month, now.day));
    final assignee = a['assigned_to'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: overdue
                ? AppTheme.danger.withOpacity(0.5)
                : AppTheme.border),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _toggleActivityDone(a),
            child: const Icon(Icons.radio_button_unchecked,
                size: 20, color: AppTheme.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _typeChip(a['type'] as String?),
                  const SizedBox(width: 8),
                  if (due != null)
                    Text(DateFormat('d MMM y').format(due),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: overdue
                                ? AppTheme.danger
                                : AppTheme.textSecondary)),
                  if (overdue)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Text('overdue',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.danger,
                              fontWeight: FontWeight.w700)),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(a['note'] as String? ?? '',
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.person_outline,
                      size: 13, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                      assignee == null
                          ? 'Unassigned'
                          : (_userNames[assignee] ?? 'Unknown'),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                ]),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined,
                size: 16, color: AppTheme.textSecondary),
            onPressed: () => _editFollowUp(a),
            tooltip: 'Edit',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline,
                size: 16, color: AppTheme.textSecondary),
            onPressed: () => _deleteActivity(a['id'] as String),
            tooltip: 'Delete',
          ),
        ],
      ),
    );
  }

  Widget _activityCard(Map<String, dynamic> a) {
    final isTask = a['due_date'] != null;
    final done = (a['status'] as String?) == 'done';
    final created = DateTime.tryParse('${a['created_at']}')?.toLocal();
    final assignee = a['assigned_to'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(done ? Icons.check_circle : Icons.notes,
              size: 18,
              color: done ? AppTheme.success : AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _typeChip(a['type'] as String?),
                  const SizedBox(width: 8),
                  if (created != null)
                    Text(DateFormat('d MMM y · HH:mm').format(created),
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                  if (isTask && done)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Text('done',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppTheme.success,
                              fontWeight: FontWeight.w700)),
                    ),
                ]),
                const SizedBox(height: 4),
                Text(a['note'] as String? ?? '',
                    style: const TextStyle(fontSize: 13)),
                if (assignee != null) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.person_outline,
                        size: 13, color: AppTheme.textSecondary),
                    const SizedBox(width: 4),
                    Text(_userNames[assignee] ?? 'Unknown',
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                  ]),
                ],
              ],
            ),
          ),
          if (isTask && done)
            IconButton(
              icon: const Icon(Icons.undo,
                  size: 16, color: AppTheme.textSecondary),
              onPressed: () => _toggleActivityDone(a),
              tooltip: 'Reopen',
            ),
        ],
      ),
    );
  }

  Widget _typeChip(String? type) {
    final t = (type == null || type.isEmpty) ? 'note' : type;
    final label = t[0].toUpperCase() + t.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.primary)),
    );
  }

  // -------------------------------------------------------------- shared bits

  (String, Color) _bucketOf(int age) {
    if (age <= 30) return ('0-30', AppTheme.success);
    if (age <= 60) return ('31-60', AppTheme.warning);
    if (age <= 90) return ('61-90', Colors.orange);
    if (age <= 120) return ('91-120', Colors.deepOrange);
    return ('120+', AppTheme.danger);
  }

  (IconData, Color, String) _statusOf(String status) {
    return switch (status) {
      'verified' => (Icons.check_circle, AppTheme.success, 'Verified'),
      'outside' => (Icons.warning_amber_rounded, AppTheme.warning, 'Outside'),
      'noLocation' => (
          Icons.location_off_outlined,
          AppTheme.danger,
          'No location'
        ),
      'skipped' => (Icons.skip_next, AppTheme.textSecondary, 'Skipped'),
      _ => (Icons.circle_outlined, AppTheme.textSecondary,
          status.isEmpty ? 'Visit' : status),
    };
  }

  Widget _card(
      {required String title, required IconData icon, required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Text(title,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value,
      {VoidCallback? onTap}) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppTheme.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: onTap != null ? AppTheme.primary : null)),
          ),
          if (onTap != null)
            const Icon(Icons.copy, size: 13, color: AppTheme.textSecondary),
        ],
      ),
    );
    return onTap == null
        ? content
        : InkWell(onTap: onTap, child: content);
  }

  Widget _miniStat(String label, String value, {Color? color}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color ?? Colors.black87)),
      ],
    );
  }

  Widget _bucketCard(String label, double v, Color c, {bool bold = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text(_money2.format(v),
                style: TextStyle(
                    fontSize: bold ? 16 : 14,
                    fontWeight: FontWeight.w800,
                    color: v.abs() > 0.005 ? c : AppTheme.textSecondary)),
          ],
        ),
      ),
    );
  }
}
