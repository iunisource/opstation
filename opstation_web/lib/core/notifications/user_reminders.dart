// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../../features/auth/auth_controller.dart';

/// Personal, user-created reminders ("remind me every 2 hours to check the
/// Purchase Dashboard"). OFF by default — nothing fires until a user adds one
/// via a screen's Remind-me button.
///
/// Design (deliberately NOT a cron job): each reminder is a row in
/// user_reminders; this engine — mounted once in the shell, so it runs on
/// every screen while logged in — checks once a minute for rows that are due
/// and shows an in-app dialog with a chime. Delivery is in-app only, matching
/// the "while I'm logged in" intent; nothing nags a logged-out user. A
/// recurring reminder advances itself from the moment it FIRES (not from
/// login), so a long absence produces one catch-up nag, never a stack.
class UserRemindersEngine extends ConsumerStatefulWidget {
  const UserRemindersEngine({super.key});
  @override
  ConsumerState<UserRemindersEngine> createState() => _UserRemindersEngineState();
}

class _UserRemindersEngineState extends ConsumerState<UserRemindersEngine> {
  Timer? _tick;
  bool _dialogOpen = false;
  Object? _audio; // WebAudio context for the chime

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 60), (_) => _check());
    // First check shortly after login/refresh so an overdue reminder greets
    // the user without waiting a full minute.
    Future.delayed(const Duration(seconds: 5), _check);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_dialogOpen || !mounted) return;
    final uid = ref.read(currentUserProvider)?.id;
    if (uid == null) return;
    List<Map<String, dynamic>> due;
    try {
      final rows = await Supabase.instance.client
          .from('user_reminders')
          .select()
          .eq('user_id', uid)
          .eq('is_active', true)
          .lte('remind_at', DateTime.now().toUtc().toIso8601String())
          .order('remind_at');
      due = List<Map<String, dynamic>>.from(rows);
    } catch (_) {
      return; // table missing / transient — try again next minute
    }
    if (due.isEmpty || !mounted || _dialogOpen) return;
    _dialogOpen = true;
    _chime();
    try {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DueRemindersDialog(reminders: due),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  void _chime() {
    try {
      var ctor = js_util.getProperty(html.window, 'AudioContext');
      ctor ??= js_util.getProperty(html.window, 'webkitAudioContext');
      if (ctor == null) return;
      _audio ??= js_util.callConstructor(ctor, const []);
      final ctx = _audio!;
      if (js_util.getProperty(ctx, 'state') == 'suspended') {
        js_util.callMethod(ctx, 'resume', const []);
      }
      final now = js_util.getProperty(ctx, 'currentTime') as num;
      final dest = js_util.getProperty(ctx, 'destination');
      void tone(double f, double start, double dur) {
        final osc = js_util.callMethod(ctx, 'createOscillator', const []);
        final gain = js_util.callMethod(ctx, 'createGain', const []);
        js_util.callMethod(osc, 'connect', [gain]);
        js_util.callMethod(gain, 'connect', [dest]);
        js_util.setProperty(osc, 'type', 'sine');
        js_util.setProperty(js_util.getProperty(osc, 'frequency'), 'value', f);
        js_util.setProperty(js_util.getProperty(gain, 'gain'), 'value', 0.4);
        final t0 = now + start;
        js_util.callMethod(osc, 'start', [t0]);
        js_util.callMethod(osc, 'stop', [t0 + dur]);
      }
      tone(880, 0, 0.15);
      tone(1175, 0.18, 0.22);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The "it's time" dialog: every due reminder with Open / Snooze / Done.
class _DueRemindersDialog extends StatefulWidget {
  final List<Map<String, dynamic>> reminders;
  const _DueRemindersDialog({required this.reminders});
  @override
  State<_DueRemindersDialog> createState() => _DueRemindersDialogState();
}

class _DueRemindersDialogState extends State<_DueRemindersDialog> {
  late List<Map<String, dynamic>> _due;

  @override
  void initState() {
    super.initState();
    _due = List.of(widget.reminders);
  }

  /// Recurring: next fire = NOW + interval (counts from the fire, so a late
  /// catch-up doesn't stack). One-time: deactivate.
  Future<void> _complete(Map<String, dynamic> r, {int? snoozeMinutes}) async {
    final c = Supabase.instance.client;
    final now = DateTime.now().toUtc();
    try {
      if (snoozeMinutes != null) {
        await c.from('user_reminders').update({
          'remind_at': now.add(Duration(minutes: snoozeMinutes)).toIso8601String(),
          'updated_at': now.toIso8601String(),
        }).eq('id', r['id']);
      } else {
        final interval = r['interval_minutes'] as int?;
        await c.from('user_reminders').update({
          if (interval != null)
            'remind_at': now.add(Duration(minutes: interval)).toIso8601String(),
          if (interval == null) 'is_active': false,
          'updated_at': now.toIso8601String(),
        }).eq('id', r['id']);
      }
    } catch (_) {}
    setState(() => _due.removeWhere((e) => e['id'] == r['id']));
    if (_due.isEmpty && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  String _dueLabel(Map<String, dynamic> r) {
    final at = DateTime.tryParse('${r['remind_at']}')?.toLocal();
    if (at == null) return '';
    final late = DateTime.now().difference(at);
    if (late.inMinutes < 2) return 'due now';
    if (late.inHours >= 1) return 'was due ${late.inHours}h ago';
    return 'was due ${late.inMinutes}m ago';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(children: [
        Icon(Icons.alarm, color: AppTheme.primary),
        SizedBox(width: 10),
        Text('Reminder'),
      ]),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final r in _due)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primary.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.primary.withOpacity(0.25)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['message']}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  [
                    _dueLabel(r),
                    if (r['interval_minutes'] != null)
                      'repeats every ${_fmtInterval(r['interval_minutes'] as int)}',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  if ((r['route'] as String?)?.isNotEmpty == true)
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white),
                      icon: const Icon(Icons.open_in_new, size: 15),
                      label: Text('Open ${r['route_label'] ?? 'screen'}',
                          style: const TextStyle(fontSize: 12.5)),
                      onPressed: () {
                        final route = r['route'] as String;
                        _complete(r);
                        if (context.mounted) context.go(route);
                      },
                    ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => _complete(r, snoozeMinutes: 30),
                    child: const Text('Snooze 30m', style: TextStyle(fontSize: 12.5)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    onPressed: () => _complete(r),
                    child: const Text('Done', style: TextStyle(fontSize: 12.5)),
                  ),
                ]),
              ]),
            ),
        ]),
      ),
    );
  }
}

