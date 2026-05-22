import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// A slide-to-confirm button: drag the thumb to the right to commit a
/// high-stakes action. Prevents accidental taps for operations like
/// "start delivery" or "complete delivery early" where a misfire is
/// costly.
///
/// Fires [onConfirmed] exactly once when the thumb reaches the right
/// edge. Parent is responsible for disabling the widget afterward
/// (e.g. replacing it with a loading indicator) — this widget does
/// NOT auto-reset.
class SlideToConfirm extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color? foregroundColor;
  final VoidCallback onConfirmed;
  final bool disabled;

  const SlideToConfirm({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onConfirmed,
    this.foregroundColor,
    this.disabled = false,
  });

  @override
  State<SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<SlideToConfirm>
    with SingleTickerProviderStateMixin {
  /// Current drag position, in [0, 1]. 0 = thumb at left, 1 = committed.
  double _progress = 0;

  /// Once true, [widget.onConfirmed] has been called and we ignore
  /// further drags. Parent will typically unmount / replace us.
  bool _fired = false;

  late AnimationController _springBack;

  static const double _thumbDiameter = 52;
  static const double _trackPadding = 4;

  @override
  void initState() {
    super.initState();
    _springBack = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() {
        setState(() {
          _progress = _springBack.value;
        });
      });
    // The LayoutBuilder occasionally gets stale constraints on the very
    // first build — e.g. when this slider replaces a different one
    // inside the bottomNavigationBar after a status change (assigned →
    // in_progress). Without this, the new slider renders with an
    // incorrect width until the user navigates away and back.
    // Forcing one rebuild after the first frame settles the layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _springBack.dispose();
    super.dispose();
  }

  void _release() {
    if (_fired) return;
    // Spring back to 0 from wherever the drag left us.
    _springBack.value = _progress;
    _springBack.animateTo(0, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.foregroundColor ?? Colors.white;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final maxThumbLeft = trackWidth - _thumbDiameter - _trackPadding * 2;
        final thumbLeft = _trackPadding + _progress * maxThumbLeft;

        return GestureDetector(
          // Use pan (not horizontal drag) so a straight-across motion is
          // honored even if the user's finger wobbles a bit.
          onPanStart: widget.disabled
              ? null
              : (_) {
                  if (_fired) return;
                  _springBack.stop();
                },
          onPanUpdate: widget.disabled
              ? null
              : (details) {
                  if (_fired) return;
                  _springBack.stop();
                  final delta = details.delta.dx / maxThumbLeft;
                  final next = (_progress + delta).clamp(0.0, 1.0);
                  setState(() => _progress = next);
                  if (next >= 1.0) {
                    _fired = true;
                    widget.onConfirmed();
                  }
                },
          onPanEnd: widget.disabled ? null : (_) => _release(),
          onPanCancel: widget.disabled ? null : _release,
          child: Container(
            // Explicit width prevents the Stack from collapsing when
            // all its children are Positioned, which was making the
            // thumb render in the wrong spot on some layouts.
            width: trackWidth,
            height: _thumbDiameter + _trackPadding * 2,
            decoration: BoxDecoration(
              color: widget.color.withOpacity(widget.disabled ? 0.4 : 1.0),
              borderRadius: BorderRadius.circular(32),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Centered label. Fades out as the user drags.
                Positioned.fill(
                  child: Center(
                    child: Opacity(
                      opacity: (1.0 - _progress).clamp(0.0, 1.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              widget.label,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: fg,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.arrow_forward, color: fg, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
                // The draggable thumb.
                Positioned(
                  left: thumbLeft,
                  top: _trackPadding,
                  child: Container(
                    width: _thumbDiameter,
                    height: _thumbDiameter,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      widget.icon,
                      color: widget.color,
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
