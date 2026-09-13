import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

class ErpPlaceholderScreen extends StatelessWidget {
  final String title;
  const ErpPlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background,
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 700 ? 16 : 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('Coming soon — this module is under construction.',
              style: TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}
