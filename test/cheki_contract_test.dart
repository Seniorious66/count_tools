import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/ui/ticket_components.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = OccurredOn.parse('2026-10-11');
  test('real calendar date, leap day and Shanghai instant boundary', () {
    expect(OccurredOn.parse('2024-02-29').value, '2024-02-29');
    for (final bad in [
      '2025-02-29',
      '2026-04-31',
      '2026-00-12',
      '0000-01-01',
      '2026-10-11T00:00:00',
      '2026-1-01',
      '2026-13-01',
    ]) {
      expect(() => OccurredOn.parse(bad), throwsFormatException);
    }
    expect(
      OccurredOn.shanghaiDay(DateTime.parse('2026-10-10T15:59:59Z')).value,
      '2026-10-10',
    );
    expect(OccurredOn.shanghaiDay(DateTime.parse('2026-10-10T16:00:00Z')), day);
  });
  test(
    'three exclusive classifications, invalid back signature is rejected',
    () {
      final signed = ChekiAttributes().setBackSigned(true);
      expect(signed.kind, SignatureKind.signed);
      for (final kind in [SignatureKind.unsigned, SignatureKind.homework]) {
        final changed = signed.select(kind);
        expect(changed.backSigned, isFalse);
        expect(changed.select(SignatureKind.signed).backSigned, isFalse);
        expect(
          () => ChekiAttributes(kind: kind, backSigned: true),
          throwsArgumentError,
        );
      }
      expect(signed.select(SignatureKind.signed).backSigned, isTrue);
    },
  );
  test(
    'initial received has no fabricated timestamp and cannot be partial',
    () {
      final state = ReceiptState.initialReceived(3, day);
      expect(state.status, ReceiptStatus.received);
      expect(state.batches.single.receivedAt, isNull);
      expect(state.unreceivedQuantity, 0);
      expect(
        () => ReceiptState(
          quantity: 3,
          occurredOn: day,
          batches: [ReceiptBatch(quantity: 1, origin: ReceiptOrigin.initial)],
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'actual receipt batches conserve quantity and do not alter occurrence',
    () {
      final first = ReceiptBatch(
        quantity: 1,
        origin: ReceiptOrigin.actual,
        receivedAt: DateTime.parse('2026-10-11T01:00:00Z'),
      );
      final second = ReceiptBatch(
        quantity: 2,
        origin: ReceiptOrigin.actual,
        receivedAt: DateTime.parse('2026-11-01T01:00:00Z'),
      );
      final empty = ReceiptState(quantity: 3, occurredOn: day, batches: []);
      final partial = ReceiptState(
        quantity: 3,
        occurredOn: day,
        batches: [first],
      );
      final full = ReceiptState(
        quantity: 3,
        occurredOn: day,
        batches: [first, second],
      );
      expect(empty.status, ReceiptStatus.unreceived);
      expect(partial.status, ReceiptStatus.partial);
      expect(partial.unreceivedQuantity, 2);
      expect(full.status, ReceiptStatus.received);
      expect(full.occurredOn, day);
      expect(() => full.batches.clear(), throwsUnsupportedError);
      expect(
        () => ReceiptState(
          quantity: 2,
          occurredOn: day,
          batches: [first, second],
        ),
        throwsArgumentError,
      );
    },
  );
  test('missing, early and invented receipt instants are refused', () {
    expect(
      () => ReceiptBatch(quantity: 1, origin: ReceiptOrigin.actual),
      throwsArgumentError,
    );
    expect(
      () => ReceiptBatch(
        quantity: 0,
        origin: ReceiptOrigin.actual,
        receivedAt: DateTime.now(),
      ),
      throwsArgumentError,
    );
    expect(
      () => ReceiptBatch(
        quantity: 1,
        origin: ReceiptOrigin.legacyUnknown,
        receivedAt: DateTime.now(),
      ),
      throwsArgumentError,
    );
    expect(
      () => ReceiptState(
        quantity: 1,
        occurredOn: day,
        batches: [
          ReceiptBatch(
            quantity: 1,
            origin: ReceiptOrigin.actual,
            receivedAt: DateTime.parse('2026-10-10T15:59:59Z'),
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
  test(
    'legacy unknown receipt origin stays distinct from new initial receipt',
    () {
      final old = ReceiptState(
        quantity: 2,
        occurredOn: day,
        batches: [
          ReceiptBatch(quantity: 1, origin: ReceiptOrigin.legacyUnknown),
        ],
      );
      expect(old.status, ReceiptStatus.partial);
      expect(old.batches.single.origin, ReceiptOrigin.legacyUnknown);
    },
  );
  test('hidden zero pool cannot silently acquire a positive allocation', () {
    final stock = TicketAvailabilityView(
      ticketId: 'morning-general',
      ticketName: '晨星 · 通用券',
      pools: [
        TicketPoolView(id: 'long', kind: TicketPoolKind.longTerm, available: 8),
        TicketPoolView(
          id: 'limited',
          kind: TicketPoolKind.limited,
          available: 0,
          expiresOn: day,
        ),
      ],
    );
    expect(stock.visiblePools.map((p) => p.id), ['long']);
    expect(stock.poolLabel(stock.visiblePools.single), '可用');
    expect(stock.allocationError({'long': '8'}, 9), '还差 1 张');
    expect(stock.allocationError({'long': '1', 'limited': '1'}, 2), isNotNull);
    expect(stock.allocationError({'long': '2'}, 2), isNull);
    for (final raw in ['', '-1', '1.2', 'abc']) {
      expect(stock.allocationError({'long': raw}, 2), isNotNull);
    }
    expect(stock.allocationError({'unknown': '1'}, 1), isNotNull);
    expect(stock.allocationError({'long': '9'}, 9), isNotNull);
    expect(stock.allocationError({'long': '3'}, 2), '多分配 1 张');
  });
}
