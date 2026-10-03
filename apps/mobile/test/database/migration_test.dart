import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:fieldlens_mobile/database/app_database.dart';

void main() {
  test(
    'upgrades frozen v1 schema additively and preserves local records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fieldlens_migrate_',
      );
      final path = '${directory.path}/fieldlens.sqlite';
      final old = sqlite3.open(path);
      old.execute('PRAGMA foreign_keys = ON');
      old.execute('''
      CREATE TABLE sites (
        id TEXT NOT NULL,
        org_id TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
      old.execute('''
      CREATE TABLE assets (
        id TEXT NOT NULL,
        site_id TEXT NOT NULL REFERENCES sites (id) ON DELETE CASCADE,
        serial TEXT NOT NULL,
        asset_tag TEXT NOT NULL,
        qr_value TEXT NOT NULL,
        asset_type TEXT NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
      old.execute('''
      CREATE UNIQUE INDEX assets_site_serial_unique ON assets (site_id, serial)
    ''');
      old.execute('''
      CREATE UNIQUE INDEX assets_qr_value_unique ON assets (qr_value)
    ''');
      old.execute('''
      CREATE TABLE work_orders (
        id TEXT NOT NULL,
        asset_id TEXT NOT NULL REFERENCES assets (id) ON DELETE CASCADE,
        assigned_to TEXT NULL,
        template_id TEXT NOT NULL,
        status TEXT NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
      old.execute('''
      CREATE TABLE sync_outbox (
        operation_id TEXT NOT NULL,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (operation_id)
      )
    ''');
      old.execute(
        "INSERT INTO sites VALUES ('site-v1', 'org-v1', 'Factory A')",
      );
      old.execute("""
      INSERT INTO assets VALUES
        ('asset-v1', 'site-v1', 'SERIAL-1', 'ASSET-1', 'QR-1', 'Cabinet')
    """);
      old.execute("""
      INSERT INTO work_orders VALUES
        ('work-v1', 'asset-v1', 'tech-v1', 'template-v1', 'in_progress')
    """);
      old.execute("""
      INSERT INTO sync_outbox VALUES
        ('operation-v1', 'work_order', 'work-v1', '{"status":"in_progress"}',
         123456, 2)
    """);
      old.execute("""
      INSERT INTO sync_outbox VALUES
        ('operation-v1-b', 'inspection_draft', 'draft-v1', '{"answer":1}',
         123456, 0)
    """);
      old.execute("""
      INSERT INTO sync_outbox VALUES
        ('operation-v1-c', 'inspection_draft', 'draft-v1', '{"answer":2}',
         123456, 1)
    """);
      old.execute('PRAGMA user_version = 1');
      old.dispose();

      final db = AppDatabase(NativeDatabase(File(path)));
      addTearDown(() async {
        await db.close();
        await directory.delete(recursive: true);
      });

      final site = await db.select(db.sites).getSingle();
      final asset = await db.select(db.assets).getSingle();
      final workOrder = await db.select(db.workOrders).getSingle();
      final outbox = await (db.select(
        db.syncOutbox,
      )..orderBy([(row) => OrderingTerm.asc(row.localSequence)])).get();
      expect(site.name, 'Factory A');
      expect(asset.serial, 'SERIAL-1');
      expect(workOrder.status, 'in_progress');
      expect(outbox.map((row) => row.operationId), [
        'operation-v1',
        'operation-v1-b',
        'operation-v1-c',
      ]);
      expect(outbox.map((row) => row.payloadJson), [
        '{"status":"in_progress"}',
        '{"answer":1}',
        '{"answer":2}',
      ]);
      expect(outbox.map((row) => row.localSequence), [1, 2, 3]);
      expect(outbox.first.attempts, 2);
      expect(await db.select(db.inspectionTemplates).get(), isEmpty);
      expect(await db.select(db.inspectionDrafts).get(), isEmpty);
      expect(await db.select(db.inspectionAnswers).get(), isEmpty);

      final fourthSequence = await _insertOperation(db, 'operation-v2-d');
      expect(fourthSequence, greaterThan(outbox.last.localSequence));
      await (db.delete(
        db.syncOutbox,
      )..where((row) => row.operationId.equals('operation-v2-d'))).go();
      final fifthSequence = await _insertOperation(db, 'operation-v2-e');
      expect(fifthSequence, greaterThan(fourthSequence));

      await expectLater(
        db
            .into(db.inspectionDrafts)
            .insert(
              InspectionDraftsCompanion.insert(
                id: 'draft-orphan',
                workOrderId: 'missing-work-order',
                technicianId: 'tech-v1',
                templateJson: '{}',
                updatedAt: DateTime.utc(2026),
              ),
            ),
        throwsA(isA<SqliteException>()),
      );
    },
  );
}

Future<int> _insertOperation(AppDatabase db, String operationId) async {
  await db
      .into(db.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          operationId: operationId,
          entity: 'inspection_draft',
          entityId: 'draft-v1',
          payloadJson: '{}',
          createdAt: DateTime.fromMillisecondsSinceEpoch(123456, isUtc: true),
        ),
      );
  final operation = await (db.select(
    db.syncOutbox,
  )..where((row) => row.operationId.equals(operationId))).getSingle();
  return operation.localSequence;
}
