import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A master-detail layout where the left list panel can be collapsed
/// with an animated toggle strip, giving the detail area full width.
class CollapsibleListPane extends StatefulWidget {
  final Widget listChild;
  final Widget detailChild;
  final double paneWidth;

  const CollapsibleListPane({
    super.key,
    required this.listChild,
    required this.detailChild,
    this.paneWidth = 300,
  });

  @override
  State<CollapsibleListPane> createState() => _CollapsibleListPaneState();
}

class _CollapsibleListPaneState extends State<CollapsibleListPane> {
  bool _collapsed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      // ── Animated list panel ──────────────────────────────────────────────
      AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        width: _collapsed ? 0 : widget.paneWidth,
        clipBehavior: Clip.hardEdge,
        decoration: const BoxDecoration(color: Colors.white),
        child: widget.listChild,
      ),

      // ── Collapse / expand toggle strip ──────────────────────────────────
      MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: () => setState(() => _collapsed = !_collapsed),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 16,
            color: _hovered
                ? AppTheme.primary.withOpacity(0.10)
                : AppTheme.border.withOpacity(0.6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Top grip dots
                Container(width: 3, height: 3, decoration: BoxDecoration(
                  color: _hovered ? AppTheme.primary : AppTheme.sidebarText,
                  borderRadius: BorderRadius.circular(1.5),
                )),
                const SizedBox(height: 3),
                Container(width: 3, height: 3, decoration: BoxDecoration(
                  color: _hovered ? AppTheme.primary : AppTheme.sidebarText,
                  borderRadius: BorderRadius.circular(1.5),
                )),
                const SizedBox(height: 8),
                // Chevron
                Icon(
                  _collapsed ? Icons.chevron_right : Icons.chevron_left,
                  size: 14,
                  color: _hovered ? AppTheme.primary : AppTheme.textSecondary,
                ),
                const SizedBox(height: 8),
                // Bottom grip dots
                Container(width: 3, height: 3, decoration: BoxDecoration(
                  color: _hovered ? AppTheme.primary : AppTheme.sidebarText,
                  borderRadius: BorderRadius.circular(1.5),
                )),
                const SizedBox(height: 3),
                Container(width: 3, height: 3, decoration: BoxDecoration(
                  color: _hovered ? AppTheme.primary : AppTheme.sidebarText,
                  borderRadius: BorderRadius.circular(1.5),
                )),
              ],
            ),
          ),
        ),
      ),

      // ── Detail panel (always takes remaining space) ──────────────────────
      Expanded(
        child: Container(
          color: AppTheme.background,
          child: widget.detailChild,
        ),
      ),
    ]);
  }
}
