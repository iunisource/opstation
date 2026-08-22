import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Floating "Get the Android app" badge for master admins / admins. Sits in the
/// bottom-right area (left of the Station Master bubble) and opens the app
/// download link.
class DownloadAppButton extends ConsumerWidget {
  const DownloadAppButton({super.key});

  static const _url =
      'https://drive.google.com/drive/folders/1QczU7LCACXQwuq_RKts7uki1i-arYwbv?usp=sharing';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(currentUserProvider)?.role;
    final show = role == WebUserRole.masterAdmin || role == WebUserRole.admin;
    if (!show) return const SizedBox.shrink();

    return Positioned(
      right: 88,
      bottom: 20,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: () async {
            final uri = Uri.parse(_url);
            try {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open the download link.')));
              }
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppTheme.textPrimary,
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.textPrimary.withOpacity(0.28),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.android, color: Color(0xFF3DDC84), size: 20),
              SizedBox(width: 8),
              Text('Get the Android app',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}
