import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// "Update available" prompt for the Play Store app.
///
/// Asks Google Play whether a newer version is published. When there is one,
/// shows a prompt with **Later** and **Update** — at most about twice a day
/// (every [_every]) until the phone is updated. **Update** opens Play's own
/// update screen inside the app, which downloads and installs right away on
/// any connection (Wi-Fi or mobile data) and restarts the app.
/// Phones not installed from Play (side-loaded APKs) never see it.
class UpdatePrompter extends StatefulWidget {
  final Widget child;
  const UpdatePrompter({super.key, required this.child});
  @override
  State<UpdatePrompter> createState() => _UpdatePrompterState();
}

const _every = Duration(hours: 10); // ~twice in a working day
const _lastKey = 'update_prompt_last_shown';

class _UpdatePrompterState extends State<UpdatePrompter> with WidgetsBindingObserver {
  bool _show = false;
  bool _busy = false;
  bool _checking = false;
  DateTime? _lastCheck;
  Timer? _first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Let the app open and settle first.
    _first = Timer(const Duration(seconds: 8), _check);
  }

  @override
  void dispose() {
    _first?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!Platform.isAndroid || _checking || _show) return;
    // Don't ask Play more than every 30 minutes.
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!) < const Duration(minutes: 30)) return;
    _checking = true;
    _lastCheck = now;
    try {
      final info = await InAppUpdate.checkForUpdate();
      if (info.updateAvailability == UpdateAvailability.developerTriggeredUpdateInProgress) {
        // An update started earlier was interrupted: let Play finish it.
        await InAppUpdate.performImmediateUpdate();
        return;
      }
      if (info.updateAvailability != UpdateAvailability.updateAvailable) return;
      final prefs = await SharedPreferences.getInstance();
      final last = DateTime.tryParse(prefs.getString(_lastKey) ?? '');
      if (last != null && now.difference(last) < _every) return;
      await prefs.setString(_lastKey, now.toIso8601String());
      if (mounted) setState(() => _show = true);
    } catch (_) {
      // Not installed from Play, no Play services, offline: nothing to do.
    } finally {
      _checking = false;
    }
  }

  Future<void> _update() async {
    setState(() => _busy = true);
    try {
      final r = await InAppUpdate.performImmediateUpdate();
      // On success Play restarts the app. If they backed out, close the prompt.
      if (r != AppUpdateResult.success && mounted) setState(() => _show = false);
    } catch (_) {
      // Fall back to the app's Play Store page.
      try {
        final pkg = (await PackageInfo.fromPlatform()).packageName;
        final ok = await launchUrl(Uri.parse('market://details?id=$pkg'), mode: LaunchMode.externalApplication);
        if (!ok) {
          await launchUrl(Uri.parse('https://play.google.com/store/apps/details?id=$pkg'),
              mode: LaunchMode.externalApplication);
        }
      } catch (_) {}
      if (mounted) setState(() => _show = false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(children: [
      widget.child,
      // Blocks taps on the app behind until Later / Update.
      const Positioned.fill(child: ModalBarrier(dismissible: false, color: Color(0x73000000))),
      Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Material(
            color: scheme.surface,
            elevation: 6,
            borderRadius: BorderRadius.circular(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: scheme.primary.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.system_update_outlined, color: scheme.primary),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Update available', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    'A new version of Opstation is ready with the latest fixes and features. '
                    'Update now — it takes about a minute and you can continue right after.',
                    style: TextStyle(fontSize: 14, height: 1.4, color: scheme.onSurface.withOpacity(0.75)),
                  ),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _show = false),
                      child: const Text('Later'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy ? null : _update,
                      child: _busy
                          ? const SizedBox(
                              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Update'),
                    ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
