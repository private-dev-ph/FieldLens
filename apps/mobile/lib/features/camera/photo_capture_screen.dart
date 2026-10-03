import 'dart:async';

import 'package:camera/camera.dart';
import 'package:fieldlens_mobile/core/structured_log.dart';
import 'package:flutter/material.dart';

/// A camera capture that remains temporary until its caller imports it.
class CapturedPhoto {
  const CapturedPhoto({required this.file, required this.capturedAt});

  final XFile file;
  final DateTime capturedAt;
}

class PhotoCaptureScreen extends StatefulWidget {
  const PhotoCaptureScreen({super.key});

  @override
  State<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _PhotoCaptureScreenState extends State<PhotoCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _cameraOperations = Future<void>.value();
  bool _shouldRunCamera = true;
  bool _returnedPhoto = false;
  bool _capturing = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _shouldRunCamera =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_reconcileCamera());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _shouldRunCamera = state == AppLifecycleState.resumed;
    unawaited(_reconcileCamera());
  }

  @override
  void dispose() {
    _returnedPhoto = true;
    _shouldRunCamera = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_reconcileCamera());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final initialized = controller?.value.isInitialized ?? false;

    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _stopForPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Capture photo'),
          actions: [
            IconButton(
              key: const ValueKey('cancel-photo-capture'),
              tooltip: 'Cancel photo capture',
              onPressed: _cancel,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: _cameraError != null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.no_photography_outlined,
                                  color: Colors.white,
                                  size: 40,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _cameraError!,
                                  key: const ValueKey('photo-camera-error'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  key: const ValueKey('retry-photo-camera'),
                                  onPressed: _retryCamera,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry camera'),
                                ),
                              ],
                            ),
                          )
                        : initialized
                        ? CameraPreview(controller!)
                        : const CircularProgressIndicator(
                            key: ValueKey('photo-camera-loading'),
                            color: Colors.white,
                          ),
                  ),
                ),
              ),
              if (_cameraError == null) ...[
                if (_capturing)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Capturing photo…',
                      key: ValueKey('photo-capturing'),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const ValueKey('capture-photo'),
                      onPressed: initialized && !_capturing
                          ? _capturePhoto
                          : null,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Capture photo'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reconcileCamera() {
    final operation = _cameraOperations.then((_) => _applyCameraState());
    _cameraOperations = operation.catchError((Object error, StackTrace stack) {
      StructuredLog.error(
        'photo_camera_lifecycle_failed',
        error: error,
        stackTrace: stack,
      );
    });
    return _cameraOperations;
  }

  Future<void> _applyCameraState() async {
    if (!_shouldRunCamera || _returnedPhoto) {
      await _disposeController();
      return;
    }
    if (_controller != null) return;

    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!_shouldRunCamera || _returnedPhoto) return;
      if (cameras.isEmpty) {
        throw CameraException('NoCamerasAvailable', '');
      }
      final camera = cameras.firstWhere(
        (candidate) => candidate.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      _controller = controller;
      await controller.initialize();
      if (!_shouldRunCamera || _returnedPhoto || !mounted) {
        await _disposeController();
      } else {
        setState(() => _cameraError = null);
      }
    } catch (error) {
      if (controller != null) {
        if (identical(_controller, controller)) _controller = null;
        await _disposeControllerInstance(controller);
      }
      StructuredLog.warning(
        'photo_camera_initialization_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      if (mounted && _shouldRunCamera && !_returnedPhoto) {
        setState(() {
          _cameraError =
              'Camera unavailable. Check camera permission or try again.';
        });
      }
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    _capturing = false;
    if (controller == null) return;
    if (mounted) setState(() {});
    await _disposeControllerInstance(controller);
  }

  Future<void> _disposeControllerInstance(CameraController controller) async {
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      StructuredLog.error(
        'photo_camera_dispose_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _retryCamera() async {
    if (!mounted || _returnedPhoto || !_shouldRunCamera) return;
    setState(() => _cameraError = null);
    await _reconcileCamera();
  }

  Future<void> _capturePhoto() async {
    final controller = _controller;
    if (_capturing ||
        _returnedPhoto ||
        !_shouldRunCamera ||
        !mounted ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    setState(() {
      _capturing = true;
      _cameraError = null;
    });
    try {
      final capturedAt = DateTime.now().toUtc();
      final capture = controller.takePicture();
      final file = await capture;
      if (!mounted ||
          _returnedPhoto ||
          !_shouldRunCamera ||
          !identical(_controller, controller)) {
        return;
      }
      _returnedPhoto = true;
      _shouldRunCamera = false;
      unawaited(_reconcileCamera());
      Navigator.of(
        context,
      ).pop(CapturedPhoto(file: file, capturedAt: capturedAt));
    } catch (error, stackTrace) {
      StructuredLog.error(
        'photo_capture_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted &&
          !_returnedPhoto &&
          _shouldRunCamera &&
          identical(_controller, controller)) {
        _controller = null;
        setState(() {
          _capturing = false;
          _cameraError =
              'The photo could not be captured. Try again when the camera is ready.';
        });
        await _disposeControllerInstance(controller);
      }
    } finally {
      if (!_shouldRunCamera || _returnedPhoto) {
        unawaited(_reconcileCamera());
      }
    }
  }

  void _stopForPop() {
    _returnedPhoto = true;
    _shouldRunCamera = false;
    unawaited(_reconcileCamera());
  }

  void _cancel() {
    if (_returnedPhoto || !mounted) return;
    _stopForPop();
    Navigator.of(context).pop();
  }
}
