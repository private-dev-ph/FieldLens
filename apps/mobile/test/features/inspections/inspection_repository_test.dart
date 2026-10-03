import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/inspections/template.dart' as schema;
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';

void main() {
  late AppDatabase db;
  late InspectionRepository repository;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = InspectionRepository(db);
    await WorkRepository(db).seedFactoryDemo();
    await repository.seedFactoryTemplate();
  });

  tearDown(() async => db.close());

  const workOrderId = '40000000-0000-4000-8000-000000000001';

  test(
    'begins an assigned draft locally with an immutable template snapshot',
    () async {
      final draftId = await repository.beginDraft(workOrderId);
      final draft = await repository.watchDraft(draftId).first;
      final workOrder = await (db.select(
        db.workOrders,
      )..where((order) => order.id.equals(workOrderId))).getSingle();

      expect(draft.id, draftId);
      expect(draft.workOrderId, workOrderId);
      expect(draft.template.title, 'Factory asset inspection');
      expect(draft.answers, isEmpty);
      expect(workOrder.status, 'in_progress');
      expect(await _outboxRows(db), hasLength(2));
    },
  );

  test('beginDraft is idempotent and does not discard saved answers', () async {
    final draftId = await repository.beginDraft(workOrderId);
    await repository.saveAnswer(draftId, 'safety_check', false);
    final outboxCount = (await _outboxRows(db)).length;

    final repeatedId = await repository.beginDraft(workOrderId);
    final draft = await repository.watchDraft(repeatedId).first;

    expect(repeatedId, draftId);
    expect(draft.answers, {'safety_check': false});
    expect((await _outboxRows(db)).length, outboxCount);
  });

  test(
    'validates fields, keeps answer IDs stable, and avoids equal JSON writes',
    () async {
      final draftId = await repository.beginDraft(workOrderId);

      await expectLater(
        repository.saveAnswer(draftId, 'not_a_field', 'value'),
        throwsArgumentError,
      );
      await expectLater(
        repository.saveAnswer(draftId, 'safety_check', 'yes'),
        throwsArgumentError,
      );
      expect((await _answerRows(db, draftId)), isEmpty);

      await repository.saveAnswer(draftId, 'safety_check', false);
      final first = (await _answerRows(db, draftId)).single;
      final outboxCount = (await _outboxRows(db)).length;
      await repository.saveAnswer(draftId, 'safety_check', false);
      final second = (await _answerRows(db, draftId)).single;

      expect(second.id, first.id);
      expect((await _outboxRows(db)).length, outboxCount);

      await repository.saveAnswer(draftId, 'safety_check', true);
      final edited = (await _answerRows(db, draftId)).single;
      expect(edited.id, first.id);
      final latestDraftOperation = (await _outboxRows(
        db,
      )).where((operation) => operation.entity == 'inspection_draft').last;
      final editedPayload =
          jsonDecode(latestDraftOperation.payloadJson) as Map<String, dynamic>;
      final inspection = editedPayload['inspection'] as Map<String, dynamic>;
      expect(inspection['answers'], {'safety_check': true});
      expect((inspection['answerRecords'] as List).single['id'], first.id);
      expect((await repository.watchDraft(draftId).first).answers, {
        'safety_check': true,
      });
    },
  );

  test(
    'watchDraft recursively freezes JSON answers from local storage',
    () async {
      final draftId = await repository.beginDraft(workOrderId);
      await db
          .into(db.inspectionAnswers)
          .insert(
            InspectionAnswersCompanion.insert(
              id: '50000000-0000-4000-8000-000000000001',
              inspectionId: draftId,
              itemId: 'legacy_payload',
              valueJson: '{"nested":{"values":[1,2]}}',
            ),
          );

      final view = await repository.watchDraft(draftId).first;
      final answer = view.answers['legacy_payload'] as Map<String, Object?>;
      final nested = answer['nested'] as Map<String, Object?>;
      final values = nested['values'] as List<Object?>;

      expect(() => view.answers['new'] = 'value', throwsUnsupportedError);
      expect(() => answer['new'] = 'value', throwsUnsupportedError);
      expect(() => nested['new'] = 'value', throwsUnsupportedError);
      expect(() => values.add(3), throwsUnsupportedError);
    },
  );

  test(
    'rejects missing or unassigned work orders and unavailable templates',
    () async {
      await expectLater(
        repository.beginDraft('missing-work-order'),
        throwsStateError,
      );

      await db
          .into(db.workOrders)
          .insert(
            WorkOrdersCompanion.insert(
              id: '40000000-0000-4000-8000-000000000091',
              assetId: '30000000-0000-4000-8000-000000000001',
              assignedTo: const Value(null),
              templateId: schema.factoryDemoTemplate().id,
              status: 'assigned',
            ),
          );
      await db
          .into(db.workOrders)
          .insert(
            WorkOrdersCompanion.insert(
              id: '40000000-0000-4000-8000-000000000093',
              assetId: '30000000-0000-4000-8000-000000000003',
              assignedTo: const Value('technician-id'),
              templateId: schema.factoryDemoTemplate().id,
              status: 'completed',
            ),
          );
      await db
          .into(db.workOrders)
          .insert(
            WorkOrdersCompanion.insert(
              id: '40000000-0000-4000-8000-000000000092',
              assetId: '30000000-0000-4000-8000-000000000002',
              assignedTo: const Value('technician-id'),
              templateId: 'unavailable-template',
              status: 'assigned',
            ),
          );

      await expectLater(
        repository.beginDraft('40000000-0000-4000-8000-000000000091'),
        throwsStateError,
      );
      await expectLater(
        repository.beginDraft('40000000-0000-4000-8000-000000000092'),
        throwsStateError,
      );
      await expectLater(
        repository.beginDraft('40000000-0000-4000-8000-000000000093'),
        throwsStateError,
      );
      expect(await _outboxRows(db), isEmpty);
    },
  );

  test(
    'outbox failure rolls back draft and work order status together',
    () async {
      await db.customStatement('''
      CREATE TRIGGER reject_draft_outbox
      BEFORE INSERT ON sync_outbox
      WHEN NEW.entity = 'inspection_draft'
      BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
    ''');

      await expectLater(
        repository.beginDraft(workOrderId),
        throwsA(isA<SqliteException>()),
      );

      final workOrder = await (db.select(
        db.workOrders,
      )..where((order) => order.id.equals(workOrderId))).getSingle();
      expect(workOrder.status, 'assigned');
      expect(await db.select(db.inspectionDrafts).get(), isEmpty);
      expect(await _outboxRows(db), isEmpty);
    },
  );

  test(
    'template catalog edits do not change an existing draft snapshot',
    () async {
      final draftId = await repository.beginDraft(workOrderId);
      final bundled = schema.factoryDemoTemplate();
      final changed = schema.InspectionTemplate(
        id: bundled.id,
        revision: bundled.revision + 1,
        title: 'Revised catalog template',
        items: bundled.items,
      );
      await (db.update(
        db.inspectionTemplates,
      )..where((template) => template.id.equals(bundled.id))).write(
        InspectionTemplatesCompanion(
          revision: Value(changed.revision),
          schemaJson: Value(jsonEncode(changed.toJson())),
        ),
      );

      final view = await repository.watchDraft(draftId).first;
      expect(view.template.revision, bundled.revision);
      expect(view.template.title, bundled.title);
    },
  );

  test(
    'answer and outbox operation IDs survive file database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fieldlens_draft_',
      );
      final path = '${directory.path}/fieldlens.sqlite';
      await db.close();
      final fileDb = AppDatabase(NativeDatabase(File(path)));
      final fileRepository = InspectionRepository(fileDb);
      await WorkRepository(fileDb).seedFactoryDemo();
      await fileRepository.seedFactoryTemplate();
      final draftId = await fileRepository.beginDraft(workOrderId);
      await fileRepository.saveAnswer(draftId, 'safety_check', true);
      final answerId = (await _answerRows(fileDb, draftId)).single.id;
      final operationIds = (await _outboxRows(
        fileDb,
      )).map((operation) => operation.operationId).toList();
      await fileDb.close();

      final reopenedDb = AppDatabase(NativeDatabase(File(path)));
      addTearDown(() async {
        await reopenedDb.close();
        await directory.delete(recursive: true);
      });
      final reopenedRepository = InspectionRepository(reopenedDb);
      final draft = await reopenedRepository.watchDraft(draftId).first;

      expect(draft.answers, {'safety_check': true});
      expect((await _answerRows(reopenedDb, draftId)).single.id, answerId);
      expect(
        (await _outboxRows(
          reopenedDb,
        )).map((operation) => operation.operationId),
        operationIds,
      );
      final draftOutbox = (await _outboxRows(
        reopenedDb,
      )).where((operation) => operation.entity == 'inspection_draft').last;
      final payload =
          jsonDecode(draftOutbox.payloadJson) as Map<String, dynamic>;
      final inspection = payload['inspection'] as Map<String, dynamic>;
      final answerRecords = inspection['answerRecords'] as List<dynamic>;
      expect(answerRecords.single['id'], answerId);
    },
  );
}

Future<List<InspectionAnswer>> _answerRows(AppDatabase db, String draftId) =>
    (db.select(
      db.inspectionAnswers,
    )..where((answer) => answer.inspectionId.equals(draftId))).get();

Future<List<SyncOutboxData>> _outboxRows(AppDatabase db) => (db.select(
  db.syncOutbox,
)..orderBy([(row) => OrderingTerm.asc(row.localSequence)])).get();
