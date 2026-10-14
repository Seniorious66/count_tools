import 'dart:io';
import 'package:count_tools/cheki/data/bi_query.dart';
import 'package:count_tools/cheki/data/catalog_store.dart';
import 'package:count_tools/cheki/data/catalog_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/record_store.dart';
import 'package:count_tools/cheki/data/ticket_store.dart';
import 'package:count_tools/cheki/data/transfer_store.dart';
import 'package:count_tools/cheki/data/entry_store.dart';
import 'package:count_tools/cheki/domain/record_information.dart';
import 'package:count_tools/cheki/domain/ticket_information.dart';
import 'package:count_tools/cheki/domain/transfer_information.dart';
import 'package:count_tools/cheki/domain/coupon_plan.dart';
import 'package:count_tools/data/database/data_base.dart';
import 'storage_migration_test.dart' show legacyFixture;

class BiFixture {
  late Directory root;
  late RecordStore records;
  late CatalogStore catalog;
  late IdentityStore identities;
  late TicketStore tickets;
  late BiStore bi;
  late String groupA, groupB, a, b, three, five, source, target;
  int n = 0;
  final clock = DateTime.utc(2026, 10, 14, 1);
  Future<void> open() async {
    await DatabaseHelper().close();
    root = await Directory.systemTemp.createTemp('cheki-bi-');
    await legacyFixture('${root.path}/user_database.db');
    DatabaseHelper.pathResolver = () async => '${root.path}/user_database.db';
    records = RecordStore(() => DatabaseHelper().database, clock: () => clock);
    bi = BiStore(records.database, clock: () => clock);
    catalog = CatalogStore(records.database, clock: () => clock);
    identities = IdentityStore(records.database, clock: () => clock);
    tickets = TicketStore(records.database, clock: () => clock);
    groupA = (await catalog.create(
      CatalogKind.group,
      name: '晨星',
      operationId: 'group-a',
    )).id;
    groupB = (await catalog.create(
      CatalogKind.group,
      name: '夜航',
      operationId: 'group-b',
    )).id;
    a = (await identities.createMember(
      name: 'A',
      groupId: groupA,
      colorRgb: 0x123456,
      operationId: 'member-a',
    )).id;
    b = (await identities.createMember(
      name: 'B',
      groupId: groupB,
      colorRgb: 0xffffff,
      operationId: 'member-b',
    )).id;
    final sizes = await catalog.list(CatalogKind.size);
    three = sizes.singleWhere((e) => e.name == '三寸').id;
    five = sizes.singleWhere((e) => e.name == '五寸').id;
  }

  Future<void> close() async {
    await DatabaseHelper().close();
    DatabaseHelper.pathResolver = null;
    await root.delete(recursive: true);
  }

  Future<StoredRecord> record(
    int? q,
    List<String>? members, {
    String? day = '2026-10-11',
    String? signature = 'signed',
    bool? back = false,
    String? size,
    List<Object?>? receipt = const [],
  }) => records.save(
    RecordInformation.fromMap({
      'quantity': q,
      'member_ids': members,
      'occurred_on': day,
      'size_id': size ?? three,
      'attributes': {'kind': signature, 'back_signed': back},
      'receipt_batches': receipt,
      'ext': {
        '原文': [null, '=保留,\n"原文"'],
      },
    }),
    operationId: 'record-${n++}',
  );
  Future<void> quantities() async {
    await record(3, [a]);
    await record(
      2,
      [b],
      signature: 'unsigned',
      size: five,
      receipt: [
        {'quantity': 2, 'origin': 'initial'},
      ],
    );
    await record(
      2,
      [a, b],
      signature: 'homework',
      receipt: [
        {
          'quantity': 1,
          'origin': 'actual',
          'received_at': '2026-10-12T01:00:00.000Z',
        },
      ],
    );
  }

  Future<TicketObject> buy(
    String def,
    int quantity, {
    String day = '2026-10-10',
    String? unit,
    String? total,
    String? expiry,
  }) => tickets.save(
    kind: 'purchase',
    information: TicketInformation({
      'definition_id': def,
      'quantity': quantity,
      'occurred_on': day,
      'pool': expiry == null ? 'long' : 'dated',
      'expires_on': expiry,
      'unit_price': unit,
      'total_price': total,
    }),
    posted: true,
    operationId: 'purchase-${n++}',
  );
  Future<void> finances({bool unknown = false, bool future = false}) async {
    source = (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '基础',
        'scope': 'group',
        'group_id': groupA,
        'active': true,
      }),
      operationId: 'source',
    )).id;
    target = (await tickets.save(
      kind: 'definition',
      information: TicketInformation({
        'name': '通用',
        'scope': 'group',
        'group_id': groupB,
        'active': true,
      }),
      operationId: 'target',
    )).id;
    await buy(source, 2, unit: '30.00');
    await buy(source, 2, unit: '20');
    final transfers = TransferStore(records.database, clock: () => clock);
    await transfers.save(
      TransferInformation({
        'kind': 'gift',
        'source_definition_id': source,
        'source_pool': 'long',
        'quantity': 1,
        'occurred_on': '2026-10-11',
      }),
      operationId: 'gift',
      posted: true,
    );
    await transfers.save(
      TransferInformation({
        'kind': 'exchange',
        'source_definition_id': source,
        'source_pool': 'long',
        'target_definition_id': target,
        'target_pool': 'long',
        'quantity': 1,
        'occurred_on': '2026-10-12',
      }),
      operationId: 'exchange',
      posted: true,
    );
    await EntryStore(records.database, clock: () => clock).save(
      RecordInformation.fromMap({
        'quantity': 1,
        'occurred_on': '2026-10-13',
        'member_ids': [b],
      }),
      plan: CouponPlan({
        'mode': 'consume',
        'lines': [
          {
            'member_id': b,
            'definition_id': target,
            'quantity': 1,
            'pools': [
              {'pool': 'long', 'quantity': 1},
            ],
          },
        ],
      }),
      operationId: 'consume',
    );
    if (unknown) await buy(source, 2, expiry: '2026-10-12');
    if (future) await buy(source, 1, unit: '6', day: '2026-10-20');
  }

  Future<IdentityEntity> member(String id) async => (await identities.list(
    IdentityKind.member,
  )).singleWhere((e) => e.id == id);
}
