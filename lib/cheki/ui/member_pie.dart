import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';

/// Both the existing bars and the pie legend format the same exact share.
String biShareLabel(int quantity, int denominator, {int unknown = 0}) =>
    denominator <= 0 || quantity == 0 && unknown > 0
    ? '—'
    : '${(100 * quantity / denominator).toStringAsFixed(1)}%';

class MemberPieSlice {
  const MemberPieSlice(
    this.id,
    this.label,
    this.quantity,
    this.unknown,
    this.color,
  );
  final String id, label;
  final int quantity, unknown;
  final Color color;
  String description(int denominator) =>
      '$label · ${unknown > 0 && quantity == 0 ? '张数未填写' : '$quantity 张'} · '
      '${biShareLabel(quantity, denominator, unknown: unknown)}'
      '${unknown > 0 ? ' · $unknown 条张数未填写' : ''}';
}

class MemberPie extends StatelessWidget {
  MemberPie({
    required List<MemberPieSlice> slices,
    required this.denominator,
    super.key,
  }) : slices = List.unmodifiable(slices);
  final List<MemberPieSlice> slices;
  final int denominator;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (denominator <= 0)
        const Text('暂无可统计张数')
      else
        Center(
          child: SizedBox(
            width: 224,
            height: 224,
            child: ExcludeSemantics(
              child: CustomPaint(
                key: const ValueKey('bi-pie-paint'),
                painter: MemberPiePainter(slices, denominator),
              ),
            ),
          ),
        ),
      if (slices.isNotEmpty) const SizedBox(height: 12),
      for (final slice in slices)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Semantics(
            container: true,
            label: slice.description(denominator),
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    key: ValueKey('bi-pie-color-${slice.id}'),
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.only(top: 4, right: 8),
                    decoration: BoxDecoration(
                      color: slice.color,
                      border: Border.all(color: ChekiColors.inputBorder),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      slice.description(denominator),
                      key: ValueKey('bi-pie-legend-${slice.id}'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// Sector angles use original counts/denominator, never rounded percentages,
/// top-N categories or a second aggregate. Unknown-only rows have no sector.
class MemberPiePainter extends CustomPainter {
  MemberPiePainter(List<MemberPieSlice> slices, this.denominator)
    : slices = List.unmodifiable(slices);
  final List<MemberPieSlice> slices;
  final int denominator;
  @override
  void paint(Canvas canvas, Size size) {
    if (denominator <= 0) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: math.min(size.width, size.height) / 2 - 1,
    );
    var start = -math.pi / 2;
    for (final slice in slices.where((s) => s.quantity > 0)) {
      final sweep = 2 * math.pi * slice.quantity / denominator;
      canvas.drawArc(rect, start, sweep, true, Paint()..color = slice.color);
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()
          ..color = ChekiColors.inputBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant MemberPiePainter old) => true;
}
