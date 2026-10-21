import 'package:flutter/material.dart';
import '../data/catalog_contract.dart';
import '../data/catalog_store.dart';
import '../data/identity_contract.dart';
import '../data/identity_store.dart';
import '../data/record_store.dart';
import '../data/ticket_store.dart';
import 'catalog_pages.dart';
import 'components.dart';
import 'member_inputs.dart';
import 'theme.dart';
import 'entity_grid.dart';

String identityActionLabel(String utc) => DateTime.parse(utc)
    .add(const Duration(hours: 8))
    .toIso8601String()
    .replaceFirst('T', ' ')
    .substring(0, 19);

double _toolbarHeight(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(24) > 32
    ? MediaQuery.textScalerOf(context).scale(24) * 1.5 + 16
    : 56;

class IdentityListPage extends StatefulWidget {
  const IdentityListPage({required this.kind, required this.store, super.key});
  final IdentityKind kind;
  final IdentityStore store;
  @override
  State<IdentityListPage> createState() => _IdentityListPageState();
}

class _IdentityListPageState extends State<IdentityListPage> {
  late Future<IdentityDirectory> _directory = widget.store.directory();
  void _reload() => setState(() {
    _directory = widget.store.directory();
  });
  Future<void> _edit([IdentityEntity? original]) async {
    final result = await Navigator.push<IdentityEntity>(
      context,
      MaterialPageRoute(
        builder: (_) => IdentityEditPage(
          kind: widget.kind,
          store: widget.store,
          original: original,
        ),
      ),
    );
    if (mounted && result != null) _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: _toolbarHeight(context),
      title: Text(
        widget.kind == IdentityKind.member ? '成员' : '同人关联',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: widget.kind == IdentityKind.member ? '新增成员' : '新增同人标签',
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<IdentityDirectory>(
        future: _directory,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _IdentityReadError(onRetry: _reload);
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final directory = snapshot.data!;
          final items = widget.kind == IdentityKind.member
              ? directory.members
              : directory.persons;
          final groupMap = {for (final g in directory.groups) g.id: g};
          final personMap = {for (final p in directory.persons) p.id: p};
          if (items.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.kind == IdentityKind.member ? '还没有成员' : '还没有同人关联',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => _edit(),
                      child: Text(
                        widget.kind == IdentityKind.member ? '新增成员' : '新增同人标签',
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          if (widget.kind == IdentityKind.member) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                CompactEntityGrid(
                  items: [
                    for (final item in items)
                      EntityGridItem(
                        id: 'identity-${item.id}',
                        name: item.name,
                        subtitle: groupMap[item.groupId]?.knownName,
                        color: item.colorRgb == null
                            ? ChekiColors.inputBorder
                            : Color(0xff000000 | item.colorRgb!),
                        inactiveLabel: MemberAvailability.fromMember(
                          item,
                          groupMap[item.groupId],
                        ).description,
                        onTap: () => _edit(item),
                      ),
                  ],
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.kind == IdentityKind.person)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('同一人的不同成员身份可以使用同一个关联标签。'),
                ),
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ChekiCard(
                    child: InkWell(
                      key: ValueKey('identity-${item.id}'),
                      onTap: () => _edit(item),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (item.kind == IdentityKind.member)
                              MemberLabel(
                                group: groupMap[item.groupId]?.name ?? '未填写团体',
                                name: item.name,
                                color: item.colorRgb == null
                                    ? ChekiColors.inputBorder
                                    : Color(0xff000000 | item.colorRgb!),
                              )
                            else
                              Text(item.name),
                            const SizedBox(height: 8),
                            Text(
                              item.active ? '使用中' : '已停用',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (item.kind == IdentityKind.member)
                              Text(
                                item.personId == null
                                    ? '未关联同一人'
                                    : '同人关联：${personMap[item.personId]?.name ?? '信息不可用'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            if (item.kind == IdentityKind.member &&
                                groupMap[item.groupId]?.active == false)
                              const Text('团体已停用'),
                            if (item.kind == IdentityKind.person)
                              Text(
                                '关联 ${directory.members.where((m) => m.personId == item.id).length} 个成员身份',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
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

class _IdentityReadError extends StatelessWidget {
  const _IdentityReadError({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('读取失败，请重试'),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class IdentityEditPage extends StatefulWidget {
  const IdentityEditPage({
    required this.kind,
    required this.store,
    this.original,
    this.transferFrom,
    super.key,
  });
  final IdentityKind kind;
  final IdentityStore store;
  final IdentityEntity? original;
  final IdentityEntity? transferFrom;
  @override
  State<IdentityEditPage> createState() => _IdentityEditPageState();
}

class _IdentityEditPageState extends State<IdentityEditPage> {
  IdentityEntity? get _initial => widget.original ?? widget.transferFrom;
  late final _name = TextEditingController(text: _initial?.knownName ?? '');
  late String? _groupId = widget.original?.groupId;
  late String? _personId = _initial?.personId;
  late int? _color = _initial?.colorRgb;
  late bool _active = widget.original?.active ?? true;
  late Future<IdentityDirectory> _directory = widget.store.directory();
  final _operationId = newOperationId();
  bool _saving = false, _discarded = false, _clearColorFallback = false;
  String? _error;
  bool get _dirty =>
      _name.text != (_initial?.knownName ?? '') ||
      _active != (widget.original?.active ?? true) ||
      (widget.kind == IdentityKind.member &&
          (_groupId != widget.original?.groupId ||
              _personId != _initial?.personId ||
              _color != _initial?.colorRgb));
  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.removeListener(_changed);
    _name.dispose();
    super.dispose();
  }

  Future<void> _related(bool groups) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => groups
            ? CatalogListPage(
                kind: CatalogKind.group,
                store: CatalogStore(
                  widget.store.database,
                  clock: widget.store.clock,
                ),
              )
            : IdentityListPage(kind: IdentityKind.person, store: widget.store),
      ),
    );
    if (mounted) {
      setState(() {
        _directory = widget.store.directory();
      });
    }
  }

  void _leave([IdentityEntity? result]) {
    setState(() {
      _discarded = true;
      _saving = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, result);
    });
  }

  Future<void> _discard() async {
    if (_saving) return;
    if (!_dirty) {
      _leave();
      return;
    }
    final discard = await showDialog<bool>(
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
    if (mounted && discard == true) _leave();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (widget.transferFrom != null && _groupId == null) {
      setState(() => _error = '转团请选择目标团体');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final original = widget.original;
      final IdentityEntity result;
      if (widget.kind == IdentityKind.person) {
        result = original == null
            ? await widget.store.createPerson(
                name: _name.text,
                operationId: _operationId,
              )
            : await widget.store.editPerson(
                original: original,
                name: _name.text,
                active: _active,
                operationId: _operationId,
              );
      } else if (widget.transferFrom != null) {
        result = await widget.store.transferMember(
          original: widget.transferFrom!,
          groupId: _groupId!,
          name: _name.text,
          operationId: _operationId,
        );
      } else if (original == null) {
        result = await widget.store.createMember(
          name: _name.text,
          groupId: _groupId,
          personId: _personId,
          colorRgb: _color,
          operationId: _operationId,
        );
      } else {
        result = await widget.store.editMember(
          original: original,
          name: _name.text,
          correctGroup: _groupId != original.groupId,
          correctedGroupId: _groupId,
          colorRgb: _color,
          personId: _personId,
          active: _active,
          operationId: _operationId,
          clearColorFallback: _clearColorFallback && _color == null,
        );
      }
      RecordStore.invalidateReads();
      TicketStore.invalidateReads();
      if (mounted) _leave(result);
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

  Future<void> _transfer() async {
    if (_dirty) {
      setState(() => _error = '请先保存或取消当前修改，再转团');
      return;
    }
    if (widget.original!.personId == null) {
      setState(() => _error = '请先设置同人关联，再转团');
      return;
    }
    final result = await Navigator.push<IdentityEntity>(
      context,
      MaterialPageRoute(
        builder: (_) => IdentityEditPage(
          kind: IdentityKind.member,
          store: widget.store,
          transferFrom: widget.original,
        ),
      ),
    );
    if (mounted && result != null) _leave(result);
  }

  @override
  Widget build(BuildContext context) => PopScope<IdentityEntity>(
    canPop: !_saving && _discarded,
    onPopInvokedWithResult: (popped, result) {
      if (!popped && !_saving) _discard();
    },
    child: Scaffold(
      appBar: AppBar(
        toolbarHeight: _toolbarHeight(context),
        title: Text(
          widget.transferFrom != null
              ? '转团 · 新身份'
              : '${widget.original == null ? '新增' : '修改'}${widget.kind == IdentityKind.member ? '成员' : '同人标签'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (widget.original != null)
            IconButton(
              tooltip: '修改历史',
              onPressed: _saving
                  ? null
                  : () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => IdentityHistoryPage(
                          entity: widget.original!,
                          store: widget.store,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.history),
            ),
          if (widget.original?.kind == IdentityKind.member)
            IconButton(
              tooltip: '转团新增身份',
              onPressed: _saving ? null : _transfer,
              icon: const Icon(Icons.group_add_outlined),
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
                    key: const ValueKey('identity-name'),
                    controller: _name,
                    enabled: !_saving,
                    decoration: InputDecoration(
                      labelText: widget.kind == IdentityKind.member
                          ? '成员名称'
                          : '关联标签',
                    ),
                  ),
                  if (widget.kind == IdentityKind.person)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('标签用于手动关联同一人的不同成员身份。同名不会自动合并。'),
                    ),
                  if (widget.kind == IdentityKind.member)
                    FutureBuilder<IdentityDirectory>(
                      future: _directory,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: _IdentityReadError(
                              onRetry: () => setState(() {
                                _directory = widget.store.directory();
                              }),
                            ),
                          );
                        }
                        if (!snapshot.hasData) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        final directory = snapshot.data!;
                        final groups = directory.groups
                            .where(
                              (g) =>
                                  (g.active ||
                                      g.id == widget.original?.groupId) &&
                                  g.id != widget.transferFrom?.groupId,
                            )
                            .toList();
                        final persons = directory.persons
                            .where((p) => p.active || p.id == _personId)
                            .toList();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              key: ValueKey('identity-group-$_groupId'),
                              initialValue: groups.any((g) => g.id == _groupId)
                                  ? _groupId
                                  : null,
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: widget.original == null
                                    ? '团体'
                                    : '团体（纠正填写）',
                              ),
                              items: [
                                if (widget.transferFrom == null)
                                  const DropdownMenuItem<String>(
                                    value: '',
                                    child: Text('未填写'),
                                  ),
                                ...groups.map(
                                  (g) => DropdownMenuItem(
                                    value: g.id,
                                    child: Text(
                                      '${g.name}${g.active ? '' : '（团体已停用）'}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (id) => setState(
                                      () => _groupId = id == '' ? null : id,
                                    ),
                            ),
                            if (groups.any(
                              (g) => g.id == _groupId && !g.active,
                            ))
                              const Text('团体已停用'),
                            if (widget.original != null)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('填错团体可在此纠正。真实转团请使用右上角转团入口，历史保留。'),
                              ),
                            TextButton(
                              onPressed: _saving ? null : () => _related(true),
                              child: const Text('管理团体'),
                            ),
                            const SizedBox(height: 16),
                            if (widget.transferFrom == null) ...[
                              DropdownButtonFormField<String?>(
                                key: ValueKey('identity-person-$_personId'),
                                initialValue: _personId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '同人关联',
                                ),
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('不关联'),
                                  ),
                                  for (final p in persons)
                                    DropdownMenuItem<String?>(
                                      value: p.id,
                                      child: Text(
                                        '${p.name}${p.active ? '' : '（已停用）'}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: _saving
                                    ? null
                                    : (id) => setState(() => _personId = id),
                              ),
                              TextButton(
                                onPressed: _saving
                                    ? null
                                    : () => _related(false),
                                child: const Text('管理同人关联'),
                              ),
                              const SizedBox(height: 8),
                              MemberColorField(
                                value: Color(0xff000000 | (_color ?? 0x83bcd8)),
                                enabled: !_saving,
                                onChanged: (color) => setState(
                                  () => _color = color.toARGB32() & 0xffffff,
                                ),
                              ),
                              TextButton(
                                onPressed: _saving || _color == null
                                    ? null
                                    : () => setState(() {
                                        _color = null;
                                        _clearColorFallback = true;
                                      }),
                                child: Text(_color == null ? '颜色未填写' : '清空颜色'),
                              ),
                            ] else
                              const Text('保留原同人关联与颜色，新增后可修改。原成员身份保持不变。'),
                          ],
                        );
                      },
                    ),
                  if (widget.original != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: ChekiCard(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _active,
                          title: Text(
                            widget.kind == IdentityKind.member
                                ? '成员使用中'
                                : '同人关联使用中',
                          ),
                          subtitle: Text(
                            widget.kind == IdentityKind.member
                                ? '仅设置成员自身状态，停用后保留历史'
                                : '停用后保留历史',
                          ),
                          onChanged: _saving
                              ? null
                              : (value) => setState(() => _active = value),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: ChekiColors.danger),
                  ),
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

class IdentityHistoryPage extends StatefulWidget {
  const IdentityHistoryPage({
    required this.entity,
    required this.store,
    super.key,
  });
  final IdentityEntity entity;
  final IdentityStore store;
  @override
  State<IdentityHistoryPage> createState() => _IdentityHistoryPageState();
}

class _IdentityHistoryPageState extends State<IdentityHistoryPage> {
  late Future<List<Map<String, Object?>>> _history = widget.store.history(
    widget.entity,
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: _toolbarHeight(context),
      title: const Text('修改历史', maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: SafeArea(
      top: false,
      child: FutureBuilder<List<Map<String, Object?>>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _IdentityReadError(
              onRetry: () => setState(() {
                _history = widget.store.history(widget.entity);
              }),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final row in snapshot.data!)
                _IdentityHistoryItem(kind: widget.entity.kind, row: row),
            ],
          );
        },
      ),
    ),
  );
}

class _IdentityHistoryItem extends StatelessWidget {
  const _IdentityHistoryItem({required this.kind, required this.row});
  final IdentityKind kind;
  final Map<String, Object?> row;
  @override
  Widget build(BuildContext context) {
    final after = decodeSqlRow(row['after_json'] as String);
    final before = row['before_json'] == null
        ? null
        : decodeSqlRow(row['before_json'] as String);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ChekiCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(after['name'] as String? ?? '未填写名称'),
            if (before != null && before['name'] != after['name'])
              Text('原名：${before['name']}'),
            Text(
              after['active'] == 1
                  ? '使用中'
                  : kind == IdentityKind.member
                  ? '成员已停用'
                  : '同人关联已停用',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (kind == IdentityKind.member)
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: after['color_rgb'] == null
                          ? ChekiColors.inputBorder
                          : Color(0xff000000 | (after['color_rgb'] as int)),
                      shape: BoxShape.circle,
                      border: Border.all(color: ChekiColors.inputBorder),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(after['color_rgb'] == null ? '颜色未填写' : '成员颜色'),
                  ),
                ],
              ),
            if (before != null && before['group_id'] != after['group_id'])
              const Text('团体填写已纠正，原归属保留在历史中'),
            if (before != null && before['person_id'] != after['person_id'])
              const Text('同人关联已变更'),
            const SizedBox(height: 8),
            Text(
              '动作时间：${identityActionLabel(row['created_at'] as String)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
