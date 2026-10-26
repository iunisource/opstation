import 'dart:io' show Platform;
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';

/// One phone per login runs the routes.
///
/// Signing in claims this phone as the user's route phone (the server moves
/// any open route to it). Another phone signed in with the same login is then
/// told so and can no longer start, mark or end routes — its trip uploads are
/// ignored by the server too. Unsent visits from before still upload.
///
/// Also warns when the phone's time zone isn't Pakistan time, which the
/// cut-off and "today" rely on.
class DeviceGuard {
  static const _kId = 'opstation_device_id';
  static String? cachedId;
  static bool blocked = false;
  static bool _blockAlerted = false;
  static bool _tzAlerted = false;

  static const blockedMessage =
      'You signed in on another phone. Routes can only be run from that phone. '
      'To use this phone, sign out and sign in again here.';
  static const timezoneMessage =
      "Your device's timezone is not same as the country you are in. Please adjust the timezone.";

  /// Pakistan time (UTC+5) — the cut-off and day boundaries use it.
  static bool get timezoneWrong => DateTime.now().timeZoneOffset != const Duration(hours: 5);

  static Future<String> id() async {
    if (cachedId != null) return cachedId!;
    final prefs = await SharedPreferences.getInstance();
    var v = prefs.getString(_kId);
    if (v == null || v.isEmpty) {
      final r = Random.secure();
      v = 'dev_${DateTime.now().microsecondsSinceEpoch}_${r.nextInt(1 << 30)}';
      await prefs.setString(_kId, v);
    }
    cachedId = v;
    return v;
  }

  /// Phone model ("Samsung SM-A155F"), Android version and app version.
  static Future<(String?, String?, String?)> _about() async {
    String? model, os, app;
    try {
      if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        final brand = a.manufacturer.trim();
        final m = a.model.trim();
        model = m.toLowerCase().startsWith(brand.toLowerCase()) ? m : '$brand $m'.trim();
        os = 'Android ${a.version.release}';
      } else if (Platform.isIOS) {
        final i = await DeviceInfoPlugin().iosInfo;
        model = i.utsname.machine;
        os = 'iOS ${i.systemVersion}';
      }
    } catch (_) {}
    try {
      final p = await PackageInfo.fromPlatform();
      app = '${p.version}+${p.buildNumber}';
    } catch (_) {}
    return (model, os, app);
  }

  /// Make this phone the login's route phone (call right after signing in).
  /// Also records the sign-in (time, phone model, and [lat]/[lng] if known)
  /// in the person's phone history.
  static Future<void> claim({double? lat, double? lng}) async {
    final d = await id();
    final about = await _about();
    try {
      try {
        await Supabase.instance.client.rpc('claim_trip_device', params: {
          'p_device': d,
          'p_model': about.$1,
          'p_os': about.$2,
          'p_app': about.$3,
          'p_lat': lat,
          'p_lng': lng,
        });
      } catch (_) {
        // Server without update 423: the older call.
        await Supabase.instance.client.rpc('claim_trip_device', params: {'p_device': d});
      }
      blocked = false;
      _blockAlerted = false;
    } catch (_) {
      // Server not updated yet (update 421) — nothing to enforce.
    }
  }

  /// Is another phone the route phone now? Updates [blocked] and the banner.
  static Future<void> check(Ref ref) async {
    final d = await id();
    try {
      final res = await Supabase.instance.client.rpc('my_trip_device');
      final current = res is String ? res : null;
      blocked = current != null && current.isNotEmpty && current != d;
    } catch (_) {
      // Offline or server not updated: keep the last known state.
    }
    ref.read(deviceBlockedProvider.notifier).state = blocked;
    try {
      if (blocked && !_blockAlerted) {
        _blockAlerted = true;
        await ref.read(notificationServiceProvider)
            .showLocalAlert(id: 90011, title: 'Signed in on another phone', body: blockedMessage);
      }
      if (timezoneWrong && !_tzAlerted) {
        _tzAlerted = true;
        await ref.read(notificationServiceProvider)
            .showLocalAlert(id: 90012, title: 'Check your phone\'s timezone', body: timezoneMessage);
      }
    } catch (_) {}
  }
}

final deviceBlockedProvider = StateProvider<bool>((ref) => DeviceGuard.blocked);
