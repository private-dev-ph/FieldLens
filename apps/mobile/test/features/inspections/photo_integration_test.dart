import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/database/app_database.dart'
    hide InspectionTemplate;
import 'package:fieldlens_mobile/features/camera/file_system_media_store.dart';
import 'package:fieldlens_mobile/features/camera/media_providers.dart';
import 'package:fieldlens_mobile/features/camera/media_repository.dart';
import 'package:fieldlens_mobile/features/camera/photo_capture_screen.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_screen.dart';
import 'package:fieldlens_mobile/features/inspections/template.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

void main() {
  testWidgets(
    'capture creates durable intent before callback and saves evidence',
    (tester) async {
      final fixture = await _createFixture(tester);
      _registerCleanup(tester, fixture);
      final intentReady = Completer<MediaRecord>();
      await _listenForMedia(tester, fixture, (record) {
        if (record.state == 'capturing' && !intentReady.isCompleted) {
          intentReady.complete(record);
        }
      });
      late String mediaId;

      await tester.pumpWidget(
        _createApp(
          fixture,
          capturePhoto: (context) async {
            final intent = await intentReady.future.timeout(_timeout);
            mediaId = intent.id;
            expect(intent.inspectionId, fixture.draftId);
            expect(intent.itemId, 'evidence_photo');
            expect(intent.state, 'capturing');
            expect(intent.originalPath, '$mediaId/original.jpg');
            return CapturedPhoto(
              file: XFile(fixture.capturedFile.path),
              capturedAt: DateTime.utc(2026, 10, 3, 12),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tapPhotoCapture(tester);
      final record = await _waitForMedia(
        tester,
        fixture,
        (record) => record.state == 'ready',
      );

      expect(mediaId, record.id);
      expect(record.state, 'ready');
      expect(record.byteLength, greaterThan(0));
      expect(record.thumbnailByteLength, greaterThan(0));
      expect(
        await _runIo(
          tester,
          () => fixture.files.originalFile(record.id).exists(),
        ),
        isTrue,
      );
      expect(
        await _runIo(
          tester,
          () => fixture.files.thumbnailFile(record.id).exists(),
        ),
        isTrue,
      );
      expect(
        jsonDecode(
          (await _runIo(
            tester,
            () => _answer(fixture, 'evidence_photo'),
          )).valueJson,
        ),
        [record.id],
      );
      final outbox = await _runIo(tester, () => _outbox(fixture));
      expect(outbox.last.entity, 'inspection_draft');
      final inspection = jsonDecode(outbox.last.payloadJson)['inspection'];
      expect(inspection['answers']['evidence_photo'], [record.id]);
      expect(inspection['mediaRecords'].single['id'], record.id);
      expect(find.byKey(const ValueKey('photo-saved')), findsOneWidget);
      expect(
        find.byKey(ValueKey('photo-thumbnail-${record.id}')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'cancel leaves no answer or mutation and hides cancelled evidence',
    (tester) async {
      final fixture = await _createFixture(tester);
      _registerCleanup(tester, fixture);
      final initialOutbox = await _runIo(tester, () => _outbox(fixture));

      await tester.pumpWidget(
        _createApp(
          fixture,
          capturePhoto: (context) async {
            return null;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tapPhotoCapture(tester);
      final cancelled = await _waitForMedia(
        tester,
        fixture,
        (record) => record.state == 'failed',
      );
      expect(cancelled.errorCode, 'capture_cancelled');
      expect(
        await _runIo(
          tester,
          () =>
              fixture.database.select(fixture.database.inspectionAnswers).get(),
        ),
        isEmpty,
      );
      expect(
        (await _runIo(
          tester,
          () => _outbox(fixture),
        )).map((row) => row.operationId),
        initialOutbox.map((row) => row.operationId),
      );
      expect(find.byKey(const ValueKey('photo-saved')), findsNothing);
      expect(
        find.text('Photo evidence is unavailable on this device.'),
        findsNothing,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('capture-photo-evidence_photo')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('pending capture disables review, back, and duplicate capture', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final callbackStarted = Completer<void>();
    final pendingPhoto = Completer<CapturedPhoto?>();
    var callbackCount = 0;

    await tester.pumpWidget(
      _createApp(
        fixture,
        capturePhoto: (context) {
          callbackCount++;
          callbackStarted.complete();
          return pendingPhoto.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await _tapPhotoCapture(tester);
    await _waitForFuture(tester, callbackStarted.future);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('capture-photo-evidence_photo')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('review-inspection-draft')),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.byWidgetPredicate((widget) => widget is PopScope && !widget.canPop),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('capture-photo-evidence_photo')),
      warnIfMissed: false,
    );
    expect(callbackCount, 1);
    pendingPhoto.complete(null);
    await _waitForMedia(tester, fixture, (record) => record.state == 'failed');
  });

  testWidgets('invalid JPEG shows a local error without attaching an answer', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final invalidFile = File(path.join(fixture.directory.path, 'invalid.jpg'));
    await _runIo(tester, () => invalidFile.writeAsBytes([1, 2, 3, 4, 5]));

    await tester.pumpWidget(
      _createApp(
        fixture,
        capturePhoto: (context) async => CapturedPhoto(
          file: XFile(invalidFile.path),
          capturedAt: DateTime.utc(2026, 10, 3),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapPhotoCapture(tester);
    await _waitForWidget(
      tester,
      find.byKey(const ValueKey('photo-error-evidence_photo')),
    );

    expect(
      find.text(
        'The photo could not be saved locally. You can capture another photo.',
      ),
      findsOneWidget,
    );
    expect(
      (await _waitForMedia(
        tester,
        fixture,
        (record) => record.state == 'failed',
      )).state,
      'failed',
    );
    expect(
      await _runIo(
        tester,
        () => fixture.database.select(fixture.database.inspectionAnswers).get(),
      ),
      isEmpty,
    );
    expect(
      (await _runIo(
        tester,
        () => _outbox(fixture),
      )).where((row) => row.entity == 'inspection_draft'),
      hasLength(1),
    );
  });

  testWidgets('legacy unavailable reference can be removed and reviewed', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    const legacyId = '60000000-0000-4000-8000-000000000099';
    await _runIoVoid(tester, () async {
      await fixture.database
          .into(fixture.database.inspectionAnswers)
          .insert(
            InspectionAnswersCompanion.insert(
              id: 'legacy-answer-uuid',
              inspectionId: fixture.draftId,
              itemId: 'evidence_photo',
              valueJson: jsonEncode([legacyId]),
            ),
          );
      await fixture.database
          .into(fixture.database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              operationId: '60000000-0000-4000-8000-000000000098',
              entity: 'inspection_draft',
              entityId: fixture.draftId,
              payloadJson: jsonEncode({
                'inspection': {
                  'answers': {
                    'evidence_photo': [legacyId],
                  },
                },
              }),
              createdAt: DateTime.utc(2026, 10, 3),
            ),
          );
    });
    final queuedBefore = await _runIo(tester, () => _outbox(fixture));

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    final review = find.byKey(const ValueKey('review-inspection-draft'));
    await _scrollTo(tester, review);
    await tester.tap(review);
    await _waitForWidget(
      tester,
      find.byKey(const ValueKey('inspection-error-evidence_photo')),
    );
    expect(
      find.text(
        'Photo evidence is unavailable on this device. Capture it again before reviewing.',
      ),
      findsOneWidget,
    );

    final removeButton = find.byKey(
      const ValueKey('remove-unavailable-photo-evidence_photo-$legacyId'),
    );
    await _scrollTo(tester, removeButton);
    await tester.tap(removeButton);
    await _waitForDraft(
      tester,
      fixture,
      (draft) =>
          draft.answers['evidence_photo'] is List &&
          (draft.answers['evidence_photo'] as List).isEmpty,
    );

    final afterRemoval = await _runIo(tester, () => _outbox(fixture));
    expect(afterRemoval, hasLength(queuedBefore.length + 1));
    expect(
      afterRemoval.map((row) => row.operationId),
      containsAll(queuedBefore.map((row) => row.operationId)),
    );
    expect(
      jsonDecode(
        afterRemoval
            .singleWhere(
              (row) =>
                  row.operationId == '60000000-0000-4000-8000-000000000098',
            )
            .payloadJson,
      )['inspection']['answers']['evidence_photo'],
      [legacyId],
    );
    expect(
      jsonDecode(
        afterRemoval.last.payloadJson,
      )['inspection']['answers']['evidence_photo'],
      isEmpty,
    );
    expect(
      await _runIo(
        tester,
        () => fixture.database.select(fixture.database.inspectionMedia).get(),
      ),
      isEmpty,
    );

    await _scrollTo(tester, review);
    await tester.tap(review);
    await _waitForWidget(
      tester,
      find.byKey(const ValueKey('draft-review-valid')),
    );
    expect(find.byKey(const ValueKey('draft-review-valid')), findsOneWidget);
  });

  testWidgets('same-length modified evidence blocks review', (tester) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(
      _createApp(
        fixture,
        capturePhoto: (context) async => CapturedPhoto(
          file: XFile(fixture.capturedFile.path),
          capturedAt: DateTime.utc(2026, 10, 3),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapPhotoCapture(tester);
    final record = await _waitForMedia(
      tester,
      fixture,
      (record) => record.state == 'ready',
    );
    final original = await _runIo(
      tester,
      () => fixture.files.originalFile(record.id).readAsBytes(),
    );
    original[original.length - 1] ^= 0xff;
    await _runIo(
      tester,
      () => fixture.files
          .originalFile(record.id)
          .writeAsBytes(original, flush: true),
    );

    final review = find.byKey(const ValueKey('review-inspection-draft'));
    await _scrollTo(tester, review);
    await tester.tap(review);
    final photoError = find.byKey(
      const ValueKey('inspection-error-evidence_photo'),
    );
    await _waitForWidget(tester, photoError);

    expect(
      find.text(
        'Photo evidence is unavailable on this device. Capture it again before reviewing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('outbox failure leaves intent recoverable', (tester) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await _runIoVoid(
      tester,
      () => fixture.database.customStatement('''
      CREATE TRIGGER reject_photo_snapshot
      BEFORE INSERT ON sync_outbox
      WHEN NEW.entity = 'inspection_draft'
      BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END
    '''),
    );

    await tester.pumpWidget(
      _createApp(
        fixture,
        capturePhoto: (context) async => CapturedPhoto(
          file: XFile(fixture.capturedFile.path),
          capturedAt: DateTime.utc(2026, 10, 3),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _tapPhotoCapture(tester);
    await _waitForWidget(
      tester,
      find.byKey(const ValueKey('photo-error-evidence_photo')),
    );

    var media = await _waitForMedia(
      tester,
      fixture,
      (record) => record.state == 'capturing',
    );
    expect(media.state, 'capturing');
    expect(find.byKey(const ValueKey('photo-saved')), findsNothing);
    expect(
      await _runIo(tester, () => fixture.files.originalFile(media.id).exists()),
      isTrue,
    );
    expect(
      await _runIo(
        tester,
        () => fixture.database.select(fixture.database.inspectionAnswers).get(),
      ),
      isEmpty,
    );

    await _runIoVoid(
      tester,
      () => fixture.database.customStatement(
        'DROP TRIGGER reject_photo_snapshot',
      ),
    );
    await _runAsyncPumping(tester, () => fixture.media.recoverPending());
    media = await _waitForMedia(
      tester,
      fixture,
      (record) => record.state == 'ready',
    );
    expect(media.state, 'ready');
    expect(
      jsonDecode(
        (await _runIo(
          tester,
          () => _answer(fixture, 'evidence_photo'),
        )).valueJson,
      ),
      [media.id],
    );
  });
}

const _timeout = Duration(seconds: 5);

Future<_Fixture> _createFixture(WidgetTester tester) async {
  final fixture = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fieldlens-photo-integration-',
    );
    final database = AppDatabase(
      NativeDatabase.createInBackground(
        File(path.join(directory.path, 'fieldlens.sqlite')),
      ),
    );
    final workRepository = WorkRepository(database);
    final inspectionRepository = InspectionRepository(database);
    final files = FileSystemMediaStore(
      Directory(path.join(directory.path, 'media')),
    );
    final mediaRepository = MediaRepository(database, files);
    final jpeg = image.Image(width: 24, height: 18);
    image.fill(jpeg, color: image.ColorRgb8(60, 140, 220));
    final capturedFile = File(path.join(directory.path, 'captured.jpg'));
    await capturedFile.writeAsBytes(image.encodeJpg(jpeg));
    await workRepository.seedFactoryDemo();
    await inspectionRepository.seedFactoryTemplate();
    final template = _photoTemplate();
    await (database.update(
      database.inspectionTemplates,
    )..where((row) => row.id.equals(template.id))).write(
      InspectionTemplatesCompanion(
        revision: Value(template.revision),
        schemaJson: Value(jsonEncode(template.toJson())),
      ),
    );
    final workOrder = (await workRepository.watchAssignedWork().first).first;
    final draftId = await inspectionRepository.beginDraft(workOrder.id);
    await inspectionRepository.watchDraft(draftId).first;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        inspectionRepositoryProvider.overrideWithValue(inspectionRepository),
        mediaRepositoryProvider.overrideWith((ref) async => mediaRepository),
      ],
    );
    await container
        .read(inspectionDraftProvider(draftId).future)
        .timeout(_timeout);
    await container.read(mediaRepositoryProvider.future).timeout(_timeout);
    await container
        .read(inspectionMediaProvider(draftId).future)
        .timeout(_timeout);
    return _Fixture(
      directory: directory,
      database: database,
      repository: inspectionRepository,
      media: mediaRepository,
      files: files,
      capturedFile: capturedFile,
      draftId: draftId,
      container: container,
    );
  });
  return fixture!;
}

void _registerCleanup(WidgetTester tester, _Fixture fixture) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      for (final subscription in fixture.subscriptions) {
        await subscription.cancel();
      }
      fixture.container.dispose();
      await fixture.database.close();
      await fixture.directory.delete(recursive: true);
    });
  });
}

Widget _createApp(_Fixture fixture, {CapturePhotoCallback? capturePhoto}) =>
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(
        home: InspectionScreen(
          draftId: fixture.draftId,
          capturePhoto: capturePhoto,
        ),
      ),
    );

Future<void> _tapPhotoCapture(WidgetTester tester) async {
  final capture = find.byKey(const ValueKey('capture-photo-evidence_photo'));
  await _scrollTo(tester, capture);
  await tester.tap(capture);
  await tester.pump();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final list = find.byType(ListView).first;
  var attempts = 30;
  while (attempts > 0 && finder.evaluate().isEmpty) {
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    attempts--;
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _listenForMedia(
  WidgetTester tester,
  _Fixture fixture,
  void Function(MediaRecord) onRecord,
) async {
  await tester.runAsync(() async {
    final subscription = fixture.media.watchForDraft(fixture.draftId).listen((
      records,
    ) {
      for (final record in records) {
        onRecord(record);
      }
    });
    fixture.subscriptions.add(subscription);
  });
}

Future<MediaRecord> _waitForMedia(
  WidgetTester tester,
  _Fixture fixture,
  bool Function(MediaRecord) matches,
) async {
  final completer = Completer<MediaRecord>();
  StreamSubscription<List<MediaRecord>>? subscription;
  await tester.runAsync(() async {
    subscription = fixture.media.watchForDraft(fixture.draftId).listen((
      records,
    ) {
      for (final record in records) {
        if (!completer.isCompleted && matches(record)) {
          completer.complete(record);
        }
      }
    }, onError: completer.completeError);
  });
  try {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (completer.isCompleted) {
        final record = await completer.future;
        await tester.pumpAndSettle();
        return record;
      }
      await _pumpCycle(tester);
    }
    throw TimeoutException('Media did not reach the expected state.', _timeout);
  } finally {
    await tester.runAsync(() async => subscription?.cancel());
  }
}

Future<void> _waitForDraft(
  WidgetTester tester,
  _Fixture fixture,
  bool Function(InspectionDraftView) matches,
) async {
  final completer = Completer<void>();
  StreamSubscription<InspectionDraftView>? subscription;
  await tester.runAsync(() async {
    subscription = fixture.repository.watchDraft(fixture.draftId).listen((
      draft,
    ) {
      if (!completer.isCompleted && matches(draft)) completer.complete();
    }, onError: completer.completeError);
  });
  try {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (completer.isCompleted) {
        await completer.future;
        await tester.pumpAndSettle();
        return;
      }
      await _pumpCycle(tester);
    }
    throw TimeoutException('Draft did not reach the expected state.', _timeout);
  } finally {
    await tester.runAsync(() async => subscription?.cancel());
  }
}

Future<void> _waitForWidget(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
    await _pumpCycle(tester);
  }
  throw TimeoutException('Widget $finder did not appear.', _timeout);
}

Future<void> _waitForFuture(WidgetTester tester, Future<void> future) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  unawaited(
    future.then<void>(
      (_) => completed = true,
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        completed = true;
      },
    ),
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    if (completed) {
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      return;
    }
    await _pumpCycle(tester);
  }
  throw TimeoutException('Future did not complete.', _timeout);
}

Future<void> _pumpCycle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 10));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
}

Future<void> _runAsyncPumping(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  unawaited(
    action().then<void>(
      (_) => completed = true,
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        completed = true;
      },
    ),
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    if (completed) {
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      return;
    }
    await _pumpCycle(tester);
  }
  throw TimeoutException('I/O operation did not complete.', _timeout);
}

