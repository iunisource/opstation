/// Floating alerts: the options, the alert itself and the queue that decides
/// which alerts are on screen. No Flutter, no browser — so it can be tested.

/// Options set in Admin Settings (app_config, keys org.float_alerts*).
class FloatingAlertSettings {
  const FloatingAlertSettings({
    this.enabled = true,
    this.seconds = 6,
    this.bottom = false,
    this.chime = true,
    this.maxVisible = 3,
    this.pauseOnHover = true,
  });

  final bool enabled;

  /// How long an alert stays (3 to 30).
  final int seconds;

  /// false = top right (the default), true = bottom right.
  final bool bottom;

  /// A short chime when an alert appears.
  final bool chime;

  /// Alerts on screen at once (1 to 5); the rest wait.
  final int maxVisible;

  /// The countdown pauses while the mouse is on an alert.
  final bool pauseOnHover;

  static const keys = <String>[
    'org.float_alerts',
    'org.float_alerts_seconds',
    'org.float_alerts_position',
    'org.float_alerts_sound',
    'org.float_alerts_max',
    'org.float_alerts_hover',
  ];

  /// Reads the stored values; anything missing or out of range falls back to the default.
  factory FloatingAlertSettings.fromConfig(Map<String, String> c) {
    int num(String k, int d, int lo, int hi) {
      final v = int.tryParse((c[k] ?? '').trim());
      return v == null ? d : v.clamp(lo, hi);
    }

    final on = c['org.float_alerts'];
    return FloatingAlertSettings(
      enabled: on == null ? true : on.trim().toLowerCase() != 'false',
      seconds: num('org.float_alerts_seconds', 6, 3, 30),
      bottom: (c['org.float_alerts_position'] ?? '').trim() == 'bottom_right',
      chime: (c['org.float_alerts_sound'] ?? 'chime').trim() != 'off',
      maxVisible: num('org.float_alerts_max', 3, 1, 5),
      pauseOnHover: (c['org.float_alerts_hover'] ?? 'pause').trim() != 'none',
    );
  }
}

/// What an alert is about — it sets the colour and the icon.
enum AlertKind { action, success, problem, info }

/// The kind of an alert, read from its words (the notification has no event type).
AlertKind alertKindOf(String title, String body) {
  final t = '$title $body'.toLowerCase();
  bool has(List<String> words) => words.any(t.contains);
  if (has(['reject', 'declin', 'denied', 'failed', 'overdue', 'cancelled', 'voided'])) return AlertKind.problem;
  if (has(['approved', 'ready to pay', 'marked paid', 'was paid', 'is paid', 'completed', 'granted'])) return AlertKind.success;
  if (has(['needs', 'waiting', 'pending', 'review', 'supervis', 'approval', 'requested', 'to receive', 'action'])) {
    return AlertKind.action;
  }
  return AlertKind.info;
}

class FloatingAlert {
  const FloatingAlert({required this.id, required this.title, this.body = '', this.link, this.createdAt});

  final String id;
  final String title;
  final String body;

  /// An in-app route, e.g. /erp/purchase. Null = nothing to open.
  final String? link;
  final DateTime? createdAt;

  AlertKind get kind => alertKindOf(title, body);
}

enum AddResult { shown, queued, duplicate }

/// Which alerts are on screen (newest on top, at most [maxVisible]) and which wait.
class FloatingAlertQueue {
  FloatingAlertQueue({this.maxVisible = 3, this.maxWaiting = 20});

  int maxVisible;
  final int maxWaiting;
  final List<FloatingAlert> visible = [];
  final List<FloatingAlert> waiting = [];
  final Set<String> _known = {};

  AddResult add(FloatingAlert a) {
    if (!_known.add(a.id)) return AddResult.duplicate;
    if (visible.length < maxVisible) {
      visible.insert(0, a);
      return AddResult.shown;
    }
    waiting.add(a);
    while (waiting.length > maxWaiting) {
      _known.remove(waiting.removeAt(0).id); // a burst: the oldest waiting one is dropped
    }
    return AddResult.queued;
  }

  /// Removes an alert; a waiting one takes its place on screen.
  void dismiss(String id) {
    final wasVisible = visible.any((a) => a.id == id);
    visible.removeWhere((a) => a.id == id);
    waiting.removeWhere((a) => a.id == id);
    _known.remove(id);
    if (wasVisible) {
      while (visible.length < maxVisible && waiting.isNotEmpty) {
        visible.add(waiting.removeAt(0));
      }
    }
  }

  void clear() {
    visible.clear();
    waiting.clear();
    _known.clear();
  }
}
