import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_theme.dart';

/// Wraps any "shape" widget in a left-to-right shimmer sweep. Build the shapes
/// as plain opaque containers; the shimmer gradient is painted over them.
class SkeletonLoader extends StatelessWidget {
  final Widget child;
  const SkeletonLoader({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFFE5EAF1),
      highlightColor: const Color(0xFFF6F8FC),
      period: const Duration(milliseconds: 1200),
      child: child,
    );
  }
}

/// A single rounded skeleton bar.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE5EAF1),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

/// A skeleton shaped like a data table: a header strip plus [rows] shimmer
/// rows, sized to sit inside the same bordered card the real table uses.
class TableSkeleton extends StatelessWidget {
  final int rows;
  const TableSkeleton({super.key, this.rows = 9});

  @override
  Widget build(BuildContext context) {
    return SkeletonLoader(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            decoration: const BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: const Row(children: [
              Expanded(flex: 4, child: SkeletonBar(width: 90)),
              SizedBox(width: 16),
              Expanded(flex: 2, child: SkeletonBar(width: 50)),
              SizedBox(width: 16),
              Expanded(flex: 2, child: SkeletonBar(width: 50)),
              SizedBox(width: 16),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: SkeletonBar(width: 44))),
            ]),
          ),
          const Divider(height: 1),
          for (int i = 0; i < rows; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              child: Row(children: [
                Expanded(flex: 4, child: SkeletonBar(width: 120 + (i % 3) * 50.0)),
                const SizedBox(width: 16),
                const Expanded(flex: 2, child: SkeletonBar(width: 70)),
                const SizedBox(width: 16),
                const Expanded(flex: 2, child: SkeletonBar(width: 60)),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: SkeletonBar(width: 40 + (i % 2) * 24.0))),
              ]),
            ),
            if (i != rows - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}
