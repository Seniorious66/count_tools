import 'package:flutter/material.dart';
import 'theme.dart';

/// Presentation only: IDs, grouping, money and navigation stay with the reader.
class CompactRecordContent extends StatelessWidget {
  const CompactRecordContent({
    required this.date,
    required this.members,
    required this.quantitySize,
    required this.attributesReceipt,
    required this.cost,
    required this.onTap,
    super.key,
  });
  final String date, quantitySize, attributesReceipt, cost;
  final List<({String name, Color color})> members;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final names = members.map((m) => m.name).join('、');
    final summary = members.isEmpty ? '成员未填写' : members.first.name;
    return Semantics(
      button: true,
      label: [
        date,
        members.isEmpty ? '成员未填写' : names,
        quantitySize,
        attributesReceipt,
        if (cost.isNotEmpty) cost,
      ].join('，'),
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 244 ||
                  MediaQuery.textScalerOf(context).scale(14) > 19;
              final identity = Column(
                key: const ValueKey('record-identity'),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(date, style: const TextStyle(fontSize: 14, height: 1.3)),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 46),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (members.isNotEmpty) ...[
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final m in members.take(3))
                                Container(
                                  width: 8,
                                  height: 8,
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: m.color,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: ChekiColors.inputBorder,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              height: 1.15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (members.length > 1) ...[
                          const SizedBox(width: 4),
                          Text(
                            '等${members.length}人',
                            style: const TextStyle(
                              fontSize: 12,
                              color: ChekiColors.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
              final details = Column(
                key: const ValueKey('record-facts'),
                crossAxisAlignment: stacked
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final text in [
                    quantitySize,
                    attributesReceipt,
                    if (cost.isNotEmpty) cost,
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        text,
                        textAlign: stacked ? TextAlign.start : TextAlign.end,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                ],
              );
              return ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: stacked
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          identity,
                          const SizedBox(height: 8),
                          details,
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(flex: 6, child: identity),
                          const SizedBox(width: 12),
                          Expanded(flex: 4, child: details),
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
