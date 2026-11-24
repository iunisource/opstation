import 'package:flutter/material.dart';

/// The small "ERP" tag shown after the Opstation name next to the logo, the same as on the sign-in page.
/// [dark] is for dark or photo backgrounds (sign-in, sign-up panel, retailer portal); the light version is for white bars.
class ErpPill extends StatelessWidget {
  const ErpPill({super.key, this.dark = true});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withOpacity(0.08) : const Color(0xFF2F6FED).withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: dark ? Colors.white.withOpacity(0.18) : const Color(0xFF2F6FED).withOpacity(0.25)),
      ),
      child: Text('ERP',
          style: TextStyle(
              color: dark ? const Color(0xFF9DBBFA) : const Color(0xFF1F55C4),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2)),
    );
  }
}
