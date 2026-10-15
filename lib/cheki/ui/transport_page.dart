import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/backup_store.dart';
import '../data/transport_store.dart';
import 'components.dart';
import 'theme.dart';

class TransportFileAccess {
  static const channel = MethodChannel('com.seniorious66.counttools/backup');
  Future<bool> save(Uint8List bytes, String name) async =>
      await channel.invokeMethod<bool>('exportTables', {
        'bytes': bytes,
        'name': name,
      }) ??
      false;
  Future<Uint8List?> choose() =>
      channel.invokeMethod<Uint8List>('importBackup');
}

class TransportPage extends StatefulWidget {
  const TransportPage({this.store, this.access, super.key});
  final TransportStore? store;
  final TransportFileAccess? access;
  @override
  State<TransportPage> createState() => _TransportPageState();
}

class _TransportPageState extends State<TransportPage> {
  late final store = widget.store == null
      ? BackupStore.app().then(TransportStore.new)
      : Future.value(widget.store!);
  late final access = widget.access ?? TransportFileAccess();
  TransportMode mode = TransportMode.transactions;
  TransportPreview? preview;
  bool busy = false;
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
              : '操作未完成，请保留数据包重试；账本变更以恢复检查结果为准。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export(bool template) => action(() async {
    final data = await (await store).export(
      mode: template ? TransportMode.transactions : mode,
      template: template,
    );
    final saved = await access.save(
      data,
      'Cheki-${template ? 'template' : mode.name}-${DateTime.now().toIso8601String().substring(0, 10)}.chekicsv.zip',
    );
    if (mounted) setState(() => message = saved ? '数据包已保存到选择的位置' : '已取消保存');
  });
  Future<void> select() => action(() async {
    // A failed or cancelled new selection must never leave an older confirmable preview.
    final old = preview;
    setState(() => preview = null);
    if (old != null) await (await store).discard(old);
    final bytes = await access.choose();
    if (bytes == null) {
      if (mounted) setState(() => message = '已取消选择');
      return;
    }
    final result = await (await store).prepare(bytes, mode);
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
    final candidate = preview;
    if (candidate == null || busy) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(mode == TransportMode.snapshot ? '恢复这个完整快照？' : '导入这批交易？'),
        content: Text(
          mode == TransportMode.snapshot
              ? '将替换当前完整账本、设置和附件；恢复前的完整副本会保留。'
              : '仅追加预览中的新内容；相同内容跳过，冲突整批拒绝。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await action(() async {
      await (await store).apply(candidate);
      if (mounted) {
        setState(() {
          preview = null;
          message = '数据携带完成';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('数据携带')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<TransportMode>(
              initialValue: mode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '数据模式'),
              items: const [
                DropdownMenuItem(
                  value: TransportMode.transactions,
                  child: Text('交易追加'),
                ),
                DropdownMenuItem(
                  value: TransportMode.snapshot,
                  child: Text('完整账本快照'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) async {
                      final old = preview;
                      if (v != null) {
                        setState(() {
                          mode = v;
                          preview = null;
                          message = null;
                        });
                      }
                      if (old != null) await (await store).discard(old);
                    },
            ),
            const SizedBox(height: 16),
            ChekiCard(
              color: ChekiColors.blue,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('CSV 多表数据包'),
                  const Text('包含团体、成员、记录、领取、券、成本来源和完整流水；保留设置与附件。'),
                  FilledButton(
                    onPressed: busy ? null : () => export(false),
                    child: const Text('导出完整数据包'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => export(true),
                    child: const Text('导出交易模板'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ChekiCard(
              color: ChekiColors.pink,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    mode == TransportMode.transactions
                        ? '按稳定 ID 检查新增内容；不按姓名自动合并。'
                        : '恢复完整快照，不叠加其中的库存或历史交易。',
                  ),
                  const Text('先检查格式、关联和库存，再查看预览。普通统计表不能作为数据包导入。'),
                  TextButton(
                    onPressed: busy ? null : select,
                    child: const Text('选择并检查数据包'),
                  ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(message!),
              ),
            if (preview != null) ...[
              const SizedBox(height: 16),
              ChekiCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode == TransportMode.snapshot ? '完整恢复预览' : '交易追加预览',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      mode == TransportMode.snapshot
                          ? '以下数量为恢复后的完整内容'
                          : '新增 ${preview!.added} 行 · 相同跳过 ${preview!.unchanged} 行',
                    ),
                    for (final entry in const {
                      'cheki_groups': '团体',
                      'cheki_members': '成员',
                      'cheki_records': 'Cheki记录',
                      'cheki_ticket_objects': '券与库存',
                      'cheki_transfer_objects': '交换与赠送',
                    }.entries)
                      Text(
                        '${entry.value}：${(preview!.backup.before['tables'] as Map)[entry.key] ?? 0} → ${(preview!.backup.after['tables'] as Map)[entry.key] ?? 0}',
                      ),
                    Text(
                      '设置：${preview!.backup.before['settings']} → ${preview!.backup.after['settings']}',
                    ),
                    Text(
                      '文件：${preview!.backup.before['files']} → ${preview!.backup.after['files']}',
                    ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: busy ? null : apply,
                child: const Text('确认这个预览'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => action(() async {
                        final old = preview;
                        setState(() => preview = null);
                        if (old != null) await (await store).discard(old);
                      }),
                child: const Text('取消预览'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
