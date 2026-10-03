import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../core/structured_log.dart';
import '../inspections/inspection_repository.dart';
import '../inspections/template.dart' as schema;
import 'media_file_store.dart';

class MediaRepository {
  MediaRepository(this.db, this.files)
    : _inspections = InspectionRepository(db);

  final AppDatabase db;
  final MediaFileStore files;
  final InspectionRepository _inspections;
  static const _uuid = Uuid();

  static String originalRelativePath(String mediaId) => '$mediaId/original.jpg';

  static String thumbnailRelativePath(String mediaId) =>
      '$mediaId/thumbnail.jpg';

  Future<String> beginCapture(String draftId, String itemId) async {
    final mediaId = _uuid.v4();
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
      final items = template.items.where((item) => item.id == itemId);
      if (items.isEmpty || items.single.type != schema.FieldType.photo) {
        throw ArgumentError.value(itemId, 'itemId', 'Expected a photo field');
      }

      await db
          .into(db.inspectionMedia)
          .insert(
            InspectionMediaCompanion.insert(
              id: mediaId,
              inspectionId: draftId,
              itemId: itemId,
              state: 'capturing',
              createdAt: DateTime.now().toUtc(),
              originalPath: originalRelativePath(mediaId),
              thumbnailPath: thumbnailRelativePath(mediaId),
            ),
          );
    });
    return mediaId;
  }

  /// Writes capture time before file IO. The final metadata, photo answer, and
  /// replayable outbox snapshot commit together after both files are verified.
  Future<void> completeCapture(
    String mediaId,
    Uint8List bytes, {
    DateTime? capturedAt,
  }) async {
    final stableBytes = Uint8List.fromList(bytes);
    final inputHash = sha256.convert(stableBytes).toString();
    final prior = await db.transaction(() async {
      final media = await (db.select(
        db.inspectionMedia,
      )..where((row) => row.id.equals(mediaId))).getSingleOrNull();
      if (media == null) {
        throw StateError('Media capture $mediaId does not exist');
      }
      if (media.state == 'ready') {
        if (media.sha256 == inputHash) return null;
        throw StateError('Ready media $mediaId has immutable original bytes');
      }
      if (media.state != 'capturing') {
        throw StateError('Media capture $mediaId is ${media.state}');
      }

      final time =
          media.capturedAt ?? capturedAt?.toUtc() ?? DateTime.now().toUtc();
      if (media.capturedAt == null) {
        await (db.update(db.inspectionMedia)
              ..where((row) => row.id.equals(mediaId)))
            .write(InspectionMediaCompanion(capturedAt: Value(time)));
      }
      return time;
    });
    if (prior == null) return;

    late final StoredPhoto photo;
    try {
      photo = await files.writePhoto(mediaId, stableBytes);
      _validateStoredPhoto(mediaId, photo, inputHash: inputHash);
    } on FormatException {
      await _markFailed(mediaId, 'capture_failed');
      rethrow;
    }

    // A database/outbox error here must leave the row capturing, so recovery
    // can attach the already durable files later.
    await _attachStoredPhoto(mediaId, photo, prior);
  }

  Future<void> cancelCapture(String mediaId) async {
    await db.transaction(() async {
      final media = await (db.select(
        db.inspectionMedia,
      )..where((row) => row.id.equals(mediaId))).getSingleOrNull();
      if (media == null) {
        throw StateError('Media capture $mediaId does not exist');
      }
      if (media.state == 'failed' && media.errorCode == 'capture_cancelled') {
        return;
      }
      if (media.state != 'capturing') {
        throw StateError('Only an in-progress capture can be cancelled');
      }
      await (db.update(
        db.inspectionMedia,
      )..where((row) => row.id.equals(mediaId))).write(
        const InspectionMediaCompanion(
          state: Value('failed'),
          errorCode: Value('capture_cancelled'),
        ),
      );
    });
  }

  Future<void> recoverPending() async {
    final capturing =
        await (db.select(db.inspectionMedia)
              ..where((row) => row.state.equals('capturing'))
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();
    for (final media in capturing) {
      StoredPhoto? recovered;
      try {
        recovered = await files.recoverPhoto(media.id);
        if (recovered != null) _validateStoredPhoto(media.id, recovered);
      } on FormatException catch (error) {
        StructuredLog.warning(
          'media.capture_recovery_failed',
          fields: {
            'mediaId': media.id,
            'errorType': error.runtimeType.toString(),
          },
        );
        recovered = null;
      } on Object catch (error) {
        StructuredLog.warning(
          'media.capture_recovery_unavailable',
          fields: {
            'mediaId': media.id,
            'errorType': error.runtimeType.toString(),
          },
        );
        rethrow;
      }
      if (recovered == null) {
        await _markFailed(media.id, 'capture_failed');
      } else {
        await _attachStoredPhoto(
          media.id,
          recovered,
          media.capturedAt ?? media.createdAt,
        );
      }
    }

    final ready =
        await (db.select(db.inspectionMedia)
              ..where((row) => row.state.equals('ready'))
              ..orderBy([
                (row) => OrderingTerm.asc(row.createdAt),
                (row) => OrderingTerm.asc(row.id),
              ]))
            .get();
    for (final media in ready) {
      final problem = await _readyFileProblem(media);
      if (problem != null) {
        await _markMissing(media.id, problem);
      }
    }
  }

  Stream<List<MediaRecord>> watchForDraft(String draftId) {
    return (db.select(db.inspectionMedia)
          ..where((row) => row.inspectionId.equals(draftId))
          ..orderBy([
            (row) => OrderingTerm.asc(row.createdAt),
            (row) => OrderingTerm.asc(row.id),
          ]))
        .watch();
  }

  Future<void> _attachStoredPhoto(
    String mediaId,
    StoredPhoto photo,
    DateTime capturedAt,
  ) async {
    await db.transaction(() async {
      final media = await (db.select(
        db.inspectionMedia,
      )..where((row) => row.id.equals(mediaId))).getSingleOrNull();
      if (media == null) {
        throw StateError('Media capture $mediaId does not exist');
      }
      if (media.state == 'ready') {
        if (_matchesPhoto(media, photo)) return;
        throw StateError('Ready media $mediaId has immutable file provenance');
      }
      if (media.state != 'capturing') {
        throw StateError('Media capture $mediaId is ${media.state}');
      }
      if (media.capturedAt != null && media.capturedAt != capturedAt) {
        capturedAt = media.capturedAt!;
      }

      await (db.update(
        db.inspectionMedia,
      )..where((row) => row.id.equals(mediaId))).write(
        InspectionMediaCompanion(
          state: const Value('ready'),
          capturedAt: Value(capturedAt.toUtc()),
          originalPath: Value(photo.originalPath),
          thumbnailPath: Value(photo.thumbnailPath),
          mimeType: Value(photo.mimeType),
          byteLength: Value(photo.byteLength),
          thumbnailByteLength: Value(photo.thumbnailByteLength),
          sha256: Value(photo.sha256),
          thumbnailSha256: Value(photo.thumbnailSha256),
          width: Value(photo.width),
          height: Value(photo.height),
          errorCode: const Value(null),
        ),
      );

      final answer =
          await (db.select(db.inspectionAnswers)..where(
                (row) =>
                    row.inspectionId.equals(media.inspectionId) &
                    row.itemId.equals(media.itemId),
              ))
              .getSingleOrNull();
      final existing = answer == null
          ? const <String>[]
          : _photoIds(answer.valueJson);
      if (existing.contains(mediaId)) return;
      await _inspections.saveAnswer(media.inspectionId, media.itemId, [
        ...existing,
        mediaId,
      ]);
    });
  }

  Future<void> _markFailed(String mediaId, String errorCode) async {
    await db.transaction(() async {
      await (db.update(db.inspectionMedia)..where(
            (row) => row.id.equals(mediaId) & row.state.equals('capturing'),
          ))
          .write(
            InspectionMediaCompanion(
              state: const Value('failed'),
              errorCode: Value(errorCode),
            ),
          );
    });
  }

  Future<void> _markMissing(String mediaId, String errorCode) async {
    await db.transaction(() async {
      await (db.update(
            db.inspectionMedia,
          )..where((row) => row.id.equals(mediaId) & row.state.equals('ready')))
          .write(
            InspectionMediaCompanion(
              state: const Value('missing'),
              errorCode: Value(errorCode),
            ),
          );
    });
  }

  Future<String?> _readyFileProblem(MediaRecord media) async {
    try {
      if (media.originalPath != originalRelativePath(media.id) ||
          media.thumbnailPath != thumbnailRelativePath(media.id)) {
        return 'integrity_mismatch';
      }
      final original = files.originalFile(media.id);
      final thumbnail = files.thumbnailFile(media.id);
      if (!await original.exists()) {
        return 'source_missing';
      }
      if (await original.length() != media.byteLength ||
          await _fileHash(original) != media.sha256) {
        return 'integrity_mismatch';
      }
      if (await thumbnail.exists() &&
          await thumbnail.length() == media.thumbnailByteLength &&
          await _fileHash(thumbnail) == media.thumbnailSha256) {
        return null;
      }

      final repaired = await files.recoverPhoto(media.id);
      if (repaired == null) return 'source_missing';
      _validateStoredPhoto(media.id, repaired);
      return _matchesOriginalMetadata(media, repaired) &&
              repaired.thumbnailByteLength == media.thumbnailByteLength &&
              repaired.thumbnailSha256 == media.thumbnailSha256
          ? null
          : 'integrity_mismatch';
    } on FormatException {
      return 'integrity_mismatch';
    }
  }

  Future<String> _fileHash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  bool _matchesPhoto(MediaRecord record, StoredPhoto photo) =>
      record.originalPath == photo.originalPath &&
      record.thumbnailPath == photo.thumbnailPath &&
      record.mimeType == photo.mimeType &&
      record.byteLength == photo.byteLength &&
      record.thumbnailByteLength == photo.thumbnailByteLength &&
      record.sha256 == photo.sha256 &&
      record.thumbnailSha256 == photo.thumbnailSha256 &&
      record.width == photo.width &&
      record.height == photo.height;

  void _validateStoredPhoto(
    String mediaId,
    StoredPhoto photo, {
    String? inputHash,
  }) {
    final hashPattern = RegExp(r'^[0-9a-f]{64}$');
    if (photo.originalPath != originalRelativePath(mediaId) ||
        photo.thumbnailPath != thumbnailRelativePath(mediaId) ||
        photo.mimeType != 'image/jpeg' ||
        photo.byteLength <= 0 ||
        photo.thumbnailByteLength <= 0 ||
        photo.width <= 0 ||
        photo.height <= 0 ||
        !hashPattern.hasMatch(photo.sha256) ||
        !hashPattern.hasMatch(photo.thumbnailSha256) ||
        (inputHash != null && photo.sha256 != inputHash)) {
      throw const FormatException('Photo store returned invalid metadata');
    }
  }

  bool _matchesOriginalMetadata(MediaRecord record, StoredPhoto photo) =>
      record.originalPath == photo.originalPath &&
      record.thumbnailPath == photo.thumbnailPath &&
      record.mimeType == photo.mimeType &&
      record.byteLength == photo.byteLength &&
      record.sha256 == photo.sha256 &&
      record.width == photo.width &&
      record.height == photo.height;

  List<String> _photoIds(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded == null) return const [];
    if (decoded is! List || decoded.any((value) => value is! String)) {
      throw const FormatException('Stored photo answer is malformed');
    }
    return decoded.cast<String>();
  }

  schema.InspectionTemplate _decodeTemplate(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Invalid template snapshot');
    }
    return schema.InspectionTemplate.fromJson(decoded.cast<String, Object?>());
  }
}
