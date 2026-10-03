import 'package:drift/drift.dart';

part 'app_database.g.dart';

class Sites extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get name => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(
  name: 'assets_site_serial_unique',
  columns: {#siteId, #serial},
  unique: true,
)
// QR payloads identify an asset globally in the FieldLens URI namespace.
@TableIndex(name: 'assets_qr_value_unique', columns: {#qrValue}, unique: true)
class Assets extends Table {
  TextColumn get id => text()();
  TextColumn get siteId =>
      text().references(Sites, #id, onDelete: KeyAction.cascade)();
  TextColumn get serial => text()();
  TextColumn get assetTag => text()();
  TextColumn get qrValue => text()();
  TextColumn get assetType => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class WorkOrders extends Table {
  TextColumn get id => text()();
  TextColumn get assetId =>
      text().references(Assets, #id, onDelete: KeyAction.cascade)();
  TextColumn get assignedTo => text().nullable()();
  TextColumn get templateId => text()();
  TextColumn get status => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class SyncOutbox extends Table {
  IntColumn get localSequence => integer().autoIncrement()();
  TextColumn get operationId => text().unique()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
}

class InspectionTemplates extends Table {
  TextColumn get id => text()();
  IntColumn get revision => integer()();
  TextColumn get schemaJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class InspectionDrafts extends Table {
  TextColumn get id => text()();
  TextColumn get workOrderId =>
      text().references(WorkOrders, #id, onDelete: KeyAction.cascade)();
  TextColumn get technicianId => text()();
  TextColumn get templateJson => text()();
  TextColumn get status => text().withDefault(const Constant('draft'))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {workOrderId},
  ];
}

class InspectionAnswers extends Table {
  TextColumn get id => text()();
  TextColumn get inspectionId =>
      text().references(InspectionDrafts, #id, onDelete: KeyAction.cascade)();
  TextColumn get itemId => text()();
  TextColumn get valueJson => text()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Set<Column>> get uniqueKeys => [
    {inspectionId, itemId},
  ];
}

@DriftDatabase(
  tables: [
    Sites,
    Assets,
    WorkOrders,
    SyncOutbox,
    InspectionTemplates,
    InspectionDrafts,
    InspectionAnswers,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.alterTable(
          TableMigration(
            syncOutbox,
            newColumns: [syncOutbox.localSequence],
            columnTransformer: {
              syncOutbox.localSequence: const CustomExpression<int>('rowid'),
            },
          ),
        );
        await migrator.createTable(inspectionTemplates);
        await migrator.createTable(inspectionDrafts);
        await migrator.createTable(inspectionAnswers);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
