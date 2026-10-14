import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import '../domain/member_color.dart';
import 'components.dart';
import 'theme.dart';

/// Display data, not a Person/member persistence model or identity policy.
class MemberOption {
  MemberOption({
    required this.id,
    required this.group,
    required this.name,
    required this.color,
    this.available = true,
  }) {
    if (id.trim().isEmpty || group.trim().isEmpty || name.trim().isEmpty) {
      throw ArgumentError('成员标识、团体和姓名不能为空');
    }
  }
  final String id;
  final String group;
  final String name;
  final Color color;
  final bool available;
  String get label => '$group · $name';
}

/// Controlled field. Dialog changes are private until confirmed. The saving
/// service must recheck availability and the eventual Person identity rule.
class MemberMultiSelectField extends StatelessWidget {
  MemberMultiSelectField({
    required List<MemberOption> options,
    required List<String> selectedIds,
    required this.onChanged,
    this.errorText,
    this.enabled = true,
    super.key,
  }) : options = List.unmodifiable(options),
       selectedIds = List.unmodifiable(selectedIds) {
    if (options.map((o) => o.id).toSet().length != options.length ||
        selectedIds.any((id) => id.trim().isEmpty) ||
        selectedIds.toSet().length != selectedIds.length) {
      throw ArgumentError('成员标识必须非空且不能重复');
    }
  }
  final List<MemberOption> options;
  final List<String> selectedIds;
  final ValueChanged<List<String>> onChanged;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final option in options) option.id: option};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('参与成员'),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: enabled
                ? () async {
                    final next = await showDialog<List<String>>(
                      context: context,
                      builder: (context) => _MemberSelectionDialog(
                        options: options,
                        initial: selectedIds,
                      ),
                    );
                    if (next != null && context.mounted) onChanged(next);
                  }
                : null,
            icon: const Icon(Icons.expand_more),
            label: Text(
              selectedIds.isEmpty ? '选择成员' : '已选 ${selectedIds.length} 位 · 修改',
            ),
            style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
          ),
        ),
        if (selectedIds.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final id in selectedIds)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                key: ValueKey('selected-member-$id'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (byId[id] case final option?)
                            MemberLabel(
                              group: option.group,
                              name: option.name,
                              color: option.color,
                            )
                          else
                            const Text('成员信息不可用'),
                          if (byId[id] == null || !byId[id]!.available)
                            Text(
                              byId[id] == null ? '请核对原选择' : '已停用',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('remove-member-$id'),
                    tooltip: '移除 ${byId[id]?.label ?? '原选择'}',
                    onPressed: enabled
                        ? () => onChanged(
                            List.unmodifiable(
                              selectedIds.where((s) => s != id),
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
        ],
        if (errorText != null)
          Semantics(
            liveRegion: true,
            child: Text(
              errorText!,
              style: const TextStyle(color: ChekiColors.danger),
            ),
          ),
      ],
    );
  }
}

class _MemberSelectionDialog extends StatefulWidget {
  const _MemberSelectionDialog({required this.options, required this.initial});
  final List<MemberOption> options;
  final List<String> initial;
  @override
  State<_MemberSelectionDialog> createState() => _MemberSelectionDialogState();
}

