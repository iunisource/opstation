import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/pdf/pdf_output.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/place_name.dart';
import '../reports/pdf/report_pdf_builder.dart';

/// "Adjusted by approver" text for one trip's adjustment row
/// (reimb_adjustments): who, when, what was left out and the km change.
String reimbAdjustNote(Map a, {String? dayLabel, bool reasons = true, double? defaultAllowance}) {
  final ex = [for (final e in (a['excluded'] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
  String why(Object? r) => reasons && '${r ?? ''}'.trim().isNotEmpty ? ' (${'$r'.trim()})' : '';
  final parts = <String>[
    for (final e in ex) '${e['time'] ?? ''} ${e['shop'] ?? 'visit'}${why(e['reason'])}'.trim(),
    if (a['exclude_return'] == true) 'return to end point${why(a['return_reason'])}',
  ];
  final allow = (a['allowance'] as num?)?.toDouble();
  final at = DateTime.tryParse('${a['at'] ?? ''}')?.toLocal();
  final o = (a['original_km'] as num?)?.toDouble() ?? 0;
  final n = (a['adjusted_km'] as num?)?.toDouble() ?? 0;
  final nf = NumberFormat('#,##0');
  return '${dayLabel == null ? '' : '$dayLabel: '}${a['by_name'] ?? 'Approver'}'
      '${at == null ? '' : ', ${DateFormat('d MMM yyyy').format(at)}'}: '
      '${parts.isEmpty ? '' : 'left out ${parts.join('; ')}. ${o.toStringAsFixed(2)} km → ${n.toStringAsFixed(2)} km. '}'
      '${allow == null ? '' : 'Allowance ${defaultAllowance == null ? '' : 'Rs ${nf.format(defaultAllowance)} → '}Rs ${nf.format(allow)}.'}'
      .trim();
}

/// Approver adjusts one trip of a claim: untick visits / the return leg, give
/// reasons; the road distance is worked out again. Returns 'saved',
/// 'approve' (save, then open Approve) or null. Read-only when [canEdit] is
/// false (the adjustment can still be printed).
Future<String?> showAdjustTripDialog(
  BuildContext context, {
  required Map<String, dynamic> claim,
  required String tripId,
  required double lineKm, // the claim line's km now (adjusted if already adjusted)
  Map<String, dynamic>? existing, // reimb_adjustments row
  double? rate,
  double allowanceDefault = 0, // Admin Settings allowance per day (0 = none)
  required String orgName,
  required bool canEdit,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _AdjustTripDialog(
      claim: claim, tripId: tripId, lineKm: lineKm, existing: existing,
      rate: rate, allowanceDefault: allowanceDefault, orgName: orgName, canEdit: canEdit),
  );
}

class _AdjustTripDialog extends StatefulWidget {
  final Map<String, dynamic> claim;
  final String tripId;
  final double lineKm;
  final Map<String, dynamic>? existing;
  final double? rate;
  final double allowanceDefault;
  final String orgName;
  final bool canEdit;
  const _AdjustTripDialog({
    required this.claim, required this.tripId, required this.lineKm, this.existing,
    this.rate, this.allowanceDefault = 0, required this.orgName, required this.canEdit,
  });
  @override
  State<_AdjustTripDialog> createState() => _AdjustTripDialogState();
}

class _AdjustTripDialogState extends State<_AdjustTripDialog> {
  final _db = Supabase.instance.client;
  bool _loading = true, _calc = false, _saving = false;
  String? _error;
  Map<String, dynamic>? _trip;
  List<Map<String, dynamic>> _visits = [];
  final Map<String, Map<String, dynamic>> _custs = {};
  (String?, String?) _places = (null, null);
  TripReportContext? _orig, _adj;
  final Map<String, TextEditingController> _out = {}; // visit id → reason
  bool _noReturn = false;
  final _returnReason = TextEditingController();
  final _allowCtl = TextEditingController();

  /// The day's allowance as typed (falls back to the default).
  double get _allowance => double.tryParse(_allowCtl.text.trim()) ?? widget.allowanceDefault;
  bool get _allowChanged => (_allowance - widget.allowanceDefault).abs() > 0.004;

  /// The claim's original km for this trip (before any adjustment).
  double get _originalKm =>
      (widget.existing?['original_km'] as num?)?.toDouble() ?? widget.lineKm;

  /// Adjusted km, kept consistent with the claim: original − what was removed.
  double? get _adjustedKm {
    final o = _orig, a = _adj;
    if (o == null || a == null) return null;
    final removed = o.totalDistanceKm - a.totalDistanceKm;
    final v = _originalKm - (removed < 0 ? 0 : removed);
    return v < 0 ? 0 : v;
  }

  bool get _changed => _out.isNotEmpty || _noReturn;
  bool get _anyChange => _changed || _allowChanged;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      for (final e in (ex['excluded'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(e as Map);
        _out['${m['visit']}'] = TextEditingController(text: '${m['reason'] ?? ''}');
      }
      _noReturn = ex['exclude_return'] == true;
      _returnReason.text = '${ex['return_reason'] ?? ''}';
    }
    final a0 = (ex?['allowance'] as num?)?.toDouble() ?? widget.allowanceDefault;
    _allowCtl.text = a0 == a0.roundToDouble() ? '${a0.round()}' : '$a0';
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await _db.from('trips').select().eq('id', widget.tripId).maybeSingle();
      if (t == null) throw 'This trip was not found.';
      _trip = Map<String, dynamic>.from(t);
      _visits = List<Map<String, dynamic>>.from(
          await _db.from('visits').select().eq('trip_id', widget.tripId).order('timestamp', ascending: true));
      final ids = {for (final v in _visits) if (v['customer_id'] != null) v['customer_id'] as String}.toList();
      for (var i = 0; i < ids.length; i += 400) {
        final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        for (final c in await _db.from('customers').select('id, shop_name, code').inFilter('id', chunk)) {
          _custs[c['id'] as String] = Map<String, dynamic>.from(c);
        }
      }
      _places = await tripPlaceNames(_trip!);
      _orig = await TripReportContext.buildRoad(
          trip: _trip!, visits: _visits, customersById: _custs, startAddress: _places.$1, endAddress: _places.$2);
      await _recalc();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = friendlyError('Could not load the trip', e); });
    }
  }

  Future<void> _recalc() async {
    final t = _trip;
    if (t == null) return;
    setState(() => _calc = true);
    try {
      final keep = _visits.where((v) => !_out.containsKey('${v['id']}')).toList();
      var a = await TripReportContext.buildRoad(
          trip: t, visits: keep, customersById: _custs, startAddress: _places.$1, endAddress: _places.$2);
      if (_noReturn) {
        a = TripReportContext(
          trip: a.trip, visits: a.visits, customersById: a.customersById,
          startAddress: a.startAddress, endAddress: a.endAddress,
          orderedVerifiedVisits: a.orderedVerifiedVisits, distanceKm: a.distanceKm,
          returnDistanceKm: 0, totalDistanceKm: a.totalDistanceKm - a.returnDistanceKm,
          usedGoogle: a.usedGoogle,
        );
      }
      if (mounted) setState(() { _adj = a; _calc = false; });
    } catch (_) {
      if (mounted) setState(() => _calc = false);
    }
  }

  String _shop(Map v) => '${(_custs[v['customer_id']] ?? const {})['shop_name'] ?? 'Shop'}';
  String _time(Map v) {
    final d = DateTime.tryParse('${v['timestamp'] ?? ''}')?.toLocal();
    return d == null ? '' : DateFormat('HH:mm').format(d);
  }

  List<Map<String, dynamic>> _excludedJson() => [
        for (final v in _visits)
          if (_out.containsKey('${v['id']}'))
            {'visit': '${v['id']}', 'shop': _shop(v), 'time': _time(v), 'reason': _out['${v['id']}']!.text.trim()},
      ];

  String? _check() {
    for (final e in _excludedJson()) {
      if ('${e['reason']}'.isEmpty) return 'Enter the reason for ${e['shop']}.';
    }
    if (_noReturn && _returnReason.text.trim().isEmpty) return 'Enter the reason for leaving out the return leg.';
    return null;
  }

  Future<void> _save({required bool approve}) async {
    final err = _check();
    if (err != null) { setState(() => _error = err); return; }
    final adj = _adjustedKm;
    if (_changed && adj == null) { setState(() => _error = 'Still working out the distance — try again in a moment.'); return; }
    setState(() { _saving = true; _error = null; });
    try {
      await _db.rpc('reimb_adjust_trip', params: {
        'p_claim': widget.claim['id'],
        'p_trip': widget.tripId,
        'p_excluded': _excludedJson(),
        'p_exclude_return': _noReturn,
        'p_return_reason': _returnReason.text.trim(),
        'p_original_km': _originalKm,
        'p_adjusted_km': _changed ? adj : _originalKm,
        'p_allowance': _allowance,
      });
      if (mounted) Navigator.pop(context, approve ? 'approve' : 'saved');
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = friendlyError('Could not save', e); });
    }
  }

  Future<void> _print() async {
    final a = _adj, t = _trip;
    if (a == null || t == null) return;
    final err = _changed ? _check() : null;
    if (err != null) { setState(() => _error = err); return; }
    // Salesperson-facing: what was left out, without the approver's reasons.
    final note = _anyChange
        ? reimbAdjustNote({
            'excluded': _excludedJson(),
            'exclude_return': _noReturn,
            'by_name': widget.canEdit ? null : widget.existing?['by_name'],
            'at': widget.canEdit ? DateTime.now().toIso8601String() : widget.existing?['at'],
            'original_km': _originalKm,
            'adjusted_km': _adjustedKm,
            if (_allowChanged) 'allowance': _allowance,
          }, reasons: false, defaultAllowance: widget.allowanceDefault)
        : null;
    // The adjusted distance on the print matches the claim.
    final adjKm = _adjustedKm ?? a.totalDistanceKm;
    final ctx = TripReportContext(
      trip: a.trip, visits: a.visits, customersById: a.customersById,
      startAddress: a.startAddress, endAddress: a.endAddress,
      orderedVerifiedVisits: a.orderedVerifiedVisits, distanceKm: a.distanceKm,
      returnDistanceKm: a.returnDistanceKm, totalDistanceKm: _changed ? adjKm : a.totalDistanceKm,
      usedGoogle: a.usedGoogle,
    );
    final bytes = await ReportPdfBuilder.buildTripSummary(
      ctx: ctx,
      orgName: widget.orgName,
      reimb: ReimbInfo(rate: widget.rate, allowancePerDay: _allowance > 0 || _allowChanged ? _allowance : null, unpaidDays: 1),
      adjustNote: note,
    );
    await outputPdf(bytes, _anyChange ? 'Trip Summary (adjusted)' : 'Trip Summary',
        date: DateTime.tryParse('${t['started_at'] ?? ''}')?.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final o = _orig;
    final rate = widget.rate;
    final adjKm = _adjustedKm;
    final nf = NumberFormat('#,##0');
    final day = DateTime.tryParse('${_trip?['started_at'] ?? ''}')?.toLocal();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 900, maxHeight: MediaQuery.of(context).size.height * 0.92),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${widget.canEdit ? 'Adjust trip' : 'Trip adjustment'} · ${widget.claim['claimant_name'] ?? ''}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  Text([
                    if (day != null) DateFormat('EEE, d MMM yyyy').format(day),
                    if ((_trip?['route_name'] ?? '') != '') '${_trip!['route_name']}',
                  ].join(' · '), style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
                ]),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (o == null)
              Padding(padding: const EdgeInsets.all(20), child: Text(_error ?? 'Could not load the trip.', style: const TextStyle(color: AppTheme.danger)))
            else ...[
              if (widget.canEdit)
                const Text('Untick a visit or the return leg to leave it out, and give the reason. '
                    'The distance is worked out again by road (stop before → stop after).',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 8),
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: AppTheme.border), borderRadius: BorderRadius.circular(10)),
                    child: Column(children: [
                      for (var i = 0; i < o.orderedVerifiedVisits.length; i++)
                        _row(
                          id: '${o.orderedVerifiedVisits[i]['id']}',
                          time: _time(o.orderedVerifiedVisits[i]),
                          title: i == 0 && o.distanceKm[i] > 0
                              ? '${_shop(o.orderedVerifiedVisits[i])}  (incl. start → first stop)'
                              : _shop(o.orderedVerifiedVisits[i]),
                          km: i < o.distanceKm.length ? o.distanceKm[i] : 0,
                        ),
                      if (o.returnDistanceKm > 0) _returnRow(o.returnDistanceKm),
                      if (o.orderedVerifiedVisits.isEmpty)
                        const Padding(padding: EdgeInsets.all(16), child: Text('No verified visits on this trip.')),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
                child: Wrap(spacing: 22, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  _fig('Distance', _changed && adjKm != null
                      ? '${_originalKm.toStringAsFixed(1)} → ${adjKm.toStringAsFixed(1)} km'
                      : '${_originalKm.toStringAsFixed(1)} km'),
                  if (rate != null)
                    _fig('Distance amount', _changed && adjKm != null
                        ? 'Rs ${nf.format((_originalKm * rate).round())} → Rs ${nf.format((adjKm * rate).round())}'
                        : 'Rs ${nf.format((_originalKm * rate).round())}'),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    const Text('Allowance (this day)', style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _allowCtl,
                        enabled: widget.canEdit,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixText: 'Rs ',
                          border: const OutlineInputBorder(),
                          helperText: _allowChanged ? 'default Rs ${nf.format(widget.allowanceDefault)}' : null,
                        ),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ]),
                  if (rate != null || _allowance > 0)
                    _fig('Total', 'Rs ${nf.format(((adjKm ?? _originalKm) * (rate ?? 0)).round() + _allowance.round())}'),
                  _fig('Left out', _changed
                      ? [if (_out.isNotEmpty) '${_out.length} visit${_out.length == 1 ? '' : 's'}', if (_noReturn) 'return leg'].join(' · ')
                      : 'nothing'),
                  if (_calc) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
              ],
              const SizedBox(height: 10),
              Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                OutlinedButton.icon(
                  onPressed: _calc ? null : _print,
                  icon: const Icon(Icons.print_outlined, size: 16),
                  label: Text(_anyChange ? 'Print adjusted summary' : 'Print summary'),
                ),
                if (widget.canEdit) ...[
                  OutlinedButton(onPressed: _saving || _calc ? null : () => _save(approve: false), child: const Text('Save')),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669), foregroundColor: Colors.white),
                    onPressed: _saving || _calc ? null : () => _save(approve: true),
                    child: const Text('Save & approve'),
                  ),
                ],
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _fig(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(k, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
      ]);

  Widget _row({required String id, required String time, required String title, required double km}) {
    final off = _out.containsKey(id);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: off ? const Color(0xFFFEF2F2) : null,
        border: const Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      child: Row(children: [
        Checkbox(
          value: !off,
          onChanged: !widget.canEdit
              ? null
              : (v) {
                  setState(() {
                    if (v == true) {
                      _out.remove(id);
                    } else {
                      _out[id] = TextEditingController();
                    }
                    _error = null;
                  });
                  _recalc();
                },
        ),
        SizedBox(width: 46, child: Text(time, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
          child: Text(title,
              style: TextStyle(fontSize: 13, decoration: off ? TextDecoration.lineThrough : null,
                  color: off ? AppTheme.textSecondary : null)),
        ),
        SizedBox(width: 70, child: Text('${km.toStringAsFixed(1)} km', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, decoration: off ? TextDecoration.lineThrough : null))),
        if (off) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _out[id],
              enabled: widget.canEdit,
              decoration: const InputDecoration(isDense: true, hintText: 'Reason *', border: OutlineInputBorder()),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _returnRow(double km) {
    final off = _noReturn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: off ? const Color(0xFFFEF2F2) : null,
      child: Row(children: [
        Checkbox(
          value: !off,
          onChanged: !widget.canEdit
              ? null
              : (v) {
                  setState(() { _noReturn = v != true; _error = null; });
                  _recalc();
                },
        ),
        const SizedBox(width: 46),
        Expanded(
          child: Text('Last stop → end point (return)',
              style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic,
                  decoration: off ? TextDecoration.lineThrough : null)),
        ),
        SizedBox(width: 70, child: Text('${km.toStringAsFixed(1)} km', textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12.5, decoration: off ? TextDecoration.lineThrough : null))),
        if (off) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _returnReason,
              enabled: widget.canEdit,
              decoration: const InputDecoration(isDense: true, hintText: 'Reason *', border: OutlineInputBorder()),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ]),
    );
  }
}
