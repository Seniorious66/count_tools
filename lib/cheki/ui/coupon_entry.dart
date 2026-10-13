import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/catalog_contract.dart';
import '../data/entry_store.dart';
import '../data/identity_store.dart';
import '../data/ticket_store.dart';
import '../domain/coupon_plan.dart';
import '../domain/record_information.dart';
import 'components.dart';
import 'theme.dart';

class CouponEntryController extends ChangeNotifier {
  CouponEntryController({
    required this.store,
    required this.initialMode,
    this.recordId,
  });
  final EntryStore store;
  final String? initialMode, recordId;
  String? mode;
  bool loaded = false, loading = false, manual = false;
  String? error;
  TicketModel? model;
  IdentityDirectory? directory;
  Map<String, Object?> raw = {};
  List<Map<String, Object?>> lines = [];
  String baseline = '';
  RecordInformation info = RecordInformation.fromMap({});
  var request = 0;
  bool disposed = false;
  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }

  bool get changed => loaded && jsonEncode(_planRaw) != baseline;
  bool modeTouched = false;
  Map<String, Object?> get _planRaw => {
    ...raw,
    if (modeTouched || mode != raw['mode']) 'mode': mode,
    if (jsonEncode(lines) != jsonEncode(raw['lines'] ?? [])) 'lines': lines,
  };
  CouponPlan get plan => CouponPlan(_planRaw);
  Future<void> load(RecordInformation next) async {
    info = next;
    loading = true;
    notifyListeners();
    final preserve = loaded;
    try {
      final state = recordId == null ? null : await store.state(recordId!);
      directory = await IdentityStore(store.database).directory();
      if (!preserve) {
        mode = state == null ? initialMode : state.plan.mode;
        raw = state?.plan.toMap() ?? {};
        lines = state?.plan.lines ?? [];
        manual = state != null;
      }
      model = await store.availability(
        recordId: recordId,
        day: info.occurredOn?.value,
      );
      loaded = true;
      loading = false;
      if (!manual) suggest();
      if (!preserve) baseline = plan.encode();
      error = null;
      notifyListeners();
    } catch (e) {
      loading = false;
      error = '券库存读取失败，请重试';
      notifyListeners();
    }
  }

  Future<void> sync(RecordInformation next) async {
    if (next.encode() == info.encode()) return;
    final previous = info;
    info = next;
    if (!loaded) return;
    final id = ++request;
    try {
      if (next.occurredOn != previous.occurredOn) {
        loading = true;
        notifyListeners();
        final updated = await store.availability(
          recordId: recordId,
          day: next.occurredOn?.value,
        );
        if (id != request) return;
        model = updated;
      }
      if (!manual) {
        suggest();
      } else {
        lines = lines
            .where(
              (l) =>
                  l['member_id'] == null ||
                  next.memberIds == null ||
                  next.memberIds!.contains(l['member_id']),
            )
            .toList();
      }
      loading = false;
      error = null;
      notifyListeners();
    } catch (e) {
      if (id == request) {
        loading = false;
        error = '券库存读取失败，请重试';
        notifyListeners();
      }
    }
  }

  List<TicketObject> eligible(String memberId) {
    final member = directory?.members
        .where((m) => m.id == memberId)
        .firstOrNull;
    if (member?.groupId == null || model == null) return [];
    final found = model!.definitions.where((d) {
      final v = d.information.toMap();
      return v['active'] == true &&
          v['group_id'] == member!.groupId &&
          (v['scope'] == 'group' ||
              v['scope'] == 'personal' && v['member_id'] == memberId);
    }).toList();
    return found;
  }

  String memberName(Object? id) {
    final member = directory?.members.where((m) => m.id == id).firstOrNull;
    return member == null
        ? '成员未填写'
        : '${model?.groups[member.groupId] ?? '团体未填写'} · ${member.name}';
  }

  void suggest({bool reset = false}) {
    if (model == null) return;
    if (reset) manual = false;
    final old = lines;
    lines = [];
    for (final member in info.memberIds ?? <String>[]) {
      final existing = old.where((l) => l['member_id'] == member).toList();
      if (existing.isNotEmpty) {
        for (final l in existing) {
          lines.add({
            ...l,
            'quantity': reset ? l['quantity'] : info.quantity,
            'pools': l['pools'],
          });
        }
      } else {
        final candidates = eligible(member)
            .where(
              (d) =>
                  (d.information.text('size_id') == null ||
                      d.information.text('size_id') == info.sizeId) &&
                  (d.information.text('signature') == null ||
                      d.information.text('signature') == info.signature?.name),
            )
            .toList();
        final personal = candidates
            .where((d) => d.information.text('scope') == 'personal')
            .toList();
        final choices = personal.isNotEmpty ? personal : candidates;
        lines.add({
          'member_id': member,
          'definition_id': choices.length == 1 ? choices.single.id : null,
          if (choices.length == 1)
            'definition_name': choices.single.information.text('name'),
          if (choices.length == 1)
            'group_name': directory?.groups
                .where(
                  (g) => g.id == choices.single.information.text('group_id'),
                )
                .firstOrNull
                ?.knownName,
          'quantity': info.quantity,
          'pools': [],
        });
      }
    }
    allocate();
  }

  void restoreAutomatic() {
    suggest(reset: true);
    notifyListeners();
  }

  void allocate({int? only}) {
    if (info.occurredOn == null) {
      for (final l in lines) {
        l['pools'] = [];
      }
      return;
    }
    final available = <String, int>{};
    for (final p in model?.allPools ?? <TicketPool>[]) {
      if (!p.expired(model!.day)) {
        available['${p.definitionId}:${p.expiry ?? ''}'] = p.quantity;
      }
    }
    if (only != null) {
      for (var i = 0; i < lines.length; i++) {
        if (i == only) continue;
        for (final pool in CouponPlan.pools(lines[i])) {
          final key =
              '${lines[i]['definition_id']}:${pool['expires_on'] ?? ''}';
          available[key] =
              ((available[key] ?? 0) - (pool['quantity'] as int? ?? 0)).clamp(
                0,
                1 << 53,
              );
        }
      }
    }
    for (var i = 0; i < lines.length; i++) {
      if (only != null && only != i) continue;
      final line = lines[i];
      final priorPools = CouponPlan.pools(line);
      final def = line['definition_id'] as String?;
      var left = line['quantity'] as int?;
      final pools = <Map<String, Object?>>[];
      if (def != null) {
        for (final p in model!.pools(def)) {
          if (p.expired(model!.day)) continue;
          final key = '$def:${p.expiry ?? ''}';
          final capacity = available[key] ?? 0;
          final n = left == null
              ? null
              : left < capacity
              ? left
              : capacity;
          pools.add({
            ...?priorPools
                .where(
                  (old) =>
                      old['pool'] == (p.expiry == null ? 'long' : 'dated') &&
                      old['expires_on'] == p.expiry,
                )
                .firstOrNull,
            'pool': p.expiry == null ? 'long' : 'dated',
            if (p.expiry != null) 'expires_on': p.expiry,
            'quantity': n,
          });
          if (n != null) {
            available[key] = capacity - n;
            left = left! - n;
          }
        }
      }
      line['pools'] = pools;
    }
  }

  void selectMode(String? value) {
    modeTouched = true;
    mode = value;
    notifyListeners();
  }

  void selectDefinition(int index, String? id) {
    manual = true;
    lines[index]['definition_id'] = id;
    final d = model?.definitions.where((d) => d.id == id).firstOrNull;
    if (d != null) {
      lines[index].addAll({
        'definition_name': d.information.text('name'),
        'group_name': directory?.groups
            .where((g) => g.id == d.information.text('group_id'))
            .firstOrNull
            ?.knownName,
      });
    }
    // Reserve other manual rows before suggesting only the selected row.
    allocate(only: index);
    notifyListeners();
  }

  void editQuantity(int index, String text) {
    manual = true;
    lines[index]['quantity'] = text.trim().isEmpty
        ? null
        : int.tryParse(text) ?? -1;
    notifyListeners();
  }

  void editPool(int line, int pool, String text) {
    manual = true;
    final p = CouponPlan.pools(lines[line]);
    p[pool]['quantity'] = text.trim().isEmpty ? null : int.tryParse(text) ?? -1;
    lines[line]['pools'] = p;
    notifyListeners();
  }

  void addLine(String member) {
    manual = true;
    lines.add({
      'member_id': member,
      'definition_id': null,
      'quantity': info.quantity,
      'pools': [],
    });
    notifyListeners();
  }

  void removeLine(int i) {
    manual = true;
    lines.removeAt(i);
    notifyListeners();
  }

  void addExpired(int line, TicketPool pool) {
    manual = true;
    final pools = CouponPlan.pools(lines[line]);
    if (!pools.any(
      (p) => p['pool'] == 'dated' && p['expires_on'] == pool.expiry,
    )) {
      pools.add({
        'pool': 'dated',
        'expires_on': pool.expiry,
        'quantity': 0,
        'allow_expired': false,
      });
    }
    lines[line]['pools'] = pools;
    notifyListeners();
  }

  void confirmExpired(int line, int pool, bool yes) {
    manual = true;
    final pools = CouponPlan.pools(lines[line]);
    pools[pool]['allow_expired'] = yes;
    lines[line]['pools'] = pools;
    notifyListeners();
  }

  Future<CouponPlan> checked(RecordInformation current) async {
    if (!loaded || loading || error != null) {
      throw const CatalogException('券库存尚未读取成功，请重试；不会按零库存保存');
    }
    final p = plan;
    final db = await store.database();
    await EntrySchema.validatePlan(db, current, p, actual: p.consuming);
    if (p.consuming) {
      final demand = <String, int>{};
      for (final l in p.lines) {
        for (final pool in CouponPlan.pools(l)) {
          final n = pool['quantity'] as int;
          if (n == 0) continue;
          final def = l['definition_id'] as String,
              key = '$def:${pool['expires_on'] ?? ''}';
          final matches = model!
              .pools(def)
              .where((x) => x.expiry == pool['expires_on'])
              .toList();
          if (matches.isEmpty) {
            throw const CatalogException('所选券池当前无可用库存，请重新核对');
          }
          final stock = matches.single;
          if (stock.expired(model!.day) && pool['allow_expired'] != true) {
            throw const CatalogException('请明确确认使用过期券');
          }
          demand.update(key, (q) => q + n, ifAbsent: () => n);
          if (demand[key]! > stock.quantity) {
            throw const CatalogException('共享券池库存不足，请减少用券或选择仅记录');
          }
        }
      }
    }
    return p;
  }
}

