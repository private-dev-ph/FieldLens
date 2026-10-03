import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/assets/asset_identification_screen.dart';
import 'package:fieldlens_mobile/features/assets/asset_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as path;

void main() {
  testWidgets('serial search finds local asset and miss stays local', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-CTRL-0042',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    await _pumpUntil(tester, find.text('CTRL-0042'));
    expect(
      find.text('Control cabinet · Factory A\nAST-CTRL-0042'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'MISSING-999',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    await _pumpUntil(tester, find.byKey(const ValueKey('asset-search-empty')));
    expect(
      find.text('No local asset matches that identifier.'),
      findsOneWidget,
    );
  });

  testWidgets('serial search reports ambiguous local matches', (tester) async {
    final fixture = await _createFixture(tester, addDuplicateSerial: true);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-CTRL-0042',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    await _pumpUntil(
      tester,
      find.byKey(const ValueKey('asset-search-ambiguous')),
    );

    expect(
      find.byKey(
        const ValueKey('asset-result-30000000-0000-4000-8000-000000000001'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('asset-result-60000000-0000-4000-8000-000000000001'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('editing serial clears the previously selected asset', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-CTRL-0042',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    final assetResult = find.byKey(
      const ValueKey('asset-result-30000000-0000-4000-8000-000000000001'),
    );
    await _pumpUntil(tester, assetResult);
    await tester.tap(assetResult);
    await _pumpUntil(
      tester,
      find.byKey(
        const ValueKey('open-asset-work-40000000-0000-4000-8000-000000000001'),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-MOTOR-0018',
    );
    await tester.pump();

    expect(assetResult, findsNothing);
    expect(find.text('Assigned inspections'), findsNothing);
    expect(
      find.byKey(
        const ValueKey('open-asset-work-40000000-0000-4000-8000-000000000001'),
      ),
      findsNothing,
    );
  });

  testWidgets('QR known asset resolves from the local repository', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(
      _createApp(
        fixture,
        scanQr: (_) async => 'FIELDLENS://ASSET/AST-CTRL-0042',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan-asset-qr')));
    await _pumpUntil(tester, find.text('CTRL-0042'));

    expect(
      find.text('Control cabinet · Factory A\nAST-CTRL-0042'),
      findsOneWidget,
    );
    expect(find.text('Assigned inspections'), findsOneWidget);
  });

  testWidgets('QR unknown and malformed codes have distinct local messages', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    String? nextCode = 'FIELDLENS://ASSET/NO-SUCH-ASSET';
    await tester.pumpWidget(_createApp(fixture, scanQr: (_) async => nextCode));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan-asset-qr')));
    await _pumpUntil(tester, find.text('No local asset matches that QR code.'));

    nextCode = 'not a FieldLens QR';
    await tester.tap(find.byKey(const ValueKey('scan-asset-qr')));
    await _pumpUntil(
      tester,
      find.text('That QR code is not a supported asset identifier.'),
    );
  });

  testWidgets('QR collisions ask technician to select by serial and site', (
    tester,
  ) async {
    final fixture = await _createFixture(tester, addDuplicateQrAlias: true);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(
      _createApp(
        fixture,
        scanQr: (_) async => 'FIELDLENS://ASSET/AST-CTRL-0042',
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('scan-asset-qr')));
    await _pumpUntil(
      tester,
      find.text(
        'Multiple local assets match this QR code. Search by serial and select the correct site.',
      ),
    );
    expect(find.text('Assigned inspections'), findsNothing);
  });

  testWidgets('search and scan are serialized and scanner failures recover', (
    tester,
  ) async {
    final searchGate = Completer<List<AssetDetails>>();
    final fixture = await _createFixture(
      tester,
      assetRepositoryFactory: (database) =>
          _GatedAssetRepository(database, searchGate),
    );
    _registerCleanup(tester, fixture);
    var scanAttempts = 0;
    await tester.pumpWidget(
      _createApp(
        fixture,
        scanQr: (_) async {
          scanAttempts += 1;
          throw StateError('test scanner error');
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-CTRL-0042',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('asset-serial-input')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('scan-asset-qr')))
          .onPressed,
      isNull,
    );

    searchGate.complete([
      const AssetDetails(
        id: '30000000-0000-4000-8000-000000000001',
        serial: 'AST-CTRL-0042',
        assetTag: 'CTRL-0042',
        qrValue: 'FIELDLENS://ASSET/AST-CTRL-0042',
        assetType: 'Control cabinet',
        siteName: 'North Plant',
      ),
    ]);
    await _pumpUntil(tester, find.text('CTRL-0042'));
    expect(scanAttempts, 0);

    await tester.tap(find.byKey(const ValueKey('scan-asset-qr')));
    await _pumpUntil(
      tester,
      find.text('Could not scan or resolve a QR code on this device.'),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('search-asset-serial')),
          )
          .onPressed,
      isNotNull,
    );
    expect(scanAttempts, 1);
  });

  testWidgets('selected asset opens a durable assigned inspection', (
    tester,
  ) async {
    final fixture = await _createFixture(tester);
    _registerCleanup(tester, fixture);
    await tester.pumpWidget(_createApp(fixture));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('asset-serial-input')),
      'AST-CTRL-0042',
    );
    await tester.tap(find.byKey(const ValueKey('search-asset-serial')));
    final assetResult = find.byKey(
      const ValueKey('asset-result-30000000-0000-4000-8000-000000000001'),
    );
    await _pumpUntil(tester, assetResult);
    await tester.tap(assetResult);
    await _pumpUntil(
      tester,
      find.byKey(
        const ValueKey('open-asset-work-40000000-0000-4000-8000-000000000001'),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey('open-asset-work-40000000-0000-4000-8000-000000000001'),
      ),
    );
    await _pumpUntil(tester, find.text('Factory asset inspection'));

    expect(find.text('Inspection draft'), findsOneWidget);
    final draft = await tester.runAsync(() async {
      final row = await fixture.database
          .select(fixture.database.inspectionDrafts)
          .getSingle();
      final view = await fixture.inspections.watchDraft(row.id).first;
      return (
        draft: view,
        pendingCount: await fixture.workOrders.pendingCount(),
      );
    });
    expect(draft!.draft.workOrderId, '40000000-0000-4000-8000-000000000001');
    expect(draft.draft.template.title, 'Factory asset inspection');
    expect(draft.pendingCount, greaterThan(0));
  });

  testWidgets('inactive lifecycle stops after a delayed camera start', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = _DelayedScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      MobileScannerPlatform.instance = originalPlatform;
      MobileScannerController.resetPlatformSessionOwner();
      await platform.close();
    });

    await tester.pumpWidget(const MaterialApp(home: QRScannerScreen()));
    await _pumpScannerUntil(tester, () => platform.startCalls == 1);
    expect(platform.startOptions!.formats, [BarcodeFormat.qrCode]);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(platform.stopCalls, 0);

    platform.completeStart();
    await _pumpScannerUntil(tester, () => platform.stopCalls == 1);
    expect(platform.disposeCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpScannerUntil(tester, () => platform.disposeCalls == 1);
  });

  testWidgets('route pop defers native disposal until delayed start settles', (
    tester,
  ) async {
    final originalPlatform = MobileScannerPlatform.instance;
    final platform = _DelayedScannerPlatform();
    MobileScannerPlatform.instance = platform;
    addTearDown(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      MobileScannerPlatform.instance = originalPlatform;
      MobileScannerController.resetPlatformSessionOwner();
      await platform.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const QRScannerScreen(),
                ),
              ),
              child: const Text('Open scanner'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open scanner'));
    await _pumpScannerUntil(tester, () => platform.startCalls == 1);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cancel-qr-scan')));
    await tester.pumpAndSettle();
    expect(platform.disposeCalls, 0);

    platform.completeStart();
    await _pumpScannerUntil(tester, () => platform.disposeCalls == 1);
    expect(platform.stopCalls, 1);
  });
}

Widget _createApp(_Fixture fixture, {ScanQrCallback? scanQr}) =>
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp(home: AssetIdentificationScreen(scanQr: scanQr)),
    );

