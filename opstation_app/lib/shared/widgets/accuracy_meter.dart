import 'package:flutter/material.dart';

// ---- GPS accuracy health meter ----------------------------------------

/// A 4-segment signal-strength-style meter that grades a captured fix's
/// accuracy so a surveyor can tell at a glance whether the pin is trustworthy
/// or worth re-capturing. Bands (radius in metres):
///   <=10  Excellent (4)   <=25 Good (3)   <=50 Fair (2)   >50 Poor (1)
/// A stale (last-known) fix is shown greyed at one bar regardless of radius.
class AccuracyMeter extends StatelessWidget {
  final double accuracyMeters;
  final bool stale;
  const AccuracyMeter({super.key, required this.accuracyMeters, this.stale = false});

  int get _band {
    if (accuracyMeters <= 10) return 4;
    if (accuracyMeters <= 25) return 3;
    if (accuracyMeters <= 50) return 2;
    return 1;
  }

  String get _label {
    if (stale) return 'Last known';
    switch (_band) {
      case 4:
        return 'Excellent';
      case 3:
        return 'Good';
      case 2:
        return 'Fair';
      default:
        return 'Poor';
    }
  }

  Color get _color {
    if (stale) return const Color(0xFF6B7280); // grey
    switch (_band) {
      case 4:
        return const Color(0xFF16A34A); // green
      case 3:
        return const Color(0xFF22C55E); // light green
      case 2:
        return const Color(0xFFF59E0B); // amber
      default:
        return const Color(0xFFDC2626); // red
    }
  }

  @override
  Widget build(BuildContext context) {
    final filled = stale ? 1 : _band;
    return Row(
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            margin: const EdgeInsets.only(right: 4),
            width: 20,
            height: 8,
            decoration: BoxDecoration(
              color: i < filled ? _color : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$_label  ·  ±${accuracyMeters.round()}m',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _color,
            ),
          ),
        ),
      ],
    );
  }
}

