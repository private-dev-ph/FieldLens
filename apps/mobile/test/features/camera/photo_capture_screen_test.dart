import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:fieldlens_mobile/features/camera/photo_capture_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets('captures one photo and returns its temporary file and time', (
    tester,
  ) async {
    final platform = _FakeCameraPlatform();
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);
    CapturedPhoto? captured;

    await tester.pumpWidget(_cameraApp(onResult: (value) => captured = value));
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    platform.completeInitialize();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
    );

    expect(platform.lastSettings?.enableAudio, isFalse);
    expect(platform.lastSettings?.resolutionPreset, ResolutionPreset.high);
    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.file.path, platform.photoPath);
    expect(captured!.capturedAt.isUtc, isTrue);
    expect(platform.takePictureCalls, 1);
  });

  testWidgets('capture failure can be retried', (tester) async {
    final platform = _FakeCameraPlatform()
      ..failNextCapture = true
      ..failWithCameraException = true;
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);
    CapturedPhoto? captured;

    await tester.pumpWidget(_cameraApp(onResult: (value) => captured = value));
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    platform.completeInitialize();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('photo-camera-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(captured, isNull);

    await tester.tap(find.byKey(const ValueKey('retry-photo-camera')));
    await _pumpUntil(tester, () => platform.initializeCalls == 2);
    expect(platform.disposeCalls, 1);
    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await tester.pumpAndSettle();

    expect(platform.takePictureCalls, 2);
    expect(captured, isNotNull);
  });

  testWidgets('duplicate taps do not start concurrent captures', (
    tester,
  ) async {
    final platform = _FakeCameraPlatform()..holdCapture = true;
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);

    await tester.pumpWidget(_cameraApp());
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    platform.completeInitialize();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await tester.pump();
    expect(platform.takePictureCalls, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('capture-photo')))
          .onPressed,
      isNull,
    );
    platform.completeCapture();
    await tester.pumpAndSettle();
    expect(platform.takePictureCalls, 1);
  });

  testWidgets('cancel releases camera while capture is still pending', (
    tester,
  ) async {
    final platform = _FakeCameraPlatform()..holdCapture = true;
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);
    CapturedPhoto? captured;

    await tester.pumpWidget(_cameraApp(onResult: (value) => captured = value));
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    platform.completeInitialize();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('capture-photo')));
    await tester.pump();
    expect(platform.takePictureCalls, 1);
    await tester.tap(find.byKey(const ValueKey('cancel-photo-capture')));
    await tester.pump();
    await _pumpUntil(tester, () => platform.disposeCalls == 1);
    expect(platform.disposeCalls, 1);

    platform.completeCapture();
    await tester.pumpAndSettle();
    expect(captured, isNull);
    expect(find.text('Open camera'), findsOneWidget);
  });

  testWidgets(
    'backgrounding during capture restarts camera and ignores stale result',
    (tester) async {
      final platform = _FakeCameraPlatform()..heldCaptureCalls.addAll([1, 2]);
      final originalPlatform = CameraPlatform.instance;
      CameraPlatform.instance = platform;
      addTearDown(() {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        CameraPlatform.instance = originalPlatform;
      });
      final capturedPhotos = <CapturedPhoto>[];

      await tester.pumpWidget(_cameraApp(onResult: capturedPhotos.add));
      await tester.tap(find.text('Open camera'));
      await tester.pump();
      await _pumpUntil(tester, () => platform.initializeCalls == 1);
      platform.completeInitialize();
      await _pumpUntil(
        tester,
        () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
      );

      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      await tester.pump();
      expect(platform.takePictureCalls, 1);

      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      await _pumpUntil(tester, () => platform.disposeCalls == 1);
      expect(platform.disposeCalls, 1);

      platform.holdCapture = false;
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await _pumpUntil(tester, () => platform.initializeCalls == 2);
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty &&
            tester
                    .widget<FilledButton>(
                      find.byKey(const ValueKey('capture-photo')),
                    )
                    .onPressed !=
                null,
      );

      await tester.tap(find.byKey(const ValueKey('capture-photo')));
      await tester.pump();
      expect(platform.takePictureCalls, 2);
      expect(capturedPhotos, isEmpty);

      platform.completeCapture(1);
      await tester.pump();
      expect(capturedPhotos, isEmpty);
      expect(find.byKey(const ValueKey('photo-capturing')), findsOneWidget);

      platform.completeCapture(2);
      await tester.pumpAndSettle();
      expect(capturedPhotos, hasLength(1));
      expect(capturedPhotos.single.file.path, '${platform.photoPath}-2');
    },
  );

  testWidgets('no camera reports unavailable and supports retry', (
    tester,
  ) async {
    final platform = _FakeCameraPlatform()..cameras = const [];
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);

    await tester.pumpWidget(_cameraApp());
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('photo-camera-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('Camera unavailable'), findsOneWidget);

    platform.cameras = [_FakeCameraPlatform.backCamera];
    await tester.tap(find.byKey(const ValueKey('retry-photo-camera')));
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    platform.completeInitialize();
    await _pumpUntil(
      tester,
      () => find.byKey(const ValueKey('capture-photo')).evaluate().isNotEmpty,
    );
  });

  testWidgets(
    'inactive lifecycle releases camera after delayed initialization',
    (tester) async {
      final platform = _FakeCameraPlatform()..holdInitialize = true;
      final originalPlatform = CameraPlatform.instance;
      CameraPlatform.instance = platform;
      addTearDown(() {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        CameraPlatform.instance = originalPlatform;
      });

      await tester.pumpWidget(_cameraApp());
      await tester.tap(find.text('Open camera'));
      await tester.pump();
      await _pumpUntil(tester, () => platform.initializeCalls == 1);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      platform.completeInitialize();
      await _pumpUntil(tester, () => platform.disposeCalls == 1);
      expect(platform.disposeCalls, 1);
    },
  );

  testWidgets('route pop during delayed initialization disposes camera', (
    tester,
  ) async {
    final platform = _FakeCameraPlatform()..holdInitialize = true;
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const PhotoCaptureScreen(),
                ),
              ),
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(tester, () => platform.initializeCalls == 1);
    await tester.tap(find.byKey(const ValueKey('cancel-photo-capture')));
    await tester.pump();
    platform.completeInitialize();
    await _pumpUntil(tester, () => platform.disposeCalls == 1);
    await tester.pumpAndSettle();
    expect(find.text('Open camera'), findsOneWidget);
    expect(platform.disposeCalls, 1);
  });

  testWidgets('camera permission error offers retry', (tester) async {
    final platform = _FakeCameraPlatform()..denyPermission = true;
    final originalPlatform = CameraPlatform.instance;
    CameraPlatform.instance = platform;
    addTearDown(() => CameraPlatform.instance = originalPlatform);

    await tester.pumpWidget(_cameraApp());
    await tester.tap(find.text('Open camera'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('photo-camera-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('Check camera permission'), findsOneWidget);
    expect(find.byKey(const ValueKey('retry-photo-camera')), findsOneWidget);
  });
}

Widget _cameraApp({ValueChanged<CapturedPhoto>? onResult}) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () async {
          final photo = await Navigator.of(context).push<CapturedPhoto>(
            MaterialPageRoute<CapturedPhoto>(
              builder: (_) => const PhotoCaptureScreen(),
            ),
          );
          if (photo != null) onResult?.call(photo);
        },
        child: const Text('Open camera'),
      ),
    ),
  ),
);

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
  }
  fail('Condition did not become true before timeout.');
}

