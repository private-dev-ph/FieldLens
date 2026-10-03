import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';

void main() {
  late AppDatabase db;
  late WorkRepository repository;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repository = WorkRepository(db);
  });

  tearDown(() async => db.close());

  test('fresh schema opens and Factory Demo seeding is idempotent', () async {
    await repository.seedFactoryDemo();
    await repository.seedFactoryDemo();

    final rows = await repository.watchAssignedWork().first;
    expect(rows, hasLength(5));
    expect(rows.map((row) => row.assetTag).toSet(), contains('CTRL-0042'));
    expect(
      rows.firstWhere((row) => row.assetTag == 'CTRL-0042').siteName,
      'Factory A',
    );
    expect(await repository.pendingCount(), 0);
  });

  test('status mutation is local, durable, and observed reactively', () async {
    await repository.seedFactoryDemo();
    final iterator = StreamIterator(repository.watchAssignedWork());
    expect(await iterator.moveNext(), isTrue);
    expect(
      iterator.current.firstWhere((row) => row.assetTag == 'CTRL-0042').status,
      'assigned',
    );

    await repository.setStatus(
      '40000000-0000-4000-8000-000000000001',
      'in_progress',
    );

    expect(await iterator.moveNext(), isTrue);
    expect(
      iterator.current.firstWhere((row) => row.assetTag == 'CTRL-0042').status,
      'in_progress',
    );
    await iterator.cancel();
    expect(await repository.pendingCount(), 1);
  });

  test(
    'mutation and outbox insertion roll back together on storage failure',
    () async {
      await repository.seedFactoryDemo();
      await db.customStatement('''
      CREATE TRIGGER reject_outbox BEFORE INSERT ON sync_outbox
      BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
    ''');

      await expectLater(
        repository.setStatus(
          '40000000-0000-4000-8000-000000000001',
          'completed',
        ),
        throwsA(isA<SqliteException>()),
      );

      final workOrder =
          await (db.select(db.workOrders)..where(
                (order) =>
                    order.id.equals('40000000-0000-4000-8000-000000000001'),
              ))
              .getSingle();
      expect(workOrder.status, 'assigned');
      expect(await repository.pendingCount(), 0);
    },
  );

  test(
    'database state survives closing and reopening a file database',
    () async {
      final directory = await Directory.systemTemp.createTemp('fieldlens_db_');
      final path = '${directory.path}/fieldlens.sqlite';
      final fileDb = AppDatabase(NativeDatabase(File(path)));
      final fileRepository = WorkRepository(fileDb);
      await fileRepository.seedFactoryDemo();
      await fileRepository.setStatus(
        '40000000-0000-4000-8000-000000000001',
        'completed',
      );
      await fileDb.close();

      final reopenedDb = AppDatabase(NativeDatabase(File(path)));
      addTearDown(() async {
        await reopenedDb.close();
        await directory.delete(recursive: true);
      });
      final reopenedRepository = WorkRepository(reopenedDb);
      final row = (await reopenedRepository.watchAssignedWork().first)
          .firstWhere((item) => item.assetTag == 'CTRL-0042');

      expect(row.status, 'completed');
      expect(await reopenedRepository.pendingCount(), 1);
    },
  );

  test(
    'invalid statuses and missing work orders do not enqueue mutations',
    () async {
      await repository.seedFactoryDemo();

      await expectLater(
        repository.setStatus('40000000-0000-4000-8000-000000000001', 'paused'),
        throwsArgumentError,
      );
      await expectLater(
        repository.setStatus('missing-work-order', 'completed'),
        throwsStateError,
      );

      expect(await repository.pendingCount(), 0);
    },
  );

  test(
    'setting the current status does not create a redundant operation',
    () async {
      await repository.seedFactoryDemo();

      await repository.setStatus(
        '40000000-0000-4000-8000-000000000001',
        'assigned',
      );

      expect(await repository.pendingCount(), 0);
    },
  );

  test('foreign keys reject an asset with an unknown site', () async {
    await expectLater(
      db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: '30000000-0000-4000-8000-000000000099',
              siteId: 'missing-site',
              serial: 'ORPHAN-1',
              assetTag: 'ORPHAN-1',
              qrValue: 'FIELDLENS://ASSET/ORPHAN-1',
              assetType: 'Test asset',
            ),
          ),
      throwsA(isA<SqliteException>()),
    );
  });

  test(
    'serials may repeat across sites but are unique within a site',
    () async {
      await repository.seedFactoryDemo();

      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: '30000000-0000-4000-8000-000000000098',
              siteId: '20000000-0000-4000-8000-000000000002',
              serial: 'AST-CTRL-0042',
              assetTag: 'CTRL-0042-OTHER-SITE',
              qrValue: 'FIELDLENS://ASSET/CTRL-0042-OTHER-SITE',
              assetType: 'Control cabinet',
            ),
          );

      await expectLater(
        db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                id: '30000000-0000-4000-8000-000000000097',
                siteId: '20000000-0000-4000-8000-000000000001',
                serial: 'AST-CTRL-0042',
                assetTag: 'CTRL-0042-DUPLICATE',
                qrValue: 'FIELDLENS://ASSET/CTRL-0042-DUPLICATE',
                assetType: 'Control cabinet',
              ),
            ),
        throwsA(isA<SqliteException>()),
      );
    },
  );
}
