import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/backup_store.dart';
import '../data/catalog_contract.dart';
import '../data/legacy_mapping_store.dart';
import '../domain/record_contract.dart';
import '../domain/record_information.dart';
import 'components.dart';
import 'theme.dart';

class LegacyMappingPage extends StatefulWidget {
  const LegacyMappingPage({this.store, super.key});
  final LegacyMappingStore? store;
  @override
  State<LegacyMappingPage> createState() => _LegacyMappingPageState();
}

class _LegacyMappingPageState extends State<LegacyMappingPage> {
  late final store = widget.store == null
      ? BackupStore.app().then(LegacyMappingStore.new)
      : Future.value(widget.store!);
  LegacyArchive? archive;
  LegacyMappingPreview? preview;
  final selections = <int, RecordInformation>{};
  final memberRules = <String, String?>{};
  final signatureRules = <String, String?>{}, sizeRules = <String, String?>{};
  bool busy = false, oneEach = false, sourceDate = false, received = false;
  String? message;

  @override
  void dispose() {
    final old = preview;
    if (old != null) unawaited(store.then((s) => s.discard(old)));
    super.dispose();
  }

  Future<void> action(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is FormatException
              ? e.message
              : e is CatalogException
              ? e.toString()
              : '操作未完成，请重新读取旧档案；保留原账本和备份。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => action(() async {
    final old = preview;
    setState(() {
      preview = null;
      archive = null;
      selections.clear();
    });
    if (old != null) await (await store).discard(old);
    final result = await (await store).read();
    if (!mounted) return;
    setState(() {
      archive = result;
      oneEach = sourceDate = received = false;
      memberRules.clear();
      signatureRules.clear();
      sizeRules.clear();
      for (final row in result.rows.where((r) => r.existingRecordId == null)) {
        selections[row.id] = RecordInformation.fromMap({});
      }
      message = null;
    });
  });

  Future<void> check() => action(() async {
    final old = preview;
    setState(() => preview = null);
    if (old != null) await (await store).discard(old);
    final result = await (await store).prepare(archive!, selections);
    if (mounted) {
      setState(() {
        preview = result;
        message = null;
      });
    } else {
      await (await store).discard(result);
    }
  });

  Future<void> apply() async {
    final selected = preview;
    if (selected == null || busy) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认迁移预览中的记录？'),
        content: Text('新增 ${selected.added} 条；原始旧档案、现有记录和库存保留。迁移前完整账本副本会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认迁移'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await action(() async {
      await (await store).apply(selected);
      if (mounted) {
        setState(() {
          preview = null;
          archive = null;
          selections.clear();
          message = '迁移完成，可在记录页继续补全；原始旧档案已保留。';
        });
      }
    });
  }

  void bulk() {
    for (final row in archive!.rows.where(
      (r) => selections.containsKey(r.id),
    )) {
      final m = selections[row.id]!.toMap(), raw = row.raw;
      if (oneEach) m['quantity'] = 1;
      if (sourceDate) {
        final text = raw['date'];
        if (text is String &&
            text.length >= 10 &&
            DateTime.tryParse(text) != null) {
          try {
            m['occurred_on'] = OccurredOn.parse(text.substring(0, 10)).value;
          } on FormatException {
            /* keep original and leave unresolved */
          }
        }
      }
      final member = memberRules[raw['parentId'].toString()];
      if (member != null) m['member_ids'] = [member];
      final type = raw['type']?.toString() ?? '';
      final signature = signatureRules[type];
      if (signature != null) m['attributes'] = {'kind': signature};
      final size = sizeRules[type];
      if (size != null) m['size_id'] = size;
      if (received) {
        m['receipt_status_hint'] = 'received';
        m['receipt_batches'] = [
          {
            'origin': 'legacyUnknown',
            if (m['quantity'] != null) 'quantity': m['quantity'],
          },
        ];
      }
      selections[row.id] = RecordInformation.fromMap(m);
    }
    setState(() => message = '所选规则已应用到草稿，请逐条核对；未识别的日期保持原文。');
  }

  Future<void> edit(LegacyArchiveRow row) async {
    final result = await Navigator.push<RecordInformation>(
      context,
      MaterialPageRoute(
        builder: (_) => _LegacyRowEditor(
          row: row,
          archive: archive!,
          initial: selections[row.id]!,
        ),
      ),
    );
    if (result != null && mounted) setState(() => selections[row.id] = result);
  }

  Widget select(
    String label,
    String? value,
    Map<String, String> choices,
    void Function(String?) change,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label:$value'),
      initialValue: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: '', child: Text('未指定')),
        for (final e in choices.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: busy
          ? null
          : (s) => setState(() => change(s == '' ? null : s)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final a = archive;
    final names = <String, String>{
      if (a != null)
        for (final m in a.directory.members.where((m) => m.active))
          m.id:
              '${a.directory.groups.where((g) => g.id == m.groupId).map((g) => g.name).firstOrNull ?? '团体未填写'} · ${m.name}',
    };
    final sizes = <String, String>{
      if (a != null)
        for (final s in a.sizes.where((s) => s.active)) s.id: s.name,
    };
    final lists = <String, String>{
      if (a != null)
        for (final r in a.rows.where((r) => r.existingRecordId == null))
          r.raw['parentId'].toString():
              (r.context['subproject'] as Map?)?['name']?.toString() ??
              '原列表未命名',
    };
    final types =
        a?.rows
            .where((r) => r.existingRecordId == null)
            .map((r) => r.raw['type']?.toString() ?? '')
            .toSet() ??
        <String>{};
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('旧档案映射')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('读取账本中保留的旧档案，先明确映射，再预览迁移。原始内容始终保留；未知信息可以留空。'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy ? null : load,
                child: const Text('读取旧档案'),
              ),
              if (busy) const LinearProgressIndicator(),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(message!),
                ),
              if (a != null) ...[
                Text(
                  '旧行 ${a.rows.length} · 已迁移 ${a.existing} · 本次选择 ${selections.length}',
                ),
                if (preview == null && selections.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  ExpansionTile(
                    title: const Text('批量填写已确认的信息'),
                    children: [
                      CheckboxListTile(
                        value: oneEach,
                        title: const Text('所选每条旧行均为一张 Cheki'),
                        onChanged: busy
                            ? null
                            : (v) => setState(() => oneEach = v!),
                      ),
                      CheckboxListTile(
                        value: sourceDate,
                        title: const Text('采用原日期中的年月日'),
                        onChanged: busy
                            ? null
                            : (v) => setState(() => sourceDate = v!),
                      ),
                      CheckboxListTile(
                        value: received,
                        title: const Text('所选记录全部已领取（实际时间未知）'),
                        onChanged: busy
                            ? null
                            : (v) => setState(() => received = v!),
                      ),
                      for (final e in lists.entries)
                        select(
                          '原列表 ${e.value} → 成员',
                          memberRules[e.key],
                          names,
                          (s) => memberRules[e.key] = s,
                        ),
                      for (final type in types) ...[
                        select(
                          '旧类型「${type.isEmpty ? '空' : type}」→ 属性',
                          signatureRules[type],
                          const {
                            'unsigned': '无签',
                            'signed': '带签',
                            'homework': '宿题',
                          },
                          (s) => signatureRules[type] = s,
                        ),
                        select(
                          '旧类型「${type.isEmpty ? '空' : type}」→ 尺寸',
                          sizeRules[type],
                          sizes,
                          (s) => sizeRules[type] = s,
                        ),
                      ],
                      OutlinedButton(
                        onPressed: busy ? null : bulk,
                        child: const Text('应用所选规则到草稿'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                if (preview != null) ...[
                  ChekiCard(
                    color: ChekiColors.pink,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('迁移预览：新增 ${preview!.added} 条'),
                        Text(
                          '已有跳过 ${preview!.report['already_mapped']} · 留在原档案 ${preview!.report['left_in_archive']}',
                        ),
                        const Text('原档案与旧金额保留；购买和库存变更 0。'),
                        const Text('下面每条为本次迁移后的信息，未填写信息继续留空。'),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => action(() async {
                            final saved =
                                await const MethodChannel(
                                  'com.seniorious66.counttools/backup',
                                ).invokeMethod<bool>('exportBackup', {
                                  'bytes': Uint8List.fromList(
                                    utf8.encode(preview!.reportJson),
                                  ),
                                  'name': 'Cheki-legacy-mapping-report.json',
                                });
                            if (mounted) {
                              setState(
                                () => message = saved == true
                                    ? '差异报告已保存到所选位置'
                                    : '已取消保存',
                              );
                            }
                          }),
                    child: const Text('导出差异报告'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : apply,
                    child: const Text('核对并迁移'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => action(() async {
                            final old = preview!;
                            setState(() => preview = null);
                            await (await store).discard(old);
                          }),
                    child: const Text('返回调整'),
                  ),
                ],
                for (final row in a.rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ChekiCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.label,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            '原日期：${row.raw['date'] ?? '空'} · 原属性：${row.raw['type'] ?? '空'}',
                          ),
                          Text('原金额：${row.raw['price'] ?? '空'}'),
                          if (row.existingRecordId != null)
                            const Text('已有来源记录，保留现有内容'),
                          if (selections[row.id] case final info?)
                            Text(
                              '${info.occurredOn?.value ?? '日期未填'} · ${info.quantity?.toString() ?? '数量未填'}${info.quantity == null ? '' : ' 张'} · '
                              '${(info.memberIds ?? []).map((id) => names[id] ?? id).join('、')} · '
                              '${sizes[info.sizeId] ?? '尺寸未填'} · '
                              '${const {'signed': '带签', 'unsigned': '无签', 'homework': '宿题'}[info.signature?.name] ?? '属性未填'} · '
                              '${info.backSigned == null
                                  ? '背签未填'
                                  : info.backSigned!
                                  ? '背签'
                                  : '无背签'} · '
                              '${const {'received': '已领取', 'unreceived': '未领取', 'partial': '部分领取'}[info.receiptStatus?.name] ?? '领取未填'}',
                            ),
                          if (preview == null && row.existingRecordId == null)
                            Wrap(
                              spacing: 8,
                              children: [
                                if (selections.containsKey(row.id))
                                  TextButton(
                                    onPressed: busy ? null : () => edit(row),
                                    child: const Text('调整映射'),
                                  ),
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => setState(() {
                                          if (selections.containsKey(row.id)) {
                                            selections.remove(row.id);
                                          } else {
                                            selections[row.id] =
                                                RecordInformation.fromMap({});
                                          }
                                        }),
                                  child: Text(
                                    selections.containsKey(row.id)
                                        ? '本次跳过'
                                        : '加入本次',
                                  ),
                                ),
                              ],
                            ),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('查看只读原文'),
                            children: [
                              SelectableText(
                                const JsonEncoder.withIndent(
                                  '  ',
                                ).convert({'row': row.raw, ...row.context}),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (preview == null && selections.isNotEmpty)
                  FilledButton(
                    onPressed: busy ? null : check,
                    child: const Text('生成隔离迁移预览'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LegacyRowEditor extends StatefulWidget {
  const _LegacyRowEditor({
    required this.row,
    required this.archive,
    required this.initial,
  });
  final LegacyArchiveRow row;
  final LegacyArchive archive;
  final RecordInformation initial;
  @override
  State<_LegacyRowEditor> createState() => _LegacyRowEditorState();
}

class _LegacyRowEditorState extends State<_LegacyRowEditor> {
  late final date = TextEditingController(
    text: widget.initial.occurredOn?.value,
  );
  late final quantity = TextEditingController(
    text: widget.initial.quantity?.toString(),
  );
  late final note = TextEditingController(text: widget.initial.note);
  late List<String> members = [...?widget.initial.memberIds];
  late String? size = widget.initial.sizeId,
      signature = widget.initial.signature?.name,
      receipt = widget.initial.receiptStatus?.name;
  late bool? back = widget.initial.backSigned;
  String? error;
  @override
  void dispose() {
    date.dispose();
    quantity.dispose();
    note.dispose();
    super.dispose();
  }

  Widget pick(
    String label,
    String? value,
    Map<String, String> items,
    void Function(String?) onChange,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<String>(
      initialValue: value ?? '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        const DropdownMenuItem(value: '', child: Text('未填写')),
        for (final e in items.entries)
          DropdownMenuItem(value: e.key, child: Text(e.value)),
      ],
      onChanged: (v) => setState(() => onChange(v == '' ? null : v)),
    ),
  );
  void save() {
    try {
      final q = quantity.text.trim();
      if (q.isNotEmpty && int.tryParse(q) == null) {
        throw const FormatException('张数需为整数');
      }
      final m = <String, Object?>{
        ...widget.initial.toMap(),
        'quantity': q.isEmpty ? null : int.parse(q),
        'occurred_on': date.text.trim().isEmpty ? null : date.text.trim(),
        'member_ids': members.isEmpty ? null : members,
        'size_id': size,
        'attributes': {
          'kind': signature,
          'back_signed': signature == 'signed' ? back : null,
        },
        'receipt_status_hint': receipt,
        'receipt_batches': receipt == 'received'
            ? [
                {
                  'origin': 'legacyUnknown',
                  if (q.isNotEmpty) 'quantity': int.parse(q),
                },
              ]
            : null,
        'note': note.text.isEmpty ? null : note.text,
      };
      Navigator.pop(context, RecordInformation.fromMap(m));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  Widget attribute(
    String label,
    bool? value,
    ValueChanged<bool?>? changed, {
    bool nullable = false,
  }) => SizedBox(
    width: MediaQuery.textScalerOf(context).scale(14) > 20 ? 130 : 72,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Checkbox(
          value: value,
          tristate: nullable,
          semanticLabel: label,
          onChanged: changed,
        ),
        Text(label),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.row.label)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '原日期 ${widget.row.raw['date'] ?? '空'}\n原属性 ${widget.row.raw['type'] ?? '空'}\n原金额 ${widget.row.raw['price'] ?? '空'}（独立保留）',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: date,
            decoration: const InputDecoration(labelText: '发生日期（YYYY-MM-DD，可空）'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: quantity,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '张数（可空）'),
          ),
          ExpansionTile(
            title: Text('参与成员（${members.length}）'),
            children: [
              for (final member in widget.archive.directory.members.where(
                (m) => m.active,
              ))
                CheckboxListTile(
                  value: members.contains(member.id),
                  title: Text(
                    '${widget.archive.directory.groups.where((g) => g.id == member.groupId).map((g) => g.name).firstOrNull ?? '团体未填写'} · ${member.name}',
                  ),
                  onChanged: (v) => setState(() {
                    if (v!) {
                      members.add(member.id);
                    } else {
                      members.remove(member.id);
                    }
                  }),
                ),
            ],
          ),
          pick('尺寸', size, {
            for (final s in widget.archive.sizes.where((s) => s.active))
              s.id: s.name,
          }, (v) => size = v),
          Wrap(
            children: [
              for (final entry in const {
                'unsigned': '无签',
                'signed': '带签',
                'homework': '宿题',
              }.entries)
                attribute(
                  entry.value,
                  signature == entry.key,
                  (v) => setState(() {
                    signature = v! ? entry.key : null;
                    if (signature != 'signed') back = null;
                  }),
                ),
              attribute(
                '背签',
                back,
                signature == 'signed' ? (v) => setState(() => back = v) : null,
                nullable: true,
              ),
            ],
          ),
          if (signature == 'signed') const Text('背签横线表示未知，可留空。'),
          pick('领取', receipt, const {
            'received': '已领取',
            'unreceived': '未领取',
            'partial': '部分领取',
          }, (v) => receipt = v),
          const Text('旧领取的实际时间未知，后续可在记录页补充批次。'),
          TextField(
            controller: note,
            decoration: const InputDecoration(labelText: '备注（可空）'),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          FilledButton(onPressed: save, child: const Text('保留到映射草稿')),
        ],
      ),
    ),
  );
}
