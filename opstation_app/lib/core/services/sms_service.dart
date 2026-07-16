import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/providers/auth_controller.dart';

/// One recorded SMS attempt, kept on-device so the outcome is visible in the
/// app without depending on Sentry, adb, or the network. Read via
/// [SmsService.log] / [smsDebugLogProvider].
class SmsAttempt {
  final DateTime at;
  final String phone; // normalized
  final String outcome; // human-readable: what happened
  final bool ok;
  SmsAttempt(this.phone, this.outcome, this.ok) : at = DateTime.now();

  String get line {
    final t =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    return '[$t] ${ok ? "✓" : "✗"} $phone — $outcome';
  }
}

class SmsService {
  final Ref _ref;
  SmsService(this._ref);

  /// Last SMS attempts, newest first. Surfaced in the SMS Debug screen.
  static final List<SmsAttempt> log = [];
  static void _record(String phone, String outcome, bool ok) {
    log.insert(0, SmsAttempt(phone, outcome, ok));
    if (log.length > 30) log.removeLast();
    // Also print so `adb logcat | grep SMSLOG` works if ever needed.
    print('SMSLOG ${ok ? "OK" : "FAIL"} $phone :: $outcome');
  }

  /// Public note for the CALLER (sync_controller) to record why it did or did
  /// not reach the SMS send — e.g. "no pending visits", "amount 0", "customer
  /// not in local db". Makes upstream skips visible in the SMS Debug screen.
  static void note(String msg) {
    log.insert(0, SmsAttempt('—', msg, false));
    if (log.length > 30) log.removeLast();
    print('SMSLOG NOTE :: $msg');
  }

  Future<void> sendVisitSms({
    required String customerPhone,
    required String customerName,
    required int amount,
    required String receiptNo,
    String salespersonName = '',
  }) async {
    await _send(
      phone: customerPhone,
      configKey: 'org.sms_visit_template',
      placeholders: {
        '{customer_name}': customerName,
        '{amount}': amount.toString(),
        '{receipt_no}': receiptNo,
        '{salesperson_name}': salespersonName,
      },
    );
  }

  Future<void> sendDeliverySms({
    required String customerPhone,
    required String customerName,
    required int amount,
    String driverName = '',
  }) async {
    await _send(
      phone: customerPhone,
      configKey: 'org.sms_delivery_template',
      placeholders: {
        '{customer_name}': customerName,
        '{amount}': amount.toString(),
        '{driver_name}': driverName,
      },
    );
  }

