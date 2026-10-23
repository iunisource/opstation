import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/database/app_database_provider.dart';
import '../../../../core/services/device_gps_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/customer_locations.dart';
import '../../../auth/providers/auth_controller.dart';
import '../../../salesperson/models/customer.dart';

/// "Other locations" of a customer (e.g. Godown). Visits there count as
/// verified, same as at the main location. Everyone sees the list; only an
/// admin can add, change or remove (needs internet).
class OtherLocationsCard extends ConsumerStatefulWidget {
  final Customer customer;
  final bool canManage;
  const OtherLocationsCard({super.key, required this.customer, required this.canManage});

  @override
  ConsumerState<OtherLocationsCard> createState() => _OtherLocationsCardState();
}

class _OtherLocationsCardState extends ConsumerState<OtherLocationsCard> {
  List<CustomerExtraLocation> _list = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    await CustomerLocations.ensureLoaded(db);
    if (mounted) setState(() => _list = CustomerLocations.of(widget.customer.id));
    try {
      final rows = await Supabase.instance.client
          .from('customer_locations')
          .select('id, customer_id, name, latitude, longitude')
          .eq('customer_id', widget.customer.id)
          .order('name');
      final list = <CustomerExtraLocation>[
        for (final r in rows as List)
          CustomerExtraLocation('${r['id']}', '${r['customer_id']}', '${r['name'] ?? ''}',
              (r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble()),
      ];
      await CustomerLocations.replaceFor(db, widget.customer.id, list);
      if (mounted) setState(() => _list = list);
    } catch (_) {
      // Offline: the copy on the phone is shown.
    }
    if (mounted) setState(() => _loading = false);
  }

  void _say(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  String _clean(Object e) {
    final s = e is PostgrestException ? e.message : e.toString();
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
      return 'No internet. Connect and try again.';
    }
    return s.replaceFirst('Exception: ', '');
  }

  Future<void> _edit([CustomerExtraLocation? loc]) async {
    final res = await showModalBottomSheet<_LocInput>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LocationForm(initial: loc, taken: {
        for (final l in _list) if (l.id != loc?.id) l.name.toLowerCase(),
      }),
    );
    if (res == null || !mounted) return;
    final orgId = ref.read(orgIdProvider);
    setState(() => _busy = true);
    try {
      // Same spot as another customer? Ask first (never blocks).
      if (orgId != null) {
        try {
          final hits = List<Map<String, dynamic>>.from(await Supabase.instance.client.rpc(
              'customer_location_duplicates', params: {
            'p_org_id': orgId, 'p_lat': res.lat, 'p_lng': res.lng, 'p_exclude_id': widget.customer.id,
          }) as List)
              .where((h) => h['is_active'] != false)
              .toList();
          if (hits.isNotEmpty && mounted) {
            final go = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                icon: const Icon(Icons.wrong_location_outlined, color: Colors.orange),
                title: const Text('Another customer is at this exact location'),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final h in hits)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('${h['code'] ?? ''}  ${h['shop_name'] ?? ''}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  const SizedBox(height: 6),
                  const Text('Check that this is the right place. If you save anyway it will be listed in Duplicate References for review.',
                      style: TextStyle(fontSize: 12.5)),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
                ],
              ),
            );
            if (go != true) return;
          }
        } catch (_) {}
      }
      if (loc == null) {
        await Supabase.instance.client.rpc('customer_location_add', params: {
          'p_customer_id': widget.customer.id, 'p_name': res.name, 'p_lat': res.lat, 'p_lng': res.lng,
        });
        _say('Location "${res.name}" added');
      } else {
        await Supabase.instance.client.rpc('customer_location_update', params: {
          'p_id': loc.id, 'p_name': res.name, 'p_lat': res.lat, 'p_lng': res.lng,
        });
        _say('Location "${res.name}" saved');
      }
      await _load();
    } catch (e) {
      _say(_clean(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(CustomerExtraLocation loc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${loc.name}"?'),
        content: const Text('Visits at this place will no longer be verified. Past visits are not changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.rpc('customer_location_delete', params: {'p_id': loc.id});
      _say('Location removed');
      await _load();
    } catch (e) {
      _say(_clean(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openMaps(CustomerExtraLocation l) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=${l.lat},${l.lng}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _say('Could not open a maps app.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canManage && _list.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.add_location_alt_outlined, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Other locations', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          ),
          if (_loading || _busy)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 4),
        const Text('Visits at any of these places count as verified, same as the main location.',
            style: TextStyle(color: AppColors.textSecondaryLight, fontSize: 12.5)),
        const SizedBox(height: 8),
        if (_list.isEmpty && !_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('None added.', style: TextStyle(color: AppColors.textSecondaryLight, fontSize: 13)),
          ),
        for (final l in _list)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              const Icon(Icons.location_on, size: 16, color: AppColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                  Text('${l.lat.toStringAsFixed(6)}, ${l.lng.toStringAsFixed(6)}',
                      style: const TextStyle(color: AppColors.textSecondaryLight, fontSize: 12)),
                ]),
              ),
              IconButton(
                tooltip: 'Open in Maps',
                icon: const Icon(Icons.directions, size: 20, color: AppColors.primary),
                onPressed: () => _openMaps(l),
              ),
              if (widget.canManage)
                PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (v) => v == 'edit' ? _edit(l) : _remove(l),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
            ]),
          ),
        if (widget.canManage) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : () => _edit(),
              icon: const Icon(Icons.add_location_alt, size: 18),
              label: const Text('Add another location'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            ),
          ),
        ],
      ]),
    );
  }
}

