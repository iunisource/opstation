import 'package:flutter/material.dart';

import 'login_scene.dart';
import 'login_video.dart';
import 'login_video_api.dart';

/// How the sign-in form is framed: a floating card beside the headline (wide screens), or a sheet rising
/// from the bottom of the screen (phones).
enum LoginFormFrame { card, sheet }

/// The video (or, failing that, the still picture) behind the login page, under a dark layer that keeps the
/// words readable.
class LoginBackdrop extends StatelessWidget {
  const LoginBackdrop({super.key, required this.controller, required this.src, required this.wide});

  final LoginVideoController controller;
  final String src;

  /// A wide screen may play the video; a narrow one (a phone) shows the still picture only.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const RepaintBoundary(child: CustomPaint(painter: LoginScenePainter())),
      if (wide) LoginVideoLayer(controller: controller, src: src),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: wide
              ? const LinearGradient(colors: [Color(0xE60B1220), Color(0x9E0B1220), Color(0x5C0B1220)], stops: [0, 0.52, 1])
              : const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x800B1220), Color(0xD10B1220)]),
        ),
      ),
    ]);
  }
}

/// Pause / play for the background video. It is only there while there is a video: a moving picture that
/// starts by itself must always be stoppable.
class LoginPauseButton extends StatelessWidget {
  const LoginPauseButton({super.key, required this.controller});

  final LoginVideoController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LoginVideoStatus>(
      valueListenable: controller.status,
      builder: (context, s, _) {
        if (s == LoginVideoStatus.off || s == LoginVideoStatus.loading) return const SizedBox.shrink();
        final paused = s == LoginVideoStatus.paused;
        return OutlinedButton.icon(
          onPressed: controller.toggle,
          icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
          label: Text(paused ? 'Play background' : 'Pause background'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0x8C0B1220),
            side: const BorderSide(color: Color(0x4DFFFFFF)),
            shape: const StadiumBorder(),
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          ),
        );
      },
    );
  }
}

/// The whole login page: the background, the brand (logo, headline, footer) and the sign-in form, arranged
/// for a wide screen (headline on the left, form on a card on the right) or a phone (short headline, form on
/// a sheet at the bottom).
class LoginShell extends StatelessWidget {
  const LoginShell({
    super.key,
    required this.controller,
    required this.logo,
    required this.headline,
    required this.compactHeadline,
    required this.footer,
    required this.retailerButton,
    required this.form,
    this.videoSrc = 'login_bg.mp4',
    this.wideAt = 900,
  });

  final LoginVideoController controller;
  final Widget logo;
  final Widget headline;
  final Widget compactHeadline;
  final Widget footer;
  final Widget Function(bool compact) retailerButton;
  final Widget Function(LoginFormFrame frame) form;
  final String videoSrc;
  final double wideAt;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) => c.maxWidth >= wideAt ? _wide() : _narrow(c));
  }

  Widget _wide() {
    return Stack(children: [
      Positioned.fill(child: LoginBackdrop(controller: controller, src: videoSrc, wide: true)),
      Positioned.fill(
        child: Column(children: [
          SizedBox(
            height: 74,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Padding(padding: const EdgeInsets.only(left: 48), child: logo),
              const Spacer(),
              Padding(padding: const EdgeInsets.only(right: 32), child: retailerButton(false)),
            ]),
          ),
          Expanded(
            child: Row(children: [
              Expanded(
                flex: 11,
                child: Padding(
                  padding: const EdgeInsets.only(left: 96, right: 24),
                  child: Align(alignment: Alignment.centerLeft, child: SingleChildScrollView(child: headline)),
                ),
              ),
              Expanded(
                flex: 9,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form(LoginFormFrame.card)),
                  ),
                ),
              ),
            ]),
          ),
          SizedBox(
            height: 64,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Padding(padding: const EdgeInsets.only(left: 48), child: footer),
              const Spacer(),
              Padding(padding: const EdgeInsets.only(right: 32), child: LoginPauseButton(controller: controller)),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _narrow(BoxConstraints c) {
    return Stack(children: [
      Positioned.fill(child: LoginBackdrop(controller: controller, src: videoSrc, wide: false)),
      Positioned.fill(
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 24),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    logo,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: retailerButton(true)),
                    const SizedBox(height: 22),
                    compactHeadline,
                  ]),
                ),
                Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form(LoginFormFrame.sheet))),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
