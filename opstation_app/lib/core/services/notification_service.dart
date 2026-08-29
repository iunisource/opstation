import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';
import '../supabase/supabase_pull_service.dart';
import '../audio/alarm_sound.dart';
import '../../features/auth/providers/auth_controller.dart';

/// Handles FCM token registration and notification permissions.
class NotificationService {
  // Foreground notification plumbing. firebase_messaging delivers
  // RemoteMessages while the app is open but does NOT display anything
  // automatically — that's the OS's job, and the OS only does it when
  // the app is in the background. We use flutter_local_notifications
  // to surface a banner ourselves on foreground delivery.
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  static const AndroidNotificationChannel _channel =
      AndroidNotificationChannel(
    'opstation_alerts',
    'Opstation alerts',
    description: 'Order, delivery, and route alerts',
    importance: Importance.high,
  );
  static bool _localInitialized = false;

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final SupabaseClient _supabase;
  final AppDatabase _db;
  final Ref _ref;

  NotificationService(this._supabase, this._db, this._ref);

  /// Call after login — requests permission and saves FCM token.
  Future<void> initialize(String userId) async {
    try {
      // Initialize the local notifications plugin once (and register the
      // Android channel) before the FCM listener starts firing.
      if (!_localInitialized) {
        await _local.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        // Channel is registered implicitly by Android on the first
        // show() call with matching AndroidNotificationDetails — explicit
        // registration tripped a Dart generic-parsing edge case and is
        // not actually required.
        _localInitialized = true;
      }

      // Request permission
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      // Get token
      final token = await _messaging.getToken();
      if (token == null) return;

      // Save to local DB
      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(UsersCompanion(fcmToken: Value(token)));

      // Save to Supabase
      await _supabase
          .from('users')
          .update({'fcm_token': token})
          .eq('id', userId);

      // Listen for token refresh
      _messaging.onTokenRefresh.listen((newToken) async {
        await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
            .write(UsersCompanion(fcmToken: Value(newToken)));
        await _supabase
            .from('users')
            .update({'fcm_token': newToken})
            .eq('id', userId);
      });

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    } catch (_) {}
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // Delivery assignment: sound the alarm and pull the new job into local
    // Drift so the driver-home stream refreshes automatically. Done before the
    // banner so the alert is immediate even if the pull is slow.
    if (message.data['type'] == 'delivery_assigned') {
      AlarmSound.instance.play();
      final orgId =
          _ref.read(authControllerProvider).valueOrNull?.organizationId;
      if (orgId != null && orgId.isNotEmpty) {
        // Fire-and-forget; the Drift .watch() in driver_home reacts when rows land.
        _ref.read(supabasePullServiceProvider).pullOrgData(orgId).catchError((_) {});
      }
    }
    final notification = message.notification;
    if (notification == null) return;
    debugPrint(
        'FCM foreground: ${notification.title} — ${notification.body}');
    // Surface a real banner — FCM doesn't auto-display in foreground.
    // Use message.hashCode as the notification id so concurrent messages
    // stack rather than overwriting each other.
    _local.show(
      message.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          icon: '@mipmap/ic_launcher',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  /// Shows a device-generated notification — no FCM, no server round-trip.
  /// Used for on-device reminders such as the idle-route nudge, which must
  /// work even when the phone has no connectivity.
  Future<void> showLocalAlert({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      if (!_localInitialized) {
        await _local.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        _localInitialized = true;
      }
      await _local.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            icon: '@mipmap/ic_launcher',
            importance: Importance.high,
            priority: Priority.high,
            enableVibration: true,
          ),
        ),
      );
    } catch (_) {}
  }

  /// Retailer push registration. Retailers are public.users rows but have no
  /// RLS grant to UPDATE users, so the staff `initialize()` path (which writes
  /// the token with a direct table update) silently saves nothing for them.
  /// This saves the token through a SECURITY DEFINER RPC instead.
  Future<void> registerRetailerToken() async {
    try {
      if (!_localInitialized) {
        await _local.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        _localInitialized = true;
      }

      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;

      final token = await _messaging.getToken();
      if (token != null) {
        await _supabase
            .rpc('retailer_save_fcm_token', params: {'p_token': token});
      }

      _messaging.onTokenRefresh.listen((t) async {
        try {
          await _supabase
              .rpc('retailer_save_fcm_token', params: {'p_token': t});
        } catch (_) {}
      });

      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    } catch (_) {}
  }

  /// Send notification to a specific user via Supabase Edge Function.
  Future<void> sendToUser({
    required String targetUserId,
    required String title,
    required String body,
    Map<String, String>? data,
  }) async {
    try {
      print('FCM: invoking send-notification for user $targetUserId');
      final res = await _supabase.functions.invoke(
        'send-notification',
        body: {
          'userId': targetUserId,
          'title': title,
          'body': body,
          'data': data ?? {},
        },
      );
      print('FCM: response for $targetUserId status=${res.status} data=${res.data}');
    } catch (e, st) {
      print('FCM notify failed for $targetUserId: $e\n$st');
    }
  }
}

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(
    Supabase.instance.client,
    ref.watch(appDatabaseProvider),
    ref,
  );
});