class CouponEntryEditor extends StatefulWidget {
  const CouponEntryEditor({
    required this.controller,
    required this.info,
    super.key,
  });
  final CouponEntryController controller;
  final RecordInformation info;
  @override
  State<CouponEntryEditor> createState() => _CouponEntryEditorState();
}

class _CouponEntryEditorState extends State<CouponEntryEditor> {
  CouponEntryController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(update);
    if (!c.loaded && !c.loading) c.load(widget.info);
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(CouponEntryEditor old) {
    super.didUpdateWidget(old);
    if (widget.info.encode() != old.info.encode()) c.sync(widget.info);
  }

  @override
  void dispose() {
    c.removeListener(update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (c.loading || !c.loaded && c.error == null) {
      return const LinearProgressIndicator();
    }
    if (c.error != null) {
      return TextButton(
        onPressed: () => c.load(widget.info),
        child: Text(c.error!),
      );
    }
    final model = c.model!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('用券'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const ValueKey('use-consume'),
              label: const Text('记录并扣券'),
              selected: c.mode == 'consume',
              onSelected: (_) => c.selectMode('consume'),
            ),
            ChoiceChip(
              key: const ValueKey('use-record-only'),
              label: const Text('仅记录'),
              selected: c.mode == 'record_only',
              onSelected: (_) => c.selectMode('record_only'),
            ),
            ChoiceChip(
              key: const ValueKey('use-unknown'),
              label: const Text('用券信息待补录'),
              selected: c.mode == null,
              onSelected: (_) => c.selectMode(null),
            ),
          ],
        ),
        if (c.mode == null) const Text('本次仅保存信息，不生成扣券流水。'),
        if (c.mode == 'consume') ...[
          const SizedBox(height: 12),
          const Text('扣券明细'),
          TextButton(
            onPressed: () {
              c.restoreAutomatic();
            },
            child: const Text('恢复自动分配'),
          ),
          if (c.lines.isEmpty) const Text('先选择参与成员和券种，也可以选择仅记录或待补录。'),
          for (var index = 0; index < c.lines.length; index++)
            _line(index, model),
          for (final id in widget.info.memberIds ?? <String>[])
            TextButton(
              onPressed: () => c.addLine(id),
              child: Text('为${c.memberName(id)}添加券种'),
            ),
        ],
      ],
    );
  }

  Widget _line(int i, TicketModel model) {
    final l = c.lines[i], def = l['definition_id'] as String?;
    final selected = model.definitions.where((d) => d.id == def).firstOrNull;
    final candidates = c.eligible(l['member_id'] as String? ?? '');
    if (selected != null && !candidates.any((d) => d.id == selected.id)) {
      candidates.add(selected);
    }
    final pools = CouponPlan.pools(l),
        available = def == null ? <TicketPool>[] : model.pools(def);
    final valid = available.where((p) => !p.expired(model.day)).toList();
    final mixed =
        valid.any((p) => p.expiry == null) &&
        valid.any((p) => p.expiry != null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ChekiCard(
        color: ChekiColors.pink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.memberName(l['member_id'])),
            DropdownButtonFormField<String>(
              key: ValueKey('coupon-definition-$i-$def'),
              initialValue: def,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '券种'),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text('请选择')),
                for (final d in candidates)
                  DropdownMenuItem(
                    value: d.id,
                    child: Text(
                      '${model.label(d)} · ${model.scopeLabel(d)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (id) => c.selectDefinition(i, id),
            ),
            const SizedBox(height: 12),
            CouponNumberField(
              key: ValueKey('coupon-wanted-$i'),
              value: l['quantity']?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '需用张数（可空）'),
              onChanged: (text) => c.editQuantity(i, text),
            ),
            if (def != null && valid.isEmpty)
              const Text('该日期无有效库存，可查看过期库存或切换仅记录。'),
            for (var p = 0; p < pools.length; p++)
              if (pools[p]['expires_on'] != null ||
                  valid.any((x) => x.expiry == null) ||
                  (pools[p]['quantity'] as int? ?? 0) > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '${pools[p]['expires_on'] ?? (mixed ? '长期' : '可用')} · 库存 ${available.where((x) => x.expiry == pools[p]['expires_on']).map((x) => x.quantity).firstOrNull ?? 0} 张',
                ),
                if (pools[p]['expires_on'] != null &&
                    (pools[p]['expires_on'] as String).compareTo(model.day) < 0)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('已过期 ${pools[p]['expires_on']}，明确使用'),
                    value: pools[p]['allow_expired'] == true,
                    onChanged: (yes) => c.confirmExpired(i, p, yes ?? false),
                  ),
                CouponNumberField(
                  key: ValueKey('coupon-pool-$i-$p'),
                  value: pools[p]['quantity']?.toString() ?? '',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '本池扣量（可空）'),
                  onChanged: (text) => c.editPool(i, p, text),
                ),
              ],
            if (l['quantity'] is int)
              Text(
                '已分配 ${pools.fold(0, (q, p) => q + (p['quantity'] is int ? p['quantity'] as int : 0))} / 需用 ${l['quantity']} 张',
              ),
            for (final expired in available.where((p) => p.expired(model.day)))
              TextButton(
                onPressed: () => c.addExpired(i, expired),
                child: Text('选择过期池 ${expired.expiry} · ${expired.quantity} 张'),
              ),
            TextButton(
              onPressed: () => c.removeLine(i),
              child: const Text('移除此券种'),
            ),
          ],
        ),
      ),
    );
  }
}

