import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database_provider.dart';
import '../../features/auth/providers/auth_controller.dart';

/// The company logo uploaded on the web (Admin Settings → Company logo),
/// kept on the phone with the other org settings. Null when none is set.
final orgLogoUrlProvider = FutureProvider<String?>((ref) async {
  ref.watch(orgIdProvider);
  final v = (await ref.watch(appDatabaseProvider).getConfig('org.logo_url'))?.trim() ?? '';
  return v.isEmpty ? null : v;
});

/// Company logo in a circle. Shows nothing when no logo is set or it can't load.
class OrgLogo extends ConsumerWidget {
  final double size;
  const OrgLogo({super.key, this.size = 52});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(orgLogoUrlProvider).valueOrNull;
    if (url == null) return const SizedBox.shrink();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      padding: EdgeInsets.all(size * 0.12),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}
