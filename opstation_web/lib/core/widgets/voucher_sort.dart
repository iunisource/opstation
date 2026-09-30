import 'dart:html' as html;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// App-wide voucher list ordering: by voucher number (sequence) or by voucher
/// date, newest or oldest first. One choice applies to every voucher list and
/// is remembered on this computer. Default: by number, newest first — so a
/// back-dated or late-saved voucher still sits in its sequence.
enum VoucherSortField { number, date }

class VoucherSortState {
  final VoucherSortField field;
  final bool descending;
  const VoucherSortState(this.field, this.descending);
}

class VoucherSort {
  VoucherSort._();
  static const _key = 'opstation.voucher_sort';

  static final ValueNotifier<VoucherSortState> state = ValueNotifier(_load());

  static VoucherSortState _load() {
    try {
      final v = html.window.localStorage[_key] ?? '';
      final parts = v.split(':');
      if (parts.length == 2) {
        return VoucherSortState(
          parts[0] == 'date' ? VoucherSortField.date : VoucherSortField.number,
          parts[1] != 'asc',
        );
      }
    } catch (_) {}
    return const VoucherSortState(VoucherSortField.number, true);
  }

  static void set(VoucherSortState s) {
    state.value = s;
    try {
      html.window.localStorage[_key] =
          '${s.field == VoucherSortField.date ? 'date' : 'number'}:${s.descending ? 'desc' : 'asc'}';
    } catch (_) {}
  }

  static const _numberKeys = [
    'voucher_number', 'entry_number', 'advice_number', 'transfer_number',
    'invoice_number', 'order_number', 'receipt_number', 'number',
  ];
  static const _dateKeys = [
    'voucher_date', 'entry_date', 'advice_date', 'transfer_date',
    'order_date', 'invoice_date', 'date', 'created_at',
  ];

  static String _pick(Map r, List<String> keys) {
    for (final k in keys) {
      final v = r[k];
      if (v != null && '$v'.isNotEmpty) return '$v';
    }
    return '';
  }

  static final _tok = RegExp(r'\d+|\D+');

  /// Natural compare: "PI-2026-0100" > "PI-2026-0048", "JV-9" < "JV-10".
  static int natural(String a, String b) {
    final ta = _tok.allMatches(a).map((m) => m.group(0)!).toList();
    final tb = _tok.allMatches(b).map((m) => m.group(0)!).toList();
    for (var i = 0; i < ta.length && i < tb.length; i++) {
      final x = ta[i], y = tb[i];
      final xd = x.codeUnitAt(0) >= 48 && x.codeUnitAt(0) <= 57;
      final yd = y.codeUnitAt(0) >= 48 && y.codeUnitAt(0) <= 57;
      int c;
      if (xd && yd) {
        final xs = x.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        final ys = y.replaceFirst(RegExp(r'^0+(?=\d)'), '');
        c = xs.length != ys.length ? xs.length.compareTo(ys.length) : xs.compareTo(ys);
      } else {
        c = x.toLowerCase().compareTo(y.toLowerCase());
      }
      if (c != 0) return c;
    }
    return ta.length.compareTo(tb.length);
  }

  static List<Map<String, dynamic>> sort(List items, VoucherSortState s) {
    final out = List<Map<String, dynamic>>.of(items.cast<Map<String, dynamic>>());
    int byNum(Map a, Map b) => natural(_pick(a, _numberKeys), _pick(b, _numberKeys));
    int byDate(Map a, Map b) => _pick(a, _dateKeys).compareTo(_pick(b, _dateKeys));
    out.sort((a, b) {
      var c = s.field == VoucherSortField.number ? byNum(a, b) : byDate(a, b);
      if (c == 0) c = s.field == VoucherSortField.number ? byDate(a, b) : byNum(a, b);
      if (c == 0) c = '${a['created_at'] ?? ''}'.compareTo('${b['created_at'] ?? ''}');
      return s.descending ? -c : c;
    });
    return out;
  }
}

/// Wraps a voucher list: shows a small "Sort: No. | Date ↓" bar and hands the
/// builder the rows in the chosen order. Must sit where the list would get a
/// bounded height (inside an Expanded, like the ListView it wraps).
class VoucherSortedList extends StatelessWidget {
  final List items;
  final Widget Function(List<Map<String, dynamic>> rows) builder;
  const VoucherSortedList({super.key, required this.items, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoucherSortState>(
      valueListenable: VoucherSort.state,
      builder: (context, s, _) {
        final rows = VoucherSort.sort(items, s);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          VoucherSortBar(state: s),
          Expanded(child: builder(rows)),
        ]);
      },
    );
  }
}

class VoucherSortBar extends StatelessWidget {
  final VoucherSortState state;
  const VoucherSortBar({super.key, required this.state});

  Widget _pill(String label, bool on, VoidCallback tap) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: on ? AppTheme.primary.withOpacity(0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: on ? AppTheme.primary.withOpacity(0.5) : AppTheme.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? AppTheme.primary : AppTheme.textSecondary)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isNum = state.field == VoucherSortField.number;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 8, 4),
      child: Row(children: [
        const Text('Sort', style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
        const SizedBox(width: 6),
        _pill('No.', isNum, () => VoucherSort.set(VoucherSortState(VoucherSortField.number, state.descending))),
        const SizedBox(width: 4),
        _pill('Date', !isNum, () => VoucherSort.set(VoucherSortState(VoucherSortField.date, state.descending))),
        const Spacer(),
        Tooltip(
          message: state.descending ? 'Newest first' : 'Oldest first',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => VoucherSort.set(VoucherSortState(state.field, !state.descending)),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(state.descending ? Icons.south : Icons.north, size: 13, color: AppTheme.textSecondary),
                const SizedBox(width: 2),
                Text(state.descending ? 'Newest' : 'Oldest',
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.textSecondary)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
