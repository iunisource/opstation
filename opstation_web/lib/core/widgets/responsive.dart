import 'package:flutter/material.dart';

/// Breakpoints for the ERP web app.
///
/// These are not arbitrary: 600 is where a phone in portrait stops being able to
/// hold two columns of content, and 1024 is where the sidebar plus a master-detail
/// pane stop competing for width. Everything else follows from those two facts.
class Breakpoints {
  static const double mobile = 600;
  static const double tablet = 1024;
}

enum ScreenSize { mobile, tablet, desktop }

extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.sizeOf(this).width;

  ScreenSize get screenSize {
    final w = screenWidth;
    if (w < Breakpoints.mobile) return ScreenSize.mobile;
    if (w < Breakpoints.tablet) return ScreenSize.tablet;
    return ScreenSize.desktop;
  }

  bool get isMobile => screenSize == ScreenSize.mobile;
  bool get isTablet => screenSize == ScreenSize.tablet;
  bool get isDesktop => screenSize == ScreenSize.desktop;

  /// True when a side-by-side master-detail layout will not fit. Tablets are
  /// included because the nav rail plus a list plus a detail pane leaves the
  /// detail too narrow to be useful.
  bool get isCompact => screenWidth < Breakpoints.tablet;

  /// Page padding that does not waste a phone's limited width.
  EdgeInsets get pagePadding => isMobile
      ? const EdgeInsets.all(12)
      : const EdgeInsets.all(28);

  /// Horizontal padding for list rows and table cells.
  double get rowPadding => isMobile ? 12 : 16;
}

/// Builds different widgets per screen size without repeating MediaQuery lookups.
///
/// [tablet] falls back to [desktop] when omitted, and [desktop] is required —
/// so an existing desktop layout can be wrapped and a mobile variant added
/// incrementally, rather than needing all three up front.
class Adaptive extends StatelessWidget {
  final WidgetBuilder mobile;
  final WidgetBuilder? tablet;
  final WidgetBuilder desktop;

  const Adaptive({
    super.key,
    required this.mobile,
    required this.desktop,
    this.tablet,
  });

  @override
  Widget build(BuildContext context) {
    switch (context.screenSize) {
      case ScreenSize.mobile:
        return mobile(context);
      case ScreenSize.tablet:
        return (tablet ?? desktop)(context);
      case ScreenSize.desktop:
        return desktop(context);
    }
  }
}
