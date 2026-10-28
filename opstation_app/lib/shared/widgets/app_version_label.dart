import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// "Version 0.2.0 (16) · Built 28 Oct 2026, 4:40 PM".
/// Version and build number come from pubspec (version: 0.2.0+16); the build
/// time is stamped by the build command with --dart-define=BUILD_TIME=….
class AppVersionLabel extends StatelessWidget {
  final TextAlign align;
  const AppVersionLabel({super.key, this.align = TextAlign.left});

  static const _builtAt = String.fromEnvironment('BUILD_TIME');

  static String _fmtBuilt(String raw) {
    final d = DateTime.tryParse(raw);
    if (d == null) return raw;
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${m[d.month - 1]} ${d.year}, $h:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 11, color: Theme.of(context).hintColor);
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final p = snap.data;
        final v = p == null ? '' : 'Version ${p.version} (${p.buildNumber})';
        final b = _builtAt.isEmpty ? '' : 'Built ${_fmtBuilt(_builtAt)}';
        final text = [v, b].where((s) => s.isNotEmpty).join('  ·  ');
        if (text.isEmpty) return const SizedBox.shrink();
        return Text(text, style: style, textAlign: align);
      },
    );
  }
}
