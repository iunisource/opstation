import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import 'intel_delete_access.dart';

/// Remove a shop's survey (SQL 443): VOIDS the rows — hidden everywhere, kept
/// on record with who / when / why. A super admin can instead delete them
/// permanently. Returns true when something changed.
Future<bool> removeShopSurvey(
  BuildContext context, {
  required String orgId,
  required Map<String, dynamic> shop,
  required String kind, // 'placement' | 'competitor'
  required bool superAdmin,
}) async {
  final reason = TextEditingController();
  final what = kind == 'placement' ? 'placement survey' : 'competitor spottings';
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove $what?'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The $what of ${shop['shop_name']} (${shop['code'] ?? ''}) will be removed from all reports '
              'and phones. It stays on record (who removed it, when and why); audits of the shop are kept.'),
          const SizedBox(height: 12),
          TextField(
            controller: reason,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Reason', hintText: 'e.g. surveyed the wrong shop', border: OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(), child: const Text('Cancel')),
        if (superAdmin)
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop('delete'),
            child: const Text('Delete permanently', style: TextStyle(color: AppTheme.danger)),
          ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.of(ctx, rootNavigator: true).pop('void'),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  final why = reason.text.trim();
  reason.dispose();
  if (choice == null || !context.mounted) return false;
  if (choice == 'delete') {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text('This erases the $what of ${shop['shop_name']} and its history for good. It can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return false;
  }
  try {
    final client = Supabase.instance.client;
    if (choice == 'delete') {
      await client.rpc('survey_delete_shop', params: {'p_org': orgId, 'p_customer': shop['id'], 'p_kind': kind});
    } else {
      await client.rpc(kind == 'placement' ? 'placement_audit_remove_shop' : 'competitor_spotting_remove_shop',
          params: {'p_org': orgId, 'p_customer': shop['id'], 'p_reason': why.isEmpty ? null : why});
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(choice == 'delete' ? 'Deleted for ${shop['shop_name']}' : 'Removed for ${shop['shop_name']}')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      final m = e.toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m.contains('super admin') ? 'Only a super admin can delete permanently.' : intelDeleteError(e))));
    }
    return false;
  }
}
