import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/assets/asset_repository.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';

void main() {
  late AppDatabase db;
  late WorkRepository workRepository;
  late AssetRepository repository;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    workRepository = WorkRepository(db);
    repository = AssetRepository(db);
  });

  tearDown(() async => db.close());

  test('serial lookup is trimmed, case-insensitive, and exact', () async {
    await workRepository.seedFactoryDemo();

    final matches = await repository.searchBySerial('  ast-ctrl-0042  ');

    expect(matches, hasLength(1));
    expect(matches.single.id, '30000000-0000-4000-8000-000000000001');
    expect(matches.single.serial, 'AST-CTRL-0042');
    expect(matches.single.assetType, 'Control cabinet');
    expect(matches.single.siteName, 'Factory A');
    expect(await repository.searchBySerial('CTRL-0042'), isEmpty);
  });

  test('blank serial returns no results', () async {
    await workRepository.seedFactoryDemo();

    expect(await repository.searchBySerial('  \t '), isEmpty);
  });

  test(
    'duplicate serials across sites are all returned in site order',
    () async {
      await workRepository.seedFactoryDemo();
      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: '30000000-0000-4000-8000-000000000098',
              siteId: '20000000-0000-4000-8000-000000000002',
              serial: 'AST-CTRL-0042',
              assetTag: 'CTRL-OTHER-SITE',
              qrValue: 'FIELDLENS://ASSET/CTRL-OTHER-SITE',
              assetType: 'Control cabinet',
            ),
          );

      final matches = await repository.searchBySerial('AST-CTRL-0042');

      expect(matches, hasLength(2));
      expect(matches.map((asset) => asset.siteName), [
        'Factory A',
        'Utilities Annex',
      ]);
      expect(matches.map((asset) => asset.assetTag), [
        'CTRL-0042',
        'CTRL-OTHER-SITE',
      ]);
    },
  );

  test(
    'QR resolution identifies the local Factory Demo control cabinet',
    () async {
      await workRepository.seedFactoryDemo();

      final asset = await repository.resolveQr(
        'FIELDLENS://ASSET/AST-CTRL-0042',
      );

      expect(asset, isNotNull);
      expect(asset!.id, '30000000-0000-4000-8000-000000000001');
      expect(asset.assetTag, 'CTRL-0042');
      expect(asset.assetType, 'Control cabinet');
      expect(asset.siteName, 'Factory A');
      expect(await repository.resolveQr('FIELDLENS://ASSET/UNKNOWN'), isNull);
    },
  );

  test('QR scheme and host matching is case-insensitive', () async {
    await workRepository.seedFactoryDemo();

    final asset = await repository.resolveQr('fieldlens://asset/AST-CTRL-0042');

    expect(asset?.assetTag, 'CTRL-0042');
  });

  test('QR identifier path remains case-sensitive', () async {
    await workRepository.seedFactoryDemo();

    expect(
      await repository.resolveQr('fieldlens://asset/ast-ctrl-0042'),
      isNull,
    );
  });

  test('URI path traversal and encoded path aliases are rejected', () async {
    await workRepository.seedFactoryDemo();
    const invalidPayloads = [
      'FIELDLENS://ASSET/X/../AST-CTRL-0042',
      'FIELDLENS://ASSET/%2E%2E/AST-CTRL-0042',
      'FIELDLENS://ASSET/%2e%2e/AST-CTRL-0042',
      'FIELDLENS://ASSET/%2F',
      'FIELDLENS://ASSET/%5C',
      'FIELDLENS://ASSET/%20',
      'FIELDLENS://ASSET/%0A',
      'FIELDLENS://ASSET/%41ST-CTRL-0042',
    ];

    for (final payload in invalidPayloads) {
      await expectLater(
        repository.resolveQr(payload),
        throwsFormatException,
        reason: payload,
      );
    }
  });

  test('malformed QR payloads are rejected', () async {
    await workRepository.seedFactoryDemo();
    const invalidPayloads = [
      'https://asset/AST-CTRL-0042',
      'FIELDLENS://OTHER/AST-CTRL-0042',
      'FIELDLENS://ASSET/',
      'FIELDLENS://ASSET//',
      'FIELDLENS://ASSET/AST/CTRL',
      'FIELDLENS://user@ASSET/AST-CTRL-0042',
      'FIELDLENS://@ASSET/AST-CTRL-0042',
      'FIELDLENS://ASSET:443/AST-CTRL-0042',
      'FIELDLENS://ASSET/AST-CTRL-0042?source=qr',
      'FIELDLENS://ASSET/AST-CTRL-0042#section',
      'not a uri',
    ];

    for (final payload in invalidPayloads) {
      await expectLater(
        repository.resolveQr(payload),
        throwsFormatException,
        reason: payload,
      );
    }
  });

  test('case-normalized duplicate stored QR values fail closed', () async {
    await workRepository.seedFactoryDemo();
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: '30000000-0000-4000-8000-000000000099',
            siteId: '20000000-0000-4000-8000-000000000001',
            serial: 'DUPLICATE-QR',
            assetTag: 'DUPLICATE-QR',
            qrValue: 'fieldlens://asset/AST-CTRL-0042',
            assetType: 'Control cabinet',
          ),
        );

    await expectLater(
      repository.resolveQr('FIELDLENS://ASSET/AST-CTRL-0042'),
      throwsStateError,
    );
  });

  test(
    'encoded identifier aliases cannot redirect plain QR resolution',
    () async {
      await workRepository.seedFactoryDemo();
      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: '30000000-0000-4000-8000-000000000097',
              siteId: '20000000-0000-4000-8000-000000000001',
              serial: 'ENCODED-ALIAS',
              assetTag: 'ENCODED-ALIAS',
              qrValue: 'FIELDLENS://ASSET/%41ST-CTRL-0042',
              assetType: 'Alias record',
            ),
          );

      final plainAsset = await repository.resolveQr(
        'FIELDLENS://ASSET/AST-CTRL-0042',
      );
      expect(plainAsset?.id, '30000000-0000-4000-8000-000000000001');
      await expectLater(
        repository.resolveQr('FIELDLENS://ASSET/%41ST-CTRL-0042'),
        throwsFormatException,
      );
    },
  );

  test('lookups do not mutate local records or enqueue outbox work', () async {
    await workRepository.seedFactoryDemo();
    final assetCountBefore = await db.select(db.assets).get();
    final siteCountBefore = await db.select(db.sites).get();
    final outboxCountBefore = await db.select(db.syncOutbox).get();

    await repository.searchBySerial('AST-CTRL-0042');
    await repository.resolveQr('FIELDLENS://ASSET/AST-CTRL-0042');

    expect(await db.select(db.assets).get(), assetCountBefore);
    expect(await db.select(db.sites).get(), siteCountBefore);
    expect(await db.select(db.syncOutbox).get(), outboxCountBefore);
    expect(outboxCountBefore, isEmpty);
  });
}