class _MemberSelectionDialogState extends State<_MemberSelectionDialog> {
  late final Set<String> _selected = widget.initial.toSet();
  String _search = '';
  @override
  Widget build(BuildContext context) {
    final available = widget.options.where(
      (o) => o.available || widget.initial.contains(o.id),
    );
    final query = _search.trim().toLowerCase();
    final matches = available
        .where((o) => o.label.toLowerCase().contains(query))
        .toList();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('选择成员'),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('member-search'),
              decoration: const InputDecoration(
                labelText: '搜索成员或团体',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _search = value),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: matches.isEmpty
                  ? SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(query.isEmpty ? '还没有可选成员' : '没有匹配的成员'),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: matches.length,
                      itemBuilder: (context, index) {
                        final option = matches[index];
                        return CheckboxListTile(
                          key: ValueKey('member-option-${option.id}'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _selected.contains(option.id),
                          title: MemberLabel(
                            group: option.group,
                            name: option.name,
                            color: option.color,
                          ),
                          subtitle: option.available ? null : const Text('已停用'),
                          onChanged:
                              option.available || _selected.contains(option.id)
                              ? (value) => setState(() {
                                  if (value == true) {
                                    _selected.add(option.id);
                                  } else {
                                    _selected.remove(option.id);
                                  }
                                })
                              : null,
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            // Unknown initial IDs stay in the result. No input widget has
            // authority to silently repair imported/historical selections.
            Text('已选 ${_selected.length} 位'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    List<String>.unmodifiable(_selected),
                  ),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MemberColorField extends StatelessWidget {
  const MemberColorField({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });
  final Color value;
  final ValueChanged<Color> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
    onPressed: enabled
        ? () async {
            final next = await showDialog<Color>(
              context: context,
              builder: (_) => _MemberColorDialog(initial: value),
            );
            if (next != null && context.mounted) onChanged(next);
          }
        : null,
    child: _ColorPreview(label: '成员颜色', color: value),
  );
}

class _MemberColorDialog extends StatefulWidget {
  const _MemberColorDialog({required this.initial});
  final Color initial;
  @override
  State<_MemberColorDialog> createState() => _MemberColorDialogState();
}

class _MemberColorDialogState extends State<_MemberColorDialog> {
  late Color _color = widget.initial;
  late final _hex = TextEditingController(
    text: memberHex(_color.toARGB32() & 0xffffff),
  );
  late final _numbers = <String, TextEditingController>{
    for (final c in const [('红', 16), ('绿', 8), ('蓝', 0)])
      c.$1: TextEditingController(text: '${(_color.toARGB32() >> c.$2) & 255}'),
  };
  final _errors = <String, String>{};
  void _sync({String? preserve}) {
    if (preserve != 'hex') _hex.text = memberHex(_color.toARGB32() & 0xffffff);
    for (final c in const [('红', 16), ('绿', 8), ('蓝', 0)]) {
      if (preserve != c.$1 && !_errors.containsKey(c.$1)) {
        _numbers[c.$1]!.text = '${(_color.toARGB32() >> c.$2) & 255}';
      }
    }
  }

  void _choose(Color color) => setState(() {
    _color = Color(0xff000000 | (color.toARGB32() & 0xffffff));
    _errors.clear();
    _sync();
  });
  void _hexChanged(String text) => setState(() {
    final rgb = parseMemberHex(text);
    if (rgb == null) {
      _errors['hex'] = '请输入 #RRGGBB 颜色代码';
      return;
    }
    _color = Color(0xff000000 | rgb);
    _errors.clear();
    _sync(preserve: 'hex');
  });
  void _numberChanged(String channel, int shift, String text) => setState(() {
    final value = parseMemberChannel(text);
    if (value == null) {
      _errors[channel] = '0–255';
      return;
    }
    _color = Color(
      (_color.toARGB32() & ~(255 << shift)) | (value << shift) | 0xff000000,
    );
    _errors.remove(channel);
    _errors.remove('hex');
    _sync(preserve: channel);
  });
  @override
  void dispose() {
    _hex.dispose();
    for (final c in _numbers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _channel(int shift, double value) {
    final argb = _color.toARGB32();
    setState(() {
      _color = Color(
        (argb & ~(255 << shift)) | (value.round() << shift) | 0xff000000,
      );
      final name = const {16: '红', 8: '绿', 0: '蓝'}[shift]!;
      _errors.remove(name);
      _errors.remove('hex');
      _sync();
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('成员颜色'),
          const SizedBox(height: 12),
          _ColorPreview(
            label: '颜色预览 ${memberHex(_color.toARGB32() & 0xffffff)}',
            color: _color,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in memberColorPresets.entries)
                OutlinedButton(
                  key: ValueKey('member-color-preset-${preset.key}'),
                  onPressed: () => _choose(Color(0xff000000 | preset.value)),
                  child: _ColorPreview(
                    label: preset.key,
                    color: Color(0xff000000 | preset.value),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('member-color-hex'),
            controller: _hex,
            decoration: InputDecoration(
              labelText: '十六进制颜色',
              hintText: '#RRGGBB',
              errorText: _errors['hex'],
            ),
            onChanged: _hexChanged,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) => ColorPicker(
              pickerColor: _color,
              onColorChanged: _choose,
              colorPickerWidth: constraints.maxWidth,
              portraitOnly: true,
              enableAlpha: false,
              labelTypes: const [],
              pickerAreaHeightPercent: 0.65,
              pickerAreaBorderRadius: BorderRadius.circular(12),
            ),
          ),
          // Standard focusable sliders supplement the canvas picker for
          // keyboard and screen-reader users; all RGB colors remain possible.
          for (final channel in const [('红', 16), ('绿', 8), ('蓝', 0)]) ...[
            Text(channel.$1),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    key: ValueKey('member-color-${channel.$1}'),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    value: ((_color.toARGB32() >> channel.$2) & 255).toDouble(),
                    label: '${(_color.toARGB32() >> channel.$2) & 255}',
                    semanticFormatterCallback: (v) =>
                        '${channel.$1} ${v.round()}',
                    onChanged: (v) => _channel(channel.$2, v),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 92,
                  child: TextField(
                    key: ValueKey('member-color-number-${channel.$1}'),
                    controller: _numbers[channel.$1],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: const {16: 'R', 8: 'G', 0: 'B'}[channel.$2],
                      errorText: _errors[channel.$1],
                    ),
                    onChanged: (text) =>
                        _numberChanged(channel.$1, channel.$2, text),
                  ),
                ),
              ],
            ),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _errors.isEmpty
                    ? () => Navigator.pop(context, _color)
                    : null,
                child: const Text('确定'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _ColorPreview extends StatelessWidget {
  const _ColorPreview({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: ChekiColors.inputBorder),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}
