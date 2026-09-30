import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';

/// Shared "void instead of delete" pieces for the purchase chain
/// (PO, GRN, Purchase Invoice, Purchase Return Note, Purchase Return Invoice).

bool isVoidedRow(Map? d) =>
    d != null && (d['is_voided'] == true || d['voided_at'] != null);

/// Asks for confirmation and a reason. Returns the reason (possibly empty) or
/// null when cancelled.
Future<String?> askVoidReason(BuildContext context,
    {required String docLabel, required String number, required String effect}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dlg) => StatefulBuilder(
      builder: (dlg, setD) => AlertDialog(
        title: Text('Void $docLabel $number?'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(effect, style: const TextStyle(fontSize: 13, height: 1.4)),
            const SizedBox(height: 8),
            const Text('It keeps its number and audit trail and prints as VOIDED. This cannot be undone.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) => setD(() {}),
              decoration: const InputDecoration(labelText: 'Reason for voiding *', border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dlg, rootNavigator: true).pop(), child: const Text('Keep')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white),
            icon: const Icon(Icons.block, size: 16),
            onPressed: ctrl.text.trim().isEmpty
                ? null
                : () => Navigator.of(dlg, rootNavigator: true).pop(ctrl.text.trim()),
            label: const Text('Void'),
          ),
        ],
      ),
    ),
  );
}

/// Calls one of the void_purchase_* RPCs. Returns null on success, or a
/// readable error message.
Future<String?> runVoidRpc(String rpc, String id, String? userId, String reason) async {
  try {
    await Supabase.instance.client.rpc(rpc, params: {
      'p_id': id,
      'p_user_id': userId,
      'p_reason': reason,
    });
    return null;
  } on PostgrestException catch (e) {
    return e.message;
  } catch (e) {
    return e.toString();
  }
}

/// Red "VOIDED" banner shown at the top of a voided document.
class VoidedBanner extends StatelessWidget {
  final Map detail;
  const VoidedBanner(this.detail, {super.key});

  @override
  Widget build(BuildContext context) {
    final at = DateTime.tryParse('${detail['voided_at'] ?? ''}');
    final by = (detail['voided_by_name'] as String?)?.trim();
    final reason = (detail['void_reason'] as String?)?.trim();
    final parts = <String>[
      if (at != null) 'on ${DateFormat('d MMM yyyy, HH:mm').format(at.toLocal())}',
      if (by != null && by.isNotEmpty) 'by $by',
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.danger.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.danger.withOpacity(0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.block, size: 18, color: AppTheme.danger),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('VOIDED${parts.isEmpty ? '' : ' ${parts.join(' ')}'}',
                style: const TextStyle(color: AppTheme.danger, fontWeight: FontWeight.w800, fontSize: 13)),
            if (reason != null && reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Reason: $reason', style: const TextStyle(fontSize: 12.5)),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('Kept for the record. Its stock and ledger effects have been reversed.',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary)),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Small "Voided" pill for list rows.
class VoidedPill extends StatelessWidget {
  const VoidedPill({super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: AppTheme.danger.withOpacity(0.12), borderRadius: BorderRadius.circular(4)),
        child: const Text('Voided', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.danger)),
      );
}

/// Delete (draft) or Void (posted) action button.
Widget deleteOrVoidButton({required bool draft, required VoidCallback onDelete, required VoidCallback onVoid}) =>
    draft
        ? IconButton(icon: const Icon(Icons.delete_outline, color: AppTheme.danger), tooltip: 'Delete draft', onPressed: onDelete)
        : IconButton(icon: Icon(Icons.block, color: Colors.orange.shade800), tooltip: 'Void', onPressed: onVoid);
