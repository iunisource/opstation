import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'responsive.dart';

/// Master-detail that stops pretending a phone is a desktop.
///
/// Desktop/tablet: list and detail side by side, as now.
/// Mobile:         the list fills the screen. Selecting an item pushes the detail
///                 as a full route with a back button — the standard phone idiom.
///                 Cramming a 300px list next to a detail pane on a 380px screen
///                 leaves 80px for the detail, which is what makes the current
///                 Employees and Job Cards screens unusable.
///
/// The screen keeps owning its own selection state; this widget only decides how
/// to present it. [selected] tells us whether a detail exists, and [onClose] lets
/// the screen clear its selection when the user backs out — otherwise returning
/// to the list would immediately re-push the detail.
class AdaptiveMasterDetail extends StatefulWidget {
  final Widget list;
  final Widget? detail;

  /// Non-null when something is selected. Changing this on mobile is what
  /// triggers the push.
  final Object? selected;

  /// Called when the user backs out of the detail on mobile.
  final VoidCallback? onClose;

  /// Title for the mobile detail app bar.
  final String detailTitle;

  final double listWidth;

  /// Shown in the detail pane on desktop when nothing is selected.
  final Widget? placeholder;

  const AdaptiveMasterDetail({
    super.key,
    required this.list,
    required this.detail,
    required this.selected,
    this.onClose,
    this.detailTitle = 'Details',
    this.listWidth = 300,
    this.placeholder,
  });

  @override
  State<AdaptiveMasterDetail> createState() => _AdaptiveMasterDetailState();
}

class _AdaptiveMasterDetailState extends State<AdaptiveMasterDetail> {
  bool _detailRouteOpen = false;

  @override
  void didUpdateWidget(AdaptiveMasterDetail old) {
    super.didUpdateWidget(old);
    if (!context.isMobile) return;
    // A newly-selected item on mobile opens the detail route.
    if (widget.selected != null &&
        widget.selected != old.selected &&
        !_detailRouteOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pushDetail());
    }
  }

  Future<void> _pushDetail() async {
    if (!mounted || widget.detail == null) return;
    _detailRouteOpen = true;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _MobileDetailPage(
          title: widget.detailTitle,
          // Rebuilds with the live detail rather than a stale snapshot, so edits
          // and saves inside the detail are reflected.
          builder: () => widget.detail ?? const SizedBox.shrink(),
        ),
      ),
    );
    _detailRouteOpen = false;
    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (context.isCompact) {
      // The list IS the page. The detail lives on its own route.
      return Container(color: AppTheme.background, child: widget.list);
    }

    return Container(
      color: AppTheme.background,
      child: Row(children: [
        SizedBox(width: widget.listWidth, child: widget.list),
        Expanded(
          child: widget.detail ??
              widget.placeholder ??
              const Center(
                child: Text('Select an item',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
        ),
      ]),
    );
  }
}

class _MobileDetailPage extends StatefulWidget {
  final String title;
  final Widget Function() builder;
  const _MobileDetailPage({required this.title, required this.builder});

  @override
  State<_MobileDetailPage> createState() => _MobileDetailPageState();
}

class _MobileDetailPageState extends State<_MobileDetailPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(widget.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      body: widget.builder(),
    );
  }
}

/// KPI cards that wrap instead of crushing.
///
/// The current screens put 5 cards in a Row, so on a phone each gets ~70px and
/// the labels stack one letter per line ("O-v-e-r-d-u-e"). Wrap gives each card
/// a sane minimum and flows to the next line.
class AdaptiveKpiRow extends StatelessWidget {
  final List<Widget> children;
  final double minCardWidth;

  const AdaptiveKpiRow({
    super.key,
    required this.children,
    this.minCardWidth = 150,
  });

  @override
  Widget build(BuildContext context) {
    if (!context.isMobile) {
      return Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            Expanded(child: children[i]),
            if (i < children.length - 1) const SizedBox(width: 12),
          ],
        ],
      );
    }
    // Two per row on a phone: readable, and keeps the block from pushing the
    // actual content below the fold.
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 10) / 2;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final child in children) SizedBox(width: w, child: child),
        ],
      );
    });
  }
}