class CouponPlanView extends StatelessWidget {
  const CouponPlanView({
    required this.plan,
    required this.store,
    this.originalId,
    super.key,
  });
  final CouponPlan plan;
  final EntryStore store;
  final String? originalId;
  @override
  Widget build(BuildContext context) => FutureBuilder<TicketModel>(
    future: store.availability(recordId: originalId),
    builder: (context, s) {
      if (s.hasError) return const Text('用券明细读取失败，请返回重试');
      if (!s.hasData) return const LinearProgressIndicator();
      final m = s.data!;
      return ChekiCard(
        color: ChekiColors.pink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.consuming
                  ? '记录并扣券'
                  : plan.mode == 'record_only'
                  ? '仅记录，不扣券'
                  : '用券信息待补录，本次不扣券',
            ),
            if (plan.consuming)
              for (final l in plan.lines)
                for (final p in CouponPlan.pools(l))
                  if ((p['quantity'] as int? ?? 0) > 0) ...[
                    Text(
                      '${l['group_name'] ?? m.groups[m.definitions.where((d) => d.id == l['definition_id']).firstOrNull?.information.text('group_id')] ?? '团体未填写'} · ${l['definition_name'] ?? m.definitions.where((d) => d.id == l['definition_id']).firstOrNull?.information.text('name') ?? '券名未填写'} · ${p['quantity']} 张${p['expires_on'] == null ? '' : ' · ${p['expires_on']} 截止'}',
                    ),
                    if (p['allow_expired'] == true) const Text('已确认使用过期库存'),
                  ],
            if (originalId != null) const Text('保存时重新核对库存与成本，其他历史流水不重算。'),
          ],
        ),
      );
    },
  );
}

