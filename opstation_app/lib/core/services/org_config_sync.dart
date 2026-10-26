import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/admin_settings/providers/org_settings_controller.dart';
import '../../features/auth/providers/auth_controller.dart';
import '../../features/customers/presentation/customer_detail_screen.dart' show customerDeactivateAccessProvider;
import '../../features/customers/services/field_location_capture.dart' show fieldLocationConfigProvider;
import '../../features/salesperson/presentation/salesperson_drawer.dart' show salespersonTargetsEnabledProvider;
import '../database/app_database_provider.dart';
import 'device_guard.dart';
import '../utils/customer_locations.dart';
import '../utils/receipt_books.dart';

/// Keeps organisation settings (Admin Settings on the web / app) current on
/// the phone WITHOUT logging out: re-reads them when the app comes back to the
/// screen and every 10 minutes while it's open, saves them on the phone for
/// offline use, and refreshes only the parts whose settings changed.
class OrgConfigSync with WidgetsBindingObserver {
  OrgConfigSync(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(DeviceGuard.id()); // so trip uploads carry this phone's id
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => sync());
    // First check shortly after start (the login pull already ran).
    Future.delayed(const Duration(seconds: 20), sync);
  }

  final Ref _ref;
  Timer? _timer;
  bool _running = false;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  // Settings read through the main settings object (geofence radius, cut-off …).
  static const _orgSettingsKeys = {
    'org.cutoff_time', 'org.geofence_radius_m', 'org.accuracy_warn_m',
    'org.visit_score_bad_max', 'org.visit_score_ok_max', 'org.categories', 'org.groups',
    'org.osrm_base_url', 'org.nominatim_base_url', 'org.compliance_lookback_trips',
    'org.compliance_threshold_occ',
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Not more than once a minute when switching apps back and forth.
      if (DateTime.now().difference(_last) > const Duration(minutes: 1)) sync();
    }
  }

  /// Pull the org's settings now. Safe to call any time; never throws.
  Future<void> sync() async {
    if (_running) return;
    final orgId = _ref.read(orgIdProvider);
    if (orgId == null) return;
    // Route phone + timezone check (never blocks the settings refresh).
    unawaited(DeviceGuard.check(_ref));
    _running = true;
    _last = DateTime.now();
    try {
      final db = _ref.read(appDatabaseProvider);
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId)
          .like('key', 'org.%');
      final changed = <String>{};
      for (final r in rows as List) {
        final k = '${r['key']}';
        final v = r['value'] == null ? '' : '${r['value']}';
        final cur = await db.getConfig(k);
        if (cur != v) {
          await db.setConfig(k, v);
          changed.add(k);
        }
      }
      if (changed.any(_orgSettingsKeys.contains)) _ref.invalidate(orgSettingsProvider);
      if (changed.any((k) => k.startsWith('org.field_location_capture'))) {
        _ref.invalidate(fieldLocationConfigProvider);
      }
      if (changed.any((k) => k.startsWith('org.customer_deactivate'))) {
        _ref.invalidate(customerDeactivateAccessProvider);
      }
      if (changed.contains('org.customer_targets_enabled')) {
        _ref.invalidate(salespersonTargetsEnabledProvider);
      }
      // Receipt books and extra customer locations change without a setting.
      await ReceiptBooks.refresh(db, orgId);
      await CustomerLocations.refresh(db, orgId);
    } catch (_) {
      // Offline — the phone keeps its last copy.
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

final orgConfigSyncProvider = Provider<OrgConfigSync>((ref) {
  final s = OrgConfigSync(ref);
  ref.onDispose(s.dispose);
  return s;
});
