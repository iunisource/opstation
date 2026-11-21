import 'package:flutter/material.dart';

/// "Mark visit" on a free route: opens the camera, takes the picture (stamped with the
/// coordinates) and marks the visit at the point the phone is at — one button for both.
class FreeVisitButton extends StatelessWidget {
  const FreeVisitButton({super.key, required this.busy, required this.onPressed, this.step});

  final bool busy;
  final VoidCallback onPressed;

  /// What it is doing while [busy] ("Getting your location..."), so a slow step is never an endless spinner.
  final String? step;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Take a picture and mark the visit here',
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: busy ? null : onPressed,
          icon: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.photo_camera_outlined, size: 18),
          label: Text(busy && step != null && step!.isNotEmpty ? step! : 'Mark visit'),
        ),
      ),
    );
  }
}
