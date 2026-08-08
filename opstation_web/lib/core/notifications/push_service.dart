import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as jsu;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Web Push subscription management (admin/approver notifications).
///
/// The fiddly browser calls (service-worker registration, permission, subscribe)
/// live in native JS helpers defined in web/index.html (window.opstationPush*).
/// Dart just invokes them and stores the result — far more reliable than the
/// dart:html Push bindings.
class PushService {
  // VAPID public key — safe to ship in the client.
  static const vapidPublicKey =
      'BDsUwuFL_xt7xpeY5Q7CrIuUsMWjvhp7o4B5wSIRmA8vwoRc5sKjvdnpwQ4MDQCfl18C-QY-lQJcM5v1ItRuqE8';

  static bool get isSupported {
    try {
      final fn = jsu.getProperty(html.window, 'opstationPushSupported');
      if (fn == null) return false;
      return jsu.callMethod(html.window, 'opstationPushSupported', []) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      final r = await jsu.promiseToFuture<dynamic>(
          jsu.callMethod(html.window, 'opstationPushStatus', []));
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// Subscribes this device and stores it. Returns null on success, else an
  /// error message.
  static Future<String?> enable(
      {required String orgId, required String userId}) async {
    if (!isSupported) return 'This browser does not support notifications.';
    try {
      final res = await jsu.promiseToFuture<dynamic>(
          jsu.callMethod(html.window, 'opstationPushSubscribe', [vapidPublicKey]));
      final m = json.decode(res as String) as Map<String, dynamic>;
      final endpoint = m['endpoint'] as String;
      await Supabase.instance.client.from('push_subscriptions').upsert({
        'id': 'ps_${endpoint.hashCode & 0x7fffffff}',
        'org_id': orgId,
        'user_id': userId,
        'endpoint': endpoint,
        'p256dh': m['p256dh'],
        'auth': m['auth'],
        'user_agent': html.window.navigator.userAgent,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'endpoint');
      return null;
    } catch (e) {
      final s = e.toString();
      if (s.contains('denied')) return 'Allow notifications for this site, then try again.';
      if (s.contains('unsupported')) return 'This browser does not support notifications.';
      return 'Failed: $e';
    }
  }

  /// Unsubscribes this device and removes its row.
  static Future<void> disable() async {
    if (!isSupported) return;
    try {
      final ep = await jsu.promiseToFuture<dynamic>(
          jsu.callMethod(html.window, 'opstationPushUnsubscribe', []));
      if (ep is String && ep.isNotEmpty) {
        await Supabase.instance.client
            .from('push_subscriptions')
            .delete()
            .eq('endpoint', ep);
      }
    } catch (_) {}
  }
}
