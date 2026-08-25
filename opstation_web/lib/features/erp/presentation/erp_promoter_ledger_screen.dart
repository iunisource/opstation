import 'package:flutter/material.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../../core/format/money.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Promoter ledger — reads the Commission Payable control account (2150) filtered
/// by the promoter's party_id. Credits = commission earned (PCJ accruals);
/// debits = payouts (CPV). Running balance = outstanding owed to the promoter.
class ErpPromoterLedgerScreen extends ConsumerStatefulWidget {
  const ErpPromoterLedgerScreen({super.key});
  @override
  ConsumerState<ErpPromoterLedgerScreen> createState() => _ErpPromoterLedgerScreenState();
}

class _ErpPromoterLedgerScreenState extends ConsumerState<ErpPromoterLedgerScreen> {
  bool _loading = true;
  bool _loadingLedger = false;
  String? _payableAccount;
  List<Map<String, dynamic>> _promoters = [];
  Map<String, dynamic>? _selected;
  String _search = '';
  List<Map<String, dynamic>> _rows = [];
  double _earned = 0;
  double _paid = 0;

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
      final client = Supabase.instance.client;
      final res = await Future.wait([
        client.from('sales_promoters').select('id, name, phone, is_active').eq('org_id', orgId).order('name'),
        client.from('inventory_settings').select('commission_payable_account_id').eq('org_id', orgId).maybeSingle(),
      ]);
      final settings = res[1] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        _promoters = List<Map<String, dynamic>>.from(res[0] as List);
        _payableAccount = settings?['commission_payable_account_id'] as String?;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _snack('Load error: $e');
      }
    }
  }

  Future<void> _loadLedger(Map<String, dynamic> p) async {
    final orgId = _orgId;
    final acct = _payableAccount;
    setState(() {
      _selected = p;
      _rows = [];
      _earned = 0;
      _paid = 0;
      _loadingLedger = true;
    });
    if (orgId == null || acct == null) {
      setState(() => _loadingLedger = false);
      return;
    }
    try {
      final client = Supabase.instance.client;
      final lines = await client
          .from('journal_lines')
          .select('debit, credit, description, entry_id')
          .eq('org_id', orgId)
          .eq('account_id', acct)
          .eq('party_id', p['id']);
      final lineList = List<Map<String, dynamic>>.from(lines as List);
      if (lineList.isEmpty) {
        if (mounted) setState(() => _loadingLedger = false);
        return;
      }
      final entryIds = lineList.map((l) => l['entry_id'] as String).toSet().toList();
      final heads = await client
          .from('journal_entries')
          .select('id, entry_number, entry_date, description, reference_type, status, posted_at')
          .inFilter('id', entryIds);
      final headMap = {for (final h in (heads as List)) (h['id'] as String): h as Map<String, dynamic>};

      final merged = <Map<String, dynamic>>[];
      for (final l in lineList) {
        final h = headMap[l['entry_id']];
        if (h == null) continue;
        if ((h['status'] as String?) == 'draft') continue;
        merged.add({'line': l, 'head': h});
      }
      merged.sort((a, b) {
        final ha = a['head'] as Map<String, dynamic>;
        final hb = b['head'] as Map<String, dynamic>;
        final da = (ha['entry_date'] ?? ha['posted_at'] ?? '') as String;
        final db = (hb['entry_date'] ?? hb['posted_at'] ?? '') as String;
        return da.compareTo(db);
      });

      double bal = 0, earned = 0, paid = 0;
      final rows = <Map<String, dynamic>>[];
      for (final m in merged) {
        final l = m['line'] as Map<String, dynamic>;
        final h = m['head'] as Map<String, dynamic>;
        final cr = (l['credit'] as num?)?.toDouble() ?? 0;
        final dr = (l['debit'] as num?)?.toDouble() ?? 0;
        bal += cr - dr;
        earned += cr;
        paid += dr;
        rows.add({
          'date': (h['entry_date'] as String?) ?? ((h['posted_at'] as String?)?.split('T').first ?? ''),
          'voucher': h['entry_number'] ?? '',
          'type': h['reference_type'] ?? '',
          'detail': (h['description'] as String?) ?? '',
          'earned': cr,
          'paid': dr,
          'balance': bal,
        });
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _earned = earned;
        _paid = paid;
        _loadingLedger = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingLedger = false);
        _snack('Ledger error: $e');
      }
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  String _money(double v) => money(v);

  String _typeLabel(String t) {
    switch (t) {
      case 'promoter_commission':
        return 'Commission earned';
      case 'cpv':
        return 'Payout (CPV)';
      case 'jv':
        return 'Journal adjustment';
      default:
        return t.isEmpty ? '—' : t;
    }
  }

  void _print() {
    final p = _selected;
    if (p == null || _rows.isEmpty) {
      _snack('Nothing to print');
      return;
    }
    final org = ref.read(currentUserProvider)?.orgName ?? 'Opstation';
    final outstanding = _earned - _paid;
    final body = _rows.map((r) {
      final earned = r['earned'] as double;
      final paid = r['paid'] as double;
      final bal = r['balance'] as double;
      final detail = ((r['detail'] as String?)?.isNotEmpty == true)
          ? r['detail'] as String
          : _typeLabel(r['type'] as String? ?? '');
      return '<tr><td>${r['date']}</td><td>${r['voucher']}</td><td>$detail</td>'
          '<td class="r">${earned > 0 ? _money(earned) : ''}</td>'
          '<td class="r">${paid > 0 ? _money(paid) : ''}</td>'
          '<td class="r b">${_money(bal)}</td></tr>';
    }).join();
    final doc = '''
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Promoter Ledger — ${p['name']}</title>
<style>@page{margin:0}
 body{font-family:Arial,sans-serif;padding:24px;color:#222}
 h2{margin:0 0 2px} .sub{color:#666;font-size:12px;margin-bottom:16px}
 .stats{display:flex;gap:28px;margin:12px 0 18px}
 .stat .l{font-size:11px;color:#666} .stat .v{font-size:16px;font-weight:bold}
 table{width:100%;border-collapse:collapse;font-size:12px}
 th{text-align:left;border-bottom:2px solid #333;padding:6px 8px;background:#f5f5f5}
 td{padding:6px 8px;border-bottom:1px solid #eee} .r{text-align:right} .b{font-weight:bold}
</style></head><body>
<h2>$org — Promoter Ledger</h2>
<div class="sub">${p['name']}${(p['phone'] as String?)?.isNotEmpty == true ? '  ·  ${p['phone']}' : ''}  ·  Commission Payable (2150)  ·  ${DateFormat('dd MMM yyyy').format(DateTime.now())}</div>
<div class="stats">
 <div class="stat"><div class="l">Earned</div><div class="v">Rs. ${_money(_earned)}</div></div>
 <div class="stat"><div class="l">Paid</div><div class="v">Rs. ${_money(_paid)}</div></div>
 <div class="stat"><div class="l">Outstanding</div><div class="v">Rs. ${_money(outstanding)}</div></div>
</div>
<table><thead><tr><th>Date</th><th>Voucher</th><th>Detail</th><th class="r">Earned</th><th class="r">Paid</th><th class="r">Balance</th></tr></thead>
<tbody>$body</tbody></table>
<script>window.onload=function(){window.print();}</script>
</body></html>''';
    final blob = html.Blob([doc], 'text/html;charset=utf-8');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.window.open(url, '_blank');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final q = _search.toLowerCase();
    final filtered = q.isEmpty
        ? _promoters
        : _promoters
            .where((p) =>
                (p['name'] as String? ?? '').toLowerCase().contains(q) ||
                (p['phone'] as String? ?? '').toLowerCase().contains(q))
            .toList();

    return Container(
      color: AppTheme.background,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(children: [
            const Text('Promoter Ledger', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('Commission payable (2150) by promoter',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
          ]),
        ),
        if (_payableAccount == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
              child: const Text('Commission Payable account not set in inventory settings.',
                  style: TextStyle(fontSize: 12, color: Colors.orange)),
            ),
          ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              width: 320,
              decoration: const BoxDecoration(
                  color: Colors.white, border: Border(right: BorderSide(color: AppTheme.border))),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: TextField(
                    decoration: const InputDecoration(
                        hintText: 'Search promoters…', prefixIcon: Icon(Icons.search, size: 18), isDense: true),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(
                          child: Text('No promoters', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = filtered[i];
                            final sel = _selected != null && _selected!['id'] == p['id'];
                            return ListTile(
                              dense: true,
                              selected: sel,
                              selectedTileColor: AppTheme.primary.withOpacity(0.06),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: AppTheme.primary.withOpacity(0.12),
                                child: const Icon(Icons.badge_outlined, size: 16, color: AppTheme.primary),
                              ),
                              title: Text(p['name'] as String? ?? '-',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                              subtitle: Text(p['phone'] as String? ?? '—', style: const TextStyle(fontSize: 11)),
                              onTap: () => _loadLedger(p),
                            );
                          },
                        ),
                ),
              ]),
            ),
            Expanded(
              child: _selected == null
                  ? const Center(
                      child: Text('Select a promoter to view the ledger',
                          style: TextStyle(color: AppTheme.textSecondary)))
                  : _ledger(),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _ledger() {
    final outstanding = _earned - _paid;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Row(children: [
          Expanded(
            child: Text(_selected!['name'] as String? ?? '-',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
          ),
          _stat('Earned', _earned, AppTheme.primary),
          const SizedBox(width: 18),
          _stat('Paid', _paid, AppTheme.textSecondary),
          const SizedBox(width: 18),
          _stat('Outstanding', outstanding, AppTheme.success),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.print_outlined, size: 20),
            tooltip: 'Print / Save as PDF',
            onPressed: _rows.isEmpty ? null : _print,
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _loadingLedger
            ? const Center(child: CircularProgressIndicator())
            : _rows.isEmpty
                ? const Center(
                    child: Text('No commission activity yet', style: TextStyle(color: AppTheme.textSecondary)))
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: Column(children: [
                      _headerRow(),
                      ..._rows.map(_dataRow),
                    ]),
                  ),
      ),
    ]);
  }

  Widget _stat(String label, double v, Color c) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
        Text('Rs. ${_money(v)}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c)),
      ]);

  Widget _headerRow() => Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(children: const [
          Expanded(flex: 2, child: Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Voucher', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 3, child: Text('Detail', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Earned', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Paid', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
          Expanded(flex: 2, child: Text('Balance', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textSecondary))),
        ]),
      );

  Widget _dataRow(Map<String, dynamic> r) {
    final earned = r['earned'] as double;
    final paid = r['paid'] as double;
    final bal = r['balance'] as double;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
      child: Row(children: [
        Expanded(flex: 2, child: Text(r['date'] as String? ?? '', style: const TextStyle(fontSize: 12))),
        Expanded(flex: 2, child: Text(r['voucher'] as String? ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        Expanded(flex: 3, child: Text(((r['detail'] as String?)?.isNotEmpty == true) ? r['detail'] as String : _typeLabel(r['type'] as String? ?? ''), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary), overflow: TextOverflow.ellipsis)),
        Expanded(flex: 2, child: Text(earned > 0 ? _money(earned) : '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: AppTheme.primary))),
        Expanded(flex: 2, child: Text(paid > 0 ? _money(paid) : '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
        Expanded(flex: 2, child: Text(_money(bal), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
      ]),
    );
  }
}
