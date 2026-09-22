import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/format/money.dart';
import '../../../core/widgets/responsive.dart';
import '../../auth/auth_controller.dart';

/// Out for Processing — stock parked at processor / off-site (is_virtual)
/// locations, with per-send aging. Overdue (past return-due) lines float to the
/// top and are highlighted. Read-only; data comes from rpc_processor_open_items.
class ErpProcessorTrackerScreen extends ConsumerStatefulWidget {
  const ErpProcessorTrackerScreen({super.key});
  @override
  ConsumerState<ErpProcessorTrackerScreen> createState() =>
      _ErpProcessorTrackerScreenState();
}

class _ErpProcessorTrackerScreenState
    extends ConsumerState<ErpProcessorTrackerScreen> {
  bool _loading = true;
  bool _sending = false;
  bool _overdueOnly = false;
  String? _processorFilter; // processor_id; null = all processors
  List<Map<String, dynamic>> _rows = [];

  int _tab = 0; // 0 = currently out, 1 = conversions (job-work)
  bool _loadingConv = false;
  bool _convLoaded = false;
  List<Map<String, dynamic>> _conversions = []; // per receipt, resolved

  @override
  void initState() {
    super.initState();
    _load();
  }

  String? get _orgId => ref.read(currentUserProvider)?.orgId;
  bool get _isAdmin {
    final r = ref.read(currentUserProvider)?.role;
    return r == WebUserRole.admin ||
        r == WebUserRole.masterAdmin ||
        r == WebUserRole.superAdmin;
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('rpc_processor_open_items', params: {'p_org': orgId});
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to load: $e')));
      }
    }
  }

  Future<void> _sendReminderNow() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _sending = true);
    try {
      await Supabase.instance.client
          .rpc('rpc_send_processor_reminder_now', params: {'p_org': orgId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Reminder sent to the configured recipients (if the reminder is turned on in Settings).')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not send reminder: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // Posted job-work conversions: what was consumed at the processor and what
  // came back. Read-only movement history so the person tracking the processor
  // can see the current status of each send.
  Future<void> _loadConversions() async {
    final orgId = _orgId;
    if (orgId == null) { setState(() { _loadingConv = false; _convLoaded = true; }); return; }
    setState(() => _loadingConv = true);
    try {
      final client = Supabase.instance.client;
      final jw = await client.from('processor_jobwork')
          .select('id, voucher_number, jobwork_date, processor_branch_id, home_branch_id, fee_amount, overhead_amount, input_cost, total_cost, status')
          .eq('org_id', orgId).eq('status', 'posted')
          .order('jobwork_date', ascending: false).limit(300);
      final receipts = List<Map<String, dynamic>>.from(jw);
      final ids = [for (final r in receipts) r['id'] as String];
      final linesByJw = <String, List<Map<String, dynamic>>>{};
      if (ids.isNotEmpty) {
        for (var i = 0; i < ids.length; i += 200) {
          final chunk = ids.sublist(i, (i + 200).clamp(0, ids.length));
          final lines = await client.from('processor_jobwork_lines')
              .select('jobwork_id, direction, product_id, quantity, unit_cost').inFilter('jobwork_id', chunk);
          for (final l in lines as List) {
            (linesByJw[l['jobwork_id'] as String] ??= []).add(Map<String, dynamic>.from(l as Map));
          }
        }
      }
      final branches = await client.from('branches').select('id, name').eq('org_id', orgId);
      final bName = {for (final b in branches as List) b['id'] as String: (b['name'] as String? ?? '—')};
      final products = await client.from('products').select('id, name, sku').eq('org_id', orgId).limit(5000);
      final pName = {for (final p in products as List) p['id'] as String: p};

      final out = <Map<String, dynamic>>[];
      for (final r in receipts) {
        final ls = linesByJw[r['id']] ?? const [];
        List<Map<String, dynamic>> side(String dir) => [
          for (final l in ls) if (l['direction'] == dir) {
            'name': (pName[l['product_id']]?['name'] as String?) ?? (l['product_id'] as String? ?? '—'),
            'sku': (pName[l['product_id']]?['sku'] as String?) ?? '',
            'qty': (l['quantity'] as num?)?.toDouble() ?? 0,
          }
        ];
        out.add({
          'voucher': r['voucher_number'] ?? '—',
          'date': r['jobwork_date'] ?? '',
          'processor_name': bName[r['processor_branch_id']] ?? '—',
          'home_name': bName[r['home_branch_id']] ?? '—',
          'fee': (r['fee_amount'] as num?)?.toDouble() ?? 0,
          'overhead': (r['overhead_amount'] as num?)?.toDouble() ?? 0,
          'total': (r['total_cost'] as num?)?.toDouble() ?? 0,
          'inputs': side('input'),
          'outputs': side('output'),
        });
      }
      if (!mounted) return;
      setState(() { _conversions = out; _loadingConv = false; _convLoaded = true; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadingConv = false; _convLoaded = true; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load conversions: $e')));
    }
  }

  double _n(dynamic v) => (v as num?)?.toDouble() ?? 0;

  List<Map<String, dynamic>> get _filtered {
    var list = _rows;
    if (_processorFilter != null) {
      list = list.where((r) => r['processor_id'] == _processorFilter).toList();
    }
    if (_overdueOnly) {
      list = list.where((r) => r['is_overdue'] == true).toList();
    }
    return list;
  }

  // Distinct processors present in the data, id -> name, sorted by name.
  List<MapEntry<String, String>> get _processorOptions {
    final map = <String, String>{};
    for (final r in _rows) {
      final id = r['processor_id'] as String?;
      if (id != null) map[id] = (r['processor_name'] as String?) ?? '—';
    }
    final entries = map.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final overdueRows = _rows.where((r) => r['is_overdue'] == true).toList();
    final totalValue = _rows.fold<double>(0, (s, r) => s + _n(r['open_value']));
    final overdueValue =
        overdueRows.fold<double>(0, (s, r) => s + _n(r['open_value']));
    final processors = _rows.map((r) => r['processor_id']).toSet().length;

    // Group rows by processor for a clean, sectioned list.
    final Map<String, List<Map<String, dynamic>>> byProcessor = {};
    for (final r in rows) {
      (byProcessor[r['processor_name'] as String? ?? '—'] ??= []).add(r);
    }
    final processorNames = byProcessor.keys.toList()..sort();

    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Out for Processing',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const Spacer(),
          if (_isAdmin && overdueRows.isNotEmpty)
            OutlinedButton.icon(
              onPressed: _sending ? null : _sendReminderNow,
              icon: _sending
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.notifications_active_outlined, size: 16),
              label: const Text('Send reminder now'),
            ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
            'Stock sent to processor / off-site locations that has not yet come '
            'back. Lines past their return-due date are flagged overdue.',
            style: TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        _tabBar(),
        const SizedBox(height: 16),
        if (_tab == 1)
          Expanded(child: _conversionsView())
        else ...[
        Wrap(spacing: 12, runSpacing: 12, children: [
          _card('Stock with Processors', 'Rs. ${money(totalValue)}',
              AppTheme.primary),
          _card('Overdue value', 'Rs. ${money(overdueValue)}',
              overdueRows.isEmpty ? AppTheme.textSecondary : AppTheme.danger),
          _card('Overdue lines', '${overdueRows.length}',
              overdueRows.isEmpty ? AppTheme.textSecondary : AppTheme.danger),
          _card('Processors', '$processors', Colors.purple),
        ]),
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterChip(
            label: const Text('Overdue only'),
            selected: _overdueOnly,
            onSelected: (v) => setState(() => _overdueOnly = v),
          ),
          if (_processorOptions.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.factory_outlined, size: 15, color: Colors.purple),
                const SizedBox(width: 6),
                DropdownButton<String?>(
                  value: _processorFilter,
                  underline: const SizedBox.shrink(),
                  isDense: true,
                  hint: const Text('All processors', style: TextStyle(fontSize: 13)),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All processors', style: TextStyle(fontSize: 13))),
                    for (final e in _processorOptions)
                      DropdownMenuItem<String?>(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) => setState(() => _processorFilter = v),
                ),
                if (_processorFilter != null) ...[
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () => setState(() => _processorFilter = null),
                    child: const Icon(Icons.close, size: 15, color: AppTheme.textSecondary),
                  ),
                ],
              ]),
            ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : rows.isEmpty
                  ? Center(
                      child: Text(
                          _overdueOnly
                              ? 'Nothing overdue. '
                              : 'No stock is currently out at processors.',
                          style: const TextStyle(
                              color: AppTheme.textSecondary, fontSize: 14)))
                  : HScrollOnNarrow(
                      minWidth: 900,
                      child: ListView(children: [
                        for (final pName in processorNames)
                          _processorSection(pName, byProcessor[pName]!),
                      ]),
                    ),
        ),
        ],
      ]),
    );
  }

  Widget _tabBar() {
    Widget seg(String label, IconData icon, int idx) {
      final on = _tab == idx;
      return InkWell(
        onTap: () {
          setState(() => _tab = idx);
          if (idx == 1 && !_convLoaded && !_loadingConv) _loadConversions();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: on ? AppTheme.primary.withOpacity(0.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? AppTheme.primary.withOpacity(0.5) : AppTheme.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: on ? AppTheme.primary : AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                color: on ? AppTheme.primary : AppTheme.textSecondary)),
          ]),
        ),
      );
    }
    return Row(children: [
      seg('Currently out', Icons.inventory_2_outlined, 0),
      const SizedBox(width: 8),
      seg('Conversions (job-work)', Icons.sync_alt, 1),
    ]);
  }

  Widget _conversionsView() {
    if (_loadingConv) return const Center(child: CircularProgressIndicator());
    if (_conversions.isEmpty) {
      return const Center(child: Text(
          'No posted job-work conversions yet.\nWhen a job-work receipt is posted, the material consumed and the goods received appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)));
    }
    // Group receipts by processor.
    final byProc = <String, List<Map<String, dynamic>>>{};
    for (final r in _conversions) { (byProc[r['processor_name'] as String? ?? '—'] ??= []).add(r); }
    final names = byProc.keys.toList()..sort();
    return ListView(children: [
      for (final name in names) _convProcessorSection(name, byProc[name]!),
    ]);
  }

  Widget _convProcessorSection(String name, List<Map<String, dynamic>> receipts) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            const Icon(Icons.factory_outlined, size: 18, color: Colors.purple),
            const SizedBox(width: 8),
            Text(name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const Spacer(),
            Text('${receipts.length} conversion${receipts.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          ]),
        ),
        const Divider(height: 1),
        for (int i = 0; i < receipts.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _convRow(receipts[i]),
        ],
      ]),
    );
  }

  Widget _convRow(Map<String, dynamic> r) {
    final inputs = (r['inputs'] as List).cast<Map<String, dynamic>>();
    final outputs = (r['outputs'] as List).cast<Map<String, dynamic>>();
    String linesText(List<Map<String, dynamic>> ls) => ls.isEmpty
        ? '—'
        : ls.map((l) => '${l['name']}  ×  ${_qty(l['qty'])}').join('\n');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('${r['voucher']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Text('${r['date']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          const Spacer(),
          Text('Received at: ${r['home_name']}', style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _convLabel('Consumed at processor', AppTheme.danger),
            const SizedBox(height: 3),
            Text(linesText(inputs), style: const TextStyle(fontSize: 12.5)),
          ])),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.arrow_forward, size: 16, color: AppTheme.textSecondary)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _convLabel('Received at home', AppTheme.success),
            const SizedBox(height: 3),
            Text(linesText(outputs), style: const TextStyle(fontSize: 12.5)),
          ])),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _convLabel('Cost added', AppTheme.primary),
            const SizedBox(height: 3),
            Text('Fee Rs. ${money(_n(r['fee']))}', style: const TextStyle(fontSize: 12)),
            if (_n(r['overhead']) > 0)
              Text('OH Rs. ${money(_n(r['overhead']))}', style: const TextStyle(fontSize: 12)),
            Text('Output Rs. ${money(_n(r['total']))}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.primary)),
          ]),
        ]),
      ]),
    );
  }

  Widget _convLabel(String t, Color c) => Text(t.toUpperCase(),
      style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: c));

  Widget _processorSection(String name, List<Map<String, dynamic>> lines) {
    final subtotal = lines.fold<double>(0, (s, r) => s + _n(r['open_value']));
    final overdue = lines.where((r) => r['is_overdue'] == true).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        // Section header: processor name + subtotal + overdue chip.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: const BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            const Icon(Icons.factory_outlined, size: 18, color: Colors.purple),
            const SizedBox(width: 8),
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 15)),
            if (overdue > 0) ...[
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: AppTheme.danger.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6)),
                child: Text('$overdue overdue',
                    style: const TextStyle(
                        color: AppTheme.danger,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
            const Spacer(),
            Text('Rs. ${money(subtotal)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                    fontSize: 14)),
          ]),
        ),
        const Divider(height: 1),
        // Column header.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [
            Expanded(flex: 2, child: _H('Transfer')),
            Expanded(flex: 3, child: _H('Product')),
            Expanded(flex: 2, child: _H('Sent')),
            Expanded(flex: 2, child: _H('Due')),
            Expanded(flex: 2, child: _H('Open qty', right: true)),
            Expanded(flex: 2, child: _H('Value', right: true)),
            Expanded(flex: 2, child: _H('Status')),
          ]),
        ),
        const Divider(height: 1),
        for (int i = 0; i < lines.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          _lineRow(lines[i]),
        ],
      ]),
    );
  }

  Widget _lineRow(Map<String, dynamic> r) {
    final overdue = r['is_overdue'] == true;
    final daysOverdue = (r['days_overdue'] as num?)?.toInt() ?? 0;
    final daysOut = (r['days_out'] as num?)?.toInt() ?? 0;
    return Container(
      color: overdue ? AppTheme.danger.withOpacity(0.05) : null,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(children: [
        Expanded(
            flex: 2,
            child: Text(r['voucher_number'] as String? ?? '—',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600))),
        Expanded(
            flex: 3,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r['product_name'] as String? ?? '—',
                      style: const TextStyle(fontSize: 13)),
                  Text(r['sku'] as String? ?? '',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                ])),
        Expanded(
            flex: 2,
            child: Text('${r['transfer_date'] ?? ''}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary))),
        Expanded(
            flex: 2,
            child: Text('${r['due_date'] ?? ''}',
                style: TextStyle(
                    fontSize: 12,
                    color: overdue ? AppTheme.danger : AppTheme.textSecondary,
                    fontWeight:
                        overdue ? FontWeight.w700 : FontWeight.w400))),
        Expanded(
            flex: 2,
            child: Text(_qty(r['open_qty']),
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600))),
        Expanded(
            flex: 2,
            child: Text('Rs. ${money(_n(r['open_value']))}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary))),
        Expanded(
          flex: 2,
          child: overdue
              ? _chip('${daysOverdue}d overdue', AppTheme.danger)
              : _chip('out ${daysOut}d', AppTheme.textSecondary),
        ),
      ]),
    );
  }

  String _qty(dynamic v) {
    final d = _n(v);
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
  }

  Widget _chip(String text, Color color) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6)),
          child: Text(text,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _card(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.25))),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: color)),
            ]),
      );
}

class _H extends StatelessWidget {
  final String text;
  final bool right;
  const _H(this.text, {this.right = false});
  @override
  Widget build(BuildContext context) => Text(text,
      textAlign: right ? TextAlign.right : TextAlign.left,
      style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: AppTheme.textSecondary));
}
