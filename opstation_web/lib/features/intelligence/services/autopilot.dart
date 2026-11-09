import 'package:supabase_flutter/supabase_flutter.dart';

/// Intelligence Auto Pilot (SQL 456).
///
/// While Auto Pilot is ON in "Surveys + Sales invoices" mode, the database
/// returns one placement row per (shop, Intelligence product) the shop bought
/// in the chosen window — shaped like a survey row, with source = 'invoice',
/// `ref` = the invoice number and `ref_date` = its date. Nothing is stored, so
/// switching Auto Pilot off simply makes this list empty again.
///
/// Callers add these rows to the survey rows they already load and keep their
/// usual "latest per shop + product wins" logic ([mergeAutopilot] re-sorts
/// newest first so that logic still holds).
Future<List<Map<String, dynamic>>> autopilotRows(String orgId) async {
  final out = <Map<String, dynamic>>[];
  try {
    for (var from = 0; from < 500000; from += 1000) {
      final page = await Supabase.instance.client
          .rpc('placement_invoice_rows', params: {'p_org': orgId})
          .range(from, from + 999);
      final list = List<Map<String, dynamic>>.from(page as List);
      out.addAll(list);
      if (list.length < 1000) break;
    }
  } catch (_) {
    // Older database / Auto Pilot not set up: surveys only.
    return const [];
  }
  return out;
}

/// Survey rows + Auto Pilot rows, newest first.
List<Map<String, dynamic>> mergeAutopilot(
    Iterable<Map<String, dynamic>> surveyRows, List<Map<String, dynamic>> autoRows) {
  final all = <Map<String, dynamic>>[...surveyRows, ...autoRows];
  if (autoRows.isEmpty) return all;
  DateTime t(Map<String, dynamic> r) =>
      DateTime.tryParse('${r['surveyed_at'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0);
  all.sort((a, b) => t(b).compareTo(t(a)));
  return all;
}

bool isInvoiceRow(Map<String, dynamic>? r) => r != null && r['source'] == 'invoice';

/// Short label for where a placement came from, e.g. "Invoice SI-2026-1373".
String placementSourceLabel(Map<String, dynamic> r) {
  switch (r['source']) {
    case 'invoice':
      return r['is_present'] == true ? 'Invoice ${r['ref'] ?? ''}'.trim() : 'Not surveyed · no sale';
    case 'autopilot_kept':
      return 'Auto Pilot (kept)';
    case 'audit_fix':
      return 'Auditor correction';
    default:
      return 'Survey';
  }
}
