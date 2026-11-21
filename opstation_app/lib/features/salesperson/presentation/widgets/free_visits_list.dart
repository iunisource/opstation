import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// The visits marked so far on a free route, in the order they were marked, each with its place name (once
/// found), the time, whether it has a picture, and whether it has reached the server yet.
class FreeVisitsList extends StatelessWidget {
  const FreeVisitsList({super.key, required this.rows});

  /// FreeVisits.forTrip: oldest first.
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final hint = Theme.of(context).hintColor;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Text('Visits marked (${rows.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final ts = (r['ts'] as num?)?.toInt();
              final at = ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
              final place = '${r['place'] ?? ''}'.trim();
              final hasPhoto = '${r['photo'] ?? ''}'.trim().isNotEmpty;
              final sent = r['synced'] == true;
              final err = '${r['err'] ?? ''}'.trim();
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: const Color(0xFF059669),
                  child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
                title: Text(place.isEmpty ? 'Visit ${i + 1}' : place, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                subtitle: Text(at == null ? '' : DateFormat('hh:mm a').format(at), style: TextStyle(fontSize: 11.5, color: hint)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (hasPhoto) const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.photo_camera_outlined, size: 18, color: Color(0xFF059669))),
                  Tooltip(
                    message: sent
                        ? 'Sent to the office'
                        : (err.isEmpty ? 'Waiting to send: it goes when the network allows' : 'Waiting to send. Last try: $err'),
                    child: Icon(sent ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined, size: 18, color: sent ? const Color(0xFF059669) : const Color(0xFFB45309)),
                  ),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}
