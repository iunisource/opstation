import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/saving_overlay.dart';
import '../../auth/auth_controller.dart';
import '../../../core/utils/friendly_error.dart';

/// Scheme performance: how many times each scheme was redeemed on vouchers,
/// with the free-goods quantity and discount value it cost. Reads the
/// scheme_redemptions log written when a suggestion is confirmed.
class ErpSchemesReportScreen extends ConsumerStatefulWidget {
  const ErpSchemesReportScreen({super.key});
  @override
  ConsumerState<ErpSchemesReportScreen> createState() => _ErpSchemesReportScreenState();
}

class _ErpSchemesReportScreenState extends ConsumerState<ErpSchemesReportScreen> {
  bool _loading = true;
  DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 30)),
    end: DateTime.now(),
  );
  List<Map<String, dynamic>> _rows = [];

  String? get _orgId => ref.read(currentUserProvider)?.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orgId = _orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final from = DateFormat('yyyy-MM-dd').format(_range.start);
      final to = DateFormat('yyyy-MM-dd').format(_range.end.add(const Duration(days: 1)));
      final res = await Supabase.instance.client
          .from('scheme_redemptions')
          .select('scheme_id, scheme_name, scheme_type, benefit_type, free_qty, discount_amount, voucher_number, applied_at')
          .eq('org_id', orgId)
          .gte('applied_at', from)
          .lt('applied_at', to)
          .order('applied_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError('Could not load report', e))));
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime(2100), initialDateRange: _range);
    if (r != null) { setState(() => _range = r); _load(); }
  }

  @override
  Widget build(BuildContext context) {
    // Aggregate by scheme.
    final Map<String, Map<String, dynamic>> agg = {};
    num totalFree = 0, totalDisc = 0;
    for (final r in _rows) {
      final key = (r['scheme_id'] as String?) ?? (r['scheme_name'] as String? ?? 'unknown');
      final a = agg.putIfAbsent(key, () => {
            'name': r['scheme_name'] ?? '(deleted scheme)',
            'type': r['scheme_type'] ?? '',
            'count': 0,
            'free': 0.0,
            'disc': 0.0,
          });
      a['count'] = (a['count'] as int) + 1;
      a['free'] = (a['free'] as double) + ((r['free_qty'] as num?)?.toDouble() ?? 0);
      a['disc'] = (a['disc'] as double) + ((r['discount_amount'] as num?)?.toDouble() ?? 0);
      totalFree += (r['free_qty'] as num?)?.toDouble() ?? 0;
      totalDisc += (r['discount_amount'] as num?)?.toDouble() ?? 0;
    }
    final list = agg.values.toList()..sort((a, b) => (b['count'] as int).compareTo(a['count'] as int));
    final nf = NumberFormat('#,##0.##');

    return Container(
      color: AppTheme.background,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            const Icon(Icons.local_offer_outlined, color: AppTheme.primary),
            const SizedBox(width: 10),
            const Text('Scheme Performance', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const Spacer(),
            OutlinedButton.icon(onPressed: _pickRange, icon: const Icon(Icons.event, size: 16), label: Text('${DateFormat('d MMM').format(_range.start)} – ${DateFormat('d MMM yyyy').format(_range.end)}')),
          ]),
        ),
        if (_loading)
          const Expanded(child: Center(child: BrandSpinner()))
        else ...[
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              _stat('Redemptions', '${_rows.length}', Icons.check_circle_outline, AppTheme.primary),
              const SizedBox(width: 12),
              _stat('Free goods (units)', nf.format(totalFree), Icons.redeem_outlined, Colors.teal),
              const SizedBox(width: 12),
              _stat('Discount value', 'Rs ${nf.format(totalDisc)}', Icons.percent_outlined, Colors.indigo),
            ]),
          ),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('No redemptions in this period.', style: TextStyle(color: AppTheme.textSecondary)))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final a = list[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: (a['type'] == 'foc' ? Colors.teal : Colors.indigo).withOpacity(0.12),
                          child: Icon(a['type'] == 'foc' ? Icons.redeem_outlined : Icons.percent_outlined, size: 18, color: a['type'] == 'foc' ? Colors.teal : Colors.indigo),
                        ),
                        title: Text(a['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text('${a['count']} redemption(s)', style: const TextStyle(fontSize: 12)),
                        trailing: Text(
                          a['type'] == 'foc' ? '${nf.format(a['free'])} free units' : 'Rs ${nf.format(a['disc'])} off',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ]),
    );
  }

  Widget _stat(String label, String value, IconData ic, Color c) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.border)),
          child: Row(children: [
            CircleAvatar(backgroundColor: c.withOpacity(0.12), child: Icon(ic, color: c, size: 20)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ])),
          ]),
        ),
      );
}
