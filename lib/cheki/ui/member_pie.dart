import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'statistics_style.dart';

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

/// Largest effective-color buckets occupy even, then odd positions. Attains
/// the circular lower bound max(0, 2*largest-N) for N>=2, including the seam.
List<MemberPieSlice> arrangePieSlices(List<MemberPieSlice> slices) {
  final buckets = <int, List<MemberPieSlice>>{};
  for (final s in slices.where((s) => s.quantity > 0)) {
    (buckets[s.color.toARGB32()] ??= []).add(s);
  }
  final groups = buckets.entries.toList()
    ..sort((a, b) {
      final count = b.value.length.compareTo(a.value.length);
      return count != 0 ? count : a.key.compareTo(b.key);
    });
  final n = groups.fold(0, (n, g) => n + g.value.length);
  final result = List<MemberPieSlice?>.filled(n, null);
  var index = 0;
  for (final group in groups) {
    group.value.sort((a, b) => a.id.compareTo(b.id));
    for (final slice in group.value) {
      if (index >= n) index = 1;
      result[index] = slice;
      index += 2;
    }
  }
  return result.cast<MemberPieSlice>();
}

/// Provisional, reversible UI threshold. Geometry may reject larger labels.
const pieInnerLabelMinimumShare = .05;

class PieInnerLabel {
  const PieInnerLabel(this.slice, this.bounds, this.painter);
  final MemberPieSlice slice;
  final Rect bounds;
  final TextPainter painter;
}

List<PieInnerLabel> layoutPieLabels(
  List<MemberPieSlice> slices,
  int denominator,
  double diameter,
  TextScaler scaler,
  TextDirection direction,
  Color background, {
  TextStyle textStyle = const TextStyle(),
}) {
  if (denominator <= 0) return [];
  final radius = diameter / 2 - 2;
  final center = Offset(diameter / 2, diameter / 2);
  final labels = <PieInnerLabel>[];
  var start = -math.pi / 2;
  for (final slice in slices) {
    final sweep = 2 * math.pi * slice.quantity / denominator;
    if (slice.quantity / denominator >= pieInnerLabelMinimumShare) {
      final angle = start + sweep / 2;
      final anchor =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              radius *
              (slices.length == 1
                  ? 0
                  : sweep > math.pi / 2
                  ? .53
                  : .62);
      // Never shrink text. Every label-box corner must lie inside the sector.
      for (final width in [radius * 1.25, radius, radius * .75, radius * .5]) {
        final color = Color.alphaBlend(slice.color, background);
        TextPainter measure(String name) => TextPainter(
          text: TextSpan(
            text: '$name\n${biShareLabel(slice.quantity, denominator)}',
            style: textStyle.copyWith(
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: color.computeLuminance() > .179
                  ? Colors.black
                  : Colors.white,
            ),
          ),
          textDirection: direction,
          textAlign: TextAlign.center,
          textScaler: scaler,
          maxLines: 3,
          ellipsis: '…',
        )..layout(maxWidth: width);
        final share = TextPainter(
          text: TextSpan(
            text: biShareLabel(slice.quantity, denominator),
            style: textStyle.copyWith(
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: direction,
          textScaler: scaler,
        )..layout();
        final shareWidth = share.width;
        share.dispose();
        if (width < shareWidth) continue;
        var painter = measure(slice.label);
        if (painter.didExceedMaxLines) {
          painter.dispose();
          final characters = slice.label.runes
              .map(String.fromCharCode)
              .toList();
          var low = 0, high = characters.length;
          while (low < high) {
            final mid = (low + high + 1) ~/ 2;
            final attempt = measure('${characters.take(mid).join()}…');
            if (attempt.didExceedMaxLines) {
              high = mid - 1;
            } else {
              low = mid;
            }
            attempt.dispose();
          }
          painter = measure('${characters.take(low).join()}…');
          if (low == 0 || painter.didExceedMaxLines) {
            painter.dispose();
            continue;
          }
        }
        final box = Rect.fromCenter(
          center: anchor,
          width: painter.width + 8,
          height: painter.height + 8,
        );
        bool inside(Offset p) {
          final vector = p - center;
          if (vector.distance > radius - 3) return false;
          if (slices.length == 1) return true;
          final relative =
              (math.atan2(vector.dy, vector.dx) - angle + math.pi) %
                  (2 * math.pi) -
              math.pi;
          // A convex sub-sector also protects a label inside a >180° slice:
          // corner inclusion alone is insufficient for a concave sector.
          return relative.abs() < math.min(sweep / 2, math.pi / 2) - .012;
        }

        if ([
              box.topLeft,
              box.topRight,
              box.bottomLeft,
              box.bottomRight,
            ].every(inside) &&
            labels.every((l) => !l.bounds.overlaps(box))) {
          labels.add(PieInnerLabel(slice, box, painter));
          break;
        }
        painter.dispose();
      }
    }
    start += sweep;
  }
  return labels;
}

class MemberPie extends StatefulWidget {
  MemberPie({
    required List<MemberPieSlice> slices,
    required this.denominator,
    super.key,
  }) : slices = List.unmodifiable(slices);
  final List<MemberPieSlice> slices;
  final int denominator;
  @override
  State<MemberPie> createState() => _MemberPieState();
}

class _MemberPieState extends State<MemberPie> {
  String? selected;
  @override
  void didUpdateWidget(MemberPie old) {
    super.didUpdateWidget(old);
    if (!widget.slices.any((s) => s.id == selected)) selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final drawn = arrangePieSlices(widget.slices);
    final selectedSlice = widget.slices
        .where((s) => s.id == selected)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.denominator <= 0 || drawn.isEmpty)
          const Text('暂无可统计张数')
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final diameter = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 326.0;
              return SizedBox.square(
                dimension: diameter,
                child: GestureDetector(
                  key: const ValueKey('bi-pie-touch'),
                  onTapUp: (event) {
                    final vector =
                        event.localPosition -
                        Offset(diameter / 2, diameter / 2);
                    if (vector.distance > diameter / 2) return;
                    final angle =
                        (math.atan2(vector.dy, vector.dx) + math.pi / 2) %
                        (2 * math.pi);
                    var end = 0.0;
                    for (final s in drawn) {
                      end += 2 * math.pi * s.quantity / widget.denominator;
                      if (angle <= end) {
                        setState(() => selected = s.id);
                        break;
                      }
                    }
                  },
                  child: CustomPaint(
                    key: const ValueKey('bi-pie-paint'),
                    painter: MemberPiePainter(
                      drawn,
                      widget.denominator,
                      scaler: MediaQuery.textScalerOf(context),
                      direction: Directionality.of(context),
                      background: Theme.of(context).scaffoldBackgroundColor,
                      textStyle:
                          Theme.of(context).textTheme.bodySmall ??
                          const TextStyle(),
                      selected: selected,
                      semanticSlices: widget.slices,
                      onSelect: (id) => setState(() => selected = id),
                    ),
                  ),
                ),
              );
            },
          ),
        if (selectedSlice != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                selectedSlice.description(widget.denominator),
                key: const ValueKey('bi-pie-selection'),
              ),
            ),
          ),
        // All identities remain actionable to assistive technology, including
        // tiny/unknown-only entries. Upper member drill-down is unchanged.
        for (final s
            in widget.denominator <= 0 || drawn.isEmpty
                ? widget.slices
                : <MemberPieSlice>[])
          Semantics(
            key: ValueKey('bi-pie-semantic-${s.id}'),
            container: true,
            button: true,
            label: s.description(widget.denominator),
            onTap: () => setState(() => selected = s.id),
            child: ExcludeSemantics(
              child: Text(s.description(widget.denominator)),
            ),
          ),
      ],
    );
  }
}

