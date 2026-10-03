import 'dart:convert';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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

void main() {
  testWidgets(
    'false is a real answer and review reports other required fields',
    (tester) async {
      final fixture = await _createFixture(tester);
      _registerCleanup(tester, fixture);

      await tester.pumpWidget(_createApp(fixture));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No'));
      await tester.runAsync(() async {
        await fixture.repository
            .watchDraft(fixture.draftId)
            .firstWhere((draft) => draft.answers['safety_check'] == false);
      });
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
    await tester.runAsync(() async {
      await fixture.repository
          .watchDraft(fixture.draftId)
          .firstWhere((draft) => draft.answers['required_boolean'] == null)
          .timeout(const Duration(seconds: 5));
    });
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
    await tester.runAsync(() async {
      await fixture.repository
          .watchDraft(fixture.draftId)
          .firstWhere(
            (draft) => draft.answers['notes'] == 'Valve casing inspected',
          );
    });
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
    await tester.runAsync(() async {
      await fixture.repository
          .watchDraft(fixture.draftId)
          .firstWhere((draft) => draft.answers['safety_check'] == false);
    });
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
    InspectionDraftView? saved;
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      saved = await tester.runAsync(
        () => fixture.repository.watchDraft(fixture.draftId).first,
      );
      final answer = saved!.answers['multiple_choice'];
      if (answer is List &&
          answer.contains('first') &&
          answer.contains('second')) {
        break;
      }
    }
    expect(saved!.answers['multiple_choice'], ['first', 'second']);
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
    await tester.runAsync(() async {
      await fixture.repository
          .watchDraft(fixture.draftId)
          .firstWhere((draft) => draft.answers['notes'] == 'Retry this save');
    });
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
      final photoPlaceholder = find.text(
        'Photo capture will be available in the evidence step.',
      );
      await _scrollTo(tester, photoPlaceholder);
      expect(photoPlaceholder, findsOneWidget);
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

Future<_Fixture> _createFixture(
  WidgetTester tester, {
  InspectionTemplate? template,
}) async {
  final fixture = await tester.runAsync(() async {
    final database = AppDatabase(NativeDatabase.memory());
    final workRepository = WorkRepository(database);
    final inspectionRepository = InspectionRepository(database);
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
    return _Fixture(
      database,
      inspectionRepository,
      draftId,
      ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          inspectionRepositoryProvider.overrideWithValue(inspectionRepository),
        ],
      ),
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
    });
  });
}

Widget _createApp(_Fixture fixture) => UncontrolledProviderScope(
  container: fixture.container,
  child: MaterialApp(home: InspectionScreen(draftId: fixture.draftId)),
);

class _Fixture {
  const _Fixture(this.database, this.repository, this.draftId, this.container);

  final AppDatabase database;
  final InspectionRepository repository;
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
