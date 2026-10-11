import 'package:flutter/material.dart';
import 'legend_item.dart';
import 'pie_chart_view.dart';

class ColorPieChartWidget extends StatelessWidget {
  final Map<Color, int> data;
  final double? height;
  const ColorPieChartWidget(this.data, {super.key, this.height});
  @override
  Widget build(BuildContext context) {
    final total = data.values.fold<int>(0, (a, b) => a + b);
    final entries = data.entries.toList()
      ..sort(
        (a, b) => HSLColor.fromColor(
          a.key,
        ).hue.compareTo(HSLColor.fromColor(b.key).hue),
      );
    return PieChartView(
      entries
          .map(
            (e) => CountItemData(
              e.key,
              e.value.toString(),
              total == 0 ? 0 : e.value / total * 100,
              e.value,
            ),
          )
          .toList(),
      height: height,
    );
  }
}
