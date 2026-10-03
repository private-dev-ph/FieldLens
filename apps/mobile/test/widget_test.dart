import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fieldlens_mobile/app.dart';
import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  testWidgets('renders assigned work from the local repository', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    await _pumpUntil(tester, find.text('No pending local changes'));

    final firstWorkOrder = fixture.workOrders.first;
    expect(find.text(firstWorkOrder.assetTag), findsOneWidget);
    expect(find.text(firstWorkOrder.assetType), findsOneWidget);
    expect(find.text(firstWorkOrder.siteName), findsWidgets);
    expect(find.text('Assigned'), findsWidgets);
    expect(find.text('No pending local changes'), findsOneWidget);
    expect(find.text('Synchronization is not configured yet'), findsOneWidget);
  });

  testWidgets('starting work updates the reactive local view', (tester) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final firstWorkOrder = fixture.workOrders.first;

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    final startButton = tester.widget<FilledButton>(
      find.byKey(ValueKey('start-${firstWorkOrder.id}')),
    );
    expect(startButton.onPressed, isNotNull);
    await tester.runAsync(() async {
      final transition = fixture.repository
          .watchAssignedWork()
          .firstWhere(
            (orders) => orders.any(
              (order) =>
                  order.id == firstWorkOrder.id &&
                  order.status == 'in_progress',
            ),
          )
          .timeout(const Duration(seconds: 5));
      startButton.onPressed!();
      expect(await transition, isNotEmpty);
      expect(await fixture.repository.pendingCount(), 1);
    });
    await _pumpUntil(tester, find.text('In Progress'));
    await _pumpUntil(tester, find.text('1 change queued locally'));
    await tester.pumpAndSettle();

    expect(find.text('In Progress'), findsOneWidget);
    expect(find.byKey(ValueKey('start-${firstWorkOrder.id}')), findsNothing);
    expect(find.text('1 change queued locally'), findsOneWidget);
    expect(await tester.runAsync(fixture.repository.pendingCount), 1);
  });

  testWidgets('shows the empty assignments state', (tester) async {
    final fixture = await _createFixture(tester, seed: false);
    _registerCleanup(tester, fixture);

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();

    expect(find.text('No assigned work'), findsOneWidget);
  });

  testWidgets('opens and persists an inspection draft from assigned work', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    final firstWorkOrder = fixture.workOrders.first;

    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();
    final inspectButton = tester.widget<OutlinedButton>(
      find.byKey(ValueKey('inspect-${firstWorkOrder.id}')),
    );
    expect(inspectButton.onPressed, isNotNull);
    await tester.runAsync(() async {
      final transition = fixture.repository
          .watchAssignedWork()
          .firstWhere(
            (orders) => orders.any(
              (order) =>
                  order.id == firstWorkOrder.id &&
                  order.status == 'in_progress',
            ),
          )
          .timeout(const Duration(seconds: 5));
      inspectButton.onPressed!();
      expect(await transition, isNotEmpty);
    });
    await _pumpUntil(tester, find.text('Factory asset inspection'));

    expect(find.text('Inspection draft'), findsOneWidget);
    expect(find.text('Factory asset inspection'), findsOneWidget);
    expect(find.text('Area is safe to inspect'), findsOneWidget);

    final draft = await tester.runAsync(() async {
      final repository = InspectionRepository(fixture.database);
      final view = await repository
          .watchDraft(
            (await fixture.database
                    .select(fixture.database.inspectionDrafts)
                    .getSingle())
                .id,
          )
          .first
          .timeout(const Duration(seconds: 5));
      expect(view.workOrderId, firstWorkOrder.id);
      final workOrder = await fixture.repository.watchAssignedWork().first;
      expect(
        workOrder.singleWhere((row) => row.id == firstWorkOrder.id).status,
        'in_progress',
      );
      expect(await fixture.repository.pendingCount(), greaterThanOrEqualTo(2));
      return view;
    });
    expect(draft!.template.title, 'Factory asset inspection');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2 changes queued locally'), findsOneWidget);
  });

  testWidgets('shows a useful message when assigned work cannot load', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        assignedWorkProvider.overrideWith(
          (ref) => Stream.error(StateError('local read failed')),
        ),
      ],
    );
    _registerCleanup(tester, fixture, additionalContainers: [container]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldLensApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not load assigned work'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('surfaces a failed local status update', (tester) async {
    final fixture = await _createFixture(tester);
    final failingRepository = _FailingStartRepository(fixture.database);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        workRepositoryProvider.overrideWithValue(failingRepository),
      ],
    );
    _registerCleanup(tester, fixture, additionalContainers: [container]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldLensApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('start-${fixture.workOrders.first.id}')),
    );
    await tester.runAsync(() => failingRepository.startAttempt.future);
    await tester.pumpAndSettle();

    expect(find.text('Could not start this work order.'), findsOneWidget);
    expect(
      find.byKey(ValueKey('start-${fixture.workOrders.first.id}')),
      findsOneWidget,
    );
  });
}

Future<_Fixture> _createFixture(WidgetTester tester, {bool seed = true}) async {
  final fixture = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fieldlens-widget-',
    );
    final database = AppDatabase(
      NativeDatabase.createInBackground(
        File(path.join(directory.path, 'fieldlens.sqlite')),
      ),
    );
    final repository = WorkRepository(database);
    if (seed) await repository.seedFactoryDemo();
    await InspectionRepository(database).seedFactoryTemplate();
    final workOrders = await repository.watchAssignedWork().first.timeout(
      const Duration(seconds: 5),
    );
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
    await container
        .read(assignedWorkProvider.future)
        .timeout(const Duration(seconds: 5));
    await container
        .read(pendingMutationCountProvider.future)
        .timeout(const Duration(seconds: 5));
    return _Fixture(database, directory, repository, workOrders, container);
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

Widget _createApp(_Fixture fixture) {
  return UncontrolledProviderScope(
    container: fixture.container,
    child: const FieldLensApp(),
  );
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 50 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}

class _Fixture {
  const _Fixture(
    this.database,
    this.directory,
    this.repository,
    this.workOrders,
    this.container,
  );

  final AppDatabase database;
  final Directory directory;
  final WorkRepository repository;
  final List<WorkOrderSummary> workOrders;
  final ProviderContainer container;
}

class _FailingStartRepository extends WorkRepository {
  _FailingStartRepository(super.db);

  final startAttempt = Completer<void>();

  @override
  Future<void> setStatus(String workOrderId, String status) async {
    if (!startAttempt.isCompleted) startAttempt.complete();
    throw StateError('simulated local write failure');
  }
}
