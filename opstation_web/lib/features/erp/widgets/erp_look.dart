import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// The "Modern look" for the Sales Order, Delivery Order and Sales Invoice screens.
///
/// Design only: it changes colours, corners, spacing and shadows, never what a screen does. It is an
/// organisation setting (`org.modern_look` in app_config, default OFF = the classic look), switched in
/// Admin Settings → Sales & Customers, or from the gear icon on each of the three screens.
class ErpLook {
  ErpLook._();

  /// Kept up to date by [erpModernLookProvider]; read by the three screens while they build.
  static bool modern = false;

  static const key = 'org.modern_look';
  static const _bg = Color(0xFFF4F6FB);
  static const _edge = Color(0xFFE5E9F2);

  /// Shown in the classic look only (the modern look moves the title into the blue header band).
  static Widget classicOnly(Widget w) => modern ? const SizedBox.shrink() : w;

  /// The scrolling body of an open voucher. Classic: one column. Modern, on a wide screen: the main
  /// sections on the left and everything after an [ErpSideBreak] in a narrow column on the right.
  static Widget columns({required List<Widget> children}) {
    Widget one() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    if (!modern) return one();
    final i = children.indexWhere((w) => w is ErpSideBreak);
    if (i < 0) return one();
    final main = children.sublist(0, i);
    var side = children.sublist(i + 1);
    if (side.isNotEmpty && side.first is SizedBox) side = side.sublist(1);
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 920) return one();
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: main)),
        const SizedBox(width: 20),
        SizedBox(width: 340, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: side)),
      ]);
    });
  }

  /// The blue header band of an open voucher: kind, big number, one-line summary and the document flow.
  static Widget hero({
    required String kind,
    required String number,
    required String subtitle,
    required List<ErpFlowStep> steps,
  }) =>
      Builder(builder: (context) {
        final narrow = MediaQuery.of(context).size.width < 700;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(narrow ? 16 : 28, narrow ? 14 : 18, narrow ? 16 : 28, narrow ? 14 : 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0F1F4D), Color(0xFF1D3F94)]),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(kind, style: const TextStyle(color: Color(0xFFB9C8F0), fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(number, style: TextStyle(color: Colors.white, fontSize: narrow ? 24 : 30, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Color(0xFFB9C8F0), fontSize: 13.5)),
            ],
            if (steps.isNotEmpty && !narrow) ...[
              const SizedBox(height: 16),
              Row(children: [
                for (var i = 0; i < steps.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: _flowStep(i, steps[i])),
                ],
              ]),
            ],
          ]),
        );
      });

  static Widget _flowStep(int i, ErpFlowStep s) {
    final cur = s.state == ErpStepState.current;
    final done = s.state == ErpStepState.done;
    final ink = cur ? const Color(0xFF101828) : Colors.white;
    final mute = cur ? const Color(0xFF667085) : const Color(0xFFB9C8F0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cur ? Colors.white : const Color(0x17FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cur ? Colors.white : const Color(0x2EFFFFFF)),
      ),
      child: Row(children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cur ? AppTheme.primary : (done ? const Color(0xFF33C28F) : const Color(0x33FFFFFF)),
          ),
          child: done
              ? const Icon(Icons.check, size: 15, color: Colors.white)
              : Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(s.label, style: TextStyle(color: ink, fontSize: 13.5, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
            if (s.sub.isNotEmpty) Text(s.sub, style: TextStyle(color: mute, fontSize: 11.5), overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }

  /// Heading text of a table column (modern: small, bold, spaced capitals).
  static TextStyle th() => modern
      ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, letterSpacing: 0.6, color: Color(0xFF5B6B8C))
      : const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.textSecondary);

  static String cap(String s) => modern ? s.toUpperCase() : s;

  /// The totals strip at the foot of a line table.
  static BoxDecoration footRow() =>
      modern ? const BoxDecoration(color: Color(0xFFEAF0FF)) : const BoxDecoration(color: AppTheme.background);

  /// The page colour behind the cards of an open voucher.
  static Widget page(Widget child) => modern ? ColoredBox(color: _bg, child: child) : child;

  /// A white content card (header fields, line tables, totals ...).
  static BoxDecoration card() => modern
      ? BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _edge),
          boxShadow: const [BoxShadow(color: Color(0x1F1E3A8A), blurRadius: 22, offset: Offset(0, 8))],
        )
      : BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.border));

  /// The grey heading row of a line table (sits on top of a [card]).
  static BoxDecoration tableHead() => modern
      ? const BoxDecoration(color: Color(0xFFEAF0FF), borderRadius: BorderRadius.vertical(top: Radius.circular(14)))
      : const BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.vertical(top: Radius.circular(8)));

  /// The bar across the top of an open voucher (number, status, buttons).
  static BoxDecoration appBar() => modern
      ? const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: _edge)),
          boxShadow: [BoxShadow(color: Color(0x141E3A8A), blurRadius: 12, offset: Offset(0, 4))],
        )
      : const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: AppTheme.border)));

  /// Corner radius of a status pill: fully round in the modern look.
  static double pill(double classic) => modern ? 99 : classic;

  /// Gap between two rows of a list: a hairline in classic, a small space in modern.
  static Widget listDivider() => modern ? const SizedBox(height: 4) : const Divider(height: 1);

  /// Background of a list row (modern: a rounded highlight on the selected row).
  static BoxDecoration? rowDecoration(bool selected) => modern
      ? BoxDecoration(
          color: selected ? AppTheme.primary.withOpacity(0.09) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppTheme.primary.withOpacity(0.35) : _edge),
        )
      : null;

  static EdgeInsetsGeometry? rowMargin() => modern ? const EdgeInsets.symmetric(horizontal: 10) : null;

  /// The theme the three screens use while the modern look is on.
  static ThemeData themed(ThemeData t) {
    OutlineInputBorder ob(Color c, [double w = 1]) =>
        OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: c, width: w));
    final shape = WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)));
    return t.copyWith(
      scaffoldBackgroundColor: _bg,
      dividerColor: _edge,
      dividerTheme: const DividerThemeData(color: _edge, space: 1, thickness: 1),
      inputDecorationTheme: t.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: const Color(0xFFFAFBFD),
        border: ob(_edge),
        enabledBorder: ob(_edge),
        focusedBorder: ob(AppTheme.primary, 1.5),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: (t.elevatedButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: shape,
          elevation: const WidgetStatePropertyAll<double>(0),
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 44)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.symmetric(horizontal: 20)),
          textStyle: const WidgetStatePropertyAll<TextStyle>(TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: (t.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: shape,
          minimumSize: const WidgetStatePropertyAll<Size>(Size(0, 44)),
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.symmetric(horizontal: 18)),
          textStyle: const WidgetStatePropertyAll<TextStyle>(TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
      dialogTheme: t.dialogTheme.copyWith(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    );
  }
}