  Future<void> _send({
    required String phone,
    required String configKey,
    required Map<String, String> placeholders,
  }) async {
    try {
      // Normalize to the gateway's required format: 92XXXXXXXXXX (country code,
      // no "+", no leading 0). Customer numbers are stored inconsistently, so
      // handle every observed shape:
      //   "+923214219139" -> strip "+"              -> 923214219139
      //   "0092..."       -> drop the 00 prefix      -> 92...
      //   "923214219139"  -> already correct         -> unchanged
      //   "03214219139"   -> drop 0, prepend 92       -> 923214219139
      //   "3214219139"    -> bare 10-digit mobile     -> prepend 92 -> 923214219139
      // The bare-10-digit case is the common one in the data and was previously
      // sent without a country code, which the gateway rejected.
      phone = phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (phone.startsWith('00')) {
        phone = phone.substring(2);
      }
      if (phone.startsWith('92')) {
        // already has the country code — leave as is
      } else if (phone.startsWith('0')) {
        phone = '92' + phone.substring(1);
      } else if (phone.length == 10 && phone.startsWith('3')) {
        phone = '92' + phone;
      }

      final orgId = _ref.read(orgIdProvider);
      if (orgId == null) {
        _record(phone, 'SKIPPED — orgId is null (no org in session)', false);
        await Sentry.captureMessage('SMS skipped: orgId is null',
            level: SentryLevel.warning);
        return;
      }

      final client = Supabase.instance.client;
      final configs = await client
          .from('app_config')
          .select('key, value')
          .eq('org_id', orgId)
          .inFilter('key', [
        'org.sms_enabled',
        'org.sms_api_url',
        'org.sms_api_method',
        'org.sms_api_headers',
        'org.sms_api_body',
        'org.sms_api_key',
        'org.sms_sender_id',
        configKey,
      ]);

      final cfg = <String, String>{};
      for (final row in configs) {
        cfg[row['key'] as String] = row['value'] as String? ?? '';
      }

      if (cfg.isEmpty) {
        _record(phone,
            'SKIPPED — no app_config rows returned for org $orgId (config fetch empty)',
            false);
        return;
      }

      print('SMS CONFIG: enabled=' + (cfg['org.sms_enabled'] ?? 'null') + ' url=' + (cfg['org.sms_api_url'] ?? 'null'));
      if (cfg['org.sms_enabled'] != 'true') {
        _record(phone,
            'SKIPPED — sms_enabled != true (was "${cfg['org.sms_enabled'] ?? 'null'}")',
            false);
        await Sentry.captureMessage(
            'SMS skipped: org.sms_enabled != true (was "${cfg['org.sms_enabled'] ?? 'null'}")',
            level: SentryLevel.warning);
        return;
      }

      final apiUrl = cfg['org.sms_api_url'] ?? '';
      if (apiUrl.isEmpty) {
        _record(phone, 'SKIPPED — sms_api_url is empty', false);
        await Sentry.captureMessage('SMS skipped: org.sms_api_url is empty',
            level: SentryLevel.warning);
        return;
      }

      final apiMethod = cfg['org.sms_api_method'] ?? 'POST';
      final apiHeaders = cfg['org.sms_api_headers'] ?? '{}';
      final apiBody = cfg['org.sms_api_body'] ?? '';
      final apiKey = cfg['org.sms_api_key'] ?? '';
      final senderId = cfg['org.sms_sender_id'] ?? '';
      var template = cfg[configKey] ?? '';

      // Replace message placeholders
      for (final entry in placeholders.entries) {
        template = template.replaceAll(entry.key, entry.value);
      }
      // Clean up template — remove newlines that break JSON
      template = template.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();

      // Replace standard placeholders in body
      var body = apiBody
          .replaceAll('{phone}', phone)
          .replaceAll('{message}', template)
          .replaceAll('{api_key}', apiKey)
          .replaceAll('{sender_id}', senderId);

      // Replace standard placeholders in URL (for GET)
      var url = apiUrl
          .replaceAll('{phone}', Uri.encodeComponent(phone))
          .replaceAll('{message}', Uri.encodeComponent(template))
          .replaceAll('{api_key}', apiKey)
          .replaceAll('{sender_id}', senderId);

      // Parse headers
      Map<String, String> headers = {};
      try {
        final decoded = jsonDecode(apiHeaders) as Map<String, dynamic>;
        headers = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}

      print('SMS SENDING: url=' + url + ' method=' + apiMethod + ' body=' + body);
      http.Response resp;
      if (apiMethod.toUpperCase() == 'GET') {
        resp = await http.get(Uri.parse(url), headers: headers);
      } else {
        // Check if body is JSON
        final isJson = body.trim().startsWith('{');
        if (isJson) {
          headers['Content-Type'] = 'application/json';
          resp = await http.post(Uri.parse(url), headers: headers, body: body);
        } else {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
          resp = await http.post(Uri.parse(url), headers: headers, body: body);
        }
      }

      // The gateway's verdict was previously discarded, so a rejection (VeevoTech
      // returns 200 with an error in the body) looked identical to success. Surface
      // it: a non-2xx status, or a body that doesn't read as a success, goes to
      // Sentry with the provider's own words so the real cause is visible.
      final bodyText = resp.body;
      final okStatus = resp.statusCode >= 200 && resp.statusCode < 300;
      final looksSuccessful =
          bodyText.toUpperCase().contains('SUCCESS');
      final shortBody =
          bodyText.length > 160 ? bodyText.substring(0, 160) : bodyText;
      if (!okStatus || !looksSuccessful) {
        _record(phone,
            'GATEWAY REJECTED — status ${resp.statusCode}: $shortBody', false);
        await Sentry.captureMessage(
          'SMS gateway did not confirm success — status=${resp.statusCode} body=$bodyText',
          level: SentryLevel.error,
        );
      } else {
        _record(phone, 'SENT — status ${resp.statusCode}: $shortBody', true);
      }
    } catch (e, st) {
      _record(phone, 'THREW — $e', false);
      print('SMS ERROR: ' + e.toString());
      await Sentry.captureException(e, stackTrace: st);
    }
  }
}

/// Exposes the on-device SMS attempt log to the UI.
final smsDebugLogProvider = Provider<List<SmsAttempt>>((_) => SmsService.log);

final smsServiceProvider = Provider<SmsService>((ref) => SmsService(ref));
