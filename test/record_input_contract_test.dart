import 'dart:convert';
import 'package:count_tools/cheki/domain/input_contract.dart';
import 'package:count_tools/cheki/domain/record_contract.dart';
import 'package:count_tools/cheki/domain/record_draft.dart';
import 'package:flutter_test/flutter_test.dart';

RecordDraft draft() {
  final day = OccurredOn.parse('2026-10-11');
  return RecordDraft.create(
    occurredOn: day,
    quantity: 3,
    sizeId: 'size-3inch',
    memberIds: ['member-a', 'member-b'],
    attributes: ChekiAttributes(backSigned: true),
    receipt: ReceiptState.initialReceived(3, day),
  );
}

void main() {
  final day = OccurredOn.parse('2026-10-11');
  test(
    'strict integer entry refuses decimal, negative, empty and overflow without coercion',
    () {
      expect(parsePositiveQuantity('3'), 3);
      for (final value in [
        '',
        '0',
        '-1',
        '+1',
        '1.5',
        'abc',
        ' 2',
        '9999999999999999999999999',
      ]) {
        expect(() => parsePositiveQuantity(value), throwsFormatException);
      }
    },
  );
  test(
    'explicit receipt wall clock uses Shanghai and validates real calendar/time',
    () {
      expect(
        parseReceiptTime('2026-10-11 00:01'),
        DateTime.utc(2026, 10, 10, 16, 1),
      );
      expect(
        receiptTimeText(DateTime.utc(2026, 10, 10, 16, 1, 2)),
        '2026-10-11 00:01:02',
      );
      expect(
        parseReceiptTime('2024-02-29 23:59:59'),
        DateTime.utc(2024, 2, 29, 15, 59, 59),
      );
      for (final value in [
        '2025-02-29 09:00',
        '2026-10-11',
        '2026-10-11 24:00',
        '2026-10-11 12:60',
        '2026-10-11 12:00:60',
        '2026-1-1 09:00',
      ]) {
        expect(() => parseReceiptTime(value), throwsFormatException);
      }
    },
  );
  test(
    'default initial receipt has no actual time; partial input is strict and immutable',
    () {
      final initial = ReceiptInput();
      expect(initial.needsBatches, isFalse);
      expect(
        initial
            .validate(quantity: 3, occurredOn: day)
            .batches
            .single
            .receivedAt,
        isNull,
      );
      final partial = initial.select(ReceiptStatus.partial).replaceBatches([
        const ReceiptInputBatch(
          key: 'first',
          quantity: '1',
          time: '2026-10-11 18:30',
        ),
      ]);
      expect(
        partial.validate(quantity: 3, occurredOn: day).unreceivedQuantity,
        2,
      );
      expect(() => partial.batches.clear(), throwsUnsupportedError);
      expect(
        () => partial.validate(quantity: 1, occurredOn: day),
        throwsFormatException,
      );
      expect(
        () => partial
            .replaceBatches([
              const ReceiptInputBatch(key: 'first', quantity: '1'),
            ])
            .validate(quantity: 3, occurredOn: day),
        throwsFormatException,
      );
      expect(
        () => partial
            .replaceBatches([
              const ReceiptInputBatch(
                key: 'first',
                quantity: '4',
                time: '2026-10-11 18:30',
              ),
            ])
            .validate(quantity: 3, occurredOn: day),
        throwsArgumentError,
      );
      final hidden = partial.select(ReceiptStatus.unreceived);
      expect(hidden.validate(quantity: 3, occurredOn: day).receivedQuantity, 0);
      expect(
        hidden.select(ReceiptStatus.partial).batches.single.time,
        partial.batches.single.time,
      );
    },
  );
  test(
    'loaded actual and unknown historical receipts never become new initial defaults',
    () {
      final actual = ReceiptState(
        quantity: 2,
        occurredOn: day,
        batches: [
          ReceiptBatch(
            quantity: 2,
            origin: ReceiptOrigin.actual,
            receivedAt: DateTime.utc(2026, 10, 11, 12, 0, 0, 123, 456),
          ),
        ],
      );
      final loaded = ReceiptInput.fromState(actual);
      expect(loaded.allowInitial, isFalse);
      expect(loaded.needsBatches, isTrue);
      expect(
        loaded.validate(quantity: 2, occurredOn: day).batches.single.receivedAt,
        actual.batches.single.receivedAt,
      );
      final old = ReceiptState(
        quantity: 2,
        occurredOn: day,
        batches: [
          ReceiptBatch(quantity: 2, origin: ReceiptOrigin.legacyUnknown),
        ],
      );
      final historical = ReceiptInput.fromState(
        old,
      ).validate(quantity: 2, occurredOn: day);
      expect(historical.batches.single.origin, ReceiptOrigin.legacyUnknown);
      expect(historical.batches.single.receivedAt, isNull);
      expect(
        () => ReceiptInput(
          batches: [
            const ReceiptInputBatch(key: 'a'),
            const ReceiptInputBatch(key: 'a'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => ReceiptInput(
          batches: [
            const ReceiptInputBatch(
              key: 'old',
              origin: ReceiptOrigin.legacyUnknown,
              time: 'invented',
            ),
          ],
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'draft JSON roundtrip keeps nullable, nested unknown and precise receipt facts isolated',
    () {
      final value = draft().toMap();
      value['unknown'] = {
        'original': ['原文', null, 1.25],
        'opaque': {'keep': true},
      };
      (value['attributes'] as Map)['future_attribute'] = {'preserve': '是'};
      final protected = RecordDraft.fromMap(value);
      (value['unknown'] as Map)['original'] = 'mutated outside';
      final exported = protected.toMap();
      (exported['attributes'] as Map)['future_attribute'] = 'mutated export';
      final roundtrip = RecordDraft.decode(protected.encode());
      expect(roundtrip.toMap(), protected.toMap());
      expect((roundtrip.toMap()['unknown'] as Map)['original'], [
        '原文',
        null,
        1.25,
      ]);
      expect(roundtrip.note, isNull);
      expect(roundtrip.memberIds, ['member-a', 'member-b']);
      expect(() => roundtrip.memberIds.add('member-c'), throwsUnsupportedError);
      final precise = DateTime.parse('2026-11-01T01:02:03.123456Z');
      final receipt = ReceiptState(
        quantity: 3,
        occurredOn: day,
        batches: [
          ReceiptBatch(
            quantity: 1,
            origin: ReceiptOrigin.actual,
            receivedAt: precise,
          ),
        ],
      );
      final actual = RecordDraft.create(
        occurredOn: day,
        quantity: 3,
        sizeId: 'size-5inch',
        memberIds: ['member-a'],
        attributes: ChekiAttributes(),
        receipt: receipt,
      );
      expect(
        RecordDraft.decode(actual.encode()).receipt.batches.single.receivedAt,
        precise,
      );
    },
  );
  test(
    'changing occurrence preserves receipt and opaque creation facts; early receipts reject',
    () {
      final value = draft().toMap();
      value['created_at'] = 'opaque action fact owned by the eventual service';
      value['receipt_batches'] = [
        {
          'quantity': 1,
          'origin': 'actual',
          'received_at': '2026-10-12T01:00:00.000Z',
          'future_receipt_field': 'keep',
        },
      ];
      final original = RecordDraft.fromMap(value);
      final moved = original.changeOccurrence(OccurredOn.parse('2026-10-10'));
      expect(moved.toMap()['created_at'], value['created_at']);
      expect(
        moved.toMap()['receipt_batches'],
        original.toMap()['receipt_batches'],
      );
      expect(original.occurredOn, day);
      expect(
        () => original.changeOccurrence(OccurredOn.parse('2026-10-13')),
        throwsArgumentError,
      );
    },
  );
  test(
    'attribute change respects dependent back signature and retains future attributes',
    () {
      final value = draft().toMap();
      (value['attributes'] as Map)['future'] = 'keep';
      final original = RecordDraft.fromMap(value);
      final unsigned = original.changeAttributes(
        original.attributes.select(SignatureKind.unsigned),
      );
      expect(unsigned.attributes.backSigned, isFalse);
      expect((unsigned.toMap()['attributes'] as Map)['future'], 'keep');
      expect(
        unsigned
            .changeAttributes(unsigned.attributes.select(SignatureKind.signed))
            .attributes
            .backSigned,
        isFalse,
      );
      expect(original.attributes.backSigned, isTrue);
    },
  );
  test(
    'malformed or contradictory draft payload refuses rather than guessing new facts',
    () {
      for (final change in <String, Object?>{
        'quantity': 0,
        'member_ids': ['a', 'a'],
        'size_id': '',
        'attributes': {'kind': 'unsigned', 'back_signed': true},
        'receipt_batches': [
          {'quantity': 1, 'origin': 'actual', 'received_at': '2026-10-12'},
        ],
      }.entries) {
        expect(
          () => RecordDraft.fromMap({
            ...draft().toMap(),
            change.key: change.value,
          }),
          throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
        );
      }
      final missing = draft().toMap()..remove('note');
      expect(() => RecordDraft.fromMap(missing), throwsFormatException);
      expect(
        () => RecordDraft.fromMap({...draft().toMap(), 'unknown': double.nan}),
        throwsFormatException,
      );
      expect(() => RecordDraft.decode('[]'), throwsFormatException);
      expect(
        () => RecordDraft.decode(
          jsonEncode({
            ...draft().toMap(),
            'occurred_on': '2026-10-11T00:00:00',
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => RecordDraft.create(
          occurredOn: day,
          quantity: 4,
          sizeId: 'size-3inch',
          memberIds: ['a'],
          attributes: ChekiAttributes(),
          receipt: ReceiptState.initialReceived(3, day),
        ),
        throwsArgumentError,
      );
    },
  );
}
