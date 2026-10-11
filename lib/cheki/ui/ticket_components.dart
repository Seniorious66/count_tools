import 'package:flutter/material.dart';
import '../domain/record_contract.dart';
import 'components.dart';
import 'theme.dart';

enum TicketPoolKind { longTerm, limited }

/// Presentation snapshot of already-calculated usable inventory. This is not
/// an inventory service and is not exposed by the M1 application shell.
final class TicketPoolView {
  TicketPoolView({
    required this.id,
    required this.kind,
    required this.available,
    this.expiresOn,
  }) {
    if (id.isEmpty || available < 0) throw ArgumentError('券池数据无效');
    if ((kind == TicketPoolKind.limited) != (expiresOn != null)) {
      throw ArgumentError('限时券需要截止日期，长期券没有截止日期');
    }
  }
  final String id;
  final TicketPoolKind kind;
  final int available;
  final OccurredOn? expiresOn;
}

final class TicketAvailabilityView {
  TicketAvailabilityView({
    required this.ticketId,
    required this.ticketName,
    required List<TicketPoolView> pools,
  }) : pools = List.unmodifiable(pools) {
    if (ticketId.isEmpty ||
        ticketName.trim().isEmpty ||
        pools.map((p) => p.id).toSet().length != pools.length) {
      throw ArgumentError('券名或券池标识无效');
    }
  }
  final String ticketName; // Always includes its group prefix.
  final String ticketId;
  final List<TicketPoolView> pools;
  int get total => pools.fold(0, (sum, pool) => sum + pool.available);
  bool get hasLong =>
      pools.any((p) => p.kind == TicketPoolKind.longTerm && p.available > 0);
  bool get hasLimited =>
      pools.any((p) => p.kind == TicketPoolKind.limited && p.available > 0);
  List<TicketPoolView> get visiblePools =>
      pools.where((p) => p.available > 0).toList();
  String poolLabel(TicketPoolView pool) => pool.kind == TicketPoolKind.limited
      ? '限时 · ${pool.expiresOn}'
      : hasLimited && hasLong
      ? '长期'
      : '可用';

  /// Per-ticket validation; the M2 service must also sum shared-pool requests
  /// across members and validate the actual database inventory transaction.
  String? allocationError(Map<String, String> quantities, int needed) {
    if (needed <= 0) return '所需张数必须为正整数';
    if (quantities.keys.any((id) => !pools.any((p) => p.id == id))) {
      return '券池已变化，请重新核对';
    }
    var assigned = 0;
    for (final pool in pools) {
      final raw = quantities[pool.id] ?? '0';
      if (!RegExp(r'^\d+$').hasMatch(raw)) return '扣量必须为非负整数';
      final amount = int.tryParse(raw);
      if (amount == null) return '扣量超出支持范围';
      if (amount > pool.available) return '${poolLabel(pool)}券不足';
      assigned += amount;
    }
    if (assigned < needed) return '还差 ${needed - assigned} 张';
    if (assigned > needed) return '多分配 ${assigned - needed} 张';
    return null;
  }
}

class TicketAvailabilityCard extends StatelessWidget {
  const TicketAvailabilityCard({required this.value, super.key});

  /// Null is loading, not zero. Failures must be handled by the calling page.
  final TicketAvailabilityView? value;
  @override
  Widget build(BuildContext context) {
    final snapshot = value;
    if (snapshot == null) {
      return ChekiCard(
        child: Semantics(
          label: '正在读取券库存',
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return ChekiCard(
      color: ChekiColors.pink,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(snapshot.ticketName),
          const SizedBox(height: 8),
          Text(
            '${snapshot.total} 张',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          if (snapshot.hasLimited)
            for (final pool in snapshot.visiblePools)
              Text('${snapshot.poolLabel(pool)} · ${pool.available} 张'),
        ],
      ),
    );
  }
}

/// Always open: no expander and no implicit changes to the other pools.
class TicketAllocationEditor extends StatelessWidget {
  const TicketAllocationEditor({
    required this.value,
    required this.quantities,
    required this.needed,
    required this.onChanged,
    super.key,
  });
  final TicketAvailabilityView value;
  final Map<String, String> quantities;
  final int needed;
  final void Function(String poolId, String text) onChanged;
  @override
  Widget build(BuildContext context) => ChekiCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(value.ticketName, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('所需 $needed 张'),
        for (final pool in value.visiblePools)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _PoolInput(
              key: ValueKey(pool.id),
              text: quantities[pool.id] ?? '0',
              label: '${value.poolLabel(pool)} ${pool.available}',
              onChanged: (text) => onChanged(pool.id, text),
            ),
          ),
        if (value.allocationError(quantities, needed) case final String error)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                '! $error',
                style: const TextStyle(color: ChekiColors.danger),
              ),
            ),
          ),
      ],
    ),
  );
}

class _PoolInput extends StatefulWidget {
  const _PoolInput({
    required this.text,
    required this.label,
    required this.onChanged,
    super.key,
  });
  final String text;
  final String label;
  final ValueChanged<String> onChanged;
  @override
  State<_PoolInput> createState() => _PoolInputState();
}

class _PoolInputState extends State<_PoolInput> {
  late final controller = TextEditingController(text: widget.text);
  @override
  void didUpdateWidget(_PoolInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (controller.text != widget.text) {
      controller.value = TextEditingValue(
        text: widget.text,
        selection: TextSelection.collapsed(offset: widget.text.length),
      );
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: widget.label),
    onChanged: widget.onChanged,
  );
}

final class TicketUsageView {
  TicketUsageView({
    required this.ticketId,
    required this.ticketName,
    required this.poolKind,
    required this.quantity,
    this.expiresOn,
  }) {
    if (ticketId.isEmpty ||
        quantity < 0 ||
        ticketName.trim().isEmpty ||
        (poolKind == TicketPoolKind.limited) != (expiresOn != null)) {
      throw ArgumentError('用券明细无效');
    }
  }
  final String ticketName;
  final String ticketId;
  final TicketPoolKind poolKind;
  final int quantity;
  final OccurredOn? expiresOn;
}

/// Uses recorded usage, not today's stock: depleted/expired historical facts
/// remain visible. A long-only usage has no redundant long-term label.
class TicketUsageList extends StatelessWidget {
  const TicketUsageList({
    required this.usages,
    this.availabilityByTicket = const {},
    super.key,
  });
  final List<TicketUsageView> usages;
  final Map<String, TicketAvailabilityView> availabilityByTicket;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: usages.where((u) => u.quantity > 0).map((usage) {
      final snapshot = availabilityByTicket[usage.ticketId];
      final both = snapshot != null
          ? snapshot.hasLong && snapshot.hasLimited
          : usages.any(
              (u) =>
                  u.quantity > 0 &&
                  u.ticketId == usage.ticketId &&
                  u.poolKind != usage.poolKind,
            );
      final suffix = usage.poolKind == TicketPoolKind.limited
          ? ' · 限时 ${usage.expiresOn}'
          : both
          ? ' · 长期'
          : '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('${usage.ticketName}$suffix · ${usage.quantity} 张'),
      );
    }).toList(),
  );
}
