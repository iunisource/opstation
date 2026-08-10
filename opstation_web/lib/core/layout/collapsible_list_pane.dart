import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A master-detail layout where the left list panel can be collapsed
/// with an animated toggle strip, giving the detail area full width.
class CollapsibleListPane extends StatefulWidget {
  final Widget listChild;
  final Widget detailChild;
  final double paneWidth;

  /// Opt-in responsive behaviour. When [onBack] is provided AND the viewport is
  /// narrow (phone), the pane shows ONE panel at a time instead of squeezing the
  /// detail into a sliver: the list when nothing is selected, or the detail
  /// (with a back bar) when [detailActive] is true. Screens that don't pass
  /// [onBack] keep the original side-by-side layout unchanged.
  final bool detailActive;
  final VoidCallback? onBack;

  const CollapsibleListPane({
    super.key,
    required this.listChild,
    required this.detailChild,
    this.paneWidth = 300,
    this.detailActive = false,
    this.onBack,
  });

  @override
  State<CollapsibleListPane> createState() => _CollapsibleListPaneState();
}

class _CollapsibleListPaneState extends State<CollapsibleListPane> {
  bool _collapsed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      // Phone: opted-in screens show a single panel at a time so the detail
      // gets the full width (fixes the squished, character-wrapped header).
      if (widget.onBack != null && cons.maxWidth < 700) {
        if (widget.detailActive) {
          return Column(children: [
            Material(
              color: Colors.white,
              child: InkWell(
                onTap: widget.onBack,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: AppTheme.border))),
                  child: Row(children: const [
                    Icon(Icons.arrow_back, size: 18, color: AppTheme.primary),
                    SizedBox(width: 8),
                    Text('Back to list',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.primary)),
                  ]),
                ),
              ),
            ),
            Expanded(child: Container(color: AppTheme.background, child: widget.detailChild)),
          ]);
        }
        return Container(color: Colors.white, child: widget.listChild);
      }
      return _wide();
    });
  }

  Widget _wide() {
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