Future<T> _runIo<T>(WidgetTester tester, Future<T> Function() action) async {
  final result = await tester.runAsync(() => action().timeout(_timeout));
  if (result == null) throw StateError('I/O operation returned no result');
  return result;
}

Future<void> _runIoVoid(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  await tester.runAsync(() => action().timeout(_timeout));
}

Future<InspectionAnswer> _answer(_Fixture fixture, String itemId) =>
    (fixture.database.select(fixture.database.inspectionAnswers)..where(
          (row) =>
              row.inspectionId.equals(fixture.draftId) &
              row.itemId.equals(itemId),
        ))
        .getSingle();

Future<List<SyncOutboxData>> _outbox(_Fixture fixture) =>
    (fixture.database.select(
      fixture.database.syncOutbox,
    )..orderBy([(row) => OrderingTerm.asc(row.localSequence)])).get();

InspectionTemplate _photoTemplate() => InspectionTemplate(
  id: '10000000-0000-4000-8000-000000000003',
  revision: 2,
  title: 'Photo integration fixture',
  items: [
    TemplateItem(
      id: 'evidence_photo',
      label: 'Evidence photo',
      type: FieldType.photo,
      required: false,
    ),
  ],
);

class _Fixture {
  _Fixture({
    required this.directory,
    required this.database,
    required this.repository,
    required this.media,
    required this.files,
    required this.capturedFile,
    required this.draftId,
    required this.container,
  });

  final Directory directory;
  final AppDatabase database;
  final InspectionRepository repository;
  final MediaRepository media;
  final FileSystemMediaStore files;
  final File capturedFile;
  final String draftId;
  final ProviderContainer container;
  final List<StreamSubscription<dynamic>> subscriptions = [];
}
