import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/camera/media_file_store.dart';
import 'package:fieldlens_mobile/features/camera/media_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';

void main() {
  late AppDatabase db;
  late Directory directory;
  late _FakeMediaFileStore files;
  late MediaRepository mediaRepository;
  late InspectionRepository inspectionRepository;
  late String draftId;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fieldlens_media_');
    db = AppDatabase(NativeDatabase.memory());
    files = _FakeMediaFileStore(Directory('${directory.path}/media'));
    mediaRepository = MediaRepository(db, files);
    inspectionRepository = InspectionRepository(db);
    await WorkRepository(db).seedFactoryDemo();
    await inspectionRepository.seedFactoryTemplate();
    draftId = await inspectionRepository.beginDraft(
      '40000000-0000-4000-8000-000000000001',
    );
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'capture stores files outside SQLite and atomically attaches metadata',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final mediaId = await mediaRepository.beginCapture(
        draftId,
        'evidence_photo',
      );
      final intent = await _mediaRow(db, mediaId);
      expect(intent.state, 'capturing');
      expect(intent.originalPath, '$mediaId/original.jpg');
      expect(intent.thumbnailPath, '$mediaId/thumbnail.jpg');
      expect(intent.capturedAt, isNull);

      await mediaRepository.completeCapture(
        mediaId,
        bytes,
        capturedAt: DateTime.utc(2026, 10, 3, 12),
      );

      final ready = await _mediaRow(db, mediaId);
      expect(ready.state, 'ready');
      expect(ready.capturedAt?.toUtc(), DateTime.utc(2026, 10, 3, 12));
      expect(ready.byteLength, bytes.length);
      expect(ready.sha256, sha256.convert(bytes).toString());
      expect(await files.originalFile(mediaId).exists(), isTrue);
      expect(await files.thumbnailFile(mediaId).exists(), isTrue);

      final answer = await _answerRow(db, draftId, 'evidence_photo');
      expect(jsonDecode(answer.valueJson), [mediaId]);
      final pending = await _outboxRows(db);
      expect(pending, hasLength(3));
      final inspectionOperation = pending.lastWhere(
        (operation) => operation.entity == 'inspection_draft',
      );
      final payload =
          jsonDecode(inspectionOperation.payloadJson) as Map<String, dynamic>;
      final inspection = payload['inspection'] as Map<String, dynamic>;
      expect(inspection['answers'], {
        'evidence_photo': [mediaId],
      });
      final mediaRecords = inspection['mediaRecords'] as List<dynamic>;
      expect(mediaRecords, hasLength(1));
      expect(mediaRecords.single['id'], mediaId);
      expect(mediaRecords.single['sha256'], ready.sha256);
      expect(
        inspectionOperation.payloadJson,
        isNot(contains(base64Encode(bytes))),
      );

      await mediaRepository.completeCapture(mediaId, bytes);
      await inspectionRepository.saveAnswer(draftId, 'evidence_photo', [
        mediaId,
      ]);
      expect((await _outboxRows(db)).length, pending.length);
      await expectLater(
        mediaRepository.completeCapture(
          mediaId,
          Uint8List.fromList([99, 2, 3, 4, 5]),
        ),
        throwsStateError,
      );
      expect((await _outboxRows(db)).length, pending.length);
    },
  );

  test('capture requires a mutable draft and photo item', () async {
    await expectLater(
      mediaRepository.beginCapture(draftId, 'notes'),
      throwsArgumentError,
    );
    await expectLater(
      mediaRepository.beginCapture(draftId, 'unknown'),
      throwsArgumentError,
    );
    expect(await db.select(db.inspectionMedia).get(), isEmpty);

    await (db.update(db.inspectionDrafts)
          ..where((draft) => draft.id.equals(draftId)))
        .write(const InspectionDraftsCompanion(status: Value('submitted')));
    await expectLater(
      mediaRepository.beginCapture(draftId, 'evidence_photo'),
      throwsStateError,
    );
  });

  test(
    'photo answers reject unknown and cross-draft UUID references',
    () async {
      await expectLater(
        inspectionRepository.saveAnswer(draftId, 'evidence_photo', [
          '50000000-0000-4000-8000-000000000001',
        ]),
        throwsArgumentError,
      );

      final otherDraftId = await inspectionRepository.beginDraft(
        '40000000-0000-4000-8000-000000000002',
      );
      final foreignMediaId = await mediaRepository.beginCapture(
        otherDraftId,
        'evidence_photo',
      );
      await mediaRepository.completeCapture(
        foreignMediaId,
        Uint8List.fromList([9, 8, 7]),
      );

      await db
          .into(db.inspectionAnswers)
          .insert(
            InspectionAnswersCompanion.insert(
              id: 'legacy-answer-cross-draft',
              inspectionId: draftId,
              itemId: 'evidence_photo',
              valueJson: jsonEncode([foreignMediaId]),
            ),
          );

      await expectLater(
        inspectionRepository.saveAnswer(draftId, 'evidence_photo', [
          foreignMediaId,
        ]),
        throwsArgumentError,
      );
      await expectLater(
        inspectionRepository.saveAnswer(draftId, 'evidence_photo', [
          foreignMediaId,
          '50000000-0000-4000-8000-000000000002',
        ]),
        throwsArgumentError,
      );
    },
  );

  test('legacy unavailable IDs survive appending real evidence', () async {
    const missingLegacyId = '50000000-0000-4000-8000-000000000003';
    const failedOwnedId = '50000000-0000-4000-8000-000000000004';
    await db
        .into(db.inspectionAnswers)
        .insert(
          InspectionAnswersCompanion.insert(
            id: 'legacy-answer',
            inspectionId: draftId,
            itemId: 'evidence_photo',
            valueJson: jsonEncode([missingLegacyId, failedOwnedId]),
          ),
        );
    await db
        .into(db.inspectionMedia)
        .insert(
          InspectionMediaCompanion.insert(
            id: failedOwnedId,
            inspectionId: draftId,
            itemId: 'evidence_photo',
            state: 'failed',
            createdAt: DateTime.utc(2026, 10, 3),
            originalPath: '$failedOwnedId/original.jpg',
            thumbnailPath: '$failedOwnedId/thumbnail.jpg',
            errorCode: const Value('capture_failed'),
          ),
        );

    final newMediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    await mediaRepository.completeCapture(
      newMediaId,
      Uint8List.fromList([4, 5, 6]),
    );

    final answer = await _answerRow(db, draftId, 'evidence_photo');
    expect(jsonDecode(answer.valueJson), [
      missingLegacyId,
      failedOwnedId,
      newMediaId,
    ]);
    final operation = (await _outboxRows(
      db,
    )).lastWhere((row) => row.entity == 'inspection_draft');
    final snapshot = jsonDecode(operation.payloadJson)['inspection'];
    expect(snapshot['answers']['evidence_photo'], [
      missingLegacyId,
      failedOwnedId,
      newMediaId,
    ]);
    expect(
      (snapshot['mediaRecords'] as List).map((row) => row['id']),
      unorderedEquals([failedOwnedId, newMediaId]),
    );
  });

  test(
    'metadata, answer, and outbox roll back together on outbox failure',
    () async {
      final beforeCount = (await _outboxRows(db)).length;
      final mediaId = await mediaRepository.beginCapture(
        draftId,
        'evidence_photo',
      );
      await db.customStatement('''
      CREATE TRIGGER reject_media_snapshot
      BEFORE INSERT ON sync_outbox
      WHEN NEW.entity = 'inspection_draft'
      BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
    ''');

      await expectLater(
        mediaRepository.completeCapture(mediaId, Uint8List.fromList([1, 2, 3])),
        throwsA(isA<SqliteException>()),
      );

      final media = await _mediaRow(db, mediaId);
      expect(media.state, 'capturing');
      expect(media.capturedAt, isNotNull);
      expect(await db.select(db.inspectionAnswers).get(), isEmpty);
      expect((await _outboxRows(db)).length, beforeCount);
      expect(await files.originalFile(mediaId).exists(), isTrue);
    },
  );

  test(
    'original-only interrupted capture is recovered and attached once',
    () async {
      final mediaId = await mediaRepository.beginCapture(
        draftId,
        'evidence_photo',
      );
      await files.writeOriginalOnly(mediaId, Uint8List.fromList([3, 1, 4, 1]));
      final beforeCount = (await _outboxRows(db)).length;

      await mediaRepository.recoverPending();
      final recovered = await _mediaRow(db, mediaId);
      expect(recovered.state, 'ready');
      expect(await files.thumbnailFile(mediaId).exists(), isTrue);
      expect(
        jsonDecode((await _answerRow(db, draftId, 'evidence_photo')).valueJson),
        [mediaId],
      );
      expect((await _outboxRows(db)).length, beforeCount + 1);

      await mediaRepository.recoverPending();
      expect((await _outboxRows(db)).length, beforeCount + 1);
      expect(
        jsonDecode((await _answerRow(db, draftId, 'evidence_photo')).valueJson),
        [mediaId],
      );
    },
  );

  test('transient recovery I/O leaves capture intent retryable', () async {
    final mediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    await files.writeOriginalOnly(mediaId, Uint8List.fromList([8, 6, 7]));
    files.failRecoveryWithIoCount = 1;

    await expectLater(
      mediaRepository.recoverPending(),
      throwsA(isA<FileSystemException>()),
    );
    expect((await _mediaRow(db, mediaId)).state, 'capturing');

    await mediaRepository.recoverPending();
    expect((await _mediaRow(db, mediaId)).state, 'ready');
  });

  test('unknown recovery failures remain retryable', () async {
    final mediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    await files.writeOriginalOnly(mediaId, Uint8List.fromList([1, 4, 1, 4]));
    files.failRecoveryWithUnknownOnce = true;

    await expectLater(mediaRepository.recoverPending(), throwsStateError);
    expect((await _mediaRow(db, mediaId)).state, 'capturing');

    await mediaRepository.recoverPending();
    expect((await _mediaRow(db, mediaId)).state, 'ready');
  });

  test('transient thumbnail repair I/O leaves ready media retryable', () async {
    final mediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    await mediaRepository.completeCapture(
      mediaId,
      Uint8List.fromList([2, 3, 5, 7]),
    );
    await files.thumbnailFile(mediaId).delete();
    files.failRecoveryWithIoCount = 1;

    await expectLater(
      mediaRepository.recoverPending(),
      throwsA(isA<FileSystemException>()),
    );
    expect((await _mediaRow(db, mediaId)).state, 'ready');

    await mediaRepository.recoverPending();
    expect((await _mediaRow(db, mediaId)).state, 'ready');
    expect(await files.thumbnailFile(mediaId).exists(), isTrue);
  });

  test('partial file writes remain recoverable and attach once', () async {
    final mediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    final beforeCount = (await _outboxRows(db)).length;
    files.failAfterOriginal = true;

    await expectLater(
      mediaRepository.completeCapture(mediaId, Uint8List.fromList([2, 4, 6])),
      throwsStateError,
    );

    final media = await _mediaRow(db, mediaId);
    expect(media.state, 'capturing');
    expect(media.errorCode, isNull);
    expect(await files.originalFile(mediaId).exists(), isTrue);
    expect(await db.select(db.inspectionAnswers).get(), isEmpty);

    files.failAfterOriginal = false;
    await mediaRepository.recoverPending();

    expect((await _mediaRow(db, mediaId)).state, 'ready');
    expect(
      jsonDecode((await _answerRow(db, draftId, 'evidence_photo')).valueJson),
      [mediaId],
    );
    expect((await _outboxRows(db)).length, beforeCount + 1);
    await mediaRepository.recoverPending();
    expect((await _outboxRows(db)).length, beforeCount + 1);
  });

  test('invalid capture input remains permanently failed', () async {
    final mediaId = await mediaRepository.beginCapture(
      draftId,
      'evidence_photo',
    );
    files.invalidMetadata = true;

    await expectLater(
      mediaRepository.completeCapture(mediaId, Uint8List.fromList([2, 4, 6])),
      throwsFormatException,
    );
    await mediaRepository.recoverPending();

    expect((await _mediaRow(db, mediaId)).state, 'failed');
    expect(await db.select(db.inspectionAnswers).get(), isEmpty);
  });

  test(
    'ready media corruption is marked missing without deleting references',
    () async {
      final mediaId = await mediaRepository.beginCapture(
        draftId,
        'evidence_photo',
      );
      await mediaRepository.completeCapture(
        mediaId,
        Uint8List.fromList([5, 5, 5]),
      );
      final beforeCount = (await _outboxRows(db)).length;
      await files.originalFile(mediaId).writeAsBytes([0, 0, 0], flush: true);

      await mediaRepository.recoverPending();

      final media = await _mediaRow(db, mediaId);
      expect(media.state, 'missing');
      expect(media.errorCode, 'integrity_mismatch');
      expect(
        jsonDecode((await _answerRow(db, draftId, 'evidence_photo')).valueJson),
        [mediaId],
      );
      expect((await _outboxRows(db)).length, beforeCount);
    },
  );

  test('media and answer metadata survive file database reopen', () async {
    await db.close();
    final path = '${directory.path}/fieldlens.sqlite';
    final fileDb = AppDatabase(NativeDatabase(File(path)));
    final fileInspectionRepository = InspectionRepository(fileDb);
    await WorkRepository(fileDb).seedFactoryDemo();
    await fileInspectionRepository.seedFactoryTemplate();
    final fileDraftId = await fileInspectionRepository.beginDraft(
      '40000000-0000-4000-8000-000000000001',
    );
    final fileMediaRepository = MediaRepository(fileDb, files);
    final mediaId = await fileMediaRepository.beginCapture(
      fileDraftId,
      'evidence_photo',
    );
    await fileMediaRepository.completeCapture(
      mediaId,
      Uint8List.fromList([7, 7, 7]),
    );
    await fileDb.close();

    db = AppDatabase(NativeDatabase(File(path)));
    mediaRepository = MediaRepository(db, files);
    await mediaRepository.recoverPending();

    expect((await _mediaRow(db, mediaId)).state, 'ready');
    expect(
      jsonDecode(
        (await _answerRow(db, fileDraftId, 'evidence_photo')).valueJson,
      ),
      [mediaId],
    );
  });
}

