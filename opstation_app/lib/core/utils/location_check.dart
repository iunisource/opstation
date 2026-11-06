import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../database/app_database.dart';
import '../database/app_database_provider.dart';

/// Same-spot rules (SQL 449 / 449b), mirrored on the phone:
/// two active customers within ~1 m count as a problem unless they are the
/// same shop under another brand — same phone (last 10 digits) or same first
/// two words of the name (brand brackets, dots and dashes ignored).
String? phoneKey(String? p) {
  final d = (p ?? '').replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return null;
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

String? shopKey(String? name) {
  var s = (name ?? '').replaceAll(RegExp(r'\([^)]*\)?'), ' ').replaceAll('.', '').toUpperCase();
  s = s.replaceAll(RegExp(r'[^A-Z0-9]+'), ' ').trim();
  if (s.isEmpty) return null;
  final w = s.split(RegExp(r'\s+'));
  return w.take(2).join(' ');
}

bool sameShop(String? phoneA, String? nameA, String? phoneB, String? nameB) {
  final pa = phoneKey(phoneA), pb = phoneKey(phoneB);
  if (pa != null && pb != null && pa == pb) return true;
  final na = shopKey(nameA), nb = shopKey(nameB);
  return na != null && nb != null && na == nb;
}

double _r5(double v) => (v * 100000).roundToDouble() / 100000;

/// Other (different) shops already saved at this exact spot, from the phone's
/// copy of the customers.
Future<List<CustomersData>> otherShopsAtSpot(
  AppDatabase db, {
  required double lat,
  required double lng,
  required String customerId,
}) async {
  final all = await (db.select(db.customers)..where((c) => c.isActive.equals(true))).get();
  CustomersData? me;
  for (final c in all) {
    if (c.id == customerId) me = c;
  }
  final la = _r5(lat), lo = _r5(lng);
  return [
    for (final c in all)
      if (c.id != customerId &&
          c.latitude != null &&
          c.longitude != null &&
          _r5(c.latitude!) == la &&
          _r5(c.longitude!) == lo &&
          !(me != null && sameShop(me.phone, me.shopName, c.phone, c.shopName)) &&
          (me == null || me.orgId == null || c.orgId == null || c.orgId == me.orgId))
        c
  ];
}

/// Admin Settings → "Wrong-location warnings in the app"
/// (org.loc_fix_warning, default ON) and its language
/// (org.loc_fix_warning_lang: en | ur | both).
class LocFixWarning {
  final bool on;
  final String lang;
  const LocFixWarning(this.on, this.lang);
  bool get en => lang != 'ur';
  bool get ur => lang == 'ur' || lang == 'both';
}

final locFixWarningProvider = FutureProvider<LocFixWarning>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final on = (await db.getConfig('org.loc_fix_warning'))?.trim() ?? '';
  final lang = (await db.getConfig('org.loc_fix_warning_lang'))?.trim() ?? '';
  return LocFixWarning(on != 'false', lang.isEmpty ? 'en' : lang);
});

/// Text in English, Urdu or both (Urdu right-to-left).
class BiText extends StatelessWidget {
  final LocFixWarning w;
  final String en;
  final String ur;
  final TextStyle? style;
  const BiText(this.w, {super.key, required this.en, required this.ur, this.style});

  @override
  Widget build(BuildContext context) {
    // Urdu reads right-to-left: its line starts on the right, and English
    // words inside it (shop names) keep their own order.
    final urText = Directionality(
      textDirection: TextDirection.rtl,
      child: Text(ur, textAlign: TextAlign.start, style: (style ?? const TextStyle()).copyWith(height: 1.6)),
    );
    if (!w.ur) return Text(en, style: style);
    if (!w.en) return Align(alignment: Alignment.centerRight, child: urText);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(en, style: style),
      Align(alignment: Alignment.centerRight, child: urText),
    ]);
  }
}

