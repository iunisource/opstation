import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/friendly_error.dart';
import '../../auth/auth_controller.dart';

/// "Other locations" of a customer (SQL 409), e.g. Godown, Shop 2. A visit at
/// any of them counts as verified, same as at the main location. Everyone can
/// see them; only admins add, change or remove.
class CustomerOtherLocations extends ConsumerStatefulWidget {
  final String customerId;
  final String shopName;
  final String? shopCode;
  const CustomerOtherLocations({super.key, required this.customerId, required this.shopName, this.shopCode});

  @override
  ConsumerState<CustomerOtherLocations> createState() => _CustomerOtherLocationsState();
}

class _CustomerOtherLocationsState extends ConsumerState<CustomerOtherLocations> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  bool _busy = false;
  bool _ready = true; // false when the database update (409) isn't applied yet

  bool get _canManage {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.superAdmin || r == WebUserRole.masterAdmin || r == WebUserRole.admin;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('customer_locations')
          .select('id, name, latitude, longitude, created_by_name, created_at')
          .eq('customer_id', widget.customerId)
          .order('name');
      if (!mounted) return;
      setState(() {
        _list = List<Map<String, dynamic>>.from(rows as List);
        _ready = true;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _ready = false; _loading = false; });
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _edit([Map<String, dynamic>? loc]) async {
    final taken = {
      for (final l in _list)
        if (l['id'] != loc?['id']) '${l['name']}'.toLowerCase(),
    };
    final res = await showDialog<(String, double, double)>(
      context: context,
      builder: (_) => _LocationDialog(initial: loc, taken: taken),
    );
    if (res == null || !mounted) return;
    final (name, lat, lng) = res;
    final orgId = ref.read(currentUserProvider)?.orgId;
    // Same spot as another customer? Warn first (never blocks).
    var warned = false;
    if (orgId != null) {
      final hits = await _sameSpot(orgId, lat, lng);
      if (hits.isNotEmpty) {
        if (!mounted) return;
        final go = await _confirmSameSpot(hits, lat, lng);
        if (go != true) return;
        warned = true;
      }
    }
    setState(() => _busy = true);
    try {
      if (loc == null) {
        await Supabase.instance.client.rpc('customer_location_add', params: {
          'p_customer_id': widget.customerId, 'p_name': name, 'p_lat': lat, 'p_lng': lng,
        });
        if (warned) {
          try {
            await Supabase.instance.client.rpc('dup_loc_mark_warned', params: {'p_customer_id': widget.customerId});
          } catch (_) {}
        }
        _snack('Location "$name" added');
      } else {
        await Supabase.instance.client.rpc('customer_location_update', params: {
          'p_id': loc['id'], 'p_name': name, 'p_lat': lat, 'p_lng': lng,
        });
        _snack('Location "$name" saved');
      }
      await _load();
    } catch (e) {
      _snack(friendlyError('Could not save the location', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Other customers already saved at this spot (never blocks on failure).
  Future<List<Map<String, dynamic>>> _sameSpot(String orgId, double lat, double lng) async {
    try {
      final r = await Supabase.instance.client.rpc('customer_location_duplicates', params: {
        'p_org_id': orgId, 'p_lat': lat, 'p_lng': lng, 'p_exclude_id': widget.customerId,
      });
      return List<Map<String, dynamic>>.from(r as List).where((h) => h['is_active'] != false).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool?> _confirmSameSpot(List<Map<String, dynamic>> hits, double lat, double lng) => showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.wrong_location_outlined, color: Colors.orange),
          title: const Text('Another customer is at this exact location'),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)} is already saved for:',
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              for (final h in hits)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('${h['code'] ?? ''}  ${h['shop_name'] ?? ''}'.trim(),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                ),
              const SizedBox(height: 6),
              const Text('Check that this is the right place. If you save anyway it will be listed in '
                  'Financials → Duplicate References for review.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back and review')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade700, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save anyway'),
            ),
          ],
        ),
      );

  Future<void> _remove(Map<String, dynamic> loc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${loc['name']}"?'),
        content: const Text('Visits at this place will no longer be verified. Past visits are not changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.rpc('customer_location_delete', params: {'p_id': loc['id']});
      _snack('Location removed');
      await _load();
    } catch (e) {
      _snack(friendlyError('Could not remove the location', e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _canManage;
    if (!_ready || (!canManage && _list.isEmpty && !_loading)) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppTheme.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Other locations', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          if (_loading || _busy) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const Spacer(),
          if (canManage)
            TextButton.icon(
              onPressed: _busy ? null : () => _edit(),
              icon: const Icon(Icons.add_location_alt_outlined, size: 16),
              label: const Text('Add location'),
            ),
        ]),
        const Text('Visits at any of these places count as verified, same as the main location.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        if (_list.isEmpty && !_loading)
          const Text('None added.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
        for (final l in _list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              const Icon(Icons.location_on, size: 15, color: AppTheme.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${l['name']}  ', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  TextSpan(
                    text: '${(l['latitude'] as num).toStringAsFixed(5)}, ${(l['longitude'] as num).toStringAsFixed(5)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ])),
              ),
              IconButton(
                tooltip: 'Copy coordinates',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 15),
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: '${(l['latitude'] as num).toStringAsFixed(6)}, ${(l['longitude'] as num).toStringAsFixed(6)}'));
                  _snack('Coordinates copied');
                },
              ),
              IconButton(
                tooltip: 'Open in Maps',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.map_outlined, size: 16, color: AppTheme.primary),
                onPressed: () => launchUrl(
                    Uri.parse('https://www.google.com/maps/search/?api=1&query=${l['latitude']},${l['longitude']}'),
                    mode: LaunchMode.externalApplication),
              ),
              if (canManage) ...[
                IconButton(
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  onPressed: _busy ? null : () => _edit(l),
                ),
                IconButton(
                  tooltip: 'Remove',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                  onPressed: _busy ? null : () => _remove(l),
                ),
              ],
            ]),
          ),
      ]),
    );
  }
}

