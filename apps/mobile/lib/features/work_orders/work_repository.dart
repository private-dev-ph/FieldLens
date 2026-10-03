import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';

class WorkOrderSummary {
  const WorkOrderSummary({
    required this.id,
    required this.assetId,
    required this.assetTag,
    required this.assetType,
    required this.siteName,
    required this.status,
  });

  final String id;
  final String assetId;
  final String assetTag;
  final String assetType;
  final String siteName;
  final String status;
}

class WorkRepository {
  WorkRepository(this.db);

  final AppDatabase db;
  static const _uuid = Uuid();
  static const _demoOrgId = '10000000-0000-4000-8000-000000000001';
  static const _demoTechId = '10000000-0000-4000-8000-000000000002';
  static const _demoTemplateId = '10000000-0000-4000-8000-000000000003';

  static const _demoSites = [
    ('20000000-0000-4000-8000-000000000001', 'Factory A'),
    ('20000000-0000-4000-8000-000000000002', 'Utilities Annex'),
  ];

  static const _demoAssets = [
    (
      '30000000-0000-4000-8000-000000000001',
      '20000000-0000-4000-8000-000000000001',
      'AST-CTRL-0042',
      'CTRL-0042',
      'FIELDLENS://ASSET/AST-CTRL-0042',
      'Control cabinet',
    ),
    (
      '30000000-0000-4000-8000-000000000002',
      '20000000-0000-4000-8000-000000000001',
      'AST-MOTOR-0018',
      'MOTOR-0018',
      'FIELDLENS://ASSET/AST-MOTOR-0018',
      'Conveyor motor',
    ),
    (
      '30000000-0000-4000-8000-000000000003',
      '20000000-0000-4000-8000-000000000001',
      'AST-PCB-0007',
      'PCB-0007',
      'FIELDLENS://ASSET/AST-PCB-0007',
      'PCB/controller',
    ),
    (
      '30000000-0000-4000-8000-000000000004',
      '20000000-0000-4000-8000-000000000002',
      'AST-COMP-0103',
      'COMP-0103',
      'FIELDLENS://ASSET/AST-COMP-0103',
      'Compressor',
    ),
    (
      '30000000-0000-4000-8000-000000000005',
      '20000000-0000-4000-8000-000000000002',
      'AST-NET-0009',
      'NET-0009',
      'FIELDLENS://ASSET/AST-NET-0009',
      'Network cabinet',
    ),
  ];

  /// Installs the local Factory Demo data without creating remote mutations.
  Future<void> seedFactoryDemo() async {
    await db.transaction(() async {
      for (final (id, name) in _demoSites) {
        await db
            .into(db.sites)
            .insert(
              SitesCompanion.insert(id: id, orgId: _demoOrgId, name: name),
              mode: InsertMode.insertOrIgnore,
            );
      }

      for (final (id, siteId, serial, assetTag, qrValue, assetType)
          in _demoAssets) {
        await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                id: id,
                siteId: siteId,
                serial: serial,
                assetTag: assetTag,
                qrValue: qrValue,
                assetType: assetType,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await db
            .into(db.workOrders)
            .insert(
              WorkOrdersCompanion.insert(
                id: '40000000-0000-4000-8000-${id.substring(id.length - 12)}',
                assetId: id,
                assignedTo: const Value(_demoTechId),
                templateId: _demoTemplateId,
                status: 'assigned',
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  Stream<List<WorkOrderSummary>> watchAssignedWork() {
    final query =
        db.select(db.workOrders).join([
            innerJoin(db.assets, db.assets.id.equalsExp(db.workOrders.assetId)),
            innerJoin(db.sites, db.sites.id.equalsExp(db.assets.siteId)),
          ])
          ..where(db.workOrders.assignedTo.isNotNull())
          ..orderBy([
            OrderingTerm.asc(db.sites.name),
            OrderingTerm.asc(db.assets.assetTag),
          ]);

    return query.watch().map(
      (rows) => [
        for (final row in rows)
          WorkOrderSummary(
            id: row.readTable(db.workOrders).id,
            assetId: row.readTable(db.assets).id,
            assetTag: row.readTable(db.assets).assetTag,
            assetType: row.readTable(db.assets).assetType,
            siteName: row.readTable(db.sites).name,
            status: row.readTable(db.workOrders).status,
          ),
      ],
    );
  }

  Future<void> setStatus(String workOrderId, String status) async {
    const allowed = {'assigned', 'in_progress', 'completed'};
    if (!allowed.contains(status)) {
      throw ArgumentError.value(
        status,
        'status',
        'Unsupported work order status',
      );
    }

    await db.transaction(() async {
      final existing = await (db.select(
        db.workOrders,
      )..where((order) => order.id.equals(workOrderId))).getSingleOrNull();
      if (existing == null) {
        throw StateError('Work order $workOrderId does not exist');
      }
      if (existing.status == status) return;

      await (db.update(db.workOrders)
            ..where((order) => order.id.equals(workOrderId)))
          .write(WorkOrdersCompanion(status: Value(status)));

      final operationId = _uuid.v4();
      await db
          .into(db.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              operationId: operationId,
              entity: 'work_order',
              entityId: workOrderId,
              payloadJson: jsonEncode({
                'operationId': operationId,
                'status': status,
              }),
              createdAt: DateTime.now().toUtc(),
            ),
          );
    });
  }

  Selectable<int> _pendingCountQuery() {
    final count = db.syncOutbox.operationId.count();
    return (db.selectOnly(
      db.syncOutbox,
    )..addColumns([count])).map((row) => row.read(count) ?? 0);
  }

  Stream<int> watchPendingCount() => _pendingCountQuery().watchSingle();

  Future<int> pendingCount() => _pendingCountQuery().getSingle();
}