/// Whether the organisation uses the modern look. Re-read after the setting changes (invalidate it).
final erpModernLookProvider = FutureProvider<bool>((ref) async {
  final orgId = ref.watch(currentUserProvider)?.orgId;
  if (orgId == null) {
    ErpLook.modern = false;
    return false;
  }
  try {
    final rows = await Supabase.instance.client
        .from('app_config')
        .select('value')
        .eq('org_id', orgId)
        .eq('key', ErpLook.key)
        .limit(1);
    final on = (rows as List).isNotEmpty && rows.first['value'] == 'true';
    ErpLook.modern = on;
    return on;
  } catch (_) {
    return ErpLook.modern;
  }
});

/// Wraps a screen: applies the modern theme and page colour while the modern look is on.
class ErpLookScope extends StatelessWidget {
  const ErpLookScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!ErpLook.modern) return child;
    return Theme(
      data: ErpLook.themed(Theme.of(context)),
      child: ColoredBox(color: const Color(0xFFF4F6FB), child: child),
    );
  }
}

/// Gear icon on the list header of Sales Orders, Delivery Orders and Sales Invoices.
class ErpLookGear extends ConsumerWidget {
  const ErpLookGear({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
        icon: const Icon(Icons.settings_outlined, size: 20, color: AppTheme.textSecondary),
        tooltip: 'Look: Classic or Modern',
        visualDensity: VisualDensity.compact,
        onPressed: () => showDialog<void>(context: context, builder: (_) => _LookDialog(ref: ref)),
      );
}

class _LookDialog extends StatefulWidget {
  const _LookDialog({required this.ref});
  final WidgetRef ref;

  @override
  State<_LookDialog> createState() => _LookDialogState();
}

class _LookDialogState extends State<_LookDialog> {
  bool _on = ErpLook.modern;
  bool _busy = false;
  String? _err;

  bool get _canChange {
    final role = widget.ref.read(currentUserProvider)?.role;
    return role == WebUserRole.masterAdmin || role == WebUserRole.admin;
  }

  Future<void> _set(bool v) async {
    final orgId = widget.ref.read(currentUserProvider)?.orgId;
    if (orgId == null) return;
    setState(() { _busy = true; _err = null; });
    try {
      await Supabase.instance.client.from('app_config').upsert({
        'key': ErpLook.key,
        'value': v ? 'true' : 'false',
        'org_id': orgId,
      }, onConflict: 'key,org_id,branch_id');
      widget.ref.invalidate(erpModernLookProvider);
      if (mounted) setState(() { _on = v; _busy = false; });
    } catch (_) {
      if (mounted) setState(() { _busy = false; _err = 'Could not change the look. Please try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Look of these screens'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Modern look', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(_on ? 'On. Switch off to go back to the Classic look.' : 'Off. The Classic look is in use.'),
            value: _on,
            onChanged: (_busy || !_canChange) ? null : _set,
          ),
          const SizedBox(height: 4),
          const Text(
            'Applies to Sales Orders, Delivery Orders and Sales Invoices for everyone in your organisation. '
            'Only the appearance changes, not how anything works.',
            style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary, height: 1.4),
          ),
          if (!_canChange) ...[
            const SizedBox(height: 10),
            const Text('Only an admin can change this (Admin Settings → Sales & Customers).',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary)),
          ],
          if (_err != null) ...[
            const SizedBox(height: 10),
            Text(_err!, style: const TextStyle(fontSize: 12.5, color: AppTheme.danger)),
          ],
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}

enum ErpStepState { done, current, todo }

/// One step of the Sales Order → Delivery Order → Sales Invoice strip in the header band.
class ErpFlowStep {
  const ErpFlowStep(this.label, this.sub, this.state);
  final String label;
  final String sub;
  final ErpStepState state;
}

/// Marks where the right-hand column starts in [ErpLook.columns]. Draws nothing.
class ErpSideBreak extends StatelessWidget {
  const ErpSideBreak({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
