import 'package:flutter/material.dart';

import 'login_scene.dart';
import 'login_video.dart';
import 'login_video_api.dart';

/// How the sign-in form is framed: a floating card beside the headline (wide screens), or a sheet rising
/// from the bottom of the screen (phones).
enum LoginFormFrame { card, sheet, bar }

/// The video (or, failing that, the still picture) behind the login page, under a dark layer that keeps the
/// words readable.
class LoginBackdrop extends StatelessWidget {
  const LoginBackdrop({super.key, required this.controller, required this.src, required this.wide, this.useVideo = false});

  /// Off by default: the drifting trails are the background. Turn on to play the video over them.
  final bool useVideo;

  final LoginVideoController controller;
  final String src;

  /// A wide screen may play the video; a narrow one (a phone) shows the still picture only.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const LoginTrails(),
      if (wide && useVideo) LoginVideoLayer(controller: controller, src: src),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: wide
              ? const LinearGradient(colors: [Color(0xCC0B1220), Color(0x850B1220), Color(0x420B1220)], stops: [0, 0.52, 1])
              : const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x660B1220), Color(0xB30B1220)]),
        ),
      ),
      if (wide) const LoginRoadTruck(),
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
        final style = OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color(0x8C0B1220),
          side: const BorderSide(color: Color(0x4DFFFFFF)),
          shape: const StadiumBorder(),
          minimumSize: const Size(44, 44),
          padding: EdgeInsets.zero,
        );
        final playBtn = OutlinedButton.icon(
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
        final muteBtn = ValueListenableBuilder<bool>(
          valueListenable: controller.muted,
          builder: (context, m, _) => Tooltip(
            message: m ? 'Sound on' : 'Mute',
            child: OutlinedButton(
              onPressed: controller.mute,
              style: style,
              child: Icon(m ? Icons.volume_off_rounded : Icons.volume_up_rounded, size: 20),
            ),
          ),
        );
        return Row(mainAxisSize: MainAxisSize.min, children: [playBtn, const SizedBox(width: 8), muteBtn]);
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
    this.videoSrc = 'login_bg_v5.mp4',
    this.useVideo = false,
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
  final bool useVideo;
  final double wideAt;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) => c.maxWidth >= wideAt ? _wide() : _narrow(c));
  }

  Widget _wide() {
    // Logo and the retailer button along the top, the headline on the left and a solid sign-in card mid-right.
    return Stack(children: [
      Positioned.fill(child: LoginBackdrop(controller: controller, src: videoSrc, wide: true, useVideo: useVideo)),
      Positioned.fill(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 28, 48, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              logo,
              const Spacer(),
              retailerButton(false),
            ]),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 12, 72, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(child: Align(alignment: Alignment.centerLeft, child: SingleChildScrollView(child: headline))),
                const SizedBox(width: 32),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Center(child: SingleChildScrollView(child: form(LoginFormFrame.card))),
                ),
              ]),
            ),
          ),
          SizedBox(
            height: 72,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Padding(padding: const EdgeInsets.only(left: 48), child: footer),
              const Spacer(),
              Padding(padding: const EdgeInsets.only(right: 48), child: useVideo ? LoginPauseButton(controller: controller) : const SizedBox.shrink()),
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
