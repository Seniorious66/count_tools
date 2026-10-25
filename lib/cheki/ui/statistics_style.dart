import 'package:flutter/material.dart';

/// Data boundaries stay independent of member fill colors and text scaling.
const statisticsOutlineColor = Colors.black;
const statisticsOutlineWidth = .5;

Paint statisticsOutlinePaint() => Paint()
  ..color = statisticsOutlineColor
  ..style = PaintingStyle.stroke
  ..strokeWidth = statisticsOutlineWidth;

class StatisticsDot extends StatelessWidget {
  const StatisticsDot({required this.color, super.key});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(
        color: statisticsOutlineColor,
        width: statisticsOutlineWidth,
      ),
    ),
  );
}