class RecordCouponView extends StatelessWidget {
  const RecordCouponView({
    required this.recordId,
    required this.store,
    required this.info,
    super.key,
  });
  final String recordId;
  final RecordInformation info;
  final EntryStore store;
  @override
  Widget build(BuildContext context) => FutureBuilder<EntryState?>(
    future: store.state(recordId),
    builder: (c, s) {
      if (s.hasError) return const Text('关联券读取失败，请返回重试');
      if (s.connectionState == ConnectionState.waiting) {
        return const LinearProgressIndicator();
      }
      if (s.data == null) return const SizedBox();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CouponPlanView(
            plan: s.data!.plan,
            store: store,
            originalId: recordId,
          ),
          CouponCostPreview(
            info: info,
            plan: s.data!.plan,
            store: store,
            recordId: recordId,
          ),
        ],
      );
    },
  );
}

class CouponNumberField extends StatefulWidget {
  const CouponNumberField({
    required this.value,
    required this.decoration,
    required this.onChanged,
    this.keyboardType,
    super.key,
  });
  final String value;
  final InputDecoration decoration;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  @override
  State<CouponNumberField> createState() => _CouponNumberFieldState();
}

class _CouponNumberFieldState extends State<CouponNumberField> {
  late final controller = TextEditingController(text: widget.value);
  @override
  void didUpdateWidget(CouponNumberField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && controller.text != widget.value) {
      controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => TextField(
    controller: controller,
    keyboardType: widget.keyboardType,
    decoration: widget.decoration,
    onChanged: widget.onChanged,
  );
}

class CouponCostPreview extends StatefulWidget {
  const CouponCostPreview({
    required this.info,
    required this.plan,
    required this.store,
    this.recordId,
    super.key,
  });
  final RecordInformation info;
  final CouponPlan plan;
  final EntryStore store;
  final String? recordId;
  @override
  State<CouponCostPreview> createState() => _CouponCostPreviewState();
}

class _CouponCostPreviewState extends State<CouponCostPreview> {
  late Future<List<Map<String, Object?>>> future = widget.store.preview(
    widget.info,
    widget.plan,
    recordId: widget.recordId,
  );
  @override
  void didUpdateWidget(CouponCostPreview old) {
    super.didUpdateWidget(old);
    if (old.info.encode() != widget.info.encode() ||
        old.plan.encode() != widget.plan.encode() ||
        old.recordId != widget.recordId ||
        old.store != widget.store) {
      future = widget.store.preview(
        widget.info,
        widget.plan,
        recordId: widget.recordId,
      );
    }
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<List<Map<String, Object?>>>(
    future: future,
    builder: (c, s) {
      if (!widget.plan.consuming) return const SizedBox();
      if (s.hasError) {
        return TextButton(
          onPressed: () => setState(() {
            future = widget.store.preview(
              widget.info,
              widget.plan,
              recordId: widget.recordId,
            );
          }),
          child: const Text('库存或成本预检未通过，返回修改或重试'),
        );
      }
      if (!s.hasData) return const LinearProgressIndicator();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('成本预检'),
            for (final p in s.data!)
              Text(
                '${p['quantity']} 张 · ${p['cost'] == null ? '成本未知' : '成本 ¥${p['cost']}'}${p['preserved'] == true ? ' · 保留原分配' : ''}',
              ),
          ],
        ),
      );
    },
  );
}