class _LocInput {
  final String name;
  final double lat;
  final double lng;
  const _LocInput(this.name, this.lat, this.lng);
}

class _LocationForm extends ConsumerStatefulWidget {
  final CustomerExtraLocation? initial;
  final Set<String> taken;
  const _LocationForm({this.initial, required this.taken});

  @override
  ConsumerState<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends ConsumerState<_LocationForm> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _coords = TextEditingController(
      text: widget.initial == null
          ? ''
          : '${widget.initial!.lat.toStringAsFixed(6)}, ${widget.initial!.lng.toStringAsFixed(6)}');
  bool _locating = false;
  String? _gpsNote;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _coords.dispose();
    super.dispose();
  }

  Future<void> _useGps() async {
    setState(() { _locating = true; _gpsNote = null; _error = null; });
    final r = await ref.read(deviceGpsServiceProvider).getFixResult(timeout: const Duration(seconds: 25));
    if (!mounted) return;
    setState(() => _locating = false);
    final f = r.fix;
    if (f == null || r.isStale) {
      setState(() => _error = switch (r.outcome) {
            GpsOutcome.serviceDisabled => 'Turn on location (GPS) and try again.',
            GpsOutcome.permissionDenied || GpsOutcome.permissionBlocked => 'Allow location access for the app and try again.',
            _ => 'Could not get your location. Move to open sky and try again.',
          });
      return;
    }
    _coords.text = '${f.lat.toStringAsFixed(6)}, ${f.lng.toStringAsFixed(6)}';
    setState(() => _gpsNote = f.accuracy > 30
        ? 'GPS accuracy is ${f.accuracy.round()} m — try again for a sharper fix.'
        : 'Your location (accuracy ${f.accuracy.round()} m)');
  }

  (double, double)? _parse() {
    final parts = _coords.text.split(RegExp(r'[,\s]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length != 2) return null;
    final la = double.tryParse(parts[0]), lo = double.tryParse(parts[1]);
    if (la == null || lo == null || la.abs() > 90 || lo.abs() > 180 || (la.abs() < 0.0001 && lo.abs() < 0.0001)) {
      return null;
    }
    return (la, lo);
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter a name, e.g. Godown.');
    if (name.toLowerCase() == 'main') return setState(() => _error = '"Main" is the customer\'s own location. Use another name.');
    if (widget.taken.contains(name.toLowerCase())) return setState(() => _error = 'This name is already used for this customer.');
    final c = _parse();
    if (c == null) return setState(() => _error = 'Use your location, or enter coordinates like 31.520400, 74.358700.');
    Navigator.pop(context, _LocInput(name, c.$1, c.$2));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.initial == null ? 'Add another location' : 'Edit location',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Godown, Shop 2'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _coords,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s-]'))],
          decoration: const InputDecoration(labelText: 'Coordinates', hintText: 'Latitude, Longitude'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _locating ? null : _useGps,
          icon: _locating
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location, size: 18),
          label: Text(_locating ? 'Getting your location…' : 'Use my current location'),
        ),
        if (_gpsNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_gpsNote!, style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: const TextStyle(fontSize: 13, color: AppColors.danger)),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _locating ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          child: const Text('Save'),
        ),
      ]),
    );
  }
}
