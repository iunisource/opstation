import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/database/app_database_provider.dart';
import 'features/uploads/services/upload_worker.dart';
import 'core/router/app_router.dart';
import 'features/team/data/team_repository.dart';
import 'core/services/cutoff_service.dart';
import 'core/sync/sync_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'shared/widgets/startup_splash.dart';

class OpstationApp extends ConsumerWidget {
  const OpstationApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);
    final router = ref.watch(appRouterProvider);

    // Eagerly construct these so their timers and connectivity listeners
    // run for the app lifetime. They're no-ops until signed-in features use them.
    ref.watch(syncControllerProvider);
    ref.watch(cutoffServiceProvider);
    ref.watch(uploadWorkerStarterProvider);
    ref.watch(seedProvider);

    return MaterialApp.router(
      title: 'Opstation',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (context, child) =>
          StartupSplash(child: child ?? const SizedBox.shrink()),
      routerConfig: router,
    );
  }
}


/// Seeds superadmin using the single provider DB instance.
/// This replaces the AppDatabase() call that was in main.dart.
final seedProvider = FutureProvider<void>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  await TeamRepository(db).seedIfEmpty();
});