String _fmtInterval(int minutes) {
  if (minutes % 60 == 0) {
    final h = minutes ~/ 60;
    return h == 1 ? 'hour' : '$h hours';
  }
  return '$minutes min';
}

/// Add/manage dialog. Screens call this from their "Remind me" button with
/// their own route + a sensible preset message.
Future<void> showUserReminderDialog(
  BuildContext context,
  WidgetRef ref, {
  String? route,
  String? routeLabel,
  String? presetMessage,
}) async {
  final user = ref.read(currentUserProvider);
  if (user == null) return;
  await showDialog(
    context: context,
    builder: (_) => _ManageRemindersDialog(
      orgId: user.orgId ?? '',
      userId: user.id,
      route: route,
      routeLabel: routeLabel,
      presetMessage: presetMessage,
    ),
  );
}

class _ManageRemindersDialog extends StatefulWidget {
  final String orgId;
  final String userId;
  final String? route;
  final String? routeLabel;
  final String? presetMessage;
  const _ManageRemindersDialog({
    required this.orgId,
    required this.userId,
    this.route,
    this.routeLabel,
    this.presetMessage,
  });
  @override
  State<_ManageRemindersDialog> createState() => _ManageRemindersDialogState();
}

class _ManageRemindersDialogState extends State<_ManageRemindersDialog> {
  List<Map<String, dynamic>> _mine = [];
  bool _loading = true;
  bool _saving = false;

