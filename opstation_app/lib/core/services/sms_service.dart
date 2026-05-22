import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
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
      final orgId = _ref.read(orgIdProvider);
      if (orgId == null) return;

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
      if (cfg['org.sms_enabled'] != 'true') return;

      final apiUrl = cfg['org.sms_api_url'] ?? '';
      if (apiUrl.isEmpty) return;

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
      if (apiMethod.toUpperCase() == 'GET') {
        await http.get(Uri.parse(url), headers: headers);
      } else {
        // Check if body is JSON
        final isJson = body.trim().startsWith('{');
        if (isJson) {
          headers['Content-Type'] = 'application/json';
          await http.post(Uri.parse(url), headers: headers, body: body);
        } else {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
          await http.post(Uri.parse(url), headers: headers, body: body);
        }
      }
    } catch (e) {
      print('SMS ERROR: ' + e.toString());
    }
  }
}

final smsServiceProvider = Provider<SmsService>((ref) => SmsService(ref));
