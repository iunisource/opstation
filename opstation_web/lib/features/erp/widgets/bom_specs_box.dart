// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

/// Production specs written on a BOM (text + artwork / label files), shown
/// read-only wherever that BOM is produced: Job Card and Production Voucher.

/// Files attached to a BOM's specs (stored in voucher_documents, type 'BOM').
Future<List<Map<String, dynamic>>> loadBomSpecDocs(String? bomId) async {
  if (bomId == null || bomId.isEmpty) return const [];
  try {
    final rows = await Supabase.instance.client
        .from('voucher_documents')
        .select('id, url, name, file_type, doc_no')
        .eq('voucher_type', 'BOM')
        .eq('voucher_id', bomId)
        .order('doc_no', ascending: true);
    return List<Map<String, dynamic>>.from(rows);
  } catch (_) {
    return const [];
  }
}

bool bomHasSpecs(Map<String, dynamic>? bom, List<Map<String, dynamic>> docs) {
  final t = (bom?['production_specs'] as String?)?.trim() ?? '';
  return t.isNotEmpty || docs.isNotEmpty;
}

bool _isImage(Map<String, dynamic> d) =>
    '${d['file_type'] ?? ''}'.startsWith('image/') ||
    RegExp(r'\.(jpe?g|png|webp|gif)$', caseSensitive: false).hasMatch('${d['name'] ?? ''}');

/// HTML block for printed job cards / vouchers. Empty when there are no specs.
String bomSpecsHtml(Map<String, dynamic>? bom, List<Map<String, dynamic>> docs) {
  if (!bomHasSpecs(bom, docs)) return '';
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  final text = (bom?['production_specs'] as String?)?.trim() ?? '';
  final imgs = docs.where(_isImage).toList();
  final others = docs.where((d) => !_isImage(d)).toList();
  final b = StringBuffer()
    ..write('<div class="sec">Production specs</div>')
    ..write('<div style="border:2px solid #f59e0b;background:#fffbeb;border-radius:8px;padding:8px 10px;margin-bottom:14px">');
  if (text.isNotEmpty) b.write('<div style="white-space:pre-wrap;font-size:12.5px">${esc(text)}</div>');
  if (imgs.isNotEmpty) {
    b.write('<div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:8px">');
    for (final d in imgs) {
      b.write('<img src="${esc('${d['url']}')}" style="max-width:220px;max-height:160px;border:1px solid #ddd;border-radius:4px">');
    }
    b.write('</div>');
  }
  if (others.isNotEmpty) {
    b.write('<div style="margin-top:6px;font-size:11px;color:#666">Attached: '
        '${others.map((d) => esc('${d['name'] ?? 'file'}')).join(', ')}</div>');
  }
  b.write('</div>');
  return b.toString();
}

class BomSpecsBox extends StatelessWidget {
  final Map<String, dynamic>? bom;
  final List<Map<String, dynamic>> docs;
  /// Show the "Specs updated" warning (specs changed after this job was made
  /// or last noted) with a button to confirm it has been seen.
  final bool updated;
  final VoidCallback? onNoted;

  const BomSpecsBox({super.key, required this.bom, required this.docs, this.updated = false, this.onNoted});

  @override
  Widget build(BuildContext context) {
    if (!bomHasSpecs(bom, docs)) return const SizedBox.shrink();
    final text = (bom?['production_specs'] as String?)?.trim() ?? '';
    final imgs = docs.where(_isImage).toList();
    final others = docs.where((d) => !_isImage(d)).toList();
    final amber = Colors.amber.shade800;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: updated ? Colors.deepOrange : const Color(0xFFF59E0B), width: updated ? 2 : 1.2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.assignment_outlined, size: 18, color: amber),
          const SizedBox(width: 6),
          Expanded(child: Text('Production specs${bom?['code'] != null ? ' · ${bom!['code']}' : ''}',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: amber))),
        ]),
        if (updated) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            decoration: BoxDecoration(color: Colors.deepOrange.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.campaign_outlined, size: 18, color: Colors.deepOrange),
              const SizedBox(width: 8),
              const Expanded(child: Text('Specs updated since this job was made — please read them again.',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.deepOrange))),
              if (onNoted != null)
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange, visualDensity: VisualDensity.compact),
                  onPressed: onNoted,
                  child: const Text('Noted'),
                ),
            ]),
          ),
        ],
        if (text.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.4)),
        ],
        if (imgs.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final d in imgs)
              InkWell(
                onTap: () => html.window.open('${d['url']}', '_blank'),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network('${d['url']}', width: 120, height: 90, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(width: 120, height: 90, color: AppTheme.background,
                          child: const Icon(Icons.broken_image_outlined, color: AppTheme.textSecondary))),
                ),
              ),
          ]),
        ],
        if (others.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final d in others)
              ActionChip(
                avatar: const Icon(Icons.attach_file, size: 16),
                label: Text('${d['name'] ?? 'File'}', style: const TextStyle(fontSize: 12)),
                onPressed: () => html.window.open('${d['url']}', '_blank'),
              ),
          ]),
        ],
      ]),
    );
  }
}
