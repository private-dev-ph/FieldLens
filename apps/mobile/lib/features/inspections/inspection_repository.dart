import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import 'template.dart' as schema;

class InspectionDraftView {
  const InspectionDraftView({
    required this.id,
    required this.workOrderId,
    required this.template,
    required this.answers,
    required this.updatedAt,
  });

  final String id;
  final String workOrderId;
  final schema.InspectionTemplate template;
  final Map<String, Object?> answers;
  final DateTime updatedAt;
}

class InspectionRepository {
  InspectionRepository(this.db);

  final AppDatabase db;
  static const _uuid = Uuid();

  /// Installs the bundled schema locally without creating a sync mutation.
  Future<void> seedFactoryTemplate() async {
    final template = schema.factoryDemoTemplate();
    await db.transaction(() async {
      final existing = await (db.select(
        db.inspectionTemplates,
      )..where((row) => row.id.equals(template.id))).getSingleOrNull();
      if (existing == null) {
        await db
            .into(db.inspectionTemplates)
            .insert(
              InspectionTemplatesCompanion.insert(
                id: template.id,
                revision: template.revision,
                schemaJson: jsonEncode(template.toJson()),
              ),
            );
      } else if (existing.revision < template.revision) {
        await (db.update(
          db.inspectionTemplates,
        )..where((row) => row.id.equals(template.id))).write(
          InspectionTemplatesCompanion(
            revision: Value(template.revision),
            schemaJson: Value(jsonEncode(template.toJson())),
          ),
        );
      }
    });
  }

  /// Begins one durable draft for an assigned work order, or returns its
  /// existing draft. The template JSON is copied into the draft once and stays
  /// independent of later edits to the template catalog.
  Future<String> beginDraft(String workOrderId) {
    return db.transaction(() async {
      final existing =
          await (db.select(db.inspectionDrafts)
                ..where((draft) => draft.workOrderId.equals(workOrderId)))
              .getSingleOrNull();
      if (existing != null) {
        if (existing.status != 'draft') {
          throw StateError('Inspection ${existing.id} is no longer a draft');
        }
        return existing.id;
      }

      final workOrder = await (db.select(
        db.workOrders,
      )..where((order) => order.id.equals(workOrderId))).getSingleOrNull();
      if (workOrder == null) {
        throw StateError('Work order $workOrderId does not exist');
      }
      final technicianId = workOrder.assignedTo;
      if (technicianId == null) {
        throw StateError('Work order $workOrderId is not assigned');
      }
      if (!const {'assigned', 'in_progress'}.contains(workOrder.status)) {
        throw StateError(
          'Cannot begin an inspection for work order status ${workOrder.status}',
        );
      }

      final storedTemplate =
          await (db.select(db.inspectionTemplates)
                ..where((template) => template.id.equals(workOrder.templateId)))
              .getSingleOrNull();
      if (storedTemplate == null) {
        throw StateError(
          'Inspection template ${workOrder.templateId} is not available locally',
        );
      }
      final template = _decodeTemplate(storedTemplate.schemaJson);
      if (template.id != storedTemplate.id ||
          template.revision != storedTemplate.revision) {
        throw StateError('Stored inspection template metadata does not match');
      }

      final now = DateTime.now().toUtc();
      final draftId = _uuid.v4();
      await db
          .into(db.inspectionDrafts)
          .insert(
            InspectionDraftsCompanion.insert(
              id: draftId,
              workOrderId: workOrderId,
              technicianId: technicianId,
              templateJson: jsonEncode(template.toJson()),
              updatedAt: now,
            ),
          );
      if (workOrder.status != 'in_progress') {
        await (db.update(db.workOrders)
              ..where((order) => order.id.equals(workOrderId)))
            .write(const WorkOrdersCompanion(status: Value('in_progress')));
        await _enqueueWorkOrderStatus(workOrderId, 'in_progress', now);
      }
      await _enqueueSnapshot(
        draftId: draftId,
        workOrderId: workOrderId,
        technicianId: technicianId,
        template: template,
        answers: const {},
        answerRecords: const [],
        mediaRecords: const [],
        status: 'draft',
        updatedAt: now,
      );
      return draftId;
    });
  }

