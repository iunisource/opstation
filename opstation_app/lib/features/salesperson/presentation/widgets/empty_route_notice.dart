import 'package:flutter/material.dart';

/// Shown on a running route that has no customers on the phone: it says so, and gives a button that
/// fetches them again, instead of leaving an empty screen.
class EmptyRouteNotice extends StatelessWidget {
  const EmptyRouteNotice({super.key, required this.refreshing, required this.onRefresh});

  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.info_outline, color: Color(0xFFB45309), size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text('No customers on this route yet',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF92400E))),
          ),
        ]),
        const SizedBox(height: 6),
        const Text(
          'The customers of this route have not reached your phone. Tap Refresh customers with your internet on. '
          'If they still do not appear, tell your manager.',
          style: TextStyle(fontSize: 13, color: Color(0xFF92400E)),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: refreshing ? null : onRefresh,
          icon: refreshing
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.refresh, size: 18),
          label: Text(refreshing ? 'Refreshing...' : 'Refresh customers'),
        ),
      ]),
    );
  }
}