Future<MediaRecord> _mediaRow(AppDatabase db, String mediaId) => (db.select(
  db.inspectionMedia,
)..where((row) => row.id.equals(mediaId))).getSingle();

Future<InspectionAnswer> _answerRow(
  AppDatabase db,
  String draftId,
  String itemId,
) =>
    (db.select(db.inspectionAnswers)..where(
          (row) => row.inspectionId.equals(draftId) & row.itemId.equals(itemId),
        ))
        .getSingle();

Future<List<SyncOutboxData>> _outboxRows(AppDatabase db) => (db.select(
  db.syncOutbox,
)..orderBy([(row) => OrderingTerm.asc(row.localSequence)])).get();

class _FakeMediaFileStore implements MediaFileStore {
  _FakeMediaFileStore(this.root);

  final Directory root;
  bool failAfterOriginal = false;
  bool invalidMetadata = false;
  bool failRecoveryWithUnknownOnce = false;
  int failRecoveryWithIoCount = 0;

  @override
  File originalFile(String mediaId) =>
      File('${root.path}/$mediaId/original.jpg');

  @override
  File thumbnailFile(String mediaId) =>
      File('${root.path}/$mediaId/thumbnail.jpg');

  @override
  Future<StoredPhoto> writePhoto(String mediaId, Uint8List bytes) async {
    final original = originalFile(mediaId);
    await original.parent.create(recursive: true);
    if (await original.exists()) {
      final saved = await original.readAsBytes();
      if (sha256.convert(saved) != sha256.convert(bytes)) {
        throw StateError('Different bytes already exist for this media UUID');
      }
    } else {
      await original.writeAsBytes(bytes, flush: true);
    }
    if (failAfterOriginal) throw StateError('simulated file write failure');
    final thumbnail = thumbnailFile(mediaId);
    final thumbnailBytes = _thumbnailBytes(bytes);
    await thumbnail.parent.create(recursive: true);
    if (await thumbnail.exists()) {
      final saved = await thumbnail.readAsBytes();
      if (sha256.convert(saved) != sha256.convert(thumbnailBytes)) {
        throw StateError(
          'Different thumbnail already exists for this media UUID',
        );
      }
    } else {
      await thumbnail.writeAsBytes(thumbnailBytes, flush: true);
    }
    return _metadata(mediaId, bytes, invalidMime: invalidMetadata);
  }