  Stream<InspectionDraftView> watchDraft(String id) {
    final query =
        db.select(db.inspectionDrafts).join([
            leftOuterJoin(
              db.inspectionAnswers,
              db.inspectionAnswers.inspectionId.equalsExp(
                db.inspectionDrafts.id,
              ),
            ),
          ])
          ..where(db.inspectionDrafts.id.equals(id))
          ..orderBy([OrderingTerm.asc(db.inspectionAnswers.itemId)]);

    return query.watch().map((rows) {
      if (rows.isEmpty) {
        throw StateError('Inspection draft $id does not exist');
      }
      final draft = rows.first.readTable(db.inspectionDrafts);
      final answers = <String, Object?>{};
      for (final row in rows) {
        final answer = row.readTableOrNull(db.inspectionAnswers);
        if (answer != null) {
          answers[answer.itemId] = _freezeJson(jsonDecode(answer.valueJson));
        }
      }
      return InspectionDraftView(
        id: draft.id,
        workOrderId: draft.workOrderId,
        template: _decodeTemplate(draft.templateJson),
        answers: Map.unmodifiable(answers),
        updatedAt: draft.updatedAt,
      );
    });
  }

  /// Stores one validated answer and queues a full, replayable draft snapshot.
  /// Required fields remain optional while the technician is still editing.
  Future<void> saveAnswer(String draftId, String itemId, Object? value) async {
    late final String encodedValue;
    try {
      encodedValue = jsonEncode(value);
    } on Object catch (error) {
      throw ArgumentError.value(
        value,
        'value',
        'Answer must be JSON-safe: $error',
      );
    }

    await db.transaction(() async {
      final draft = await (db.select(
        db.inspectionDrafts,
      )..where((row) => row.id.equals(draftId))).getSingleOrNull();
      if (draft == null) {
        throw StateError('Inspection draft $draftId does not exist');
      }
      if (draft.status != 'draft') {
        throw StateError('Inspection draft $draftId is no longer editable');
      }

      final template = _decodeTemplate(draft.templateJson);
      final itemMatches = template.items.where((item) => item.id == itemId);
      if (itemMatches.isEmpty) {
        throw ArgumentError.value(itemId, 'itemId', 'Unknown template item');
      }
      final item = itemMatches.single;
      final validationError = schema.validateAnswer(
        item,
        value,
        enforceRequired: false,
      );
      if (validationError != null) {
        throw ArgumentError.value(value, 'value', validationError);
      }
      final oldAnswer =
          await (db.select(db.inspectionAnswers)..where(
                (answer) =>
                    answer.inspectionId.equals(draftId) &
                    answer.itemId.equals(itemId),
              ))
              .getSingleOrNull();
      if (item.type == schema.FieldType.photo && value is List) {
        // Preserve exact v2 photo UUIDs when appending evidence, while
        // requiring every new reference to have ready local metadata.
        final legacyIds = oldAnswer == null
            ? const <String>{}
            : _photoIds(oldAnswer.valueJson).toSet();
        await _validatePhotoReferences(
          draftId,
          itemId,
          value.cast<String>(),
          legacyIds: legacyIds,
        );
      }
      if (oldAnswer?.valueJson == encodedValue) return;

      if (oldAnswer == null) {
        await db
            .into(db.inspectionAnswers)
            .insert(
              InspectionAnswersCompanion.insert(
                id: _uuid.v4(),
                inspectionId: draftId,
                itemId: itemId,
                valueJson: encodedValue,
              ),
            );
      } else {
        await (db.update(db.inspectionAnswers)
              ..where((answer) => answer.id.equals(oldAnswer.id)))
            .write(InspectionAnswersCompanion(valueJson: Value(encodedValue)));
      }

      final now = DateTime.now().toUtc();
      await (db.update(db.inspectionDrafts)
            ..where((row) => row.id.equals(draftId)))
          .write(InspectionDraftsCompanion(updatedAt: Value(now)));
      final answerRows =
          await (db.select(db.inspectionAnswers)
                ..where((answer) => answer.inspectionId.equals(draftId))
                ..orderBy([(answer) => OrderingTerm.asc(answer.itemId)]))
              .get();
      final answers = <String, Object?>{
        for (final answer in answerRows)
          answer.itemId: jsonDecode(answer.valueJson),
      };
      final answerRecords = [
        for (final answer in answerRows)
          {
            'id': answer.id,
            'itemId': answer.itemId,
            'value': jsonDecode(answer.valueJson),
          },
      ];
      final mediaRecords = await _mediaRecordsForAnswers(
        draftId,
        template,
        answerRows,
      );
      await _enqueueSnapshot(
        draftId: draftId,
        workOrderId: draft.workOrderId,
        technicianId: draft.technicianId,
        template: template,
        answers: answers,
        answerRecords: answerRecords,
        mediaRecords: mediaRecords,
        status: draft.status,
        updatedAt: now,
      );
    });
  }

