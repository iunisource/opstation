import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/receipt_books.dart';
import '../../../../core/utils/receipt_slip_key.dart';
import '../../../auth/providers/auth_controller.dart';
import '../../providers/trip_controller.dart';

/// Under the CR# field when Receipt books are ON: which book is in use, how
/// many slips are left, and "Cancel a slip" for a torn / spoiled one.
/// Fills the CR# field with the next free slip on open and after a cancel.
class ReceiptBookHint extends ConsumerStatefulWidget {
  final TextEditingController crCtrl;
  const ReceiptBookHint({super.key, required this.crCtrl});

  @override
  ConsumerState<ReceiptBookHint> createState() => _ReceiptBookHintState();
}

class _ReceiptBookHintState extends ConsumerState<ReceiptBookHint> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Set<int> get _localUsed => ref.read(tripControllerProvider.notifier).localReceiptSlips();

  Future<void> _init() async {
    final db = ref.read(appDatabaseProvider);
    await ReceiptBooks.ensureLoaded(db);
    _prefill();
    // Freshen from the server (other phones / the office may have changed it).
    final orgId = ref.read(orgIdProvider);
    if (orgId != null) {
      await ReceiptBooks.refresh(db, orgId);
      _prefill();
    }
  }

  void _prefill() {
    if (!mounted) return;
    if (ReceiptBooks.on) {
      final n = ReceiptBooks.next(_localUsed, lastKey: ref.read(tripControllerProvider.notifier).lastReceiptSlip());
      // Replace only an empty field or our own earlier suggestion.
      final cur = widget.crCtrl.text.trim();
      final single = receiptSlipKeys(cur).length == 1 && RegExp(r'^[A-Za-z]{0,3}[ \-]?\d+$').hasMatch(cur);
      final mine = cur.isEmpty || (single && ReceiptBooks.problem(cur, _localUsed) != null);
      if (n != null && mine) widget.crCtrl.text = n;
    }
    setState(() {});
  }

  Future<void> _cancelSlip() async {
    final serialCtrl = TextEditingController(text: widget.crCtrl.text.trim());
    final reasonCtrl = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Cancel a slip'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('For a torn, spoiled or wrongly written slip. It will not be used again '
              'and is shown to your supervisor.', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: serialCtrl,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Slip number (CR#)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: reasonCtrl,
            decoration: const InputDecoration(labelText: 'Reason', hintText: 'e.g. slip torn'),
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(err!, style: const TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(
            onPressed: () {
              final ks = receiptSlipKeys(serialCtrl.text.trim());
              if (ks.length != 1) return setLocal(() => err = 'Enter one slip number.');
              if (ReceiptBooks.bookOf(ks.first) == null) {
                return setLocal(() => err = 'CR# ${serialCtrl.text.trim()} is not from your receipt book.');
              }
              if (reasonCtrl.text.trim().isEmpty) return setLocal(() => err = 'Give a reason.');
              Navigator.pop(ctx, true);
            },
            child: const Text('Cancel slip'),
          ),
        ],
      )),
    );
    if (ok != true || !mounted) return;
    final orgId = ref.read(orgIdProvider);
    if (orgId == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final k = receiptSlipKeys(serialCtrl.text.trim()).first;
      await ReceiptBooks.cancelSlip(ref.read(appDatabaseProvider), orgId, k, reasonCtrl.text.trim());
      final cur = receiptSlipKeys(widget.crCtrl.text.trim());
      if (cur.length == 1 && cur.first == k) widget.crCtrl.clear();
      _prefill();
      messenger.showSnackBar(SnackBar(content: Text('Slip ${slipLabel(k)} cancelled')));
    } catch (e) {
      final s = '$e';
      messenger.showSnackBar(SnackBar(
          content: Text(s.contains('Socket') || s.contains('host') || s.contains('ClientException')
              ? 'Cancelling a slip needs internet. Try again when online.'
              : s.replaceFirst('Exception: ', '').replaceFirst('Invalid argument(s): ', '')
                  .replaceAll(RegExp(r'PostgrestException\(message: |, code:.*$'), ''))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ReceiptBooks.on) return const SizedBox.shrink();
    final books = ReceiptBooks.books;
    final left = ReceiptBooks.left(_localUsed);
    final text = books.isEmpty
        ? 'No receipt book is issued to you — ask your supervisor.'
        : 'Book ${books.map((b) => b.range).join(' & ')} · $left slip${left == 1 ? '' : 's'} left';
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 4),
      child: Row(children: [
        Icon(Icons.menu_book_outlined, size: 14,
            color: books.isEmpty || left == 0 ? AppColors.danger : AppColors.textSecondaryLight),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 12,
                  color: books.isEmpty || left == 0 ? AppColors.danger : AppColors.textSecondaryLight)),
        ),
        if (books.isNotEmpty)
          TextButton(
            onPressed: _busy ? null : _cancelSlip,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: _busy
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Cancel a slip', style: TextStyle(fontSize: 12)),
          ),
      ]),
    );
  }
}
