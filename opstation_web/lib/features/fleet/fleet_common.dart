// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_controller.dart';

/// Shared bits for Logistics → Fleet (SQL 463).

SupabaseClient get fleetDb => Supabase.instance.client;

final _n0 = NumberFormat('#,##0');
String km(num? v) => '${_n0.format(v ?? 0)} km';
String rs(num? v) => 'Rs ${_n0.format(v ?? 0)}';
String fdate(dynamic v) {
  final d = DateTime.tryParse('${v ?? ''}');
  return d == null ? '' : DateFormat('d MMM yyyy').format(d);
}

String vehicleTitle(Map v) => [
      if ((v['make'] ?? '') != '') v['make'],
      if ((v['model'] ?? '') != '') v['model'],
      if ((v['vehicle_type'] ?? '') != '') v['vehicle_type'],
      if (v['year'] != null) '${v['year']}',
    ].join(' · ');

IconData vehicleIcon(String? type) {
  final t = (type ?? '').toLowerCase();
  if (t.contains('bike') || t.contains('motor')) return Icons.two_wheeler_rounded;
  if (t.contains('car')) return Icons.directions_car_rounded;
  if (t.contains('earth') || t.contains('excavator') || t.contains('loader')) return Icons.construction_rounded;
  return Icons.local_shipping_rounded;
}

/// Where a service stands — mirrors _fleet_service_state in SQL 463.
class ServiceState {
  final String state; // ok | due | overdue
  final num? nextKm;
  final num? kmLeft;
  final DateTime? nextDate;
  final int? daysLeft;
  final double progress; // 0..1+
  const ServiceState(this.state, this.nextKm, this.kmLeft, this.nextDate, this.daysLeft, this.progress);

  Color get color => state == 'overdue'
      ? const Color(0xFFDC2626)
      : state == 'due'
          ? const Color(0xFFD97706)
          : const Color(0xFF059669);

  String get label {
    final parts = <String>[];
    if (kmLeft != null) parts.add(kmLeft! < 0 ? '${km(kmLeft!.abs())} past due' : '${km(kmLeft)} left');
    if (daysLeft != null) {
      parts.add(daysLeft! < 0 ? '${-daysLeft!} days past due' : daysLeft == 0 ? 'due today' : 'due ${DateFormat('d MMM yyyy').format(nextDate!)}');
    }
    return parts.isEmpty ? 'Not set' : parts.join(' · ');
  }
}

ServiceState serviceState(Map s, num? odometer, num leadKm) {
  final today = DateTime.now();
  final t0 = DateTime(today.year, today.month, today.day);
  num? nextKm, kmLeft;
  DateTime? nextDate;
  int? daysLeft;
  double p = 0;
  final everyKm = (s['every_km'] as num?) ?? 0;
  if (everyKm > 0) {
    final last = (s['last_km'] as num?) ?? 0;
    nextKm = last + everyKm;
    kmLeft = nextKm - (odometer ?? 0);
    p = ((odometer ?? 0) - last) / everyKm;
  }
  final months = (s['every_months'] as num?)?.toInt() ?? 0;
  final lastDate = DateTime.tryParse('${s['last_date'] ?? ''}');
  if (months > 0 && lastDate != null) {
    nextDate = DateTime(lastDate.year, lastDate.month + months, lastDate.day);
    daysLeft = nextDate.difference(t0).inDays;
    final total = nextDate.difference(lastDate).inDays;
    final dp = total <= 0 ? 0.0 : t0.difference(lastDate).inDays / total;
    if (dp > p) p = dp;
  }
  var st = 'ok';
  if ((kmLeft != null && kmLeft < 0) || (daysLeft != null && daysLeft < 0)) {
    st = 'overdue';
  } else if ((kmLeft != null && kmLeft <= leadKm) || (daysLeft != null && daysLeft <= 7)) {
    st = 'due';
  }
  return ServiceState(st, nextKm, kmLeft, nextDate, daysLeft, p.clamp(0, 1.2).toDouble());
}

/// Worst state of a vehicle's services: ok | due | overdue.
String vehicleState(List<Map<String, dynamic>> services, num? odo, num lead) {
  var worst = 'ok';
  for (final s in services) {
    final st = serviceState(s, odo, lead).state;
    if (st == 'overdue') return 'overdue';
    if (st == 'due') worst = 'due';
  }
  return worst;
}

Future<num> fleetLeadKm(String orgId) async {
  try {
    final r = await fleetDb.from('app_config').select('value')
        .eq('org_id', orgId).eq('key', 'org.fleet_alert_km').isFilter('branch_id', null).maybeSingle();
    return num.tryParse('${r?['value'] ?? ''}') ?? 200;
  } catch (_) {
    return 200;
  }
}

String esc(Object? s) => '${s ?? ''}'
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Opens a printable page (Print / Save as PDF).
void openPrint(String title, String bodyHtml) {
  final b = StringBuffer()
    ..write('<!doctype html><html><head><meta charset="utf-8"><title>${esc(title)}</title><style>'
        'body{font-family:Arial,Helvetica,sans-serif;color:#0f172a;margin:24px;font-size:12px}'
        'h1{font-size:20px;margin:0 0 4px}h2{font-size:14px;margin:18px 0 6px}'
        '.meta{color:#64748b;margin-bottom:12px}'
        'table{width:100%;border-collapse:collapse;margin-top:6px}'
        'th,td{border:1px solid #e2e8f0;padding:6px 8px;text-align:left;vertical-align:top}'
        'th{background:#f1f5f9}.num{text-align:right}'
        '.ok{color:#047857}.due{color:#b45309}.overdue{color:#b91c1c;font-weight:bold}'
        '.photos img{height:110px;margin:0 6px 6px 0;border-radius:6px;border:1px solid #e2e8f0}'
        '.no-print{margin-bottom:12px}@media print{.no-print{display:none}}'
        '</style></head><body>'
        '<div class="no-print"><button onclick="window.print()">&#x1F5A8; Print / Save as PDF</button></div>')
    ..write(bodyHtml)
    ..write('<div class="meta" style="margin-top:18px">Printed ${esc(DateFormat('d MMM yyyy, h:mm a').format(DateTime.now()))} · Opstation</div>')
    ..write('</body></html>');
  final blob = html.Blob([b.toString()], 'text/html;charset=utf-8');
  html.window.open(html.Url.createObjectUrlFromBlob(blob), '_blank');
}

/// Services due or overdue across the fleet — the menu counter.
final fleetDueCountProvider = FutureProvider<int>((ref) async {
  final u = ref.watch(currentUserProvider);
  if (u?.orgId == null) return 0;
  try {
    final r = await fleetDb.rpc('fleet_due_count', params: {'p_org': u!.orgId});
    return (r as num?)?.toInt() ?? 0;
  } catch (_) {
    return 0;
  }
});
