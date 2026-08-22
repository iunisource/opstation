import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';

/// Floating "Request a call back" pill for org master admins / admins. Opens a
/// modal (name, email, phone — phone required) and emails the super admin via
/// the request-callback edge function. Sits bottom-left so it doesn't clash
/// with the Station Master bubble (bottom-right).
class RequestCallbackButton extends ConsumerWidget {
  const RequestCallbackButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final role = user?.role;
    final show = role == WebUserRole.masterAdmin || role == WebUserRole.admin;
    if (!show) return const SizedBox.shrink();
    // Only on the main dashboard, not every screen.
    if (GoRouterState.of(context).matchedLocation != '/dashboard') return const SizedBox.shrink();

    return Positioned(
      right: 88,
      bottom: 74,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: () => showRequestCallbackDialog(context, ref),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.support_agent, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('Request a call back',
                  style: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Shared callback dialog — used by the floating button and the trial-ended wall.
void showRequestCallbackDialog(BuildContext context, WidgetRef ref) {
    final user = ref.read(currentUserProvider);
    final nameCtrl = TextEditingController(text: user?.name ?? '');
    final emailCtrl = TextEditingController(text: user?.email ?? '');
    final phoneCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    bool busy = false;
    bool done = false;
    String? error;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setS) {
          Future<void> submit() async {
            if (phoneCtrl.text.trim().isEmpty) {
              setS(() => error = 'Please enter a phone number so we can reach you.');
              return;
            }
            setS(() { busy = true; error = null; });
            const map = {
              'contact_required': 'Please enter a phone number.',
              'not_configured': 'Callbacks aren\'t set up yet — the support inbox is missing. Please contact your administrator.',
              'send_failed': 'The request could not be emailed right now. Please try again shortly.',
            };
            try {
              final res = await Supabase.instance.client.functions.invoke('request-callback', body: {
                'name': nameCtrl.text.trim(),
                'email': emailCtrl.text.trim(),
                'contact': phoneCtrl.text.trim(),
                'orgName': user?.orgName ?? '',
                'message': msgCtrl.text.trim(),
              });
              final data = res.data is Map ? res.data as Map : const {};
              if (res.status == 200 && data['ok'] == true) {
                setS(() { busy = false; done = true; });
              } else {
                final code = data['error'] as String?;
                setS(() { busy = false; error = map[code] ?? 'Could not send your request. Please try again.'; });
              }
            } on FunctionException catch (e) {
              final det = e.details;
              final code = det is Map ? det['error'] as String? : null;
              setS(() { busy = false; error = map[code] ?? 'Could not send your request. Please try again.'; });
            } catch (e) {
              setS(() { busy = false; error = 'Could not send your request. Please try again.'; });
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(children: [
              Container(
                height: 38, width: 38, alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppTheme.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.support_agent, color: AppTheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Request a call back',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
            ]),
            content: SizedBox(
              width: 400,
              child: done
                  ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          height: 40, width: 40, alignment: Alignment.center,
                          decoration: BoxDecoration(color: AppTheme.success.withOpacity(0.12), shape: BoxShape.circle),
                          child: const Icon(Icons.check, color: AppTheme.success),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(child: Text('Thanks! Our team will call you shortly.',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
                      ]),
                    ])
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Leave your details and our team will reach out.',
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      ),
                      const SizedBox(height: 14),
                      TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Your name')),
                      const SizedBox(height: 10),
                      TextField(controller: emailCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(labelText: 'Email')),
                      const SizedBox(height: 10),
                      TextField(controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone number *')),
                      const SizedBox(height: 10),
                      TextField(controller: msgCtrl,
                          maxLines: 3,
                          decoration: const InputDecoration(labelText: 'Anything specific? (optional)')),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(error!, style: const TextStyle(color: AppTheme.danger, fontSize: 12.5)),
                      ],
                    ]),
            ),
            actions: done
                ? [ElevatedButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Done'))]
                : [
                    TextButton(onPressed: busy ? null : () => Navigator.pop(dialogCtx), child: const Text('Cancel')),
                    ElevatedButton(
                      onPressed: busy ? null : submit,
                      child: busy
                          ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Send request'),
                    ),
                  ],
          );
        },
      ),
    );
}