Future<_Fixture> _createFixture(
  WidgetTester tester, {
  bool addDuplicateSerial = false,
  bool addDuplicateQrAlias = false,
  AssetRepository Function(AppDatabase)? assetRepositoryFactory,
}) async {
  final fixture = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fieldlens-assets-widget-',
    );
    final database = AppDatabase(
      NativeDatabase.createInBackground(
        File(path.join(directory.path, 'fieldlens.sqlite')),
      ),
    );
    final workOrders = WorkRepository(database);
    final inspections = InspectionRepository(database);
    await workOrders.seedFactoryDemo();
    await inspections.seedFactoryTemplate();
    if (addDuplicateSerial) {
      await database
          .into(database.assets)
          .insert(
            AssetsCompanion.insert(
              id: '60000000-0000-4000-8000-000000000001',
              siteId: '20000000-0000-4000-8000-000000000002',
              serial: 'AST-CTRL-0042',
              assetTag: 'AST-CTRL-0042-DUP',
              qrValue: 'FIELDLENS://ASSET/AST-CTRL-0042-DUP',
              assetType: 'Spare control cabinet',
            ),
          );
    }
    if (addDuplicateQrAlias) {
      await database
          .into(database.assets)
          .insert(
            AssetsCompanion.insert(
              id: '70000000-0000-4000-8000-000000000001',
              siteId: '20000000-0000-4000-8000-000000000002',
              serial: 'AST-CTRL-ALIAS-0042',
              assetTag: 'CTRL-ALIAS-0042',
              qrValue: 'fieldlens://asset/AST-CTRL-0042',
              assetType: 'Control cabinet alias',
            ),
          );
    }
    final assetRepository =
        assetRepositoryFactory?.call(database) ?? AssetRepository(database);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        if (assetRepositoryFactory != null)
          assetRepositoryProvider.overrideWithValue(assetRepository),
      ],
    );
    await container
        .read(assignedWorkProvider.future)
        .timeout(const Duration(seconds: 5));
    await container
        .read(pendingMutationCountProvider.future)
        .timeout(const Duration(seconds: 5));
    return _Fixture(
      directory,
      database,
      assetRepository,
      workOrders,
      inspections,
      container,
    );
  });
  return fixture!;
}