class MemberPiePainter extends CustomPainter {
  MemberPiePainter(
    List<MemberPieSlice> slices,
    this.denominator, {
    this.scaler = TextScaler.noScaling,
    this.direction = TextDirection.ltr,
    this.background = Colors.white,
    this.textStyle = const TextStyle(),
    this.selected,
    this.semanticSlices,
    this.onSelect,
  }) : slices = List.unmodifiable(slices);
  final List<MemberPieSlice> slices;
  final int denominator;
  final TextScaler scaler;
  final TextDirection direction;
  final Color background;
  final TextStyle textStyle;
  final String? selected;
  final List<MemberPieSlice>? semanticSlices;
  final ValueChanged<String>? onSelect;
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    var start = -math.pi / 2;
    final angles = <String, double>{};
    for (final s in slices) {
      final sweep = 2 * math.pi * s.quantity / denominator;
      angles[s.id] = start + sweep / 2;
      start += sweep;
    }
    return [
      for (final s in semanticSlices ?? slices)
        CustomPainterSemantics(
          key: ValueKey('bi-pie-semantic-${s.id}'),
          rect: Rect.fromCenter(
            center:
                size.center(Offset.zero) +
                Offset.fromDirection(
                  angles[s.id] ?? math.pi / 2,
                  size.width * .28,
                ),
            width: 44,
            height: 44,
          ),
          properties: SemanticsProperties(
            label: s.description(denominator),
            textDirection: direction,
            button: true,
            onTap: onSelect == null ? null : () => onSelect!(s.id),
          ),
        ),
    ];
  };
  @override
  bool shouldRebuildSemantics(covariant MemberPiePainter oldDelegate) => true;
  @override
  void paint(Canvas canvas, Size size) {
    if (denominator <= 0) return;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: math.min(size.width, size.height) / 2 - 2,
    );
    var start = -math.pi / 2;
    for (final slice in slices.where((s) => s.quantity > 0)) {
      final sweep = 2 * math.pi * slice.quantity / denominator;
      final fill = Paint()..color = slice.color;
      if (slices.length == 1) {
        canvas.drawOval(rect, fill);
      } else {
        canvas.drawArc(rect, start, sweep, true, fill);
      }
      start += sweep;
    }
    // Draw shared radial edges once after all fills, without changing their
    // angles or introducing artificial gaps between small sectors.
    final outline = statisticsOutlinePaint();
    canvas.drawOval(rect, outline);
    if (slices.where((s) => s.quantity > 0).length > 1) {
      start = -math.pi / 2;
      for (final slice in slices.where((s) => s.quantity > 0)) {
        canvas.drawLine(
          rect.center,
          rect.center + Offset.fromDirection(start, rect.width / 2),
          outline,
        );
        start += 2 * math.pi * slice.quantity / denominator;
      }
    }
    for (final label in layoutPieLabels(
      slices,
      denominator,
      size.width,
      scaler,
      direction,
      background,
      textStyle: textStyle,
    )) {
      label.painter.paint(canvas, label.bounds.topLeft + const Offset(4, 4));
      label.painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant MemberPiePainter old) => true;
}
