import 'dart:math';

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

  /// Make this phone the login's route phone (call right after signing in).
  static Future<void> claim() async {
    final d = await id();
    try {
      await Supabase.instance.client.rpc('claim_trip_device', params: {'p_device': d});
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
