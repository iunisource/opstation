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
          gradient: LinearGradient(colors: [Colors.white, Color(0xFFEFF4FF)]),
          border: Border(bottom: BorderSide(color: Color(0x404B84F5), width: 2)),
          boxShadow: [BoxShadow(color: Color(0x1A1E3A8A), blurRadius: 14, offset: Offset(0, 5))],
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
