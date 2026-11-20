import 'package:flutter/material.dart';

/// The two buttons of a free route: "Mark visit here" (the GPS point is the visit) and
/// "Photo" (opens the camera, then marks the visit here with the picture, stamped with
/// the coordinates).
class FreeVisitButtons extends StatelessWidget {
  const FreeVisitButtons({super.key, required this.busy, required this.onMark, required this.onPhoto});

  final bool busy;
  final VoidCallback onMark;
  final VoidCallback onPhoto;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        flex: 5,
        child: OutlinedButton.icon(
          onPressed: busy ? null : onMark,
          icon: busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.place_outlined, size: 18),
          label: const Text('Mark visit here'),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        flex: 3,
        child: Tooltip(
          message: 'Take a picture and mark the visit here',
          child: OutlinedButton.icon(
            onPressed: busy ? null : onPhoto,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('Photo'),
          ),
        ),
      ),
    ]);
  }
}
