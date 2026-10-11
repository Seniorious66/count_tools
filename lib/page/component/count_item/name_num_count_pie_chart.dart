import 'package:count_tools/data/model/sub_project_data.dart';
import 'package:count_tools/utils/safe_utils.dart';
import 'package:count_tools/utils/ui_utils.dart';
import 'package:flutter/material.dart';
import 'legend_item.dart';
import 'pie_chart_view.dart';

class NameNumPieChartWidget extends StatelessWidget {
  final List<SubProjectData> data;
  final int count;
  final double? height;
  const NameNumPieChartWidget(this.data, this.count, {super.key, this.height});
  @override
  Widget build(BuildContext context) => PieChartView(
    data
        .map(
          (e) => CountItemData(
            parseColor(e.color),
            e.name,
            count == 0 ? 0 : safeInt(e.count) / count * 100,
            safeInt(e.count),
          ),
        )
        .toList(),
    height: height,
    showCount: true,
  );
}
