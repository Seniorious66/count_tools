import 'dart:convert';
import 'dart:io';
import 'package:count_tools/cheki/data/backup_store.dart';
import 'package:count_tools/cheki/data/identity_contract.dart';
import 'package:count_tools/cheki/data/identity_store.dart';
import 'package:count_tools/cheki/data/owned_transaction.dart';
import 'package:count_tools/cheki/domain/member_color.dart';
import 'package:count_tools/cheki/ui/member_inputs.dart';
import 'package:count_tools/cheki/ui/theme.dart';
import 'package:count_tools/data/database/schema.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'legacy hex opaque decimal black and white keep exact RGB, invalid stays unknown',
    () {
      expect(parseLegacyMemberColor('#2196f3'), 0x2196f3);
      expect(parseLegacyMemberColor('#FFF'), 0xffffff);
      expect(parseLegacyMemberColor('#000000'), 0);
      expect(parseLegacyMemberColor('#FF2196F3'), 0x2196f3);
      expect(parseLegacyMemberColor('${0xff2196f3}'), 0x2196f3);
      for (final bad in [
        null,
        '',
        '#oops',
        '#802196f3',
        '999999999999',
        '-1.5',
        '4294967296',
      ]) {
        expect(parseLegacyMemberColor(bad), isNull);
      }
    },
  );
  test('RGB has exactly 256 integer values and normalized hex round trips', () {
    for (var i = 0; i < 256; i++) {
      expect(parseMemberChannel('$i'), i);
    }
    for (final bad in ['256', '-1', '1.5', 'x', '']) {
      expect(parseMemberChannel(bad), isNull);
    }
    for (final v in [0, 1, 0xffffff, 0x2fc913]) {
      expect(parseMemberHex(memberHex(v)), v);
    }
  });
  Future<void> open(
    WidgetTester t,
    void Function(Color) changed, {
    double scale = 1,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        theme: chekiTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: MemberColorField(
            value: const Color(0xff123456),
            onChanged: changed,
          ),
        ),
      ),
    );
    await t.tap(find.byType(OutlinedButton));
    await t.pumpAndSettle();
  }

  testWidgets(
    'preset hex RGB inputs and sliders synchronize but cancel leaves caller unchanged',
    (t) async {
      Color? saved;
      await open(t, (c) => saved = c);
      await t.tap(find.byKey(const ValueKey('member-color-preset-蓝色')));
      await t.pump();
      expect(
        t
            .widget<TextField>(find.byKey(const ValueKey('member-color-hex')))
            .controller!
            .text,
        '#2196F3',
      );
      final hex = find.byKey(const ValueKey('member-color-hex'));
      await t.ensureVisible(hex);
      await t.enterText(hex, '#2FC913');
      await t.pump();
      expect(
        t.widget<Slider>(find.byKey(const ValueKey('member-color-红'))).value,
        47,
      );
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('member-color-number-绿')),
            )
            .controller!
            .text,
        '201',
      );
      final blue = find.byKey(const ValueKey('member-color-number-蓝'));
      await t.ensureVisible(blue);
      await t.enterText(blue, '255');
      await t.pump();
      expect(t.widget<TextField>(hex).controller!.text, '#2FC9FF');
      expect(saved, isNull);
      await t.ensureVisible(find.text('取消'));
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(saved, isNull);
    },
  );
  testWidgets(
    'illegal hex and 256 refuse confirmation; fixed numeric input commits exact color',
    (t) async {
      Color? saved;
      await open(t, (c) => saved = c);
      final red = find.byKey(const ValueKey('member-color-number-红'));
      await t.ensureVisible(red);
      await t.enterText(red, '256');
      await t.pump();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      await t.enterText(red, '255');
      await t.pump();
      final hex = find.byKey(const ValueKey('member-color-hex'));
      await t.ensureVisible(hex);
      await t.enterText(hex, '#ZZZZZZ');
      await t.pump();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      await t.enterText(hex, '#FF3456');
      await t.pump();
      await t.ensureVisible(find.text('确定'));
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      expect(saved, const Color(0xffff3456));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'portrait narrow 200 percent keyboard can edit channels and confirm',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetViewInsets);
      for (final width in [320.0, 430.0]) {
        t.view.physicalSize = Size(width, 900);
        Color? saved;
        await open(t, (c) => saved = c, scale: 2);
        t.view.viewInsets = const FakeViewPadding(bottom: 280);
        final green = find.byKey(const ValueKey('member-color-number-绿'));
        await t.ensureVisible(green);
        await t.enterText(green, '201');
        await t.pump();
        await t.ensureVisible(find.text('确定'));
        await t.tap(find.text('确定'));
        await t.pumpAndSettle();
        expect(saved, const Color(0xff12c956));
        expect(t.takeException(), isNull);
        t.view.resetViewInsets();
      }
    },
  );
  final destination = Platform.environment['COUNT_TOOLS_COLOR_PREPARATION'];
  if (destination == null) return;
  test(
    'current full phone copy restores only missing source colors with identity audit and full restore',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      const root =
          r'E:\OneDrive\Code\artifacts\count-tools-device\s25-color-20261014';
      final out = Directory(destination).absolute;
      if (!out.path.startsWith('$root\\') || await out.exists()) {
        throw StateError('New marked isolation required');
      }
      final bytes = await File('$root/before.chekibackup').readAsBytes();
      final envelope = jsonDecode(utf8.decode(bytes)) as Map;
      final payload = jsonDecode(envelope['payload'] as String) as Map;
      await out.create(recursive: true);
      final live = Directory('${out.path}/app-documents');
      await live.create();
      for (final e in (payload['files'] as Map).entries) {
        if (e.key is! String ||
            (e.key as String).contains('..') ||
            (e.key as String).startsWith('/')) {
          throw StateError('Unsafe backup path');
        }
        final f = File('${live.path}/${e.key}');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(base64Decode(e.value as String));
      }
      final settings = Map<String, Object?>.from(payload['settings'] as Map);
      final backup = BackupStore(
        documents: live,
        readSettings: () async => settings,
        writeSettings: (_) async {},
        closeMain: () async {},
      );
      await backup.prepare(bytes);
      final db = await openDatabase(
        '${live.path}/user_database.db',
        singleInstance: false,
      );
      await StorageSchema.validate(db, StorageSchema.version);
      final beforeRecords = await db.query('cheki_records'),
          beforeMembers = await db.query('cheki_members');
      final mapping =
          jsonDecode(
                await File(
                  '${live.path}/legacy-source/mapping.json',
                ).readAsString(),
              )
              as Map;
      final old = await db.query('sub_project_data');
      var restored = 0, retained = 0;
      await db.transaction((tx) async {
        final store = IdentityStore(
          () => Future.value(OwnedTransactionDatabase(tx)),
        );
        for (final legacy in old) {
          final id = (mapping['member_ids'] as Map)[legacy['id'].toString()];
          final member = IdentityEntity.fromRow(
            IdentityKind.member,
            (await tx.query(
              'cheki_members',
              where: 'id=?',
              whereArgs: [id],
            )).single,
          );
          if (member.colorRgb != null) {
            retained++;
            continue;
          }
          final color = parseLegacyMemberColor(legacy['color'] as String?);
          if (color == null) {
            throw StateError('Source color unresolved; preserve unknown');
          }
          await store.editMember(
            original: member,
            name: member.knownName ?? '',
            colorRgb: color,
            personId: member.personId,
            active: member.active,
            operationId: 'color-repair-20261014:${member.id}',
          );
          restored++;
        }
        await StorageSchema.validate(tx, StorageSchema.version);
      });
      expect(restored + retained, 25);
      expect(await db.query('cheki_records'), beforeRecords);
      final afterMembers = await db.query('cheki_members');
      for (final before in beforeMembers) {
        final after = afterMembers.singleWhere((r) => r['id'] == before['id']);
        for (final k in before.keys.where(
          (k) => !['color_rgb', 'updated_at', 'revision'].contains(k),
        )) {
          expect(after[k], before[k]);
        }
        if (before['color_rgb'] != null) {
          expect(after, before);
        }
      }
      await db.close();
      final corrected = await backup.snapshot();
      await File(
        '${out.path}/corrected.chekibackup',
      ).writeAsBytes(corrected, flush: true);
      final rehearsal = Directory('${out.path}/rehearsal');
      await rehearsal.create();
      await File(
        '${live.path}/user_database.db',
      ).copy('${rehearsal.path}/user_database.db');
      var prefs = <String, Object?>{};
      final restoring = BackupStore(
        documents: rehearsal,
        readSettings: () async => prefs,
        writeSettings: (v) async {
          prefs = Map.from(v);
        },
        closeMain: () async {},
      );
      await restoring.apply(await restoring.prepare(corrected));
      final read = await openDatabase(
        '${rehearsal.path}/user_database.db',
        readOnly: true,
        singleInstance: false,
      );
      await StorageSchema.validate(read, StorageSchema.version);
      expect(await read.query('cheki_members'), afterMembers);
      expect(await read.query('cheki_records'), beforeRecords);
      await read.close();
      expect(prefs, settings);
      await File('${out.path}/summary.json').writeAsString(
        jsonEncode({
          'restored_colors': restored,
          'retained_nonempty_colors': retained,
          'members': afterMembers.length,
          'records': beforeRecords.length,
          'isolated_full_restore': 'passed',
          'record_fields_unchanged': true,
        }),
        flush: true,
      );
    },
  );
}
