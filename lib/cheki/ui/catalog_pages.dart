import 'package:flutter/material.dart';
import '../../data/database/data_base.dart';
import '../../page/home_page/home_page.dart';
import '../data/catalog_contract.dart';
import '../data/catalog_store.dart';
import '../data/identity_contract.dart';
import '../data/identity_store.dart';
import '../data/record_store.dart';
import '../data/ticket_store.dart';
import 'ticket_pages.dart';
import 'backup_page.dart';
import 'record_pages.dart';
import 'identity_pages.dart';
import 'components.dart';
import 'theme.dart';

class CatalogManagementPage extends StatelessWidget {
  CatalogManagementPage({CatalogStore? store, super.key})
    : store = store ?? CatalogStore(() => DatabaseHelper().database);
  final CatalogStore store;
  @override
  Widget build(BuildContext context) => Theme(
    data: chekiTheme(),
    child: Scaffold(
      appBar: AppBar(title: const Text('管理')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChekiCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('旧版项目'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HomePage(title: '旧版项目'),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChekiCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cheki记录'),
                  subtitle: const Text('记录与旧信息补录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RecordListPage(
                        store: RecordStore(store.database, clock: store.clock),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ChekiCard(
              child: ListTile(
                title: const Text('券种管理'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TicketLibraryPage(
                      store: TicketStore(store.database, clock: store.clock),
                      definitionsOnly: true,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final kind in IdentityKind.values.reversed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ChekiCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(kind == IdentityKind.member ? '成员' : '同人关联'),
                    subtitle: Text(
                      kind == IdentityKind.member
                          ? '团体、名称、颜色与转团历史'
                          : '手动关联同一人的不同成员身份',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => IdentityListPage(
                          kind: kind,
                          store: IdentityStore(
                            store.database,
                            clock: store.clock,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            for (final kind in CatalogKind.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ChekiCard(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(kind.label),
                    subtitle: Text(
                      kind == CatalogKind.group ? '新增、修改和停用' : '三寸、五寸及自定义尺寸',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Theme(
                          data: chekiTheme(),
                          child: CatalogListPage(kind: kind, store: store),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ChekiCard(
              child: ListTile(
                title: const Text('备份与恢复'),
                subtitle: const Text('完整账本、设置和附件'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => const BackupPage()),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

class CatalogListPage extends StatefulWidget {
  const CatalogListPage({required this.kind, required this.store, super.key});
  final CatalogKind kind;
  final CatalogStore store;
  @override
  State<CatalogListPage> createState() => _CatalogListPageState();
}

class _CatalogListPageState extends State<CatalogListPage> {
  late Future<List<CatalogEntity>> _items;
  @override
  void initState() {
    super.initState();
    _items = widget.store.list(widget.kind);
  }

  void _reload() => setState(() {
    _items = widget.store.list(widget.kind);
  });
  Future<void> _edit([CatalogEntity? item]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => Theme(
          data: chekiTheme(),
          child: CatalogEditPage(
            kind: widget.kind,
            store: widget.store,
            original: item,
          ),
        ),
      ),
    );
    if (mounted && saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.kind.label),
      actions: [
        IconButton(
          onPressed: () => _edit(),
          tooltip: '新增${widget.kind.label}',
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<CatalogEntity>>(
        future: _items,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('读取失败，请重试'),
                  TextButton(onPressed: _reload, child: const Text('重试')),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('还没有${widget.kind.label}'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _edit(),
                    child: Text('新增${widget.kind.label}'),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              _reload();
              await _items;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ChekiCard(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(item.name),
                        subtitle: Text(item.active ? '使用中' : '已停用'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _edit(item),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class CatalogEditPage extends StatefulWidget {
  const CatalogEditPage({
    required this.kind,
    required this.store,
    this.original,
    super.key,
  });
  final CatalogKind kind;
  final CatalogStore store;
  final CatalogEntity? original;
  @override
  State<CatalogEditPage> createState() => _CatalogEditPageState();
}

class _CatalogEditPageState extends State<CatalogEditPage> {
  late final _name = TextEditingController(
    text: widget.original?.knownName ?? '',
  );
  late bool _active = widget.original?.active ?? true;
  final _operationId = newOperationId();
  String? _error;
  bool _saving = false, _discarded = false;
  bool get _dirty =>
      _name.text != (widget.original?.knownName ?? '') ||
      _active != (widget.original?.active ?? true);
  @override
  void initState() {
    super.initState();
    _name.addListener(_inputChanged);
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.removeListener(_inputChanged);
    _name.dispose();
    super.dispose();
  }

  Future<void> _discard() async {
    if (_saving) return;
    if (!_dirty) {
      _leaveWithoutSaving();
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃修改？'),
        content: const Text('未保存的内容将丢弃。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (mounted && accepted == true) {
      _leaveWithoutSaving();
    }
  }

  void _leaveWithoutSaving() {
    setState(() => _discarded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final original = widget.original;
      if (original == null) {
        await widget.store.create(
          widget.kind,
          name: _name.text,
          operationId: _operationId,
        );
      } else {
        await widget.store.edit(
          widget.kind,
          original: original,
          name: _name.text,
          active: _active,
          operationId: _operationId,
        );
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _discarded = true;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context, true);
        });
      }
    } on CatalogException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存失败，输入已保留，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<bool>(
    // Always inspect live input on a back request, including before the next
    // frame has rebuilt after typing. Successful saves explicitly allow pop.
    canPop: !_saving && _discarded,
    onPopInvokedWithResult: (popped, result) {
      if (!popped && !_saving) _discard();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.original == null ? '新增' : '修改'}${widget.kind.label}',
        ),
        actions: [
          if (widget.original != null)
            IconButton(
              tooltip: '修改历史',
              onPressed: _saving
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => Theme(
                          data: chekiTheme(),
                          child: CatalogHistoryPage(
                            kind: widget.kind,
                            store: widget.store,
                            original: widget.original!,
                          ),
                        ),
                      ),
                    ),
              icon: const Icon(Icons.history),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _name,
                    enabled: !_saving,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: '${widget.kind.label}名称',
                      errorText: _error,
                    ),
                  ),
                  if (widget.original != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: ChekiCard(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _active,
                          title: const Text('使用中'),
                          subtitle: const Text('停用后保留历史记录'),
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _active = value),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '正在保存…' : '保存'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class CatalogHistoryPage extends StatefulWidget {
  const CatalogHistoryPage({
    required this.kind,
    required this.store,
    required this.original,
    super.key,
  });
  final CatalogKind kind;
  final CatalogStore store;
  final CatalogEntity original;
  @override
  State<CatalogHistoryPage> createState() => _CatalogHistoryPageState();
}

class _CatalogHistoryPageState extends State<CatalogHistoryPage> {
  late Future<List<Map<String, Object?>>> _history;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _history = widget.store.history(widget.kind, widget.original.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('修改历史')),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<Map<String, Object?>>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(_reload),
                child: const Text('读取失败，点击重试'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.isEmpty) return const Center(child: Text('尚无修改'));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final row in snapshot.data!.reversed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ChekiCard(
                    child: Builder(
                      builder: (context) {
                        final after = CatalogEntity.fromRow(
                          decodeSqlRow(row['after_json'] as String),
                        );
                        final before = row['before_json'] == null
                            ? null
                            : CatalogEntity.fromRow(
                                decodeSqlRow(row['before_json'] as String),
                              );
                        final stamp = DateTime.parse(
                          row['created_at'] as String,
                        ).toUtc().add(const Duration(hours: 8));
                        final shown = stamp
                            .toIso8601String()
                            .substring(0, 19)
                            .replaceFirst('T', ' ');
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              before == null
                                  ? '新增 ${after.name}'
                                  : '${before.name} → ${after.name}',
                            ),
                            Text(after.active ? '使用中' : '已停用'),
                            const SizedBox(height: 8),
                            Text(
                              shown,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
