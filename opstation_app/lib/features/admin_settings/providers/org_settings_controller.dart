import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../features/auth/providers/auth_controller.dart';
import '../../../core/database/app_database_provider.dart';
import '../models/org_settings.dart';

/// Loads org settings from app_config and exposes setters. Writes go
/// back to app_config immediately — no separate "save" button.
class OrgSettingsController extends AsyncNotifier<OrgSettings> {
  AppDatabase get _db => ref.read(appDatabaseProvider);

  @override
  Future<OrgSettings> build() async {
    return OrgSettings(
      cutoffTime: await _db.getConfig('org.cutoff_time') ?? OrgSettings.defaults.cutoffTime,
      geofenceRadiusMeters: int.tryParse(await _db.getConfig('org.geofence_radius_m') ?? '') ??
          OrgSettings.defaults.geofenceRadiusMeters,
      accuracyWarnMeters: int.tryParse(await _db.getConfig('org.accuracy_warn_m') ?? '') ??
          OrgSettings.defaults.accuracyWarnMeters,
      scoreBadMax: int.tryParse(await _db.getConfig('org.visit_score_bad_max') ?? '') ??
          OrgSettings.defaults.scoreBadMax,
      scoreOkMax: int.tryParse(await _db.getConfig('org.visit_score_ok_max') ?? '') ??
          OrgSettings.defaults.scoreOkMax,
      categories: _decodeList(await _db.getConfig('org.categories')) ??
          _decodeList(await _getSmsConfig('org.categories')) ??
          OrgSettings.defaults.categories,
      groups: _decodeList(await _db.getConfig('org.groups')) ??
          _decodeList(await _getSmsConfig('org.groups')) ??
          OrgSettings.defaults.groups,
      osrmBaseUrl: await _db.getConfig('org.osrm_base_url') ??
          OrgSettings.defaults.osrmBaseUrl,
      nominatimBaseUrl: await _db.getConfig('org.nominatim_base_url') ??
          OrgSettings.defaults.nominatimBaseUrl,
      complianceLookbackTrips:
          int.tryParse(await _db.getConfig('org.compliance_lookback_trips') ??
                  '') ??
              OrgSettings.defaults.complianceLookbackTrips,
      complianceThresholdOccurrences: int.tryParse(
              await _db.getConfig('org.compliance_threshold_occ') ?? '') ??
          OrgSettings.defaults.complianceThresholdOccurrences,
      smsApiUrl: await _getSmsConfig('org.sms_api_url') ?? '',
      smsApiMethod: await _getSmsConfig('org.sms_api_method') ?? 'GET',
      smsApiHeaders: await _getSmsConfig('org.sms_api_headers') ?? '{}',
      smsApiBody: await _getSmsConfig('org.sms_api_body') ?? '',
      smsApiKey: await _getSmsConfig('org.sms_api_key') ?? '',
      smsSenderId: await _getSmsConfig('org.sms_sender_id') ?? '',
      smsVisitTemplate: await _getSmsConfig('org.sms_visit_template') ??
          OrgSettings.defaults.smsVisitTemplate,
      smsDeliveryTemplate: await _getSmsConfig('org.sms_delivery_template') ??
          OrgSettings.defaults.smsDeliveryTemplate,
      smsEnabled: (await _getSmsConfig('org.sms_enabled')) == 'true',
    );
  }

  List<String>? _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [for (final x in decoded) x.toString()];
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _getSmsConfig(String key) async {
    try {
      final orgId = ref.read(orgIdProvider);
      if (orgId == null) return null;
      final client = Supabase.instance.client;
      final row = await client
          .from('app_config')
          .select('value')
          .eq('key', key)
          .eq('org_id', orgId)
          .maybeSingle();
      return row?['value'] as String?;
    } catch (_) { return null; }
  }

