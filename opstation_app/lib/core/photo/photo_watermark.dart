import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Burns a small dark panel with location coordinates and a timestamp
/// into the bottom-right corner of the JPEG. Returns the watermarked
/// bytes; if the input cannot be decoded, returns the input unchanged
/// so the caller still has something to upload.
class PhotoWatermark {
  static Uint8List addWatermark({
    required Uint8List jpegBytes,
    required double latitude,
    required double longitude,
    required DateTime timestamp,
  }) {
    final image = img.decodeJpg(jpegBytes);
    if (image == null) return jpegBytes;

    final coords =
        '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
    final ts = _formatTs(timestamp);

    // arial_24 reads cleanly on our 1600px target without dominating
    // the frame. arial_48 would be too aggressive.
    final font = img.arial24;
    const lineHeight = 28;
    const padding = 10;
    const margin = 16;

    final longestLen = coords.length > ts.length ? coords.length : ts.length;
    final textWidth =
        (longestLen * 12).clamp(80, image.width - margin * 2);
    final panelW = textWidth + padding * 2;
    final panelH = lineHeight * 2 + padding * 2;

    final x1 = (image.width - panelW - margin).clamp(0, image.width).toInt();
    final y1 = (image.height - panelH - margin).clamp(0, image.height).toInt();
    final x2 = (image.width - margin).clamp(0, image.width).toInt();
    final y2 = (image.height - margin).clamp(0, image.height).toInt();

    img.fillRect(
      image,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      color: img.ColorRgba8(0, 0, 0, 180),
    );

    img.drawString(
      image,
      coords,
      font: font,
      x: x1 + padding,
      y: y1 + padding,
      color: img.ColorRgba8(255, 255, 255, 255),
    );
    img.drawString(
      image,
      ts,
      font: font,
      x: x1 + padding,
      y: y1 + padding + lineHeight,
      color: img.ColorRgba8(255, 255, 255, 255),
    );

    return Uint8List.fromList(img.encodeJpg(image, quality: 85));
  }

  static String _formatTs(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
