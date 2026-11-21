import 'package:flutter/material.dart';

/// Shows "Generating report..." over the whole page while [job] runs, so it is clear something is
/// happening (looking up place names and distances can take a few seconds). The page behind cannot be
/// tapped meanwhile — no second report is started by mistake. It always goes away: when the job
/// finishes, and also when it fails (the error then carries on to the caller as usual).
Future<T> withGenerating<T>(BuildContext context, Future<T> Function() job, {String message = 'Generating report...'}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  OverlayEntry? entry;
  if (overlay != null) {
    entry = OverlayEntry(builder: (_) => GeneratingCard(message: message));
    overlay.insert(entry);
  }
  try {
    return await job();
  } finally {
    try {
      entry?.remove();
    } catch (_) {} // the page was closed meanwhile: nothing left to remove
  }
}

class GeneratingCard extends StatelessWidget {
  const GeneratingCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      const ModalBarrier(dismissible: false, color: Color(0x59000000)),
      Center(
        child: Semantics(
          liveRegion: true,
          label: message,
          child: Material(
            color: Colors.white,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(height: 16),
                Text(message, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 4),
                const Text('This can take a few seconds', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}
