import 'package:flutter/material.dart';

import 'login_video_api.dart';

/// Outside the browser (tests, other platforms) there is no video: the still background is all there is.
class LoginVideoLayer extends StatelessWidget {
  const LoginVideoLayer({super.key, required this.controller, required this.src});

  final LoginVideoController controller;
  final String src;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
