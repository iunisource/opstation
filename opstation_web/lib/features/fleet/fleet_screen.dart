// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../auth/auth_controller.dart';
import 'fleet_common.dart';
import 'vehicle_profile.dart';

/// Logistics → Fleet (SQL 463).
class FleetScreen extends ConsumerStatefulWidget {
  final String? openId;
  const FleetScreen({super.key, this.openId});
  @override
  ConsumerState<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends ConsumerState<FleetScreen> {
  List<Map<String, dynamic>> _vehicles = [];
  Map<String, List<Map<String, dynamic>>> _services = {};
  Map<String, int> _openTasks = {};
  Map<String, num> _todayKm = {};
  Map<String, String> _users = {};
  List<Map<String, dynamic>> _userList = [];
  List<Map<String, dynamic>> _branches = [];
  num _lead = 200;
  bool _loading = true;
  bool _missing = false;
  String _search = '';
  bool _openedFromLink = false;

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(sync: true));
  }

  Future<void> _load({bool sync = false}) async {
    final org = _orgId;
    if (org == null) return;
    try {
      if (sync) {
        try { await fleetDb.rpc('fleet_sync', params: {'p_org': org}); } catch (_) {}
      }
      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final r = await Future.wait([
        fleetDb.from('fleet_vehicles').select().eq('org_id', org).eq('is_active', true).order('reg_no'),
        fleetDb.from('fleet_services').select().eq('org_id', org).eq('is_active', true),
        fleetDb.from('fleet_tasks').select('vehicle_id').eq('org_id', org).eq('status', 'open'),
        fleetDb.from('fleet_mileage_log').select('vehicle_id, km').eq('org_id', org).eq('log_date', today).eq('source', 'auto'),
        fleetDb.from('users').select('id, name, role').eq('org_id', org).or('role.is.null,role.neq.retailer').order('name'),
        fleetDb.from('branches').select('id, name, is_virtual').eq('org_id', org).eq('is_active', true).order('name'),
      ]);
      final lead = await fleetLeadKm(org);
      final svc = <String, List<Map<String, dynamic>>>{};
      for (final s in r[1] as List) {
        (svc[s['vehicle_id'] as String] ??= []).add(Map<String, dynamic>.from(s as Map));
      }
      final tasks = <String, int>{};
      for (final t in r[2] as List) {
        tasks[t['vehicle_id'] as String] = (tasks[t['vehicle_id'] as String] ?? 0) + 1;
      }
      final users = List<Map<String, dynamic>>.from(r[4] as List)
        ..sort((a, b) {
          final ad = a['role'] == 'driver' ? 0 : 1, bd = b['role'] == 'driver' ? 0 : 1;
          return ad != bd ? ad.compareTo(bd) : '${a['name']}'.compareTo('${b['name']}');
        });
      if (!mounted) return;
      setState(() {
        _vehicles = List<Map<String, dynamic>>.from(r[0] as List);
        _services = svc;
        _openTasks = tasks;
        _todayKm = {for (final m in r[3] as List) m['vehicle_id'] as String: (m['km'] as num?) ?? 0};
        _userList = users;
        _users = {for (final u in users) '${u['id']}': '${u['name'] ?? ''}'};
        // Real branches only — processor / off-site locations don't keep vehicles.
        _branches = List<Map<String, dynamic>>.from(r[5] as List).where((b) => b['is_virtual'] != true).toList();
        _lead = lead;
        _loading = false;
        _missing = false;
      });
      ref.invalidate(fleetDueCountProvider);
      if (!_openedFromLink && widget.openId != null) {
        _openedFromLink = true;
        _open(widget.openId!);
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _missing = true; });
    }
  }

  void _snack(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  void _open(String id) => showVehicleProfile(context, id,
      onChanged: () => _load(),
      onEdit: (v) => _wizard(existing: v));

  String _driversOf(Map v) => [for (final id in (v['driver_ids'] as List? ?? const [])) _users['$id'] ?? '—'].join(', ');

  /// The most urgent service of a vehicle.
  (Map<String, dynamic>, ServiceState)? _next(Map v) {
    (Map<String, dynamic>, ServiceState)? best;
    int rank(String s) => s == 'overdue' ? 0 : s == 'due' ? 1 : 2;
    for (final s in _services[v['id']] ?? const <Map<String, dynamic>>[]) {
      final st = serviceState(s, v['odometer'] as num?, _lead);
      if (best == null || rank(st.state) < rank(best.$2.state) ||
          (rank(st.state) == rank(best.$2.state) && st.progress > best.$2.progress)) {
        best = (s, st);
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final list = _vehicles.where((v) {
      if (_search.isEmpty) return true;
      final q = _search.toLowerCase();
      return '${v['reg_no']} ${vehicleTitle(v)} ${_driversOf(v)}'.toLowerCase().contains(q);
    }).toList();
    final states = {for (final v in _vehicles) v['id']: vehicleState(_services[v['id']] ?? const [], v['odometer'] as num?, _lead)};
    final due = states.values.where((s) => s == 'due').length;
    final overdue = states.values.where((s) => s == 'overdue').length;
    final repairs = _openTasks.values.fold<int>(0, (a, b) => a + b);

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(wide ? 24 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Fleet', style: TextStyle(fontSize: wide ? 26 : 22, fontWeight: FontWeight.w800)),
          const SizedBox(width: 4),
          _chip('${_vehicles.length}', 'vehicles', AppTheme.primary),
          if (due > 0) _chip('$due', 'service due', const Color(0xFFD97706)),
          if (overdue > 0) _chip('$overdue', 'overdue', const Color(0xFFDC2626)),
          if (repairs > 0) _chip('$repairs', 'repairs ongoing', const Color(0xFF7C3AED)),
          const SizedBox(width: 12),
          SizedBox(
            width: 220,
            child: TextField(
              decoration: const InputDecoration(isDense: true, hintText: 'Search vehicles…', prefixIcon: Icon(Icons.search, size: 18)),
              onChanged: (v) => setState(() => _search = v.trim()),
            ),
          ),
          OutlinedButton.icon(onPressed: _vehicles.isEmpty ? null : _printList, icon: const Icon(Icons.print_outlined, size: 16), label: const Text('Print / PDF')),
          OutlinedButton.icon(onPressed: _copyFromAssets, icon: const Icon(Icons.copy_all_outlined, size: 16), label: const Text('Copy from assets')),
          ElevatedButton.icon(onPressed: () => _wizard(), icon: const Icon(Icons.add, size: 16), label: const Text('Add vehicle')),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _missing
                  ? const Center(child: Text('Run SQL 463 to set up Fleet.', style: TextStyle(color: AppTheme.textSecondary)))
                  : list.isEmpty
                      ? const Center(child: Text('No vehicles yet. Add one, or copy from Assets.', style: TextStyle(color: AppTheme.textSecondary)))
                      : RefreshIndicator(
                          onRefresh: () => _load(sync: true),
                          child: ListView(children: [for (final v in list) _row(v, states[v['id']] ?? 'ok', wide)]),
                        ),
        ),
      ]),
    );
  }

  Widget _chip(String v, String l, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: c.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: c.withOpacity(0.25))),
        child: Text.rich(TextSpan(style: TextStyle(fontSize: 12, color: c), children: [
          TextSpan(text: v, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          TextSpan(text: '  $l'),
        ])),
      );

  Widget _statePill(String st) {
    final c = st == 'overdue' ? const Color(0xFFDC2626) : st == 'due' ? const Color(0xFFD97706) : const Color(0xFF059669);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(999)),
      child: Text(st == 'overdue' ? 'Overdue' : st == 'due' ? 'Service due soon' : 'Good',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _thumb(Map v) {
    final ph = (v['photos'] as List? ?? const []);
    return Container(
      width: 56, height: 40,
      decoration: BoxDecoration(color: const Color(0xFFE2E8F0), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: ph.isEmpty
          ? Icon(vehicleIcon(v['vehicle_type'] as String?), color: const Color(0xFF64748B))
          : Image.network('${ph.first}', fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
    );
  }

  Widget _row(Map<String, dynamic> v, String st, bool wide) {
    final nx = _next(v);
    final today = _todayKm[v['id']] ?? 0;
    final tasks = _openTasks[v['id']] ?? 0;
    final vehicle = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${v['reg_no']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
      Text.rich(TextSpan(style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary), children: [
        TextSpan(text: vehicleTitle(v)),
        if (v['asset_id'] == null) const TextSpan(text: '  ·  not in assets yet', style: TextStyle(color: Color(0xFFB45309))),
      ])),
    ]);
    final odo = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(km(v['odometer'] as num?), style: const TextStyle(fontWeight: FontWeight.w700)),
      if (today > 0) Text('+${km(today)} today', style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
    ]);
    final next = nx == null
        ? const Text('No services set', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary))
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${nx.$1['name']} · ${nx.$2.label}', style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 4),
            SizedBox(
              width: 160,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: nx.$2.progress.clamp(0, 1).toDouble(), minHeight: 5,
                    backgroundColor: const Color(0xFFE2E8F0), color: nx.$2.color),
              ),
            ),
          ]);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppTheme.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(v['id'] as String),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: wide
              ? Row(children: [
                  _thumb(v), const SizedBox(width: 14),
                  Expanded(flex: 3, child: vehicle),
                  Expanded(flex: 2, child: Text(_driversOf(v).isEmpty ? '—' : _driversOf(v), style: const TextStyle(fontSize: 12.5))),
                  Expanded(flex: 2, child: odo),
                  Expanded(flex: 3, child: next),
                  SizedBox(width: 130, child: tasks > 0
                      ? Text('$tasks repair${tasks == 1 ? '' : 's'} ongoing', style: const TextStyle(fontSize: 12, color: Color(0xFF7C3AED)))
                      : const Text('—', style: TextStyle(color: AppTheme.textSecondary))),
                  SizedBox(width: 130, child: Align(alignment: Alignment.centerLeft, child: _statePill(st))),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [_thumb(v), const SizedBox(width: 10), Expanded(child: vehicle), _statePill(st)]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 18, runSpacing: 8, children: [
                    odo, next,
                    if (_driversOf(v).isNotEmpty) Text('Driver: ${_driversOf(v)}', style: const TextStyle(fontSize: 12)),
                    if (tasks > 0) Text('$tasks repair${tasks == 1 ? '' : 's'} ongoing', style: const TextStyle(fontSize: 12, color: Color(0xFF7C3AED))),
                  ]),
                ]),
        ),
      ),
    );
  }

  // ── copy from assets ──────────────────────────────────────────────────────
  Future<void> _copyFromAssets() async {
    final org = _orgId;
    if (org == null) return;
    List<Map<String, dynamic>> assets = [];
    try {
      final cats = await fleetDb.from('asset_categories').select('id, name').eq('org_id', org);
      final ids = [
        for (final c in cats as List)
          if (RegExp(r'vehicle|earth\s*-?\s*moving', caseSensitive: false).hasMatch('${c['name'] ?? ''}')) c['id'] as String
      ];
      if (ids.isNotEmpty) {
        assets = List<Map<String, dynamic>>.from(await fleetDb.from('assets')
            .select('id, asset_code, name, model, manufacturer, serial_no, branch_id, category_id')
            .eq('org_id', org).eq('is_active', true).inFilter('category_id', ids).order('asset_code'));
      }
    } catch (e) {
      _snack(friendlyError('Could not load assets', e));
      return;
    }
    final linked = {for (final v in _vehicles) if (v['asset_id'] != null) v['asset_id']};
    assets = assets.where((a) => !linked.contains(a['id'])).toList();
    if (!mounted) return;
    var q = '';
    final pick = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        final shown = q.isEmpty
            ? assets
            : assets.where((a) => '${a['name'] ?? ''} ${a['asset_code'] ?? ''} ${a['manufacturer'] ?? ''} ${a['model'] ?? ''} ${a['serial_no'] ?? ''}'
                .toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
        title: const Text('Copy from assets'),
        content: SizedBox(
          width: 460,
          child: assets.isEmpty
              ? const Text('No assets in the "Vehicles" or "Earth moving" categories that aren\'t in Fleet already.')
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(isDense: true, hintText: 'Search name, code, make, model…', prefixIcon: Icon(Icons.search, size: 18)),
                    onChanged: (v) => setS(() => q = v.trim()),
                  ),
                  const SizedBox(height: 8),
                  if (shown.isEmpty)
                    const Padding(padding: EdgeInsets.all(12), child: Text('No match.', style: TextStyle(color: AppTheme.textSecondary))),
                  Flexible(child: ListView(shrinkWrap: true, children: [
                  for (final a in shown)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.local_shipping_outlined),
                      title: Text('${a['name'] ?? ''}'),
                      subtitle: Text([a['asset_code'], a['manufacturer'], a['model']].where((x) => (x ?? '') != '').join(' · ')),
                      onTap: () => Navigator.pop(ctx, a),
                    ),
                  ])),
                ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      );
      }),
    );
    if (pick == null) return;
    await _wizard(fromAsset: pick);
  }

  // ── add / edit wizard ─────────────────────────────────────────────────────
  Future<void> _wizard({Map<String, dynamic>? existing, Map<String, dynamic>? fromAsset}) async {
    final org = _orgId;
    if (org == null) return;
    final isEdit = existing != null;
    final e = existing ?? const <String, dynamic>{};
    final a = fromAsset ?? const <String, dynamic>{};
    final reg = TextEditingController(text: '${e['reg_no'] ?? a['name'] ?? ''}');
    final make = TextEditingController(text: '${e['make'] ?? a['manufacturer'] ?? ''}');
    final model = TextEditingController(text: '${e['model'] ?? a['model'] ?? ''}');
    final year = TextEditingController(text: '${e['year'] ?? ''}');
    final colour = TextEditingController(text: '${e['colour'] ?? ''}');
    final engine = TextEditingController(text: '${e['engine_no'] ?? ''}');
    final chassis = TextEditingController(text: '${e['chassis_no'] ?? a['serial_no'] ?? ''}');
    final odo = TextEditingController(text: e['start_odometer'] == null ? '' : '${e['start_odometer']}');
    String? type = e['vehicle_type'] as String? ?? (a.isNotEmpty ? 'Pickup' : null);
    String? fuel = e['fuel'] as String?;
    String? branch = (e['branch_id'] ?? a['branch_id']) as String?;
    final drivers = <String>{for (final d in (e['driver_ids'] as List? ?? const [])) '$d'};
    final photos = <String>[for (final p in (e['photos'] as List? ?? const [])) '$p'];
    final services = <Map<String, dynamic>>[
      if (!isEdit) ...[
        {'name': 'Oil change', 'every_km': 3000, 'every_months': 3},
        {'name': 'Tyre rotation', 'every_km': 10000},
        {'name': 'General service', 'every_months': 6},
        {'name': 'Token tax / fitness', 'every_months': 12},
      ],
    ];
    final steps = isEdit ? 3 : 4;
    var step = 0;
    var saving = false;
    var uploading = false;
    final tmpId = existing?['id'] ?? 'new_${DateTime.now().millisecondsSinceEpoch}';

    Future<void> addPhotos(void Function(void Function()) setS) async {
      final input = html.FileUploadInputElement()..accept = 'image/*'..multiple = true;
      input.style.display = 'none';
      html.document.body?.append(input);
      input.click();
      await input.onChange.first;
      final files = input.files ?? const [];
      input.remove();
      if (files.isEmpty) return;
      setS(() => uploading = true);
      for (final f in files) {
        if (photos.length >= 8) break;
        try {
          final reader = html.FileReader()..readAsArrayBuffer(f);
          await reader.onLoadEnd.first;
          final res = reader.result;
          final bytes = res is Uint8List ? res : (res as ByteBuffer).asUint8List();
          final ext = (f.name.contains('.') ? f.name.split('.').last : 'jpg').toLowerCase();
          final path = '$org/$tmpId/${DateTime.now().millisecondsSinceEpoch}.$ext';
          await Supabase.instance.client.storage.from('fleet-photos').uploadBinary(path, bytes,
              fileOptions: FileOptions(upsert: true, contentType: f.type.isEmpty ? 'image/jpeg' : f.type));
          photos.add(Supabase.instance.client.storage.from('fleet-photos').getPublicUrl(path));
        } catch (err) {
          _snack(friendlyError('Upload failed', err));
        }
      }
      setS(() => uploading = false);
    }

    InputDecoration dec(String l) => InputDecoration(labelText: l, isDense: true, border: const OutlineInputBorder());
    Widget tf(TextEditingController c, String l, {bool num = false}) => TextField(
          controller: c, decoration: dec(l),
          keyboardType: num ? TextInputType.number : TextInputType.text,
          inputFormatters: num ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))] : null,
        );
    Widget pair(Widget x, Widget y) => Row(children: [Expanded(child: x), const SizedBox(width: 10), Expanded(child: y)]);
    Widget dd(String l, String? val, List<String> opts, void Function(String?) on) => DropdownButtonFormField<String>(
          value: opts.contains(val) ? val : null, isExpanded: true, decoration: dec(l),
          items: [for (final o in opts) DropdownMenuItem(value: o, child: Text(o))], onChanged: on);

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        Widget body;
        if (step == 0) {
          body = Column(mainAxisSize: MainAxisSize.min, children: [
            pair(tf(reg, 'Registration no. *'), dd('Type', type, const ['Pickup', 'Truck', 'Van', 'Car', 'Motorbike', 'Earth moving', 'Other'], (v) => setS(() => type = v))),
            const SizedBox(height: 10),
            pair(tf(make, 'Make'), tf(model, 'Model')),
            const SizedBox(height: 10),
            pair(tf(year, 'Year', num: true), tf(colour, 'Colour')),
            const SizedBox(height: 10),
            pair(tf(engine, 'Engine no.'), tf(chassis, 'Chassis no.')),
            const SizedBox(height: 10),
            dd('Fuel', fuel, const ['Petrol', 'Diesel', 'CNG', 'LPG', 'Electric', 'Hybrid'], (v) => setS(() => fuel = v)),
            if (a.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text('Copied from asset ${a['asset_code'] ?? ''}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
          ]);
        } else if (step == 1) {
          body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            tf(odo, isEdit ? 'Starting odometer (km)' : 'Odometer now (km) *', num: true),
            if (isEdit)
              const Padding(padding: EdgeInsets.only(top: 4),
                  child: Text('To correct today\'s reading use "Odometer reading" on the vehicle.', style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary))),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _branches.any((b) => b['id'] == branch) ? branch : null, isExpanded: true, decoration: dec('Branch'),
              items: [for (final b in _branches) DropdownMenuItem(value: b['id'] as String, child: Text('${b['name']}'))],
              onChanged: (v) => setS(() => branch = v)),
            const SizedBox(height: 12),
            const Text('Assigned driver(s) — their trips and deliveries add the km', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (!_userList.any((u) => u['role'] == 'driver'))
              const Text('No drivers yet — add them in Team with the Driver role.', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final u in _userList.where((u) => u['role'] == 'driver' || drivers.contains(u['id'])))
                    FilterChip(
                      label: Text('${u['name']}', style: const TextStyle(fontSize: 12)),
                      selected: drivers.contains(u['id']),
                      onSelected: (s) => setS(() => s ? drivers.add(u['id'] as String) : drivers.remove(u['id'])),
                    ),
                ]),
              ),
            ),
          ]);
        } else if (step == 2) {
          body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Photos (${photos.length}/8)', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (var i = 0; i < photos.length; i++)
                Stack(children: [
                  Container(
                    width: 110, height: 78,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border)),
                    clipBehavior: Clip.antiAlias,
                    child: Image.network(photos[i], fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined)),
                  ),
                  Positioned(right: 2, top: 2, child: InkWell(
                    onTap: () => setS(() => photos.removeAt(i)),
                    child: const CircleAvatar(radius: 10, backgroundColor: Colors.black54, child: Icon(Icons.close, size: 12, color: Colors.white)))),
                ]),
              if (photos.length < 8)
                InkWell(
                  onTap: uploading ? null : () => addPhotos(setS),
                  child: Container(
                    width: 110, height: 78,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.primary)),
                    child: Center(child: uploading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.add_a_photo_outlined, color: AppTheme.primary),
                            Text('Add photos', style: TextStyle(fontSize: 11.5, color: AppTheme.primary)),
                          ])),
                  ),
                ),
            ]),
          ]);
        } else {
          body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Regular services — the counter fills as the vehicle drives. Leave km or months empty if not needed.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
            const SizedBox(height: 10),
            for (var i = 0; i < services.length; i++)
              Padding(
                key: ObjectKey(services[i]),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(flex: 3, child: TextFormField(
                    initialValue: '${services[i]['name'] ?? ''}', decoration: dec('Service'),
                    onChanged: (v) => services[i]['name'] = v.trim())),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextFormField(
                    initialValue: services[i]['every_km'] == null ? '' : '${services[i]['every_km']}', decoration: dec('Every km'),
                    keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) => services[i]['every_km'] = int.tryParse(v))),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextFormField(
                    initialValue: services[i]['every_months'] == null ? '' : '${services[i]['every_months']}', decoration: dec('Every months'),
                    keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) => services[i]['every_months'] = int.tryParse(v))),
                  IconButton(onPressed: () => setS(() => services.removeAt(i)), icon: const Icon(Icons.delete_outline, size: 18)),
                ]),
              ),
            TextButton.icon(
              onPressed: () => setS(() => services.add({'name': ''})),
              icon: const Icon(Icons.add, size: 16), label: const Text('Add a service')),
            const Text('Counters start from today\'s odometer. Change "last done" later on the vehicle if a service was done recently.',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
          ]);
        }

        Future<void> save() async {
          if (reg.text.trim().isEmpty) { setS(() => step = 0); _snack('Enter the registration no.'); return; }
          final startOdo = num.tryParse(odo.text.trim());
          if (!isEdit && startOdo == null) { setS(() => step = 1); _snack('Enter the odometer reading.'); return; }
          setS(() => saving = true);
          try {
            final me = await fleetDb.rpc('fleet_my_name', params: {'p_org': org}).catchError((_) => null);
            final payload = <String, dynamic>{
              'reg_no': reg.text.trim().toUpperCase(),
              'vehicle_type': type, 'make': make.text.trim(), 'model': model.text.trim(),
              'year': int.tryParse(year.text.trim()), 'colour': colour.text.trim(),
              'engine_no': engine.text.trim(), 'chassis_no': chassis.text.trim(), 'fuel': fuel,
              'branch_id': branch, 'driver_ids': drivers.toList(), 'photos': photos,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            };
            String id;
            if (isEdit) {
              id = e['id'] as String;
              if (startOdo != null) payload['start_odometer'] = startOdo;
              await fleetDb.from('fleet_vehicles').update(payload).eq('id', id);
              await fleetDb.rpc('fleet_recalc', params: {'p_vehicle': id}).catchError((_) => null);
            } else {
              final row = await fleetDb.from('fleet_vehicles').insert({
                ...payload, 'org_id': org, 'start_odometer': startOdo, 'odometer': startOdo,
                'asset_id': a['id'], 'created_by_name': me is String ? me : null,
              }).select('id').single();
              id = row['id'] as String;
              final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
              final rows = [
                for (final s in services)
                  if ('${s['name'] ?? ''}'.trim().isNotEmpty && ((s['every_km'] ?? 0) as num > 0 || (s['every_months'] ?? 0) as num > 0))
                    {
                      'org_id': org, 'vehicle_id': id, 'name': '${s['name']}'.trim(),
                      'every_km': s['every_km'], 'every_months': s['every_months'],
                      'last_km': startOdo, 'last_date': today,
                    },
              ];
              if (rows.isNotEmpty) await fleetDb.from('fleet_services').insert(rows);
            }
            if (ctx.mounted) Navigator.pop(ctx);
            await _load();
            _snack(isEdit ? 'Vehicle saved' : 'Vehicle added');
          } catch (err) {
            setS(() => saving = false);
            _snack(friendlyError('Could not save', err));
          }
        }

        const labels = ['Details', 'Mileage & driver', 'Photos', 'Service plan'];
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isEdit ? 'Edit ${e['reg_no']}' : 'Add vehicle'),
            const SizedBox(height: 10),
            Row(children: [
              for (var i = 0; i < steps; i++) ...[
                Expanded(
                  child: InkWell(
                    onTap: () => setS(() => step = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: i == step ? AppTheme.primary : i < step ? const Color(0xFFDBEAFE) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text('${i + 1} ${labels[i]}', overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600,
                              color: i == step ? Colors.white : i < step ? const Color(0xFF1D4ED8) : const Color(0xFF64748B))),
                    ),
                  ),
                ),
                if (i < steps - 1) const SizedBox(width: 6),
              ],
            ]),
          ]),
          content: SizedBox(width: 560, child: SingleChildScrollView(child: body)),
          actions: [
            TextButton(onPressed: saving ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            if (step > 0) OutlinedButton(onPressed: saving ? null : () => setS(() => step--), child: const Text('Back')),
            if (step < steps - 1)
              ElevatedButton(onPressed: () => setS(() => step++), child: const Text('Next'))
            else
              ElevatedButton(
                onPressed: saving || uploading ? null : save,
                child: saving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(isEdit ? 'Save' : 'Save vehicle')),
          ],
        );
      }),
    );
  }

  void _printList() {
    final b = StringBuffer()
      ..write('<h1>Fleet</h1><div class="meta">${_vehicles.length} vehicles</div>')
      ..write('<table><tr><th>Vehicle</th><th>Driver</th><th class="num">Odometer</th><th>Next service</th><th>Repairs</th><th>Status</th></tr>');
    for (final v in _vehicles) {
      final nx = _next(v);
      final st = vehicleState(_services[v['id']] ?? const [], v['odometer'] as num?, _lead);
      b.write('<tr><td><b>${esc(v['reg_no'])}</b><br>${esc(vehicleTitle(v))}</td><td>${esc(_driversOf(v))}</td>'
          '<td class="num">${esc(km(v['odometer'] as num?))}</td>'
          '<td>${nx == null ? '' : '${esc(nx.$1['name'])} · ${esc(nx.$2.label)}'}</td>'
          '<td>${(_openTasks[v['id']] ?? 0) > 0 ? '${_openTasks[v['id']]} ongoing' : ''}</td>'
          '<td class="$st">${st == 'overdue' ? 'Overdue' : st == 'due' ? 'Service due soon' : 'Good'}</td></tr>');
    }
    b.write('</table>');
    openPrint('Fleet', b.toString());
  }
}
