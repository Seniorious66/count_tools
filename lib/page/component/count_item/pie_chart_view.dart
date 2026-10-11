import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:count_tools/utils/ui_utils.dart';
import 'legend_item.dart';

/// Native renderer replacing the obsolete charts_flutter dependency.
class PieChartView extends StatelessWidget {
  final List<CountItemData> data;
  final double? height;
  final bool showCount;
  const PieChartView(
    this.data, {
    super.key,
    this.height,
    this.showCount = false,
  });
  @override
  Widget build(BuildContext context) {
    final legend = data.toList()..sort((a, b) => b.count.compareTo(a.count));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: data
              .map(
                (e) =>
                    '${e.name}: ${e.count} (${e.percent.toStringAsFixed(2)}%)',
              )
              .join(', '),
          child: SizedBox(
            height: height ?? 220,
            width: double.infinity,
            child: CustomPaint(painter: _PiePainter(data)),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Wrap(
            alignment: WrapAlignment.center,
            runSpacing: 8,
            children: legend
                .map((e) => LegendItem(e, isShowCount: showCount))
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _PiePainter extends CustomPainter {
  final List<CountItemData> data;
  _PiePainter(this.data);
  @override
  void paint(Canvas canvas, Size size) {
    final total = data.fold<int>(0, (sum, e) => sum + math.max(e.count, 0));
    if (total == 0) return;
    final radius = math.min(size.width, size.height) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    var start = -math.pi / 2;
    for (final item in data.where((e) => e.count > 0)) {
      final sweep = item.count / total * math.pi * 2;
      canvas.drawArc(rect, start, sweep, true, Paint()..color = item.color);
      if (sweep >= 0.22) {
        final angle = start + sweep / 2;
        final label = TextPainter(
          textDirection: TextDirection.ltr,
          text: TextSpan(
            text: '${item.percent.toStringAsFixed(2)}%',
            style: TextStyle(fontSize: 12, color: getTextColor(item.color)),
          ),
        )..layout();
        label.paint(
          canvas,
          center +
              Offset(math.cos(angle), math.sin(angle)) * radius * 0.65 -
              Offset(label.width / 2, label.height / 2),
        );
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter oldDelegate) =>
      oldDelegate.data != data;
}