  Future<void> _enqueueSnapshot({
    required String draftId,
    required String workOrderId,
    required String technicianId,
    required schema.InspectionTemplate template,
    required Map<String, Object?> answers,
    required List<Map<String, Object?>> answerRecords,
    required List<Map<String, Object?>> mediaRecords,
    required String status,
    required DateTime updatedAt,
  }) async {
    final operationId = _uuid.v4();
    await db
        .into(db.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            operationId: operationId,
            entity: 'inspection_draft',
            entityId: draftId,
            payloadJson: jsonEncode({
              'operationId': operationId,
              'inspection': {
                'id': draftId,
                'workOrderId': workOrderId,
                'technicianId': technicianId,
                'template': template.toJson(),
                'answers': answers,
                'answerRecords': answerRecords,
                'mediaRecords': mediaRecords,
                'status': status,
                'updatedAt': updatedAt.toIso8601String(),
              },
            }),
            createdAt: updatedAt,
          ),
        );
  }

  Future<void> _enqueueWorkOrderStatus(
    String workOrderId,
    String status,
    DateTime createdAt,
  ) async {
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
            createdAt: createdAt,
          ),
        );
  }

  schema.InspectionTemplate _decodeTemplate(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Invalid template snapshot');
    }
    return schema.InspectionTemplate.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> _validatePhotoReferences(
    String draftId,
    String itemId,
    List<String> ids, {
    Set<String> legacyIds = const {},
  }) async {
    if (ids.isEmpty) return;
    final records = await (db.select(
      db.inspectionMedia,
    )..where((media) => media.id.isIn(ids))).get();
    final byId = {for (final media in records) media.id: media};
    for (final id in ids) {
      final media = byId[id];
      if (media == null && legacyIds.contains(id)) continue;
      if (media == null ||
          media.inspectionId != draftId ||
          media.itemId != itemId ||
          (!legacyIds.contains(id) && media.state != 'ready')) {
        throw ArgumentError.value(
          id,
          'value',
          'Photo reference must identify ready evidence for this draft field',
        );
      }
    }
  }

  List<String> _photoIds(String encoded) {
    final value = jsonDecode(encoded);
    return value is List ? value.whereType<String>().toList() : const [];
  }

  Future<List<Map<String, Object?>>> _mediaRecordsForAnswers(
    String draftId,
    schema.InspectionTemplate template,
    List<InspectionAnswer> answerRows,
  ) async {
    final photoItemIds = {
      for (final item in template.items)
        if (item.type == schema.FieldType.photo) item.id,
    };
    final referencedIds = <String>{};
    for (final answer in answerRows) {
      if (!photoItemIds.contains(answer.itemId)) continue;
      final value = jsonDecode(answer.valueJson);
      if (value is List) {
        referencedIds.addAll(value.whereType<String>());
      }
    }
    if (referencedIds.isEmpty) return const [];

    final records =
        await (db.select(db.inspectionMedia)
              ..where(
                (media) =>
                    media.inspectionId.equals(draftId) &
                    media.id.isIn(referencedIds),
              )
              ..orderBy([
                (media) => OrderingTerm.asc(media.itemId),
                (media) => OrderingTerm.asc(media.id),
              ]))
            .get();
    return [
      for (final media in records)
        {
          'id': media.id,
          'inspectionId': media.inspectionId,
          'itemId': media.itemId,
          'state': media.state,
          'originalPath': media.originalPath,
          'thumbnailPath': media.thumbnailPath,
          'mimeType': media.mimeType,
          'byteLength': media.byteLength,
          'thumbnailByteLength': media.thumbnailByteLength,
          'sha256': media.sha256,
          'thumbnailSha256': media.thumbnailSha256,
          'width': media.width,
          'height': media.height,
          'capturedAt': media.capturedAt?.toIso8601String(),
        },
    ];
  }

  Object? _freezeJson(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: _freezeJson(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_freezeJson));
    }
    return value;
  }
}