  Future<void> _save(OrgSettings next) async {
    await _db.setConfig('org.cutoff_time', next.cutoffTime);
    await _db.setConfig('org.geofence_radius_m', next.geofenceRadiusMeters.toString());
    await _db.setConfig('org.accuracy_warn_m', next.accuracyWarnMeters.toString());
    await _db.setConfig('org.visit_score_bad_max', next.scoreBadMax.toString());
    await _db.setConfig('org.visit_score_ok_max', next.scoreOkMax.toString());
    await _db.setConfig('org.categories', jsonEncode(next.categories));
    await _db.setConfig('org.groups', jsonEncode(next.groups));
    await _db.setConfig('org.osrm_base_url', next.osrmBaseUrl);
    await _db.setConfig('org.nominatim_base_url', next.nominatimBaseUrl);
    await _db.setConfig('org.compliance_lookback_trips',
        next.complianceLookbackTrips.toString());
    await _db.setConfig('org.compliance_threshold_occ',
        next.complianceThresholdOccurrences.toString());

    // Also mirror cutoff_time to the legacy key so the CutoffService picks
    // it up immediately. TripController re-reads geofence on every refresh,
    // so no further wiring is needed.
    await _db.setConfig('cutoff_time', next.cutoffTime);
    await _db.setConfig('org.sms_api_url', next.smsApiUrl);
    await _db.setConfig('org.sms_api_method', next.smsApiMethod);
    await _db.setConfig('org.sms_api_headers', next.smsApiHeaders);
    await _db.setConfig('org.sms_api_body', next.smsApiBody);
    await _db.setConfig('org.sms_api_key', next.smsApiKey);
    await _db.setConfig('org.sms_sender_id', next.smsSenderId);
    await _db.setConfig('org.sms_visit_template', next.smsVisitTemplate);
    await _db.setConfig('org.sms_delivery_template', next.smsDeliveryTemplate);
    await _db.setConfig('org.sms_enabled', next.smsEnabled.toString());

    // Push to Supabase
    try {
      final orgId = ref.read(orgIdProvider);
      if (orgId != null) {
        final client = Supabase.instance.client;
        for (final entry in {
          'org.sms_api_url': next.smsApiUrl,
          'org.sms_api_method': next.smsApiMethod,
          'org.sms_api_key': next.smsApiKey,
          'org.sms_sender_id': next.smsSenderId,
          'org.sms_enabled': next.smsEnabled.toString(),
          'org.sms_visit_template': next.smsVisitTemplate,
          'org.sms_delivery_template': next.smsDeliveryTemplate,
          'org.cutoff_time': next.cutoffTime,
          'org.categories': jsonEncode(next.categories),
          'org.groups': jsonEncode(next.groups),
        }.entries) {
          await client.from('app_config').upsert({
            'key': entry.key,
            'value': entry.value,
            'org_id': orgId,
          });
        }
      }
    } catch (_) {}

    state = AsyncData(next);

    // Push to Supabase so server-side cutoff Edge Function can read it
    try {
      final orgId = ref.read(orgIdProvider);
      if (orgId != null) {
        final client = Supabase.instance.client;
        await client.from('app_config').upsert({
          'key': 'org.cutoff_time',
          'value': next.cutoffTime,
          'org_id': orgId,
        });
        await client.from('app_config').upsert({
          'key': 'org.geofence_radius_m',
          'value': next.geofenceRadiusMeters.toString(),
          'org_id': orgId,
        });
      }
    } catch (_) {}
  }

  Future<void> setCutoffTime(String hhmm) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(cutoffTime: hhmm));
  }

  Future<void> setGeofenceRadius(int metres) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(geofenceRadiusMeters: metres));
  }

  Future<void> setAccuracyWarn(int metres) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(accuracyWarnMeters: metres));
  }

  Future<void> setScoreBands({required int badMax, required int okMax}) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(scoreBadMax: badMax, scoreOkMax: okMax));
  }

  Future<void> setComplianceThresholds({
    required int lookbackTrips,
    required int occurrenceThreshold,
  }) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(
      complianceLookbackTrips: lookbackTrips,
      complianceThresholdOccurrences: occurrenceThreshold,
    ));
  }

  Future<void> setSmsConfig({
    required String apiUrl,
    required String apiMethod,
    required String apiHeaders,
    required String apiBody,
    required String apiKey,
    required String senderId,
    required String visitTemplate,
    required String deliveryTemplate,
    required bool enabled,
  }) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(
      smsApiUrl: apiUrl,
      smsApiMethod: apiMethod,
      smsApiHeaders: apiHeaders,
      smsApiBody: apiBody,
      smsApiKey: apiKey,
      smsSenderId: senderId,
      smsVisitTemplate: visitTemplate,
      smsDeliveryTemplate: deliveryTemplate,
      smsEnabled: enabled,
    ));
  }

  // ---- Taxonomy CRUD -------------------------------------------------

  Future<void> addCategory(String name) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (s.categories.contains(trimmed)) return;
    await _save(s.copyWith(categories: [...s.categories, trimmed]..sort()));
  }

  Future<void> removeCategory(String name) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(
      categories: s.categories.where((c) => c != name).toList(),
    ));
  }

  Future<void> renameCategory(String oldName, String newName) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final updated = [
      for (final c in s.categories) c == oldName ? trimmed : c,
    ]..sort();
    await _save(s.copyWith(categories: updated));
  }

  Future<void> addGroup(String name) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (s.groups.contains(trimmed)) return;
    await _save(s.copyWith(groups: [...s.groups, trimmed]..sort()));
  }

  Future<void> removeGroup(String name) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    await _save(s.copyWith(
      groups: s.groups.where((g) => g != name).toList(),
    ));
  }

  Future<void> renameGroup(String oldName, String newName) async {
    final s = state.valueOrNull ?? OrgSettings.defaults;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final updated = [
      for (final g in s.groups) g == oldName ? trimmed : g,
    ]..sort();
    await _save(s.copyWith(groups: updated));
  }
}

final orgSettingsProvider =
    AsyncNotifierProvider<OrgSettingsController, OrgSettings>(
        OrgSettingsController.new);