  Future<void> writeOriginalOnly(String mediaId, Uint8List bytes) async {
    final original = originalFile(mediaId);
    await original.parent.create(recursive: true);
    await original.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<StoredPhoto?> recoverPhoto(String mediaId) async {
    if (failRecoveryWithUnknownOnce) {
      failRecoveryWithUnknownOnce = false;
      throw StateError('simulated unavailable media root');
    }
    if (failRecoveryWithIoCount > 0) {
      failRecoveryWithIoCount--;
      throw const FileSystemException('simulated transient I/O failure');
    }
    final original = originalFile(mediaId);
    if (!await original.exists()) return null;
    final bytes = await original.readAsBytes();
    final thumbnail = thumbnailFile(mediaId);
    if (!await thumbnail.exists()) {
      await thumbnail.writeAsBytes(_thumbnailBytes(bytes), flush: true);
    }
    return _metadata(mediaId, bytes);
  }

  StoredPhoto _metadata(
    String mediaId,
    Uint8List bytes, {
    bool invalidMime = false,
  }) {
    final thumbnail = _thumbnailBytes(bytes);
    return StoredPhoto(
      originalPath: MediaRepository.originalRelativePath(mediaId),
      thumbnailPath: MediaRepository.thumbnailRelativePath(mediaId),
      mimeType: invalidMime ? 'image/png' : 'image/jpeg',
      byteLength: bytes.length,
      thumbnailByteLength: thumbnail.length,
      sha256: sha256.convert(bytes).toString(),
      thumbnailSha256: sha256.convert(thumbnail).toString(),
      width: 1,
      height: 1,
    );
  }

  Uint8List _thumbnailBytes(Uint8List bytes) =>
      Uint8List.fromList(bytes.take(3).toList());
}
