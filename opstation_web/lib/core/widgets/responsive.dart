import 'package:flutter/material.dart';

/// Wraps wide table-style content so it stays full-width on desktop but keeps a
/// readable [minWidth] and scrolls horizontally on narrow (phone) viewports,
/// instead of squishing every column to a few pixels.
///
/// Use it around a table block (a header Row + the list of data Rows that share
/// the same flex columns) so the header and rows scroll together and stay
/// aligned. Above [breakpoint] the child is returned untouched, so existing
/// desktop layouts are unaffected.
class HScrollOnNarrow extends StatelessWidget {
  const HScrollOnNarrow({
    super.key,
    required this.child,
    this.minWidth = 760,
    this.breakpoint = 700,
  });

  final Widget child;
  final double minWidth;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Enough room already — behave exactly as before.
        if (constraints.maxWidth >= minWidth || constraints.maxWidth >= breakpoint) {
          return child;
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: minWidth, child: child),
        );
      },
    );
  }
}

/// True when the current view is phone-width. Handy for choosing a stacked
/// card layout over a table.
bool isNarrow(BuildContext context, {double breakpoint = 700}) =>
    MediaQuery.of(context).size.width < breakpoint;
