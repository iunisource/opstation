// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/layout/main_layout.dart';
import '../../auth/auth_controller.dart';

/// QC Station — a shop-floor kiosk. Pick a job, an operator taps their RFID card,
/// then taps a QC checkpoint: it records a qc_inspection and prints a 2"x1" label.
/// Entirely gated by the per-org app_config flag 'feature.qc_station'; when off,
/// the screen shows a disabled notice and nothing about the job flow changes.
class ErpQcStationScreen extends ConsumerStatefulWidget {
  const ErpQcStationScreen({super.key});
  @override
  ConsumerState<ErpQcStationScreen> createState() => _ErpQcStationScreenState();
}

class _ErpQcStationScreenState extends ConsumerState<ErpQcStationScreen> {
  bool _flagChecked = false;
  bool _enabled = false;

  final _wedgeCtrl = TextEditingController();
  final _wedgeFocus = FocusNode();
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _jobs = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loadingJobs = true;

  Map<String, dynamic>? _job;                 // selected job
  List<Map<String, dynamic>> _checklist = []; // qc_job_checklist rows
  List<Map<String, dynamic>> _recent = [];    // recent qc_inspections for this job
  bool _loadingChecklist = false;

  String? _operatorId;
  String? _operatorName;
  Timer? _operatorTimer;
  static const _operatorTtl = Duration(minutes: 3);

  // Bluetooth thermal printer (Web Bluetooth / ESC-POS). Connected once per
  // session via a user gesture; then each checkpoint tap prints silently.
  bool _btConnected = false;
  String? _btName;
  bool _btConnecting = false;

