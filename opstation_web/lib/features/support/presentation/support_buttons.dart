import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import 'request_callback_button.dart' show showRequestCallbackDialog;

const kAndroidAppUrl =
    'https://drive.google.com/drive/folders/1QczU7LCACXQwuq_RKts7uki1i-arYwbv?usp=sharing';

Future<void> openAndroidApp(BuildContext context) async {
  try {
    await launchUrl(Uri.parse(kAndroidAppUrl), mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open the download link.')));
    }
  }
}

/// Dashboard-only support buttons (Request a call back / Get the Android app).
/// Desktop: two stacked pills with a Hide control. Mobile: a round FAB that
/// expands. Dismissable — stays hidden until the next login.
class SupportButtons extends ConsumerStatefulWidget {
  const SupportButtons({super.key});
  @override
  ConsumerState<SupportButtons> createState() => _State();
}

class _State extends ConsumerState<SupportButtons> {
  bool _expanded = false;

  void _hide() => ref.read(supportButtonsHiddenProvider.notifier).state = true;

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(currentUserProvider)?.role;
    final isAdmin = role == WebUserRole.masterAdmin || role == WebUserRole.admin;
    if (!isAdmin) return const SizedBox.shrink();
    if (ref.watch(supportButtonsHiddenProvider)) return const SizedBox.shrink();
    if (GoRouterState.of(context).matchedLocation != '/dashboard') return const SizedBox.shrink();

    final mobile = MediaQuery.of(context).size.width < 600;

    if (!mobile) {
      return Positioned(
        right: 20, bottom: 20,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          _hideChip(),
          const SizedBox(height: 8),
          _callbackPill(),
          const SizedBox(height: 10),
          _downloadPill(),
        ]),
      );
    }

    // Mobile: round FAB that expands.
    return Positioned(
      right: 16, bottom: 16,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (_expanded) ...[
          _hideChip(),
          const SizedBox(height: 8),
          _callbackPill(),
          const SizedBox(height: 10),
          _downloadPill(),
          const SizedBox(height: 12),
        ],
        _fab(),
      ]),
    );
  }

  Widget _fab() => Material(
        color: AppTheme.primary,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => setState(() => _expanded = !_expanded),
          child: SizedBox(
            width: 56, height: 56,
            child: Icon(_expanded ? Icons.close : Icons.support_agent, color: Colors.white, size: 26),
          ),
        ),
      );

  Widget _hideChip() => Material(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _hide,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.close, color: Colors.white, size: 13),
              SizedBox(width: 4),
              Text('Hide', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );

  Widget _pill({required Color color, required IconData icon, required Color iconColor,
      required String label, required VoidCallback onTap}) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(30),
      elevation: 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }

  Widget _callbackPill() => _pill(
        color: AppTheme.primary, icon: Icons.support_agent, iconColor: Colors.white,
        label: 'Request a call back',
        onTap: () { if (mounted) setState(() => _expanded = false); showRequestCallbackDialog(context, ref); },
      );

  Widget _downloadPill() => _pill(
        color: AppTheme.textPrimary, icon: Icons.android, iconColor: const Color(0xFF3DDC84),
        label: 'Get the Android app',
        onTap: () { if (mounted) setState(() => _expanded = false); openAndroidApp(context); },
      );
}
