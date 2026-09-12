import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A brief celebratory "Organization Switched" overlay, shown right before the
/// app reloads into the newly-selected org. It self-dismisses; callers fire it
/// (without awaiting), run the switch, then reload the page.
Future<void> showOrgSwitchedAnimation(BuildContext context, String orgName) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'org-switched',
    barrierColor: Colors.black.withOpacity(0.42),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => _SwitchedCard(orgName: orgName),
  );
}

class _SwitchedCard extends StatefulWidget {
  final String orgName;
  const _SwitchedCard({required this.orgName});
  @override
  State<_SwitchedCard> createState() => _SwitchedCardState();
}

class _SwitchedCardState extends State<_SwitchedCard> {
  @override
  void initState() {
    super.initState();
    // Auto-close in case the reload is slow or does not fire.
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 460),
        curve: Curves.easeOutBack,
        builder: (_, t, __) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.82 + 0.18 * t.clamp(0.0, 1.0), child: _card()),
        ),
      ),
    );
  }

  Widget _card() {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 26),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 40,
                offset: const Offset(0, 16)),
          ],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 520),
            curve: Curves.easeOutBack,
            builder: (_, t, __) => Transform.scale(
              scale: t.clamp(0.0, 1.0),
              child: Container(
                height: 58,
                width: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.success.withOpacity(0.12),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.check_circle_rounded,
                    color: AppTheme.success, size: 40),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Organization switched',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            'Loading ${widget.orgName}…',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ]),
      ),
    );
  }
}
