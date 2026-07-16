import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/sms_service.dart';

/// Shows the last SMS attempts recorded on this device. No Sentry / network /
/// adb needed — the outcome of every send is captured in memory and shown here.
/// Reach it however you wire it in (a button on an admin/settings screen, or a
/// route). Pull down / tap refresh after making a collection to see the result.
class SmsDebugScreen extends StatefulWidget {
  const SmsDebugScreen({super.key});

  @override
  State<SmsDebugScreen> createState() => _SmsDebugScreenState();
}

class _SmsDebugScreenState extends State<SmsDebugScreen> {
  @override
  Widget build(BuildContext context) {
    final entries = SmsService.log;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SMS Debug'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: 'Copy all',
            onPressed: () {
              final text = entries.map((e) => e.line).join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied SMS log')),
              );
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No SMS attempts recorded yet.\n\n'
                  'Make a collection (amount > 0) on a customer, wait for it to '
                  'sync, then tap refresh. Each attempt shows exactly what '
                  'happened — sent, skipped (with reason), gateway rejection '
                  '(with the provider\'s response), or an error.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    e.ok ? Icons.check_circle : Icons.error,
                    color: e.ok ? Colors.green : Colors.red,
                  ),
                  title: Text(e.phone,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(e.outcome,
                      style: const TextStyle(fontSize: 12)),
                  trailing: Text(
                    '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 11, color: Colors.black45),
                  ),
                );
              },
            ),
    );
  }
}
