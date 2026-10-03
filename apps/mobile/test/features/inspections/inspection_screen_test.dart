import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fieldlens_mobile/features/camera/file_system_media_store.dart';
import 'package:fieldlens_mobile/features/camera/media_providers.dart';
import 'package:fieldlens_mobile/features/camera/media_repository.dart';
import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/database/app_database.dart'
    hide InspectionTemplate;
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
    'false is a real answer and review reports other required fields',
    (tester) async {
      final fixture = await _createFixture(tester);
      _registerCleanup(tester, fixture);

      await tester.pumpWidget(_createApp(fixture));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No'));
      await _waitForDraft(
        tester,
        fixture,
        (draft) => draft.answers['safety_check'] == false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Saved locally'), findsOneWidget);

      final reviewButton = find.byKey(
        const ValueKey('review-inspection-draft'),
      );
      await _scrollTo(tester, reviewButton);
      await tester.tap(reviewButton);
      await tester.pumpAndSettle();
      final reviewSummary = find.byKey(const ValueKey('draft-review-summary'));
      await _scrollTo(tester, reviewSummary);

      expect(
        find.text('Review 1 answer before this draft is complete.'),
        findsOneWidget,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 1000));
      await tester.pumpAndSettle();
      await _scrollTo(
        tester,
        find.byKey(const ValueKey('inspection-error-corrosion')),
      );
      expect(find.text('This answer is required'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('inspection-error-safety_check')),
        findsNothing,
      );
    },
  );

  testWidgets('editing after a valid review requires reviewing again', (
    tester,
  ) async {
    final fixture = await _createFixture(
      tester,
      template: InspectionTemplate(
        id: '10000000-0000-4000-8000-000000000003',
        revision: 1,
        title: 'Required boolean check',
        items: [
          TemplateItem(
            id: 'required_boolean',
            label: 'Required boolean',
            type: FieldType.boolean,
            required: true,
          ),
        ],
      ),
    );
    _registerCleanup(tester, fixture);
    await tester.runAsync(
      () => fixture.repository.saveAnswer(
        fixture.draftId,
        'required_boolean',
        true,
      ),
    );
    await _waitForDraft(
      tester,
      fixture,
      (draft) => draft.answers['required_boolean'] == true,
    );

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    final reviewButton = find.byKey(const ValueKey('review-inspection-draft'));
    await _scrollTo(tester, reviewButton);
    await tester.tap(reviewButton);
    await tester.pumpAndSettle();
    final validReview = find.byKey(const ValueKey('draft-review-valid'));
    await _scrollTo(tester, validReview);
    expect(validReview, findsOneWidget);

    await _scrollTo(
      tester,
      find.byKey(const ValueKey('field-required_boolean')),
    );
    await tester.tap(find.text('Yes'));
    await _waitForDraft(
      tester,
      fixture,
      (draft) => draft.answers['required_boolean'] == null,
    );
    await tester.pumpAndSettle();

    expect(validReview, findsNothing);
    await _scrollTo(tester, reviewButton);
    await tester.tap(reviewButton);
    await tester.pumpAndSettle();
    expect(
      find.text('Review 1 answer before this draft is complete.'),
      findsOneWidget,
    );
  });

  testWidgets('text remains visible through reactive local draft updates', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final notesField = find.byKey(const ValueKey('field-notes'));

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    await _scrollTo(tester, notesField);
    await tester.enterText(notesField, 'Valve casing inspected');
    await _waitForDraft(
      tester,
      fixture,
      (draft) => draft.answers['notes'] == 'Valve casing inspected',
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, notesField);
    expect(
      tester.widget<TextField>(notesField).controller!.text,
      'Valve casing inspected',
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 500));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('No'));
    await tester.tap(find.text('No'));
    await _waitForDraft(
      tester,
      fixture,
      (draft) => draft.answers['safety_check'] == false,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(notesField).controller!.text,
      'Valve casing inspected',
    );
  });

  testWidgets('rapid multiple choice toggles persist both selected options', (
    tester,
  ) async {
    final fixture = await _createFixture(
      tester,
      template: _templateWithEveryField(),
    );
    _registerCleanup(tester, fixture);
    final firstOption = find.byKey(
      const ValueKey('field-multiple_choice-first'),
    );
    final secondOption = find.byKey(
      const ValueKey('field-multiple_choice-second'),
    );

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    await _scrollTo(tester, firstOption);
    await tester.pumpAndSettle();
    await tester.tap(firstOption);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(firstOption).value, isTrue);
    await _scrollTo(tester, secondOption);
    await tester.tap(secondOption);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(firstOption).value, isTrue);
    expect(tester.widget<CheckboxListTile>(secondOption).value, isTrue);
    final saved = await _waitForDraft(tester, fixture, (draft) {
      final answer = draft.answers['multiple_choice'];
      return answer is List &&
          answer.contains('first') &&
          answer.contains('second');
    });
    expect(saved.answers['multiple_choice'], ['first', 'second']);
    await tester.pumpAndSettle();

    expect(tester.widget<CheckboxListTile>(firstOption).value, isTrue);
    expect(tester.widget<CheckboxListTile>(secondOption).value, isTrue);
  });

  testWidgets('malformed numeric input stays inline and is not persisted', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final numericField = find.byKey(const ValueKey('field-temperature_c'));

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    await _scrollTo(tester, numericField);
    await tester.enterText(numericField, 'NaN');
    await tester.pumpAndSettle();

    expect(find.text('Enter a finite number.'), findsOneWidget);
    final storedDraft = await tester.runAsync(
      () => fixture.repository.watchDraft(fixture.draftId).first,
    );
    expect(storedDraft!.answers.containsKey('temperature_c'), isFalse);
    expect(tester.widget<TextField>(numericField).controller!.text, 'NaN');
  });

  testWidgets('a failed local save can be retried without losing text', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    final retryingRepository = _FailOnceInspectionRepository(fixture.database);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        inspectionRepositoryProvider.overrideWithValue(retryingRepository),
        mediaRepositoryProvider.overrideWith((ref) async => fixture.media),
      ],
    );
    _registerCleanup(tester, fixture, additionalContainers: [container]);
    final notesField = find.byKey(const ValueKey('field-notes'));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: InspectionScreen(draftId: fixture.draftId)),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollTo(tester, notesField);
    await tester.enterText(notesField, 'Retry this save');
    await tester.runAsync(() => retryingRepository.failedFirstSave.future);
    await tester.pumpAndSettle();

    expect(find.text('Could not save locally'), findsOneWidget);
    expect(find.text('Retry save'), findsOneWidget);
    expect(
      tester.widget<TextField>(notesField).controller!.text,
      'Retry this save',
    );

    await tester.tap(find.text('Retry save'));
    await _waitForDraft(
      tester,
      fixture,
      (draft) => draft.answers['notes'] == 'Retry this save',
    );
    await tester.pumpAndSettle();

    expect(find.text('Saved locally'), findsOneWidget);
    expect(find.text('Could not save locally'), findsNothing);
  });

  testWidgets(
    'renders all supported field families without fake evidence inputs',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        template: _templateWithEveryField(),
      );
      _registerCleanup(tester, fixture);

      await tester.pumpWidget(_createApp(fixture));
      await tester.pumpAndSettle();

      for (final fieldId in ['boolean', 'pass_fail', 'numeric', 'text', 'qr']) {
        final field = find.byKey(ValueKey('field-$fieldId'));
        await _scrollTo(tester, field);
        expect(field, findsOneWidget);
      }
      final photoCapture = find.byKey(const ValueKey('capture-photo-photo'));
      await _scrollTo(tester, photoCapture);
      expect(photoCapture, findsOneWidget);
      final signaturePlaceholder = find.text(
        'Signature capture will be available in the evidence step.',
      );
      await _scrollTo(tester, signaturePlaceholder);
      expect(signaturePlaceholder, findsOneWidget);
      for (final fieldId in ['single_choice', 'multiple_choice-first']) {
        final field = find.byKey(ValueKey('field-$fieldId'));
        await _scrollTo(tester, field);
        expect(field, findsOneWidget);
      }
      final reviewButton = find.byKey(
        const ValueKey('review-inspection-draft'),
      );
      await _scrollTo(tester, reviewButton);
      expect(reviewButton, findsOneWidget);
      expect(find.text('Submit'), findsNothing);
    },
  );
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  final list = find.byType(ListView).first;
  final viewportHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  var attempts = 50;
  while (attempts > 0) {
    if (finder.evaluate().isNotEmpty) {
      final rect = tester.getRect(finder.first);
      if (rect.top >= 56 && rect.bottom <= viewportHeight) break;
    }
    await tester.drag(list, const Offset(0, -120));
    await tester.pumpAndSettle();
    attempts -= 1;
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<InspectionDraftView> _waitForDraft(
  WidgetTester tester,
  _Fixture fixture,
  bool Function(InspectionDraftView) matches,
) async {
  final completer = Completer<InspectionDraftView>();
  StreamSubscription<InspectionDraftView>? subscription;
  await tester.runAsync(() async {
    subscription = fixture.repository.watchDraft(fixture.draftId).listen((
      draft,
    ) {
      if (!completer.isCompleted && matches(draft)) {
        completer.complete(draft);
      }
    }, onError: completer.completeError);
  });

  try {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (completer.isCompleted) return await completer.future;
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    throw TimeoutException(
      'The inspection draft did not reach the expected state after 100 pump cycles.',
    );
  } finally {
    await tester.runAsync(() async {
      await subscription?.cancel();
    });
  }
}

Future<_Fixture> _createFixture(
  WidgetTester tester, {
  InspectionTemplate? template,
}) async {
  final fixture = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fieldlens-inspection-widget-',
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
    final jpeg = image.Image(width: 16, height: 12);
    image.fill(jpeg, color: image.ColorRgb8(210, 40, 40));
    final capturedFile = File(path.join(directory.path, 'captured.jpg'));
    await capturedFile.writeAsBytes(image.encodeJpg(jpeg));
    await workRepository.seedFactoryDemo();
    await inspectionRepository.seedFactoryTemplate();
    if (template != null) {
      await database
          .into(database.inspectionTemplates)
          .insert(
            InspectionTemplatesCompanion.insert(
              id: template.id,
              revision: template.revision,
              schemaJson: jsonEncode(template.toJson()),
            ),
            mode: InsertMode.replace,
          );
    }
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
        .timeout(const Duration(seconds: 5));
    await container
        .read(mediaRepositoryProvider.future)
        .timeout(const Duration(seconds: 5));
    await container
        .read(inspectionMediaProvider(draftId).future)
        .timeout(const Duration(seconds: 5));
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

void _registerCleanup(
  WidgetTester tester,
  _Fixture fixture, {
  List<ProviderContainer> additionalContainers = const [],
}) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      for (final container in additionalContainers) {
        container.dispose();
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

class _Fixture {
  const _Fixture({
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
}

class _FailOnceInspectionRepository extends InspectionRepository {
  _FailOnceInspectionRepository(super.db);

  final failedFirstSave = Completer<void>();
  var _shouldFail = true;

  @override
  Future<void> saveAnswer(String draftId, String itemId, Object? value) {
    if (_shouldFail) {
      _shouldFail = false;
      failedFirstSave.complete();
      return Future<void>.error(StateError('simulated local write failure'));
    }
    return super.saveAnswer(draftId, itemId, value);
  }
}

InspectionTemplate _templateWithEveryField() => InspectionTemplate(
  id: '10000000-0000-4000-8000-000000000003',
  revision: 2,
  title: 'All inspection fields',
  items: [
    for (final (id, type) in [
      ('boolean', FieldType.boolean),
      ('pass_fail', FieldType.passFailNa),
      ('numeric', FieldType.numeric),
      ('text', FieldType.text),
      ('qr', FieldType.qrSerial),
      ('photo', FieldType.photo),
      ('signature', FieldType.signature),
    ])
      TemplateItem(id: id, label: id, type: type, required: false),
    TemplateItem(
      id: 'single_choice',
      label: 'Single choice',
      type: FieldType.singleChoice,
      required: false,
      options: const ['first', 'second'],
    ),
    TemplateItem(
      id: 'multiple_choice',
      label: 'Multiple choice',
      type: FieldType.multipleChoice,
      required: false,
      options: const ['first', 'second'],
    ),
  ],
);
