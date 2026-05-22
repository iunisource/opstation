import 'package:flutter/material.dart';

/// Cold-start splash overlay. Wraps the entire app and holds the brand
/// splash image full-screen for at least 3 seconds, then fades out to
/// reveal the actual app underneath.
///
/// flutter_native_splash only owns the launch window (a few hundred ms
/// during process init), and on Android 12+ the OS forces an icon-only
/// system splash. To guarantee a consistent, visible brand moment we
/// hold a Flutter-level overlay above the navigator on top of all that.
class StartupSplash extends StatefulWidget {
  final Widget child;
  const StartupSplash({super.key, required this.child});

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        IgnorePointer(
          ignoring: !_showSplash,
          child: AnimatedOpacity(
            opacity: _showSplash ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            child: Container(
              color: const Color(0xFF004AAD),
              // BoxFit.contain preserves the gear + text; the matching
              // blue background fills any letterbox space invisibly.
              child: Image.asset(
                'assets/splash/opstation_splash.png',
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