String _bi(LocFixWarning w, String en, String ur) => !w.ur ? en : (!w.en ? ur : '$en\n$ur');

/// English (shop name, code) inside an Urdu sentence, kept in its own order.
String _iso(String s) => '\u2068$s\u2069';

/// Warns before saving a location that a different shop already has.
/// True = go ahead (no clash, or the user chose Save anyway).
Future<bool> confirmFreeSpot(
  BuildContext context,
  AppDatabase db, {
  required double lat,
  required double lng,
  required String customerId,
  required String shopName,
  LocFixWarning warning = const LocFixWarning(true, 'en'),
}) async {
  if (!warning.on) return true; // switched off in Admin Settings
  List<CustomersData> hits = const [];
  try {
    hits = await otherShopsAtSpot(db, lat: lat, lng: lng, customerId: customerId);
  } catch (_) {}
  if (hits.isEmpty || !context.mounted) return true;
  final w = warning;
  final n = hits.length;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: w.en ? TextDirection.ltr : TextDirection.rtl,
      child: AlertDialog(
      icon: const Icon(Icons.wrong_location_outlined, color: Colors.orange),
      title: BiText(w,
          en: 'This location is already used',
          ur: 'یہ لوکیشن پہلے سے استعمال ہو رہی ہے',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          BiText(w,
              en: n == 1 ? 'Another shop is saved at this exact spot:' : '$n other shops are saved at this exact spot:',
              ur: n == 1 ? 'اس جگہ پر پہلے سے ایک اور دکان محفوظ ہے:' : 'اس جگہ پر پہلے سے $n اور دکانیں محفوظ ہیں:'),
          const SizedBox(height: 6),
          for (final h in hits.take(5))
            Align(
              alignment: w.en ? Alignment.centerLeft : Alignment.centerRight,
              // Code + name are English: always left-to-right.
              child: Text('${h.code}  ${h.shopName}',
                  textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          if (n > 5) BiText(w, en: 'and ${n - 5} more', ur: 'اور ${n - 5} مزید'),
          const SizedBox(height: 10),
          BiText(w,
              en: 'Save it only if you are standing at $shopName.',
              ur: 'صرف اسی صورت میں محفوظ کریں جب آپ ${_iso(shopName)} پر موجود ہوں۔',
              style: const TextStyle(fontSize: 12.5)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_bi(w, 'Go back', 'واپس جائیں'), textAlign: TextAlign.center)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_bi(w, 'Save anyway', 'پھر بھی محفوظ کریں'), textAlign: TextAlign.center)),
      ],
    ),
    ),
  );
  return go == true;
}

/// Shops whose saved location is shared with a different shop — the
/// "location needs fixing" list. Kept on the phone, refreshed with the org
/// settings (every few minutes when online).
const _suspectKey = 'loc_suspect_ids';

Future<void> refreshSuspectLocations(AppDatabase db, String orgId) async {
  try {
    final rows = await Supabase.instance.client.rpc('customer_location_shared', params: {'p_org_id': orgId});
    final ids = [for (final r in rows as List) '${r['customer_id']}'];
    await db.setConfig(_suspectKey, jsonEncode(ids));
  } catch (_) {} // offline / not set up: keep the last list
}

Future<void> clearSuspect(AppDatabase db, String customerId) async {
  try {
    final raw = await db.getConfig(_suspectKey);
    if (raw == null || raw.isEmpty) return;
    final ids = [for (final x in jsonDecode(raw) as List) '$x']..remove(customerId);
    await db.setConfig(_suspectKey, jsonEncode(ids));
  } catch (_) {}
}

final suspectLocationIdsProvider = FutureProvider<Set<String>>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  try {
    final raw = await db.getConfig(_suspectKey);
    if (raw == null || raw.isEmpty) return <String>{};
    return {for (final x in jsonDecode(raw) as List) '$x'};
  } catch (_) {
    return <String>{};
  }
});
