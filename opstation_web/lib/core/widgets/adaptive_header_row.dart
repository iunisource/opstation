import 'package:flutter/material.dart';

/// A voucher header: the title (and its status chips) on the left, the action
/// buttons on the right.
///
/// Wide: exactly a [Row] of [children], as the screens always had.
/// Narrow (a phone, or a squeezed panel): the actions no longer fit beside the
/// title and used to overflow off the edge. They move under the title and wrap.
///
/// How the children are read (the same list the screen already passes to a Row):
///  * the title group is everything before the first [Spacer] / [Expanded];
///    when the FIRST child is an [Expanded] it is the title itself;
///  * with neither, the first child is the title;
///  * the rest are actions. Plain spacers ([SizedBox] without a child, [Spacer])
///    are dropped, and an [Expanded]/[Flexible] is unwrapped — a Wrap can't hold one.
class AdaptiveHeaderRow extends StatelessWidget {
  const AdaptiveHeaderRow({
    super.key,
    required this.children,
    this.breakpoint = 640,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final List<Widget> children;
  final double breakpoint;
  final CrossAxisAlignment crossAxisAlignment;

  static bool _isSpacer(Widget w) => w is Spacer || (w is SizedBox && w.child == null);
  static Widget _unwrap(Widget w) => w is Flexible ? w.child : w;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      if (!cons.maxWidth.isFinite || cons.maxWidth >= breakpoint || children.isEmpty) {
        return Row(crossAxisAlignment: crossAxisAlignment, children: children);
      }
      List<Widget> title;
      List<Widget> actions;
      final firstFlex = children.indexWhere((w) => w is Spacer || w is Expanded);
      if (firstFlex == 0 && children.first is Expanded) {
        title = [_unwrap(children.first)];
        actions = children.sublist(1);
      } else if (firstFlex > 0) {
        title = children.sublist(0, firstFlex);
        actions = children.sublist(firstFlex + 1);
      } else {
        title = [children.first];
        actions = children.sublist(1);
      }
      final t = [for (final w in title) if (!_isSpacer(w)) _unwrap(w)];
      final a = [for (final w in actions) if (!_isSpacer(w)) _unwrap(w)];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (t.length == 1) t.first else Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: t),
        if (a.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: a),
        ],
      ]);
    });
  }
}

/// A search box (fixed width on a desktop) with filters beside it. On a phone the
/// search takes the whole width and the filters wrap beneath it, instead of the
/// fixed-width search plus the filters overflowing the screen.
class AdaptiveFilterRow extends StatelessWidget {
  const AdaptiveFilterRow({
    super.key,
    required this.search,
    this.trailing = const [],
    this.searchWidth = 340,
    this.breakpoint = 700,
  });

  final Widget search;
  final List<Widget> trailing;
  final double searchWidth;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      if (!cons.maxWidth.isFinite || cons.maxWidth >= breakpoint) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: searchWidth, child: search),
          for (final t in trailing) ...[const SizedBox(width: 12), t],
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        search,
        if (trailing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: trailing),
        ],
      ]);
    });
  }
}
