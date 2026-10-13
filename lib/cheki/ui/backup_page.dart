import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/backup_store.dart';
import 'components.dart';
import 'theme.dart';

class BackupFileAccess {
  static const channel = MethodChannel('com.seniorious66.counttools/backup');
  Future<bool> export(Uint8List bytes) async =>
      (await channel.invokeMethod<bool>('exportBackup', {
        'bytes': bytes,
        'name':
            'Cheki-${DateTime.now().toIso8601String().substring(0, 10)}.chekibackup',
      })) ??
      false;
  Future<Uint8List?> choose() async =>
      channel.invokeMethod<Uint8List>('importBackup');
}

class BackupPage extends StatefulWidget {
  const BackupPage({this.store, this.access, super.key});
  final BackupStore? store;
  final BackupFileAccess? access;
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final Future<BackupStore> store = widget.store == null
      ? BackupStore.app()
      : Future.value(widget.store);
  late final access = widget.access ?? BackupFileAccess();
  BackupPreview? preview;
  bool busy = false;
  String? message;
  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (_) {
      var pending = false;
      try {
        pending = await (await store).journal.exists();
      } catch (_) {}
      if (mounted) {
        setState(
          () => message = pending
              ? '恢复尚未闭合，已停止数据操作；保留恢复材料，请重启重试。'
              : '检查或操作失败，当前账本保留；请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() async => action(() async {
    final bytes = await (await store).snapshot();
    final saved = await access.export(bytes);
    if (mounted) setState(() => message = saved ? '完整备份已保存' : '已取消保存，账本未改变');
  });
  Future<void> select() async => action(() async {
    final bytes = await access.choose();
    if (bytes == null) {
      if (mounted) setState(() => message = '已取消选择，账本未改变');
      return;
    }
    final p = await (await store).prepare(bytes);
    if (mounted) {
      setState(() {
        preview = p;
        message = null;
      });
    }
  });
  Future<void> restore() async {
    if (busy || preview == null) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复这个备份？'),
        content: const Text('将替换当前账本、设置和附件，并保留恢复前的完整副本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (agreed != true) return;
    await action(() async {
      await (await store).apply(preview!);
      if (mounted) {
        setState(() {
          preview = null;
          message = '完整恢复完成';
        });
      }
    });
  }

  Widget summary(String title, Map<String, Object?> m) {
    final tables = m['tables'] as Map;
    return ChekiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          Text('Cheki ${tables['cheki_records'] ?? 0} 条'),
          Text('券与库存 ${tables['cheki_ticket_objects'] ?? 0} 条'),
          Text('换送 ${tables['cheki_transfer_objects'] ?? 0} 条'),
          Text('设置 ${m['settings']} 项 · 文件 ${m['files']} 个'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ChekiCard(
              color: ChekiColors.blue,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('保存完整账本'),
                  const Text('包含记录、库存、成本来源、修订历史、设置和附件。'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy ? null : export,
                    child: const Text('导出完整备份'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ChekiCard(
              color: ChekiColors.pink,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('从备份恢复'),
                  const Text('先检查备份并查看差异，再确认恢复。'),
                  TextButton(
                    onPressed: busy ? null : select,
                    child: const Text('选择并检查备份'),
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
              summary('当前账本', preview!.before),
              summary('恢复后的账本', preview!.after),
              if (preview!.sourceSchema != preview!.after['schema'])
                const Text('旧备份已在独立副本完成兼容检查。'),
              FilledButton(
                onPressed: busy ? null : restore,
                child: const Text('恢复此备份'),
              ),
              TextButton(
                onPressed: busy ? null : () => setState(() => preview = null),
                child: const Text('取消预览'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
