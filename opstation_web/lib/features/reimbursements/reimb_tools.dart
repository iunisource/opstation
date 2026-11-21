import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The claims to show: the status tab, the search text, and (optionally) only Combined Trip Summaries.
List<Map<String, dynamic>> claimsShown({
  required List<Map<String, dynamic>> claims,
  required String tab,
  String query = '',
  bool onlyCombined = false,
}) =>
    claims.where((c) {
      if (tab != 'all' && c['status'] != tab) return false;
      if (onlyCombined && c['doc_type'] != 'combined_summary') return false;
      if (query.isNotEmpty) {
        final s = '${c['claimant_name']} ${c['paid_ref'] ?? ''}'.toLowerCase();
        if (!s.contains(query.toLowerCase())) return false;
      }
      return true;
    }).toList();

/// How many Combined Trip Summaries the current tab and search hold (the number on the filter pill).
int combinedCount({required List<Map<String, dynamic>> claims, required String tab, String query = ''}) =>
    claimsShown(claims: claims, tab: tab, query: query, onlyCombined: true).length;

/// The message that goes with a shared claim.
String reimbShareText({
  required String claimant,
  required String docLabel,
  required String dates,
  required String km,
  required String amount,
  String? rateNote,
  String? link,
}) =>
    [
      'Reimbursement approved',
      '$claimant \u00B7 $docLabel',
      '$dates \u00B7 $km',
      [amount, if (rateNote != null && rateNote.isNotEmpty) '($rateNote)'].join(' '),
      if (link != null && link.isNotEmpty) '\nCheck it here: $link',
    ].join('\n');

/// Opens WhatsApp (the app, or WhatsApp Web) with [text] ready to send to a contact of the person's choice.
Uri whatsAppShareUri(String text) => Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');

enum ClaimShare { whatsApp, copyLink }

/// The share button on an approved claim: share on WhatsApp, or copy the link.
class ClaimShareMenu extends StatelessWidget {
  const ClaimShareMenu({super.key, required this.onSelected});

  final void Function(ClaimShare how) onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ClaimShare>(
      tooltip: 'Share',
      icon: const Icon(Icons.share_outlined, size: 20, color: AppTheme.primary),
      onSelected: onSelected,
      itemBuilder: (_) => const [
        PopupMenuItem(value: ClaimShare.whatsApp, child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.chat_outlined, size: 20), title: Text('Share on WhatsApp'))),
        PopupMenuItem(value: ClaimShare.copyLink, child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.link, size: 20), title: Text('Copy link'))),
      ],
    );
  }
}
