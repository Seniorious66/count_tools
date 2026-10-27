import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/catalog_contract.dart';
import '../data/entry_store.dart';
import '../data/record_cost.dart';
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
  final _manualLines = <Map<String, Object?>>{};
  final _definitionOnly = <Map<String, Object?>>{};
  final _manualPools = <Map<String, Object?>>{};
  final _suppressedMembers = <String>{};
  bool _historical = false;
  @override
  void notifyListeners() {
    if (!disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    amount.dispose();
    super.dispose();
  }

  bool get changed => loaded && jsonEncode(_planRaw) != baseline;
  bool modeTouched = false, amountTouched = false;
  final amount = TextEditingController();
  Map<String, Object?> get _planRaw {
    final v = <String, Object?>{
      ...raw,
      if (modeTouched || mode != raw['mode']) 'mode': mode,
      if (jsonEncode(lines) != jsonEncode(raw['lines'] ?? [])) 'lines': lines,
    };
    if (modeTouched ||
        amountTouched ||
        recordId == null && mode != null ||
        raw['expense_origin'] != null) {
      v.remove('direct_amount');
      v.remove('expense_origin');
      if (mode == 'record_only') {
        v['expense_origin'] = 'direct';
        v['direct_amount'] = amount.text.trim().isEmpty
            ? null
            : amount.text.trim();
      } else if (mode == 'consume') {
        v['expense_origin'] = 'coupons';
      }
    }
    return v;
  }

  CouponPlan get plan => CouponPlan(_planRaw);
  Future<void> load(
    RecordInformation next, {
    Future<IdentityDirectory>? directoryFuture,
  }) async {
    info = next;
    loading = true;
    notifyListeners();
    final preserve = loaded;
    try {
      final state = recordId == null ? null : await store.state(recordId!);
      directory =
          await (directoryFuture ?? IdentityStore(store.database).directory());
      if (!preserve) {
        if (!modeTouched) mode = state == null ? initialMode : state.plan.mode;
        raw = state?.plan.toMap() ?? {};
        if (!amountTouched) amount.text = raw['direct_amount'] as String? ?? '';
        if (!amountTouched &&
            raw['expense_origin'] == null &&
            recordId != null) {
          final prior = (await store.database()).query(
            'cheki_records',
            where: 'id=?',
            whereArgs: [recordId],
          );
          final rows = await prior;
          if (rows.isNotEmpty) {
            final cost = legacyRecordCost(
              RecordInformation.decode(
                rows.single['information_json'] as String,
              ).toMap(),
            );
            if (cost?.hasAmount == true) {
              amount.text =
                  (RecordInformation.decode(
                            rows.single['information_json'] as String,
                          ).toMap()['legacy_raw']
                          as Map)['price']
                      as String;
            }
          }
        }
        lines = state?.plan.lines ?? [];
        manual = state != null;
        _historical = recordId != null;
      }
      // Inputs can change while the directory or inventory is being read.
      // A loaded snapshot must belong to the latest form date.
      while (true) {
        final day = info.occurredOn?.value;
        final updated = await store.availability(recordId: recordId, day: day);
        if (disposed) return;
        if (day != info.occurredOn?.value) continue;
        model = updated;
        break;
      }
      loaded = true;
      loading = false;
      if (!_historical) suggest();
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
      if (loading ||
          next.occurredOn != previous.occurredOn ||
          next.occurredOn != null && model?.day != next.occurredOn?.value) {
        loading = true;
        notifyListeners();
        final updated = await store.availability(
          recordId: recordId,
          day: next.occurredOn?.value,
        );
        if (disposed || id != request) return;
        model = updated;
      }
      if (!_historical) {
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
        if (next.quantity != previous.quantity) {
          for (final line in lines) {
            if (lines
                        .where(
                          (other) => other['member_id'] == line['member_id'],
                        )
                        .length ==
                    1 &&
                (!_manualLines.contains(line) ||
                    _definitionOnly.contains(line))) {
              line['quantity'] = next.quantity;
            }
          }
          allocate();
        }
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
    if (reset) {
      manual = false;
      _historical = false;
      _manualLines.clear();
      _definitionOnly.clear();
      _manualPools.clear();
      _suppressedMembers.clear();
    }
    final old = lines;
    for (final line in old.where(_definitionOnly.contains)) {
      line['quantity'] = info.quantity;
    }
    lines = [];
    final remaining = <String, int>{
      for (final d in model!.definitions)
        d.id: model!
            .pools(d.id)
            .where((p) => !p.expired(model!.day))
            .fold(0, (q, p) => q + p.quantity),
    };
    // Manual rows reserve their actual pool allocations before suggestions.
    for (final l in old.where(_manualLines.contains)) {
      if (!(info.memberIds ?? []).contains(l['member_id'])) continue;
      final id = l['definition_id'] as String?;
      if (id != null) {
        remaining[id] =
            (remaining[id] ?? 0) -
            CouponPlan.pools(
              l,
            ).fold<int>(0, (q, p) => q + (p['quantity'] as int? ?? 0));
      }
    }
    for (final member in info.memberIds ?? <String>[]) {
      if (_suppressedMembers.contains(member)) continue;
      final existing = old.where((l) => l['member_id'] == member).toList();
      final pinned = existing.where(_manualLines.contains).toList();
      if (pinned.isNotEmpty) {
        lines.addAll(pinned);
        continue;
      }
      final candidates = eligible(member)
          .where(
            (d) =>
                info.occurredOn != null &&
                (remaining[d.id] ?? 0) > 0 &&
                (d.information.text('size_id') == null ||
                    info.sizeId == null ||
                    d.information.text('size_id') == info.sizeId) &&
                (d.information.text('signature') == null ||
                    info.signature == null ||
                    d.information.text('signature') == info.signature?.name),
          )
          .toList();
      int unknowns(TicketObject d) =>
          (info.sizeId != null && d.information.text('size_id') == null
              ? 1
              : 0) +
          (info.signature != null && d.information.text('signature') == null
              ? 1
              : 0);
      int sizeRank(TicketObject d) => switch (d.information.text('size_id')) {
        'size-3inch' => 0,
        'size-5inch' => 1,
        null => 3,
        _ => 2,
      };
      candidates.sort((a, b) {
        // Unknown definition metadata is not a claim of an exact match.
        var order = unknowns(a).compareTo(unknowns(b));
        if (order != 0) return order;
        order = (a.information.text('scope') == 'personal' ? 0 : 1).compareTo(
          b.information.text('scope') == 'personal' ? 0 : 1,
        );
        if (order != 0) return order;
        if (info.sizeId == null) {
          order = sizeRank(a).compareTo(sizeRank(b));
          if (order != 0) return order;
        }
        return a.id.compareTo(b.id);
      });
      final choice = candidates.firstOrNull;
      // Reset pool allocation without discarding an explicit positive demand.
      final previousQuantity = existing.firstOrNull?['quantity'];
      final quantity = reset && previousQuantity is int && previousQuantity > 0
          ? previousQuantity
          : info.quantity;
      lines.add({
        if (existing.isNotEmpty &&
            existing.first['definition_id'] == choice?.id)
          ...existing.first,
        'member_id': member,
        'definition_id': choice?.id,
        if (choice != null) 'definition_name': choice.information.text('name'),
        if (choice != null)
          'group_name': directory?.groups
              .where((g) => g.id == choice.information.text('group_id'))
              .firstOrNull
              ?.knownName,
        'quantity': quantity,
        'pools':
            existing.isNotEmpty && existing.first['definition_id'] == choice?.id
            ? existing.first['pools']
            : [],
      });
      if (choice != null) {
        remaining[choice.id] = (remaining[choice.id] ?? 0) - (quantity ?? 0);
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
      for (final l in lines.where(
        (l) => only != null
            ? identical(l, lines[only])
            : !_manualLines.contains(l) || _definitionOnly.contains(l),
      )) {
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
    } else {
      for (final line in lines.where(
        (l) => _manualLines.contains(l) && !_definitionOnly.contains(l),
      )) {
        for (final pool in CouponPlan.pools(line)) {
          final key = '${line['definition_id']}:${pool['expires_on'] ?? ''}';
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
      if (only == null &&
          _manualLines.contains(line) &&
          !_definitionOnly.contains(line)) {
        continue;
      }
      final priorPools = CouponPlan.pools(line);
      final def = line['definition_id'] as String?;
      var left = line['quantity'] as int?;
      final pools = <Map<String, Object?>>[];
      if (left != null && left < 0) {
        line['pools'] = pools;
        continue;
      }
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
    _manualLines.add(lines[index]);
    _definitionOnly.add(lines[index]);
    _manualPools.remove(lines[index]);
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
    allocate();
    notifyListeners();
  }

  void editQuantity(int index, String text) {
    manual = true;
    _manualLines.add(lines[index]);
    _definitionOnly.remove(lines[index]);
    lines[index]['quantity'] = text.trim().isEmpty
        ? null
        : int.tryParse(text) ?? -1;
    if (!_manualPools.contains(lines[index])) {
      allocate(only: index);
      allocate(); // Released stock can now satisfy the other automatic rows.
    }
    notifyListeners();
  }

  void editPool(int line, int pool, String text) {
    manual = true;
    _manualLines.add(lines[line]);
    _definitionOnly.remove(lines[line]);
    _manualPools.add(lines[line]);
    final p = CouponPlan.pools(lines[line]);
    p[pool]['quantity'] = text.trim().isEmpty ? null : int.tryParse(text) ?? -1;
    lines[line]['pools'] = p;
    allocate();
    notifyListeners();
  }

  void addLine(String member) {
    manual = true;
    _suppressedMembers.remove(member);
    lines.add({
      'member_id': member,
      'definition_id': null,
      'quantity': info.quantity,
      'pools': [],
    });
    _manualLines.add(lines.last);
    notifyListeners();
  }

  void removeLine(int i) {
    manual = true;
    final member = lines[i]['member_id'] as String? ?? '';
    _manualLines.remove(lines[i]);
    _definitionOnly.remove(lines[i]);
    _manualPools.remove(lines[i]);
    lines.removeAt(i);
    if (!lines.any((l) => l['member_id'] == member)) {
      _suppressedMembers.add(member);
    }
    notifyListeners();
  }

  void addExpired(int line, TicketPool pool) {
    manual = true;
    _manualLines.add(lines[line]);
    _definitionOnly.remove(lines[line]);
    _manualPools.add(lines[line]);
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
    _manualLines.add(lines[line]);
    _definitionOnly.remove(lines[line]);
    _manualPools.add(lines[line]);
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
    if (p.consuming) {
      for (final line in p.lines) {
        final need = line['quantity'];
        final allocated = CouponPlan.pools(
          line,
        ).fold<int>(0, (q, pool) => q + (pool['quantity'] as int? ?? 0));
        if (need is int && need > 0 && allocated != need) {
          throw CatalogException(
            '需要$need张，已分配$allocated张，${allocated < need ? '还差${need - allocated}' : '多分配${allocated - need}'}张；请核对差额、券种或分配。',
          );
        }
      }
    }
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
    this.autoLoad = true,
    super.key,
  });
  final CouponEntryController controller;
  final RecordInformation info;
  final bool autoLoad;
  @override
  State<CouponEntryEditor> createState() => _CouponEntryEditorState();
}

class _CouponEntryEditorState extends State<CouponEntryEditor> {
  CouponEntryController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(update);
    if (widget.autoLoad && !c.loaded && !c.loading) c.load(widget.info);
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
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final option in [
                ('consume', '记录并扣券'),
                ('record_only', '仅记录'),
              ]) ...[
                if (option.$1 != 'consume') const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    selected: c.mode == option.$1,
                    child: OutlinedButton(
                      key: ValueKey(
                        option.$1 == 'consume'
                            ? 'use-consume'
                            : 'use-record-only',
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: c.mode == option.$1
                            ? ChekiColors.blue
                            : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                      ),
                      onPressed: () => c.selectMode(option.$1),
                      child: Text(option.$2, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (c.mode == 'record_only') ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('direct-amount'),
            controller: c.amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: '实际总支出（元）'),
            onChanged: (_) {
              c.amountTouched = true;
              c.notifyListeners();
            },
          ),
        ],
        if (c.mode == 'consume') ...[
          const SizedBox(height: 12),
          const Text('扣券明细'),
          TextButton(
            onPressed: () {
              c.restoreAutomatic();
            },
            child: const Text('恢复自动分配'),
          ),
          if (c.lines.isEmpty) const Text('先选择参与成员和券种，也可以选择仅记录。'),
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
            if (selected != null &&
                (selected.information.text('size_id') == null ||
                    selected.information.text('signature') == null))
              const Text('券种尺寸或属性未填写，请核对是否适用。'),
            if (l['quantity'] is int &&
                pools.fold<int>(0, (q, p) => q + (p['quantity'] as int? ?? 0)) <
                    (l['quantity'] as int))
              Text(
                '需要${l['quantity']}张，${c._manualPools.contains(l) ? '已分配' : '可用'}${pools.fold<int>(0, (q, p) => q + ((p['quantity'] as int? ?? 0).clamp(0, 1000000000)))}张，还差${(l['quantity'] as int) - pools.fold<int>(0, (q, p) => q + ((p['quantity'] as int? ?? 0).clamp(0, 1000000000)))}张。可修改张数、券种或切换仅记录。',
              ),
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
            if (c._manualPools.contains(l))
              Text('手动分配已保留；记录${widget.info.quantity ?? '未填写'}张，请核对需要量和分配量。'),
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
    this.showAmount = true,
    super.key,
  });
  final CouponPlan plan;
  final EntryStore store;
  final String? originalId;
  final bool showAmount;
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
                  : '本次不扣券',
            ),
            if (showAmount &&
                plan.expenseOrigin == 'direct' &&
                plan.directAmount != null)
              Text('实际总支出：¥${plan.directAmount!.roundedYuan}'),
            if (plan.consuming)
              for (final l in plan.lines)
                for (final p in CouponPlan.pools(l))
                  if ((p['quantity'] as int? ?? 0) > 0) ...[
                    Text(
                      '${m.definitions.where((d) => d.id == l['definition_id']).map(m.label).firstOrNull ?? '券种信息不可用'} · ${p['quantity']} 张${p['expires_on'] == null ? '' : ' · ${p['expires_on']} 截止'}',
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
            showAmount: false,
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
      final legacy = widget.plan.expenseOrigin == null
          ? legacyRecordCost(widget.info.toMap())
          : null;
      if (legacy != null) return Text(legacy.label);
      if (!widget.plan.consuming) return const SizedBox.shrink();
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
      final amount = RecordCost()..linkedRecords = 1;
      amount.addAllocations(s.data!);
      if (!amount.hasAmount) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text('预计${amount.label}')],
        ),
      );
    },
  );
}
