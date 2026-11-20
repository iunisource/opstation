import 'package:flutter/foundation.dart';

import 'floating_alerts_model.dart';

/// A request to show a sample alert with the given options (not necessarily saved yet).
class FloatingAlertPreviewRequest {
  FloatingAlertPreviewRequest(this.n, this.settings);

  /// 1, 2, 3 ... so each press gives the next sample.
  final int n;
  final FloatingAlertSettings settings;
}

/// The "Show a sample" button in Admin Settings talks to the alerts host through this.
class FloatingAlertPreview {
  FloatingAlertPreview._();

  static final ValueNotifier<FloatingAlertPreviewRequest?> requests = ValueNotifier<FloatingAlertPreviewRequest?>(null);
  static int _n = 0;

  static void show(FloatingAlertSettings settings) {
    requests.value = FloatingAlertPreviewRequest(++_n, settings);
  }
}