  // Injected once: a tiny JS helper that owns the Web Bluetooth GATT connection
  // and writes ESC-POS bytes to whatever writable characteristic the chosen
  // printer exposes (works across the common generic BLE thermal printers).
  static const String _btJs = r'''
window.__qcbt = window.__qcbt || {
  device: null, ch: null,
  supported: function(){ return !!(navigator && navigator.bluetooth); },
  connected: function(){ return !!(this.device && this.device.gatt && this.device.gatt.connected && this.ch); },
  connect: async function(){
    var SVC = ['000018f0-0000-1000-8000-00805f9b34fb','0000ff00-0000-1000-8000-00805f9b34fb',
               '0000ffe0-0000-1000-8000-00805f9b34fb','0000ae30-0000-1000-8000-00805f9b34fb',
               'e7810a71-73ae-499d-8c15-faa9aef0c3f2','49535343-fe7d-4ae5-8fa9-9fafd205e455'];
    var dev = await navigator.bluetooth.requestDevice({ acceptAllDevices: true, optionalServices: SVC });
    this.device = dev;
    var server = await dev.gatt.connect();
    var services = await server.getPrimaryServices();
    this.ch = null;
    for (var i=0;i<services.length;i++){
      var chars = await services[i].getCharacteristics();
      for (var j=0;j<chars.length;j++){
        var p = chars[j].properties;
        if (p.write || p.writeWithoutResponse){ this.ch = chars[j]; break; }
      }
      if (this.ch) break;
    }
    if (!this.ch) throw new Error('No writable characteristic on this printer');
    // Prime the link: the OS often drops the very first GATT write, so send an
    // init byte now to absorb it — then the first real label prints.
    try { await this.write([0x1B,0x40]); await new Promise(function(r){ setTimeout(r,120); }); } catch(e){}
    return dev.name || 'Bluetooth printer';
  },
  write: async function(bytes){
    if (!this.ch) throw new Error('Not connected');
    var arr = Uint8Array.from(bytes);
    var CH = 180;
    for (var i=0;i<arr.length;i+=CH){
      var slice = arr.slice(i, i+CH);
      if (this.ch.properties.writeWithoutResponse) await this.ch.writeValueWithoutResponse(slice);
      else await this.ch.writeValue(slice);
      await new Promise(function(r){ setTimeout(r, 18); });
    }
  }
};
''';

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  String? get _branchId => ref.read(selectedBranchProvider)?['id'] as String?;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_applyFilter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _operatorTimer?.cancel();
    _wedgeCtrl.dispose();
    _wedgeFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    _injectBt();
    await _checkFlag();
    if (_enabled) await _loadJobs();
    _refocus();
  }

  void _injectBt() {
    try {
      if (js_util.hasProperty(html.window, '__qcbt')) return;
      final s = html.ScriptElement()..text = _btJs;
      html.document.head?.append(s);
    } catch (_) {}
  }

  bool get _btSupported {
    try {
      final nav = js_util.getProperty(html.window, 'navigator');
      return js_util.getProperty(nav, 'bluetooth') != null;
    } catch (_) { return false; }
  }

  Future<void> _connectPrinter() async {
    if (!_btSupported) {
      _snack('Bluetooth needs Chrome/Edge (Android tablet or desktop Chrome) — not Safari.');
      return;
    }
    setState(() => _btConnecting = true);
    try {
      final qcbt = js_util.getProperty(html.window, '__qcbt');
      final name = await js_util.promiseToFuture<Object?>(js_util.callMethod(qcbt, 'connect', []));
      setState(() { _btConnected = true; _btName = name?.toString(); });
      _snack('Printer connected: ${_btName ?? ''}');
    } catch (e) {
      setState(() => _btConnected = false);
      _snack('Printer connect cancelled / failed');
    } finally {
      if (mounted) setState(() => _btConnecting = false);
      _refocus();
    }
  }

  /// ESC-POS receipt for a ~58mm thermal printer.
  Future<void> _btPrint({
    required String checkpoint, required String spec, required String jobNumber,
    required String product, required int seq, int? target,
    required String operator, required DateTime at,
  }) async {
    final b = <int>[];
    void t(String s) { b.addAll(s.codeUnits.map((c) => c < 128 ? c : 63)); }
    b.addAll([0x1B, 0x40]);          // init
    b.addAll([0x1B, 0x61, 0x01]);    // center
    b.addAll([0x1D, 0x21, 0x11]);    // double width+height
    b.addAll([0x1B, 0x45, 0x01]);    // bold on
    t(checkpoint.toUpperCase() + '\n');
    b.addAll([0x1B, 0x45, 0x00]);    // bold off
    b.addAll([0x1D, 0x21, 0x00]);    // normal size
    if (spec.trim().isNotEmpty) t(spec + '\n');
    b.addAll([0x1B, 0x61, 0x00]);    // left
    t('--------------------------------\n');
    t('Job : ' + jobNumber + '\n');
    t('Item: ' + product + '\n');
    t('No. : #' + seq.toString() + (target != null ? '/$target' : '') + '\n');
    t('QC  : ' + operator + '\n');
    t('Time: ' + DateFormat('d MMM yyyy  HH:mm').format(at) + '\n');
    t('--------------------------------\n');
    b.addAll([0x0A, 0x0A, 0x0A]);    // feed
    final qcbt = js_util.getProperty(html.window, '__qcbt');
    await js_util.promiseToFuture<Object?>(js_util.callMethod(qcbt, 'write', [js_util.jsify(b)]));
  }

  void _refocus() {
    if (mounted && _enabled && !_wedgeFocus.hasFocus) _wedgeFocus.requestFocus();
  }

  Future<void> _checkFlag() async {
    final org = _orgId;
    if (org == null) { setState(() { _flagChecked = true; _enabled = false; }); return; }
    try {
      final row = await Supabase.instance.client.from('app_config')
          .select('value').eq('org_id', org).eq('key', 'feature.qc_station').maybeSingle();
      final v = (row?['value'] ?? '').toString().toLowerCase();
      setState(() { _enabled = v == 'true' || v == '1' || v == 'on' || v == 'yes'; _flagChecked = true; });
    } catch (_) {
      setState(() { _flagChecked = true; _enabled = false; });
    }
  }

  Future<void> _loadJobs() async {
    final org = _orgId;
    if (org == null) return;
    setState(() => _loadingJobs = true);
    try {
      // Only jobs actively on the floor: Queued or In progress.
      final rows = await Supabase.instance.client.from('job_cards')
          .select('id, job_number, product_id, bom_id, planned_qty, produced_qty, status, is_locked')
          .eq('org_id', org)
          .inFilter('status', ['queued', 'in_progress'])
          .order('created_at', ascending: false)
          .limit(300);
      final list = List<Map<String, dynamic>>.from(rows as List);
      // job_cards.product_id is not a declared FK, so resolve names separately
      // rather than via a PostgREST embed (which errors with PGRST200).
      final ids = list.map((j) => j['product_id']).whereType<String>().toSet().toList();
      final names = <String, String>{};
      if (ids.isNotEmpty) {
        final prods = await Supabase.instance.client.from('products')
            .select('id, name').eq('org_id', org).inFilter('id', ids);
        for (final p in prods as List) {
          names[p['id'] as String] = (p['name'] as String?) ?? '';
        }
      }
      for (final j in list) { j['product_name'] = names[j['product_id']] ?? ''; }
      setState(() { _jobs = list; _loadingJobs = false; });
      _applyFilter();
    } catch (e) {
      setState(() => _loadingJobs = false);
      _snack('Jobs load error: $e');
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.toLowerCase().trim();
    setState(() {
      _filtered = q.isEmpty ? _jobs : _jobs.where((j) {
        final num = (j['job_number'] ?? '').toString().toLowerCase();
        final prod = ((j['product_name']) ?? '').toString().toLowerCase();
        return num.contains(q) || prod.contains(q);
      }).toList();
    });
  }

  Future<void> _selectJob(Map<String, dynamic> j) async {
    setState(() { _job = j; _checklist = []; });
    await _loadChecklist();
    _refocus();
  }

  Future<void> _loadChecklist() async {
    final j = _job; if (j == null) return;
    setState(() => _loadingChecklist = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('qc_job_checklist', params: {'p_job': j['id']});
      setState(() { _checklist = List<Map<String, dynamic>>.from(rows as List); _loadingChecklist = false; });
      await _loadRecent();
    } catch (e) {
      setState(() => _loadingChecklist = false);
      _snack('Checklist error: $e');
    }
  }

  /// The soft record: recent QC taps for this job (who did what, when). Reads the
  /// station's own rows (source_type='job_card'); this is also the sync source.
  Future<void> _loadRecent() async {
    final j = _job; if (j == null) return;
    try {
      final rows = await Supabase.instance.client.from('qc_inspections')
          .select('checkpoint_name, inspector_name, seq_no, inspected_at, result')
          .eq('job_card_id', j['id'])
          .eq('source_type', 'job_card')
          .order('inspected_at', ascending: false)
          .limit(30);
      if (mounted) setState(() => _recent = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {}
  }

  // ── Operator (RFID) ─────────────────────────────────────────────────────────
  Future<void> _onWedge(String raw) async {
    final code = raw.trim();
    _wedgeCtrl.clear();
    if (code.isEmpty) { _refocus(); return; }
    final org = _orgId;
    if (org == null) return;
    try {
      var emp = await Supabase.instance.client.from('hr_employees')
          .select('id, full_name, card_uid, employee_code, is_voided')
          .eq('org_id', org).eq('card_uid', code).maybeSingle();
      emp ??= await Supabase.instance.client.from('hr_employees')
          .select('id, full_name, card_uid, employee_code, is_voided')
          .eq('org_id', org).eq('employee_code', code).maybeSingle();
      if (emp == null || emp['is_voided'] == true) {
        _snack('Card not recognised: "$code"');
        _refocus();
        return;
      }
      _setOperator(emp['id'] as String, (emp['full_name'] as String?) ?? 'Operator');
    } catch (e) {
      _snack('Card lookup failed: $e');
    }
    _refocus();
  }

  void _setOperator(String id, String name) {
    _operatorTimer?.cancel();
    setState(() { _operatorId = id; _operatorName = name; });
    _operatorTimer = Timer(_operatorTtl, () {
      if (mounted) setState(() { _operatorId = null; _operatorName = null; });
    });
  }

  void _clearOperator() {
    _operatorTimer?.cancel();
    if (mounted) setState(() { _operatorId = null; _operatorName = null; });
  }

  // ── Tap a checkpoint → record + print ───────────────────────────────────────
  Future<void> _tapCheckpoint(Map<String, dynamic> cp) async {
    final j = _job; final org = _orgId;
    if (j == null || org == null) return;
    if (_operatorId == null) { _snack('Tap an operator card first'); _refocus(); return; }

    final jobId = j['id'] as String;
    final cpId = cp['checkpoint_id'] as String;
    final cpName = (cp['name'] ?? '') as String;
    final spec = (cp['spec'] ?? '') as String? ?? '';
    final target = cp['target_count'] as int?;
    final client = Supabase.instance.client;

    try {
      // next carton number for this (job, checkpoint)
      int seq = 1;
      try {
        final s = await client.rpc('qc_next_seq', params: {'p_job': jobId, 'p_checkpoint': cpId});
        if (s is int) seq = s; else seq = int.tryParse(s.toString()) ?? 1;
      } catch (_) {}

      final now = DateTime.now();
      final id = 'qc_${now.millisecondsSinceEpoch}_$seq';
      await client.from('qc_inspections').insert({
        'id': id,
        'org_id': org,
        'job_card_id': jobId,
        'checkpoint_id': cpId,
        'checkpoint_name': cpName,
        'product_id': j['product_id'],
        'branch_id': _branchId,
        'inspector_id': _operatorId,
        'inspector_name': _operatorName,
        'inspected_at': now.toUtc().toIso8601String(),
        'result': 'pass',
        'source_id': jobId,
        'source_type': 'job_card',
        'seq_no': seq,
        'label_printed_at': now.toUtc().toIso8601String(),
      });

      final jobNumber = (j['job_number'] ?? '') as String;
      final product = ((j['product_name']) ?? '') as String;
      if (_btConnected) {
        // Silent one-tap print to the Bluetooth thermal printer.
        try {
          await _btPrint(checkpoint: cpName, spec: spec, jobNumber: jobNumber,
              product: product, seq: seq, target: target, operator: _operatorName ?? '', at: now);
        } catch (e) {
          setState(() => _btConnected = false); // dropped — fall back
          _printLabel(checkpoint: cpName, spec: spec, jobNumber: jobNumber,
              product: product, seq: seq, target: target, operator: _operatorName ?? '', at: now);
          _snack('Printer lost — printed via browser. Reconnect the printer.');
        }
      } else {
        _printLabel(checkpoint: cpName, spec: spec, jobNumber: jobNumber,
            product: product, seq: seq, target: target, operator: _operatorName ?? '', at: now);
      }

      // Clear the operator after every QC so the station never stays "logged in"
      // as one person — each label requires a fresh card tap (accountability).
      _clearOperator();
      await _loadChecklist();
      await _loadRecent();
      _refocus();
    } catch (e) {
      _snack('Could not record QC: $e');
    }
  }

  void _printLabel({
    required String checkpoint, required String spec, required String jobNumber,
    required String product, required int seq, int? target,
    required String operator, required DateTime at,
  }) {
    String esc(String s) => s
        .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final seqLine = target != null ? '#$seq / $target' : '#$seq';
    final when = DateFormat('d MMM yyyy  HH:mm').format(at);
    final specLine = spec.trim().isEmpty ? '' : '<div class="spec">${esc(spec)}</div>';

    final doc =
      '<!DOCTYPE html><html><head><meta charset="UTF-8"><title>QC Label</title><style>@page{margin:0}'
      '@page{size:2in 1in;margin:0}'
      'html,body{margin:0;padding:0;width:2in;height:1in;font-family:Arial,Helvetica,sans-serif;-webkit-print-color-adjust:exact}'
      '.lab{box-sizing:border-box;width:2in;height:1in;padding:2mm 3mm;display:flex;flex-direction:column;justify-content:space-between;overflow:hidden}'
      '.cp{font-size:12pt;font-weight:800;line-height:1.02;text-transform:uppercase}'
      '.spec{font-size:8pt;font-weight:700;margin-top:0.4mm}'
      '.job{font-size:8pt;font-weight:600;margin-top:0.6mm;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}'
      '.carton{font-size:10pt;font-weight:800;margin-top:0.6mm}'
      '.meta{font-size:6.5pt;color:#111;margin-top:0.4mm}'
      '</style></head><body>'
      '<div class="lab">'
        '<div>'
          '<div class="cp">${esc(checkpoint)}</div>'
          '$specLine'
          '<div class="job">${esc(jobNumber)} &middot; ${esc(product)}</div>'
        '</div>'
        '<div>'
          '<div class="carton">$seqLine</div>'
          '<div class="meta">QC by ${esc(operator)} &middot; $when</div>'
        '</div>'
      '</div>'
      '<script>window.onload=function(){setTimeout(function(){window.print();},150);};'
      'window.onafterprint=function(){setTimeout(function(){window.close();},200);};</script>'
      '</body></html>';

    final blob = html.Blob([doc], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, 'qc_label', 'width=420,height=260');
    Future.delayed(const Duration(seconds: 30), () { try { html.Url.revokeObjectUrl(url); } catch (_) {} });
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  // ── UI ──────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (!_flagChecked) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_enabled) return _disabledNotice();
    return GestureDetector(
      onTap: _refocus,
      child: Container(
        color: AppTheme.background,
        padding: const EdgeInsets.all(20),
        child: Stack(children: [
          Offstage(
            offstage: true,
            child: TextField(controller: _wedgeCtrl, focusNode: _wedgeFocus, autofocus: true, onSubmitted: _onWedge),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _topBar(),
            const SizedBox(height: 14),
            _operatorBanner(),
            const SizedBox(height: 14),
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 340, child: _jobsPanel()),
              const SizedBox(width: 18),
              Expanded(child: _checkpointsPanel()),
            ])),
          ]),
        ]),
      ),
    );
  }

  Widget _topBar() {
    return Row(children: [
      Container(
        width: 44, height: 44,
        decoration: BoxDecoration(color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: const Icon(Icons.verified_outlined, color: AppTheme.primary),
      ),
      const SizedBox(width: 12),
      const Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('QC Station', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        Text('Tap a job, scan your card, tap a checkpoint to print', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
      ]),
      const Spacer(),
      _printerButton(),
      const SizedBox(width: 8),
      IconButton(
        onPressed: _loadJobs,
        icon: const Icon(Icons.refresh),
        tooltip: 'Reload jobs',
        style: IconButton.styleFrom(backgroundColor: Colors.white, side: const BorderSide(color: AppTheme.border)),
      ),
    ]);
  }

  Widget _printerButton() {
    final connected = _btConnected;
    return Material(
      color: connected ? AppTheme.success.withOpacity(0.10) : Colors.white,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _btConnecting ? null : _connectPrinter,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: connected ? AppTheme.success : AppTheme.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _btConnecting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth, size: 18, color: connected ? AppTheme.success : AppTheme.textSecondary),
            const SizedBox(width: 8),
            Text(connected ? (_btName ?? 'Printer connected') : 'Connect printer',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: connected ? AppTheme.success : AppTheme.textSecondary)),
          ]),
        ),
      ),
    );
  }

  Widget _operatorBanner() {
    final active = _operatorId != null;
    if (!active) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [Colors.orange.shade50, Colors.amber.shade50]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: Colors.orange.withOpacity(0.15), shape: BoxShape.circle),
            child: Icon(Icons.contactless, color: Colors.orange.shade800, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Scan your ID card to begin', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.orange.shade900)),
            const SizedBox(height: 2),
            const Text('Present your RFID card at the reader. Every QC label is signed by whoever taps.', style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ])),
        ]),
      );
    }
    final initials = _initials(_operatorName ?? '');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [Colors.green.shade50, Colors.teal.shade50]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.shade200),
      ),
      child: Row(children: [
        CircleAvatar(radius: 24, backgroundColor: AppTheme.success, child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(_operatorName ?? 'Operator', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 2),
          Text('Ready — tap a checkpoint to record & print', style: TextStyle(fontSize: 12.5, color: Colors.green.shade800, fontWeight: FontWeight.w600)),
        ])),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.green.shade200)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_clock, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 6),
            const Text('Clears after each check', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.border),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10, offset: const Offset(0, 3))],
    ),
    child: child,
  );

  Widget _jobsPanel() {
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Search job or product…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            filled: true,
            fillColor: AppTheme.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          ),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: _loadingJobs
        ? const Center(child: CircularProgressIndicator())
        : _filtered.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('No queued or in-progress jobs.', textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary))))
          : ListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: _filtered.length,
              itemBuilder: (_, i) => _jobCard(_filtered[i]),
            )),
    ]));
  }

  Widget _jobCard(Map<String, dynamic> j) {
    final sel = _job != null && _job!['id'] == j['id'];
    final planned = (j['planned_qty'] as num?)?.toDouble() ?? 0;
    final produced = (j['produced_qty'] as num?)?.toDouble() ?? 0;
    final pct = planned > 0 ? (produced / planned).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: sel ? AppTheme.primary.withOpacity(0.08) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _selectJob(j),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? AppTheme.primary : AppTheme.border),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text((j['job_number'] ?? '') as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
                Icon(Icons.chevron_right, size: 18, color: sel ? AppTheme.primary : AppTheme.textSecondary),
              ]),
              const SizedBox(height: 2),
              Text(((j['product_name']) ?? '') as String, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: pct, minHeight: 5, backgroundColor: AppTheme.border, color: AppTheme.primary),
              ),
              const SizedBox(height: 4),
              Text('${produced.toInt()} / ${planned.toInt()} produced', style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _checkpointsPanel() {
    final j = _job;
    if (j == null) {
      return _card(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.touch_app_outlined, size: 48, color: AppTheme.textSecondary.withOpacity(0.35)),
        const SizedBox(height: 12),
        const Text('Select a job to see its QC checkpoints', style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
      ])));
    }
    final active = _operatorId != null;
    return _card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((j['job_number'] ?? '') as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            Text(((j['product_name']) ?? '') as String, style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ])),
          if (_checklist.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(20)),
              child: Text('${_checklist.length} checkpoint${_checklist.length == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textSecondary)),
            ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: _loadingChecklist
        ? const Center(child: CircularProgressIndicator())
        : _checklist.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text(
              'No in-process QC checkpoints for this product/BOM.\n\nIn QC Checkpoints, set a checkpoint stage to In-process (and give it a spec) for it to appear here.',
              textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary))))
          : LayoutBuilder(builder: (ctx, c) {
              final cols = c.maxWidth > 860 ? 3 : 2;
              return GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: cols, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 1.25,
                children: _checklist.map((cp) => _checkpointTile(cp, active)).toList(),
              );
            })),
      if (_recent.isNotEmpty) _recentPanel(),
    ]));
  }

  Widget _checkpointTile(Map<String, dynamic> cp, bool active) {
    final name = (cp['name'] ?? '') as String;
    final spec = (cp['spec'] ?? '') as String? ?? '';
    final done = (cp['times_done'] ?? 0) as int;
    final target = cp['target_count'] as int?;
    final complete = target != null && done >= target;
    final accent = complete ? AppTheme.success : AppTheme.primary;
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Material(
        color: complete ? AppTheme.success.withOpacity(0.06) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: active ? () => _tapCheckpoint(cp) : null,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: accent.withOpacity(complete ? 0.6 : 0.35), width: 1.6),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, height: 1.1), maxLines: 2, overflow: TextOverflow.ellipsis)),
                if (complete) const Icon(Icons.check_circle, size: 20, color: AppTheme.success),
              ]),
              if (spec.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(6)),
                  child: Text(spec, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
                ),
              ],
              const Spacer(),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$done', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: accent, height: 1)),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(target != null ? '/ $target' : 'printed', style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
                ),
                const Spacer(),
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(color: accent.withOpacity(0.10), borderRadius: BorderRadius.circular(10)),
                  child: Icon(Icons.print, size: 20, color: accent),
                ),
              ]),
              if (target != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: (done / target).clamp(0.0, 1.0), minHeight: 5, backgroundColor: AppTheme.border, color: accent),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _recentPanel() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.border)),
        color: AppTheme.background,
      ),
      constraints: const BoxConstraints(maxHeight: 150),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: Row(children: [
            const Icon(Icons.receipt_long, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text('Recent QC · last ${_recent.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppTheme.textSecondary)),
            const Spacer(),
            const Text('Full history in the job card', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
          ]),
        ),
        Flexible(child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 8),
          itemCount: _recent.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r = _recent[i];
            final ts = DateTime.tryParse((r['inspected_at'] ?? '').toString())?.toLocal();
            final when = ts != null ? DateFormat('d MMM  HH:mm').format(ts) : '';
            final seq = r['seq_no'];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
              child: Row(children: [
                const Icon(Icons.check_circle, size: 13, color: AppTheme.success),
                const SizedBox(width: 8),
                Expanded(flex: 4, child: Text('${r['checkpoint_name'] ?? ''}${seq != null ? '  #$seq' : ''}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                Expanded(flex: 3, child: Text((r['inspector_name'] ?? '') as String? ?? '', style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
                Text(when, style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              ]),
            );
          },
        )),
      ]),
    );
  }

  Widget _disabledNotice() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.qr_code_2, size: 56, color: AppTheme.textSecondary.withOpacity(0.3)),
      const SizedBox(height: 14),
      const Text('QC Station is turned off for this organisation.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      const Text('Enable it in Admin Settings under QC Station to use tap-to-print QC.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
    ]),
  );
}