  late final TextEditingController _msgCtrl =
      TextEditingController(text: widget.presetMessage ?? '');
  final _hoursCtrl = TextEditingController(text: '2');
  bool _recurring = true;
  DateTime _onceAt = DateTime.now().add(const Duration(hours: 1));

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _hoursCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('user_reminders')
          .select()
          .eq('user_id', widget.userId)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _mine = List<Map<String, dynamic>>.from(rows);
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty) return;
    int? intervalMin;
    DateTime firstFire;
    final now = DateTime.now();
    if (_recurring) {
      final h = double.tryParse(_hoursCtrl.text.trim()) ?? 0;
      if (h <= 0) return;
      intervalMin = (h * 60).round();
      firstFire = now.add(Duration(minutes: intervalMin));
    } else {
      if (_onceAt.isBefore(now)) return;
      firstFire = _onceAt;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('user_reminders').insert({
        'id': 'urem_${now.millisecondsSinceEpoch}',
        'org_id': widget.orgId,
        'user_id': widget.userId,
        'message': msg,
        'route': widget.route,
        'route_label': widget.routeLabel,
        'interval_minutes': intervalMin,
        'remind_at': firstFire.toUtc().toIso8601String(),
        'is_active': true,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: ${e.toString().split('\n').first}')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _toggle(Map<String, dynamic> r, bool on) async {
    try {
      final upd = <String, dynamic>{
        'is_active': on,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      // Re-enabling a recurring reminder restarts its cycle from now.
      final interval = r['interval_minutes'] as int?;
      if (on && interval != null) {
        upd['remind_at'] =
            DateTime.now().add(Duration(minutes: interval)).toUtc().toIso8601String();
      }
      await Supabase.instance.client
          .from('user_reminders')
          .update(upd).eq('id', r['id']);
      await _load();
    } catch (_) {}
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    try {
      await Supabase.instance.client
          .from('user_reminders')
          .delete()
          .eq('id', r['id']);
      await _load();
    } catch (_) {}
  }

  String _scheduleLabel(Map<String, dynamic> r) {
    final interval = r['interval_minutes'] as int?;
    final next = DateTime.tryParse('${r['remind_at']}')?.toLocal();
    final nextStr = next == null ? '' : DateFormat('d MMM HH:mm').format(next);
    if (interval != null) return 'Every ${_fmtInterval(interval)} · next $nextStr';
    return 'Once · $nextStr';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.alarm_add, size: 20, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    widget.routeLabel == null
                        ? 'My reminders'
                        : 'Remind me · ${widget.routeLabel}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
            ]),
            const SizedBox(height: 10),
            TextField(
              controller: _msgCtrl,
              decoration: const InputDecoration(
                  labelText: 'Reminder message', isDense: true,
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            Row(children: [
              ChoiceChip(
                label: const Text('Repeating', style: TextStyle(fontSize: 12.5)),
                selected: _recurring,
                onSelected: (_) => setState(() => _recurring = true),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('One-time', style: TextStyle(fontSize: 12.5)),
                selected: !_recurring,
                onSelected: (_) => setState(() => _recurring = false),
              ),
              const SizedBox(width: 14),
              if (_recurring) ...[
                const Text('Every', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _hoursCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        isDense: true, border: OutlineInputBorder()),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('hours', style: TextStyle(fontSize: 13)),
              ] else
                InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                        context: context,
                        initialDate: _onceAt,
                        firstDate: DateTime.now(),
                        lastDate: DateTime(2100));
                    if (d == null || !mounted) return;
                    final t = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(_onceAt));
                    if (t == null) return;
                    setState(() => _onceAt =
                        DateTime(d.year, d.month, d.day, t.hour, t.minute));
                  },
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.event, size: 15, color: AppTheme.primary),
                    const SizedBox(width: 4),
                    Text(DateFormat('d MMM HH:mm').format(_onceAt),
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600,
                            color: AppTheme.primary)),
                  ]),
                ),
              const Spacer(),
              ElevatedButton(
                onPressed: _saving ? null : _add,
                child: _saving
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Add'),
              ),
            ]),
            const Divider(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('MY REMINDERS',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700,
                      letterSpacing: 0.5, color: AppTheme.textSecondary)),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator())
                  : _mine.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No reminders yet.',
                              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: _mine.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final r = _mine[i];
                            final active = r['is_active'] == true;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(children: [
                                Expanded(
                                  child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('${r['message']}',
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: active
                                                    ? AppTheme.textPrimary
                                                    : AppTheme.textSecondary)),
                                        Text(
                                            [
                                              _scheduleLabel(r),
                                              if ((r['route_label'] as String?)
                                                      ?.isNotEmpty ==
                                                  true)
                                                '${r['route_label']}',
                                            ].join(' · '),
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: AppTheme.textSecondary)),
                                      ]),
                                ),
                                Switch(
                                  value: active,
                                  onChanged: (v) => _toggle(r, v),
                                ),
                                IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        size: 18, color: AppTheme.danger),
                                    onPressed: () => _delete(r)),
                              ]),
                            );
                          },
                        ),
            ),
          ]),
        ),
      ),
    );
  }
}
