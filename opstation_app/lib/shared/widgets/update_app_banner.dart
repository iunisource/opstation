import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/database/app_database_provider.dart';

/// (installed version label, minimum build, package name) when this phone's
/// app is older than the org's minimum (Admin Settings → "Ask old apps to
/// update", org.app_update_banner + org.app_min_build). Null = nothing to show.
/// Settings are per organization and kept current by OrgConfigSync.
final appUpdateNeededProvider = FutureProvider<(String, int, String)?>((ref) async {
  try {
    final db = ref.watch(appDatabaseProvider);
    if ((await db.getConfig('org.app_update_banner'))?.trim() != 'true') return null;
    final min = int.tryParse((await db.getConfig('org.app_min_build') ?? '').trim()) ?? 0;
    if (min <= 0) return null;
    final p = await PackageInfo.fromPlatform();
    final build = int.tryParse(p.buildNumber) ?? 0;
    if (build <= 0 || build >= min) return null;
    return ('${p.version} (${p.buildNumber})', min, p.packageName);
  } catch (_) {
    return null;
  }
});

/// "Please update Opstation" banner on the home screens. Warning only.
class UpdateAppBanner extends ConsumerWidget {
  final EdgeInsetsGeometry padding;
  const UpdateAppBanner({super.key, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final need = ref.watch(appUpdateNeededProvider).valueOrNull;
    if (need == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7ED),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFDBA74)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.system_update_outlined, color: Color(0xFFC2410C), size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text('Please update Opstation',
                  style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF9A3412))),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'You are on version ${need.$1}. Your company needs build ${need.$2} or newer so that reports and '
            'features work correctly.',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF7C2D12)),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEA580C)),
            onPressed: () async {
              final market = Uri.parse('market://details?id=${need.$3}');
              final web = Uri.parse('https://play.google.com/store/apps/details?id=${need.$3}');
              try {
                if (!await launchUrl(market, mode: LaunchMode.externalApplication)) {
                  await launchUrl(web, mode: LaunchMode.externalApplication);
                }
              } catch (_) {
                await launchUrl(web, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.shop_outlined, size: 18),
            label: const Text('Update on Play Store'),
          ),
        ]),
      ),
    );
  }
}
