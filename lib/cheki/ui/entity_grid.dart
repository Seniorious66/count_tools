import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'theme.dart';

class EntityGridItem {
  const EntityGridItem({
    required this.id,
    required this.name,
    required this.onTap,
    this.subtitle,
    this.color,
    this.inactive = false,
    this.inactiveLabel,
  });
  final String id, name;
  final String? subtitle;
  final Color? color;
  final bool inactive;
  final String? inactiveLabel;
  String? get status => inactiveLabel ?? (inactive ? '已停用' : null);
  final VoidCallback onTap;
}

/// The available logical width and actual font determine density. No font
/// shrinking or fixed character-count assumption is used for Chinese names.
class CompactEntityGrid extends StatelessWidget {
  const CompactEntityGrid({required this.items, super.key});
  final List<EntityGridItem> items;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final titleStyle = Theme.of(
        context,
      ).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600);
      final subtitleStyle = Theme.of(context).textTheme.bodySmall!;
      TextPainter measure(
        String value,
        TextStyle style,
        double width, {
        int? maxLines = 2,
      }) => TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: maxLines,
      )..layout(maxWidth: math.max(1, width));
      final large = scaler.scale(15) > 22;
      bool wordsFit(String value, TextStyle style, double width) =>
          RegExp(r'[A-Za-z][A-Za-z0-9]*').allMatches(value).every((match) {
            final word = TextPainter(
              text: TextSpan(text: match.group(0), style: style),
              textDirection: Directionality.of(context),
              textScaler: scaler,
            )..layout();
            return word.width <= width;
          });
      final choices = large ? [2, 1] : [4, 3];
      var columns = choices.last;
      for (final n in choices) {
        final width = (box.maxWidth - 8 * (n - 1)) / n - 24;
        if (items.every(
          (item) =>
              !measure(item.name, titleStyle, width).didExceedMaxLines &&
              wordsFit(item.name, titleStyle, width) &&
              (item.subtitle == null ||
                  (wordsFit(item.subtitle!, subtitleStyle, width) &&
                      !measure(
                        item.subtitle!,
                        subtitleStyle,
                        width,
                      ).didExceedMaxLines)),
        )) {
          columns = n;
          break;
        }
      }
      final width = (box.maxWidth - 8 * (columns - 1)) / columns;
      var height = math.max(76.0, width);
      for (final item in items) {
        final textHeight =
            measure(item.name, titleStyle, width - 24).height +
            (item.subtitle == null
                ? 0
                : measure(item.subtitle!, subtitleStyle, width - 24).height +
                      4);
        height = math.max(
          height,
          textHeight +
              24 +
              (item.color == null ? 0 : 18) +
              (item.status != null
                  ? measure(
                          item.status!,
                          subtitleStyle,
                          width - 24,
                          maxLines: null,
                        ).height +
                        4
                  : 0),
        );
      }
      return GridView.builder(
        key: ValueKey('entity-grid-$columns'),
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
          mainAxisExtent: height,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final description = [
            item.name,
            ?item.subtitle,
            ?item.status,
          ].join(' · ');
          return Semantics(
            button: true,
            label: description,
            onTap: item.onTap,
            excludeSemantics: true,
            child: Tooltip(
              message: description,
              child: Material(
                color: ChekiColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: ChekiColors.line),
                ),
                child: InkWell(
                  key: ValueKey(item.id),
                  onTap: item.onTap,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (item.color != null) ...[
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: item.color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: ChekiColors.inputBorder,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          item.name,
                          style: titleStyle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (item.subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.subtitle!,
                            style: subtitleStyle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (item.status != null) ...[
                          const SizedBox(height: 4),
                          Text(item.status!, style: subtitleStyle),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