class _GatedAssetRepository extends AssetRepository {
  _GatedAssetRepository(super.db, this.searchGate);

  final Completer<List<AssetDetails>> searchGate;

  @override
  Future<List<AssetDetails>> searchBySerial(String serial) => searchGate.future;
}

void _registerCleanup(WidgetTester tester, _Fixture fixture) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      fixture.container.dispose();
      await fixture.database.close();
      await fixture.directory.delete(recursive: true);
    });
  });
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

Future<void> _pumpScannerUntil(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue);
}

class _DelayedScannerPlatform extends MobileScannerPlatform {
  final _startCompleter = Completer<MobileScannerViewAttributes>();
  final _barcodes = StreamController<BarcodeCapture?>.broadcast();
  final _torch = StreamController<TorchState>.broadcast();
  final _zoom = StreamController<double>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  StartOptions? startOptions;

  @override
  Stream<BarcodeCapture?> get barcodesStream => _barcodes.stream;

  @override
  Stream<TorchState> get torchStateStream => _torch.stream;

  @override
  Stream<double> get zoomScaleStateStream => _zoom.stream;

  @override
  Widget buildCameraView() => const SizedBox.shrink();

  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) {
    startCalls += 1;
    startOptions = options;
    return _startCompleter.future;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
  }

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
  }

  void completeStart() {
    _startCompleter.complete(
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(640, 480),
        numberOfCameras: 1,
      ),
    );
  }

  Future<void> close() async {
    await _barcodes.close();
    await _torch.close();
    await _zoom.close();
  }
}

class _Fixture {
  const _Fixture(
    this.directory,
    this.database,
    this.assets,
    this.workOrders,
    this.inspections,
    this.container,
  );

  final Directory directory;
  final AppDatabase database;
  final AssetRepository assets;
  final WorkRepository workOrders;
  final InspectionRepository inspections;
  final ProviderContainer container;
}
