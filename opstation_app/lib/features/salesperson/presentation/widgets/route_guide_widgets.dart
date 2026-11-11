import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/location_check.dart' show LocFixWarning, BiText;
import '../../models/customer.dart';
import '../../services/route_guide.dart';

/// The "i" on a stop card. Pulses fast while the salesperson is at the shop
/// (or has the card open) and hasn't read today's brief yet. The number is how
/// many things the brief has. Hidden when there is nothing to show.
class GuideIcon extends ConsumerWidget {
  final Customer customer;
  /// The settled card was opened by hand — counts like being at the shop.
  final bool opened;
  final double size;
  const GuideIcon({super.key, required this.customer, this.opened = false, this.size = 30});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(routeGuideProvider);
    final count = g.countFor(customer.id);
    if (count == 0) return const SizedBox.shrink();
    final seen = g.seen.contains(customer.id);
    final pulse = !seen && (g.near.contains(customer.id) || opened);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showRouteGuideSheet(context, ref, customer),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: _GuideDot(count: count, pulse: pulse, seen: seen, size: size),
      ),
    );
  }
}

class _GuideDot extends StatefulWidget {
  final int count;
  final bool pulse;
  final bool seen;
  final double size;
  const _GuideDot({required this.count, required this.pulse, required this.seen, required this.size});
  @override
  State<_GuideDot> createState() => _GuideDotState();
}

class _GuideDotState extends State<_GuideDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _GuideDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) _c.repeat();
    if (!widget.pulse && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final active = widget.pulse;
    final dot = Container(
      width: s,
      height: s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? AppColors.primary : AppColors.primaryLight,
        border: active ? null : Border.all(color: const Color(0xFFC7D7FE), width: 1.5),
      ),
      child: Text('i',
          style: TextStyle(
              fontFamily: 'serif',
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w800,
              fontSize: s * 0.52,
              height: 1,
              color: active ? Colors.white : AppColors.primary)),
    );
    return SizedBox(
      width: s + 8,
      height: s + 8,
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        if (active)
          AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final t = _c.value;
              return Container(
                width: s + 16 * t,
                height: s + 16 * t,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary.withOpacity(0.35 * (1 - t)),
                ),
              );
            },
          ),
        dot,
        if (!widget.seen)
          Positioned(
            top: -2,
            right: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.warning,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Text('${widget.count}',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
      ]),
    );
  }
}

/// Opens the shop brief and marks it read for today.
Future<void> showRouteGuideSheet(BuildContext context, WidgetRef ref, Customer c) async {
  final g = ref.read(routeGuideProvider);
  final b = g.briefFor(c.id);
  if (b == null) return;
  ref.read(routeGuideProvider.notifier).markSeen(c.id);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).cardColor,
    builder: (ctx) => _BriefSheet(customer: c, brief: b, w: LocFixWarning(true, g.lang)),
  );
}

class _BriefSheet extends StatelessWidget {
  final Customer customer;
  final Map<String, dynamic> brief;
  final LocFixWarning w;
  const _BriefSheet({required this.customer, required this.brief, required this.w});

  static String _n(dynamic v) {
    final x = num.tryParse('${v ?? ''}');
    return x == null ? '0' : NumberFormat('#,##0').format(x);
  }

  static String _d(dynamic v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : DateFormat('d MMM').format(d.toLocal());
  }

  static List<String> _list(dynamic v) => v is List ? [for (final x in v) '$x'] : const [];
  static Map<String, dynamic>? _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : null;

