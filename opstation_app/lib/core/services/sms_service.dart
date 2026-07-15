import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../features/auth/providers/auth_controller.dart';

class SmsService {
  final Ref _ref;
  SmsService(this._ref);

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
      // Normalize the number to the bare digit form the gateway accepts, the
      // same format proven to work in direct testing (923XXXXXXXXX). Customer
      // records store it as "+923154074223"; the leading "+", spaces and dashes
      // are stripped. A local "03XXXXXXXXX" is converted to "923XXXXXXXXX".
      phone = phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (phone.startsWith('0')) {
        phone = '92' + phone.substring(1);
      }

      final orgId = _ref.read(orgIdProvider);
      if (orgId == null) {
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

      print('SMS CONFIG: enabled=' + (cfg['org.sms_enabled'] ?? 'null') + ' url=' + (cfg['org.sms_api_url'] ?? 'null'));
      if (cfg['org.sms_enabled'] != 'true') {
        await Sentry.captureMessage(
            'SMS skipped: org.sms_enabled != true (was "${cfg['org.sms_enabled'] ?? 'null'}")',
            level: SentryLevel.warning);
        return;
      }

      final apiUrl = cfg['org.sms_api_url'] ?? '';
      if (apiUrl.isEmpty) {
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
      if (!okStatus || !looksSuccessful) {
        await Sentry.captureMessage(
          'SMS gateway did not confirm success — status=${resp.statusCode} body=$bodyText',
          level: SentryLevel.error,
        );
      }
    } catch (e, st) {
      print('SMS ERROR: ' + e.toString());
      await Sentry.captureException(e, stackTrace: st);
    }
  }
}

final smsServiceProvider = Provider<SmsService>((ref) => SmsService(ref));
