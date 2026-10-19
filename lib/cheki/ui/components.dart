import 'package:flutter/material.dart';
import '../domain/record_contract.dart';
import 'theme.dart';

class ChekiCard extends StatelessWidget {
  const ChekiCard({
    required this.child,
    this.color = ChekiColors.surface,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: color,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: ChekiColors.line),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Configuration owns availability. Missing features have no destination.
class ChekiDestination {
  const ChekiDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.page,
  });
  final String id;
  final String label;
  final IconData icon;
  final Widget page;
}

class ChekiShell extends StatefulWidget {
  ChekiShell({
    required List<ChekiDestination> destinations,
    this.onManage,
    List<Widget> actions = const [],
    super.key,
  }) : destinations = List.unmodifiable(destinations),
       actions = List.unmodifiable(actions) {
    if (destinations.isEmpty) throw ArgumentError('至少需要一个可用页面');
    if (destinations.any(
          (d) => d.id.trim().isEmpty || d.label.trim().isEmpty,
        ) ||
        destinations.map((d) => d.id).toSet().length != destinations.length) {
      throw ArgumentError('页面标识必须非空且唯一，标题必须非空');
    }
  }
  final List<ChekiDestination> destinations;
  final VoidCallback? onManage;
  final List<Widget> actions;
  @override
  State<ChekiShell> createState() => _ChekiShellState();
}

class _ChekiShellState extends State<ChekiShell> {
  int _index = 0;
  @override
  void didUpdateWidget(ChekiShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.destinations[_index].id;
    final next = widget.destinations.indexWhere((d) => d.id == oldId);
    _index = next < 0 ? 0 : next;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _index == 0,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _index != 0) setState(() => _index = 0);
    },
    child: Scaffold(
      appBar: AppBar(
        toolbarHeight: MediaQuery.textScalerOf(context).scale(24) > 32
            ? MediaQuery.textScalerOf(context).scale(24) * 1.5 + 16
            : 56,
        title: Text(
          widget.destinations[_index].label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.onManage != null)
            IconButton(
              onPressed: widget.onManage,
              tooltip: '打开管理',
              icon: const Icon(Icons.tune),
            ),
          ...widget.actions,
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          fit: StackFit.expand,
          children: widget.destinations
              .asMap()
              .entries
              .map(
                (entry) => Offstage(
                  key: ValueKey(entry.value.id),
                  offstage: entry.key != _index,
                  child: TickerMode(
                    enabled: entry.key == _index,
                    child: ExcludeFocus(
                      excluding: entry.key != _index,
                      child: entry.value.page,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
      bottomNavigationBar: widget.destinations.length < 2
          ? null
          : NavigationBar(
              height:
                  80 +
                  (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(
                        0,
                        48,
                      ) *
                      3,
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: widget.destinations
                  .map(
                    (d) => NavigationDestination(
                      icon: Icon(d.icon),
                      label: d.label,
                    ),
                  )
                  .toList(),
            ),
    ),
  );
}

class AttributeSelector extends StatelessWidget {
  const AttributeSelector({
    required this.value,
    required this.onChanged,
    super.key,
  });
  final ChekiAttributes value;
  final ValueChanged<ChekiAttributes> onChanged;
  @override
  Widget build(BuildContext context) {
    final choices = [
      for (final kind in SignatureKind.values)
        _AttributeCheck(
          label: kind.label,
          selected: value.kind == kind,
          onTap: () => onChanged(value.select(kind)),
        ),
      _AttributeCheck(
        label: '背签',
        selected: value.backSigned,
        onTap: value.kind == SignatureKind.signed
            ? () => onChanged(value.setBackSigned(!value.backSigned))
            : null,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // Natural line wrapping for large text; no FittedBox or font reduction.
        final fitsOneRow =
            MediaQuery.textScalerOf(context).scale(15) <= 16 &&
            constraints.maxWidth >= 280;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('属性'),
            const SizedBox(height: 8),
            if (fitsOneRow)
              Row(children: choices.map((c) => Expanded(child: c)).toList())
            else
              Wrap(spacing: 8, runSpacing: 4, children: choices),
          ],
        );
      },
    );
  }
}

class _AttributeCheck extends StatelessWidget {
  const _AttributeCheck({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    checked: selected,
    enabled: onTap != null,
    onTap: onTap,
    child: ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                  color: onTap == null
                      ? ChekiColors.muted
                      : ChekiColors.blueInk,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    color: onTap == null ? ChekiColors.muted : ChekiColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Member color is a marker, never the foreground color of names or quantities.
class MemberLabel extends StatelessWidget {
  const MemberLabel({
    required this.group,
    required this.name,
    required this.color,
    super.key,
  });
  final String group;
  final String name;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: ChekiColors.inputBorder),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text('$group · $name')),
    ],
  );
}