class _FakeCameraPlatform extends CameraPlatform {
  static const backCamera = CameraDescription(
    name: 'fake-back-camera',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );

  List<CameraDescription> cameras = const [backCamera];
  bool holdInitialize = false;
  bool holdCapture = false;
  final Set<int> heldCaptureCalls = {};
  bool failNextCapture = false;
  bool failWithCameraException = false;
  bool denyPermission = false;
  int initializeCalls = 0;
  int takePictureCalls = 0;
  int disposeCalls = 0;
  MediaSettings? lastSettings;
  final String photoPath = '/tmp/fieldlens-camera-test.jpg';
  final Completer<void> _initializeGate = Completer<void>();
  final Map<int, Completer<void>> _captureGates = {};
  final Map<int, StreamController<CameraInitializedEvent>> _initialized = {};
  final Map<int, StreamController<CameraErrorEvent>> _errors = {};
  final StreamController<DeviceOrientationChangedEvent> _orientations =
      StreamController<DeviceOrientationChangedEvent>.broadcast();
  int _nextCameraId = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => cameras;

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    if (denyPermission) {
      throw CameraException('CameraAccessDenied', 'permission denied');
    }
    final id = _nextCameraId++;
    return id;
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    lastSettings = mediaSettings;
    return createCamera(
      cameraDescription,
      mediaSettings.resolutionPreset,
      enableAudio: mediaSettings.enableAudio,
    );
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    initializeCalls++;
    if (holdInitialize) await _initializeGate.future;
    _initialized[cameraId]!.add(
      CameraInitializedEvent(
        cameraId,
        640,
        480,
        ExposureMode.auto,
        false,
        FocusMode.auto,
        false,
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      (_initialized[cameraId] ??= StreamController.broadcast()).stream;

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      (_errors[cameraId] ??= StreamController.broadcast()).stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      _orientations.stream;

  @override
  Future<XFile> takePicture(int cameraId) async {
    takePictureCalls++;
    if (holdCapture || heldCaptureCalls.contains(takePictureCalls)) {
      await (_captureGates[takePictureCalls] ??= Completer<void>()).future;
    }
    if (failNextCapture) {
      failNextCapture = false;
      if (failWithCameraException) {
        throw CameraException('capture-failed', '');
      }
      throw PlatformException(code: 'capture-failed');
    }
    return XFile(
      takePictureCalls == 1 ? photoPath : '$photoPath-$takePictureCalls',
    );
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposeCalls++;
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);

  void completeInitialize() {
    if (!_initializeGate.isCompleted) _initializeGate.complete();
  }

  void completeCapture([int call = 1]) {
    final gate = _captureGates[call];
    if (gate != null && !gate.isCompleted) gate.complete();
  }
}