class _LocationDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  final Set<String> taken;
  const _LocationDialog({this.initial, required this.taken});

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final _name = TextEditingController(text: '${widget.initial?['name'] ?? ''}');
  late final _coords = TextEditingController(
      text: widget.initial == null
          ? ''
          : '${(widget.initial!['latitude'] as num).toStringAsFixed(6)}, ${(widget.initial!['longitude'] as num).toStringAsFixed(6)}');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _coords.dispose();
    super.dispose();
  }

  /// Accepts "31.5204, 74.3587" or a Google Maps link containing the point.
  (double, double)? _parse(String text) {
    final m = RegExp(r'(-?\d{1,2}\.\d+)\s*[, ]\s*(-?\d{1,3}\.\d+)').firstMatch(text) ??
        RegExp(r'@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)').firstMatch(text);
    if (m == null) return null;
    final la = double.tryParse(m.group(1)!), lo = double.tryParse(m.group(2)!);
    if (la == null || lo == null || la.abs() > 90 || lo.abs() > 180 || (la.abs() < 0.0001 && lo.abs() < 0.0001)) {
      return null;
    }
    return (la, lo);
  }

  void _save() {
    final name = _name.text.trim();
    String? err;
    if (name.isEmpty) {
      err = 'Enter a name, e.g. Godown.';
    } else if (name.toLowerCase() == 'main') {
      err = '"Main" is the customer\'s own location. Use another name.';
    } else if (widget.taken.contains(name.toLowerCase())) {
      err = 'This name is already used for this customer.';
    }
    final c = _parse(_coords.text);
    if (err == null && c == null) err = 'Enter coordinates like 31.520400, 74.358700 (or paste a Google Maps link).';
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, (name, c!.$1, c.$2));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add another location' : 'Edit location'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Godown, Shop 2'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _coords,
            decoration: const InputDecoration(
                labelText: 'Coordinates', hintText: 'Latitude, Longitude — or paste a Google Maps link'),
            onSubmitted: (_) => _save(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: AppTheme.danger)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
