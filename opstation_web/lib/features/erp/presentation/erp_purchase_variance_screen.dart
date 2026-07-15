import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Purchase Price Variance — an ECONOMIC report, purchase side only.
///
/// When goods are returned to (or invoiced by) a supplier, the price on the
/// document rarely equals what the stock was carried at in the cost ledger
/// (FIFO / LIFO / AVCO). That difference is a real, meaningful number: it says
/// your stock is carried above or below what the supplier is now pricing it at.
///
/// There is deliberately NO sale-side equivalent. On a sale, price minus cost is
/// gross margin — the business itself — not a variance. Reporting it as one would
/// be meaningless, so this report covers purchases only.
///
/// Backed by rpc_purchase_price_variance. A non-zero result here is normal and
/// informative — unlike the reconciliation report, which should always be empty.
class ErpPurchaseVarianceScreen extends ConsumerStatefulWidget {
  const ErpPurchaseVarianceScreen({super.key});

  @override
  ConsumerState<ErpPurchaseVarianceScreen> createState() => _State();
}

class _State extends ConsumerState<ErpPurchaseVarianceScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];
  String _search = '';
  DateTime _from = DateTime(DateTime.now().year, 1, 1);
  DateTime _to = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final orgId = ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'rpc_purchase_price_variance',
        params: {
          'p_org_id': orgId,
          'p_from': _d(_from),
          'p_to': _d(_to),
          'p_branch_id': null,
        },
      );
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Variance load error: $e')));
    }
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r != null && mounted) {
      setState(() {
        _from = r.start;
        _to = r.end;
      });
      _load();
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _rows;
    final q = _search.toLowerCase();
    return _rows.where((r) {
      final v = (r['voucher_no'] ?? '').toString().toLowerCase();
      final p = (r['product_name'] ?? '').toString().toLowerCase();
      final s = (r['party_name'] ?? '').toString().toLowerCase();
      return v.contains(q) || p.contains(q) || s.contains(q);
    }).toList();
  }

  double get _totalVariance =>
      _rows.fold(0.0, (s, r) => s + ((r['variance'] as num?)?.toDouble() ?? 0));

  String _fmt(num? n) {
    final v = (n ?? 0).toDouble();
    return NumberFormat('#,##0.00').format(v);
  }

  void _exportCsv() {
    final b = StringBuffer();
    b.writeln('Document,Voucher,Date,Supplier,Product,Qty,Doc Rate,Carrying Cost,Variance,Variance %');
    for (final r in _filtered) {
      String c(dynamic v) {
        final s = (v ?? '').toString().replaceAll('"', '""');
        return s.contains(',') ? '"$s"' : s;
      }

      b.writeln([
        c(r['doc_type']),
        c(r['voucher_no']),
        c(r['voucher_date']),
        c(r['party_name']),
        c(r['product_name']),
        c(r['qty']),
        c(r['doc_rate']),
        c(r['carrying_cost']),
        c(r['variance']),
        c(r['variance_pct']),
      ].join(','));
    }
    final bytes = utf8.encode(b.toString());
    final blob = html.Blob([bytes], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download',
          'purchase_price_variance_${_d(_from)}_${_d(_to)}.csv')
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
    final vTone =
        _totalVariance > 0 ? Colors.green.shade700 : AppTheme.danger;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Purchase Price Variance',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              SizedBox(height: 2),
              Text(
                  'What the supplier priced the goods at, versus what your books carried them at',
                  style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            ]),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.date_range, size: 16),
            label: Text('${_d(_from)}  \u2192  ${_d(_to)}',
                style: const TextStyle(fontSize: 12)),
            onPressed: _pickRange,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: Icon(Icons.table_chart_outlined,
                size: 16, color: Colors.green.shade700),
            label: Text('Export Excel',
                style: TextStyle(fontSize: 12, color: Colors.green.shade700)),
            onPressed: _rows.isEmpty ? null : _exportCsv,
            style: OutlinedButton.styleFrom(
                side: BorderSide(color: Colors.green.shade300)),
          ),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ]),
      ),
      if (_loading)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // A single headline number: the net variance over the period.
              // Positive (green) = you are credited/charged above carrying cost —
              // your stock is carried below current supplier pricing.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: vTone.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: vTone.withOpacity(0.30)),
                ),
                child: Row(children: [
                  Icon(
                      _totalVariance >= 0
                          ? Icons.trending_up
                          : Icons.trending_down,
                      color: vTone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Net purchase price variance',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary)),
                          const SizedBox(height: 2),
                          Text('Rs ${_fmt(_totalVariance)}',
                              style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                  color: vTone)),
                        ]),
                  ),
                  Text('${_rows.length} line${_rows.length == 1 ? '' : 's'}',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                ]),
              ),
              const SizedBox(height: 16),
              TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: InputDecoration(
                  hintText: 'Search voucher, supplier or product',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 16),
              if (rows.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  alignment: Alignment.center,
                  child: const Text('No variance in this period.',
                      style: TextStyle(color: AppTheme.textSecondary)),
                )
              else
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration:
                          const BoxDecoration(color: Color(0xFFF8F9FA)),
                      child: const Row(children: [
                        Expanded(flex: 3, child: Text('Voucher', style: _h)),
                        Expanded(flex: 3, child: Text('Supplier', style: _h)),
                        Expanded(flex: 4, child: Text('Product', style: _h)),
                        Expanded(
                            flex: 2,
                            child: Text('Qty',
                                style: _h, textAlign: TextAlign.right)),
                        Expanded(
                            flex: 2,
                            child: Text('Doc rate',
                                style: _h, textAlign: TextAlign.right)),
                        Expanded(
                            flex: 2,
                            child: Text('Carrying',
                                style: _h, textAlign: TextAlign.right)),
                        Expanded(
                            flex: 2,
                            child: Text('Variance',
                                style: _h, textAlign: TextAlign.right)),
                        Expanded(
                            flex: 2,
                            child: Text('%',
                                style: _h, textAlign: TextAlign.right)),
                      ]),
                    ),
                    const Divider(height: 1),
                    ...rows.map((r) {
                      final v = (r['variance'] as num?)?.toDouble() ?? 0;
                      final tone =
                          v >= 0 ? Colors.green.shade700 : AppTheme.danger;
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(children: [
                          Expanded(
                              flex: 3,
                              child: Text('${r['voucher_no'] ?? '-'}',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600))),
                          Expanded(
                              flex: 3,
                              child: Text('${r['party_name'] ?? '-'}',
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis)),
                          Expanded(
                              flex: 4,
                              child: Text('${r['product_name'] ?? '-'}',
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis)),
                          Expanded(
                              flex: 2,
                              child: Text(_fmt(r['qty'] as num?),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12))),
                          Expanded(
                              flex: 2,
                              child: Text(_fmt(r['doc_rate'] as num?),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12))),
                          Expanded(
                              flex: 2,
                              child: Text(_fmt(r['carrying_cost'] as num?),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 12))),
                          Expanded(
                              flex: 2,
                              child: Text(_fmt(v),
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: tone))),
                          Expanded(
                              flex: 2,
                              child: Text(
                                  '${_fmt(r['variance_pct'] as num?)}%',
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                      fontSize: 12, color: tone))),
                        ]),
                      );
                    }),
                  ]),
                ),
            ]),
          ),
        ),
    ]);
  }

  static const _h = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: AppTheme.textSecondary);
}
