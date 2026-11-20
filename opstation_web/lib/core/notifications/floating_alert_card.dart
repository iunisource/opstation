import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'floating_alerts_model.dart';

/// One floating alert: type tile, title, message, time, Open, a close cross and a
/// countdown bar. It tells its owner when the time is up ([onExpired]); the owner
/// removes it.
class FloatingAlertCard extends StatefulWidget {
  const FloatingAlertCard({
    super.key,
    required this.alert,
    required this.seconds,
    required this.pauseOnHover,
    required this.onClose,
    required this.onOpen,
    required this.onExpired,
  });

  final FloatingAlert alert;
  final int seconds;
  final bool pauseOnHover;
  final VoidCallback onClose;
  final VoidCallback onOpen;
  final VoidCallback onExpired;

  @override
  State<FloatingAlertCard> createState() => _FloatingAlertCardState();
}

class _FloatingAlertCardState extends State<FloatingAlertCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _hover = false;
  bool _focus = false;

  static (Color bg, Color fg, Color bar, IconData icon) _look(AlertKind k) {
    switch (k) {
      case AlertKind.action:
        return (const Color(0xFFFEF3C7), const Color(0xFFB45309), const Color(0xFFF59E0B), Icons.assignment_turned_in_outlined);
      case AlertKind.success:
        return (const Color(0xFFD1FAE5), const Color(0xFF047857), const Color(0xFF10B981), Icons.check_circle_outline);
      case AlertKind.problem:
        return (const Color(0xFFFEE2E2), const Color(0xFFB91C1C), const Color(0xFFEF4444), Icons.cancel_outlined);
      case AlertKind.info:
        return (const Color(0xFFDBEAFE), const Color(0xFF1D4ED8), const Color(0xFF2F6FED), Icons.info_outline);
    }
  }

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: Duration(seconds: widget.seconds), value: 1.0);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.dismissed) widget.onExpired();
    });
    _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  bool get _paused => widget.pauseOnHover && (_hover || _focus);

  void _sync() {
    if (_paused) {
      _c.stop();
    } else if (!_c.isAnimating && _c.value > 0) {
      _c.reverse();
    }
  }

  String _ago() {
    final d = widget.alert.createdAt;
    if (d == null) return 'just now';
    final s = DateTime.now().difference(d.toLocal()).inSeconds;
    if (s < 10) return 'just now';
    if (s < 60) return '$s s ago';
    return 'earlier';
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alert;
    final (bg, fg, bar, icon) = _look(a.kind);
    final compact = MediaQuery.of(context).size.width < 600;
    final hasLink = (a.link ?? '').isNotEmpty && !(a.link ?? '').startsWith('http');
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset((1 - t) * 24, 0), child: child)),
      child: MouseRegion(
        onEnter: (_) {
          _hover = true;
          _sync();
        },
        onExit: (_) {
          _hover = false;
          _sync();
        },
        child: Focus(
          canRequestFocus: false,
          onFocusChange: (f) {
            _focus = f;
            _sync();
          },
          child: Semantics(
            liveRegion: true,
            container: true,
            label: '${a.title}. ${a.body}',
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
                boxShadow: [BoxShadow(color: const Color(0xFF0F172A).withOpacity(_paused ? 0.28 : 0.18), blurRadius: _paused ? 34 : 28, offset: const Offset(0, 10))],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Material(
                  color: Colors.white,
                  child: InkWell(
                    onTap: hasLink ? widget.onOpen : null,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(14, 14, compact ? 2 : 6, 12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
                          child: Icon(icon, size: 20, color: fg),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(a.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, height: 1.3, color: AppTheme.textPrimary)),
                            if (a.body.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(a.body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppTheme.textSecondary)),
                              ),
                            const SizedBox(height: 6),
                            Row(children: [
                              Text(_ago(), style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
                              if (hasLink) ...[
                                const SizedBox(width: 12),
                                TextButton(
                                  onPressed: widget.onOpen,
                                  style: TextButton.styleFrom(
                                    padding: EdgeInsets.symmetric(vertical: compact ? 6 : 0),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    foregroundColor: const Color(0xFF1D4ED8),
                                  ),
                                  child: const Text('Open', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ]),
                          ]),
                        ),
                        IconButton(
                          tooltip: 'Dismiss',
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.close, size: 16),
                          color: AppTheme.textSecondary,
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints.tightFor(width: compact ? 44 : 28, height: compact ? 44 : 28),
                        ),
                      ]),
                    ),
                  ),
                ),
                Container(
                  height: 3,
                  color: const Color(0xFFF1F5F9),
                  alignment: Alignment.centerLeft,
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) => FractionallySizedBox(widthFactor: _c.value.clamp(0.0, 1.0), child: Container(height: 3, color: bar)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
