import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../services/approved_expenses_provider.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _d(dynamic v, {bool year = true}) {
  final d = DateTime.tryParse('$v');
  if (d == null) return '';
  final l = d.isUtc ? d.toLocal() : d;
  return '${l.day} ${_months[l.month - 1]}${year ? ' ${l.year}' : ''}';
}

String _rs(num n) {
  final s = n.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return 'Rs ${n < 0 ? '-' : ''}$b';
}

num? _amount(Map<String, dynamic> c) {
  final v = c['status'] == 'paid' ? (c['paid_amount'] ?? c['amount']) : c['amount'];
  return v is num ? v : num.tryParse('${v ?? ''}');
}

String _range(Map<String, dynamic> c) {
  final a = _d(c['date_from'], year: false), b = _d(c['date_to']);
  final fromYear = _d(c['date_from']);
  if (a.isEmpty) return '—';
  if (b.isEmpty || fromYear == b) return fromYear;
  return '$a – $b';
}

/// Drawer -> Approved Expenses: every reimbursement of mine that was approved
/// (or already paid) in the portal.
class ApprovedExpensesScreen extends ConsumerWidget {
  const ApprovedExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(approvedExpensesProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(title: const Text('Approved Expenses')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off_outlined, size: 40, color: AppColors.textSecondaryLight),
              const SizedBox(height: 10),
              Text('Could not load. Check your connection and try again.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondaryLight)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => ref.invalidate(approvedExpensesProvider), child: const Text('Retry')),
            ]),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.receipt_long_outlined, size: 40, color: AppColors.textSecondaryLight),
                  const SizedBox(height: 10),
                  Text('No approved expenses yet. They appear here once your reimbursement is approved.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondaryLight)),
                ]),
              ),
            );
          }
          final now = DateTime.now();
          num toPay = 0, paidMonth = 0;
          for (final c in list) {
            final a = _amount(c) ?? 0;
            if (c['status'] == 'approved') toPay += a;
            final p = DateTime.tryParse('${c['paid_on'] ?? ''}');
            if (c['status'] == 'paid' && p != null && p.year == now.year && p.month == now.month) paidMonth += a;
          }
          return RefreshIndicator(
            onRefresh: () async => ref.refresh(approvedExpensesProvider.future),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(child: _stat('To be paid', _rs(toPay), AppColors.warningDark, AppColors.warningLight)),
                const SizedBox(width: 10),
                Expanded(child: _stat('Paid this month', _rs(paidMonth), AppColors.successDark, AppColors.successLight)),
              ]),
              const SizedBox(height: 12),
              for (final c in list) _card(context, c),
            ]),
          );
        },
      ),
    );
  }

  Widget _stat(String l, String v, Color fg, Color bg) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
          const SizedBox(height: 3),
          Text(v, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg)),
        ]),
      );

  Widget _card(BuildContext context, Map<String, dynamic> c) {
    final paid = c['status'] == 'paid';
    final amt = _amount(c);
    final km = c['km'] is num ? c['km'] as num : num.tryParse('${c['km'] ?? ''}');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _detail(context, c),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.borderLight)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_range(c), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                    color: paid ? AppColors.successLight : AppColors.infoLight,
                    borderRadius: BorderRadius.circular(999)),
                child: Text(paid ? 'Paid' : 'Approved · to be paid',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: paid ? AppColors.successDark : AppColors.primaryDark)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text(amt == null ? '—' : _rs(amt),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              if (km != null)
                Text('${km % 1 == 0 ? km.toStringAsFixed(0) : km.toStringAsFixed(1)} km',
                    style: TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
            ]),
            const SizedBox(height: 4),
            Text(
              paid
                  ? 'Paid ${_d(c['paid_on'])}${'${c['paid_method'] ?? ''}'.isEmpty ? '' : ' · ${c['paid_method']}'}'
                  : 'Approved ${_d(c['decided_at'])}${'${c['decided_by_name'] ?? ''}'.isEmpty ? '' : ' by ${c['decided_by_name']}'}',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondaryLight),
            ),
          ]),
        ),
      ),
    );
  }

  void _detail(BuildContext context, Map<String, dynamic> c) {
    final paid = c['status'] == 'paid';
    final lines = [for (final l in (c['lines'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
    final allow = c['allowance_amount'] is num ? c['allowance_amount'] as num : null;
    Widget kv(String k, String v) => v.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight))),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.65,
        maxChildSize: 0.92,
        builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(20, 18, 20, 28), children: [
          Text(_range(c), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          kv('Amount', _amount(c) == null ? '' : _rs(_amount(c)!)),
          kv('Status', paid ? 'Paid' : 'Approved · to be paid'),
          kv('Distance', c['km'] == null ? '' : '${c['km']} km'),
          kv('Rate', c['rate'] == null ? '' : 'Rs ${c['rate']} / km'),
          kv('Allowance', allow == null || allow == 0 ? '' : _rs(allow)),
          kv('Approved', '${_d(c['decided_at'])}${'${c['decided_by_name'] ?? ''}'.isEmpty ? '' : ' by ${c['decided_by_name']}'}'),
          if (paid) kv('Paid on', _d(c['paid_on'])),
          if (paid) kv('Method', '${c['paid_method'] ?? ''}'),
          if (paid) kv('Reference', '${c['paid_ref'] ?? ''}'),
          kv('Payment advice', '${c['advice_number'] ?? ''}'),
          kv('Note', '${c['adjust_note'] ?? c['note'] ?? ''}'),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('Days', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(_d(l['day']), style: const TextStyle(fontSize: 13))),
                  Text('${l['km'] ?? ''} km', style: TextStyle(fontSize: 12.5, color: AppColors.textSecondaryLight)),
                ]),
              ),
          ],
        ]),
      ),
    );
  }
}