  Widget _head(String icon, String en, String ur) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(icon, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Expanded(
              child: BiText(w,
                  en: en,
                  ur: ur,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .3,
                      color: AppColors.textSecondaryLight))),
        ]),
      );

  Widget _line(String en, String ur) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: BiText(w, en: en, ur: ur, style: const TextStyle(fontSize: 13.5, height: 1.4)),
      );

  Widget _chips(List<String> items, Color bg, Color fg) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final s in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
            child: Text(s, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final missing = _list(brief['missing']);
    final notes = brief['notes'] is List ? (brief['notes'] as List) : const [];
    final bal = _map(brief['balance']);
    final credit = _map(brief['credit']);
    final lastPay = _map(brief['last_payment']);
    final due = _map(brief['order_due']);
    final notBought = _list(brief['not_bought']);
    final comp = _list(brief['competitors']);
    final offers = _list(brief['offers']);
    final visits = _map(brief['visits']);
    final skipped = int.tryParse('${visits?['skipped'] ?? 0}') ?? 0;

    final parts = <Widget>[
      if (missing.isNotEmpty) ...[
        _head('🎯', 'PITCH — MISSING ITEMS (${missing.length})', 'یہ آئٹمز دکان پر نہیں — پیش کریں (${missing.length})'),
        _chips(missing, AppColors.warningLight, const Color(0xFF92400E)),
      ],
      if (notes.isNotEmpty) ...[
        _head('📝', 'NOTES (${notes.length})', 'نوٹس (${notes.length})'),
        for (final raw in notes)
          if (raw is Map)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                border: Border.all(color: const Color(0xFFFDE68A)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${raw['text'] ?? ''}', style: const TextStyle(fontSize: 13.5, height: 1.4)),
                const SizedBox(height: 2),
                Text(
                  [
                    if ('${raw['by'] ?? ''}'.isNotEmpty) '${raw['by']}',
                    if (raw['until'] != null) 'until ${_d(raw['until'])}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondaryLight),
                ),
              ]),
            ),
      ],
      if (bal != null || credit != null || lastPay != null) ...[
        _head('💰', 'MONEY', 'رقم'),
        if (bal != null) ...[
          _line('Rs ${_n(bal['due'])} due', 'بقایا: Rs ${_n(bal['due'])}'),
          if ((num.tryParse('${bal['over60'] ?? 0}') ?? 0) > 0)
            _line('Rs ${_n(bal['over60'])} older than 60 days', '60 دن سے پرانا: Rs ${_n(bal['over60'])}'),
        ],
        if (credit != null)
          _line('Over credit limit — Rs ${_n(credit['due'])} due, limit Rs ${_n(credit['limit'])}',
              'کریڈٹ حد سے زیادہ — بقایا Rs ${_n(credit['due'])}، حد Rs ${_n(credit['limit'])}'),
        if (lastPay != null)
          _line('Last payment Rs ${_n(lastPay['amount'])} on ${_d(lastPay['at'])}',
              'آخری ادائیگی Rs ${_n(lastPay['amount'])} — ${_d(lastPay['at'])}'),
      ],
      if (due != null) ...[
        _head('🛒', 'ORDER DUE', 'آرڈر کا وقت'),
        _line('Usually orders every ${due['gap']} days — last order ${due['days']} days ago',
            'عموماً ہر ${due['gap']} دن بعد آرڈر — آخری آرڈر ${due['days']} دن پہلے'),
      ],
      if (notBought.isNotEmpty) ...[
        _head('📉', 'NOT BOUGHT LATELY', 'کچھ عرصے سے نہیں خریدا'),
        _chips(notBought, const Color(0xFFF1F5F9), const Color(0xFF334155)),
      ],
      if (comp.isNotEmpty) ...[
        _head('⚔️', 'COMPETITOR BRANDS SEEN', 'حریف برانڈز'),
        _chips(comp, AppColors.dangerLight, AppColors.dangerDark),
      ],
      if (offers.isNotEmpty) ...[
        _head('🎁', 'OFFERS & SCHEMES', 'آفرز اور اسکیمیں'),
        _chips(offers, AppColors.successLight, AppColors.successDark),
      ],
      if (visits != null && (visits['last'] != null || skipped > 0)) ...[
        _head('📍', 'VISITS', 'وزٹس'),
        if (visits['last'] != null)
          _line('Last visit ${_d(visits['last'])}', 'آخری وزٹ ${_d(visits['last'])}'),
        if (skipped > 0)
          _line('Skipped the last $skipped time${skipped == 1 ? '' : 's'}', 'پچھلی $skipped بار اسکپ ہوا'),
      ],
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(customer.shopName, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            BiText(w,
                en: 'Shop brief',
                ur: 'دکان کی معلومات',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondaryLight)),
            if (parts.isEmpty)
              const Padding(padding: EdgeInsets.only(top: 14), child: Text('Nothing to show for this shop.'))
            else
              ...parts,
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
            ),
          ]),
        ),
      ),
    );
  }
}
