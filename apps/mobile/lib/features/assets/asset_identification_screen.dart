import 'dart:async';

import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/core/structured_log.dart';
import 'package:fieldlens_mobile/features/assets/asset_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

typedef ScanQrCallback = Future<String?> Function(BuildContext context);

final assetRepositoryProvider = Provider<AssetRepository>((ref) {
  return AssetRepository(ref.watch(appDatabaseProvider));
});

class AssetIdentificationScreen extends ConsumerStatefulWidget {
  const AssetIdentificationScreen({this.scanQr, super.key});

  /// Allows tests to inject a scan result without claiming native camera tests.
  final ScanQrCallback? scanQr;

  @override
  ConsumerState<AssetIdentificationScreen> createState() =>
      _AssetIdentificationScreenState();
}

class _AssetIdentificationScreenState
    extends ConsumerState<AssetIdentificationScreen> {
  final _serialController = TextEditingController();
  final Set<String> _openingInspectionIds = {};
  List<AssetDetails>? _matches;
  AssetDetails? _selectedAsset;
  String? _statusMessage;
  bool _searching = false;
  bool _resolvingQr = false;
  bool get _identifying => _searching || _resolvingQr;

  @override
  void dispose() {
    _serialController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final assignedWork = ref.watch(assignedWorkProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Identify asset')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Asset information is searched on this device.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('asset-serial-input'),
              controller: _serialController,
              enabled: !_identifying,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Serial number',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_matches == null &&
                    _selectedAsset == null &&
                    _statusMessage == null) {
                  return;
                }
                setState(() {
                  _matches = null;
                  _selectedAsset = null;
                  _statusMessage = null;
                });
              },
              onSubmitted: (_) => _searchSerial(),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('search-asset-serial'),
              onPressed: _identifying ? null : _searchSerial,
              icon: const Icon(Icons.search),
              label: Text(_searching ? 'Searching locally…' : 'Search locally'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('scan-asset-qr'),
              onPressed: _identifying ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(_resolvingQr ? 'Resolving code…' : 'Scan QR code'),
            ),
            if (_statusMessage case final message?) ...[
              const SizedBox(height: 12),
              Text(
                message,
                key: const ValueKey('asset-identification-message'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_matches case final matches?) ...[
              const SizedBox(height: 16),
              if (matches.isEmpty)
                const Text(
                  'No local asset matches that identifier.',
                  key: ValueKey('asset-search-empty'),
                )
              else if (matches.length > 1)
                const Text(
                  'More than one local asset matches. Select the correct asset.',
                  key: ValueKey('asset-search-ambiguous'),
                ),
              for (final asset in matches)
                _AssetCard(
                  asset: asset,
                  selected: _selectedAsset?.id == asset.id,
                  onTap: () => setState(() {
                    _selectedAsset = asset;
                    _statusMessage = null;
                  }),
                ),
            ],
            if (_selectedAsset case final asset?) ...[
              const SizedBox(height: 16),
              Text(
                'Assigned inspections',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              assignedWork.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, stackTrace) => const Text(
                  'Could not load assigned work from this device.',
                  key: ValueKey('asset-work-orders-error'),
                ),
                data: (workOrders) {
                  final assetWorkOrders = workOrders
                      .where((workOrder) => workOrder.assetId == asset.id)
                      .toList(growable: false);
                  if (assetWorkOrders.isEmpty) {
                    return const Text(
                      'No assigned inspection is available for this asset.',
                      key: ValueKey('asset-no-assigned-work'),
                    );
                  }
                  return Column(
                    children: [
                      for (final workOrder in assetWorkOrders)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.tonalIcon(
                              key: ValueKey('open-asset-work-${workOrder.id}'),
                              onPressed:
                                  _openingInspectionIds.contains(workOrder.id)
                                  ? null
                                  : () => _openInspection(workOrder.id),
                              icon: const Icon(Icons.assignment_outlined),
                              label: const Text('Open assigned inspection'),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _searchSerial() async {
    final serial = _serialController.text.trim();
    if (serial.isEmpty || _identifying) return;
    setState(() {
      _searching = true;
      _statusMessage = null;
      _selectedAsset = null;
      _matches = null;
    });

    try {
      final matches = await ref
          .read(assetRepositoryProvider)
          .searchBySerial(serial);
      if (!mounted) return;
      setState(() => _matches = matches);
    } catch (error, stackTrace) {
      StructuredLog.error(
        'asset_serial_search_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _matches = null;
          _statusMessage = 'Could not search this device for that serial.';
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _scanQr() async {
    if (_identifying) return;
    setState(() {
      _resolvingQr = true;
      _statusMessage = null;
      _selectedAsset = null;
      _matches = null;
    });
    try {
      final rawValue =
          await (widget.scanQr?.call(context) ??
              Navigator.of(context).push<String>(
                MaterialPageRoute<String>(
                  builder: (_) => const QRScannerScreen(),
                ),
              ));
      if (!mounted || rawValue == null) return;
      final asset = await ref.read(assetRepositoryProvider).resolveQr(rawValue);
      if (!mounted) return;
      if (asset == null) {
        setState(() {
          _matches = const [];
          _statusMessage = 'No local asset matches that QR code.';
        });
      } else {
        setState(() {
          _matches = [asset];
          _selectedAsset = asset;
          _serialController.text = asset.serial;
        });
      }
    } on AmbiguousAssetQr catch (error) {
      StructuredLog.warning(
        'asset_qr_ambiguous',
        fields: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        setState(() {
          _matches = null;
          _selectedAsset = null;
          _statusMessage =
              'Multiple local assets match this QR code. Search by serial and select the correct site.';
        });
      }
    } on FormatException catch (error) {
      StructuredLog.warning(
        'asset_qr_format_invalid',
        fields: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        setState(() {
          _matches = null;
          _statusMessage = 'That QR code is not a supported asset identifier.';
        });
      }
    } catch (error, stackTrace) {
      StructuredLog.error(
        'asset_qr_resolution_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _matches = null;
          _statusMessage =
              'Could not scan or resolve a QR code on this device.';
        });
      }
    } finally {
      if (mounted) setState(() => _resolvingQr = false);
    }
  }

  Future<void> _openInspection(String workOrderId) async {
    if (!_openingInspectionIds.add(workOrderId)) return;
    setState(() {});
    try {
      final draftId = await ref
          .read(inspectionRepositoryProvider)
          .beginDraft(workOrderId);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => InspectionScreen(draftId: draftId),
        ),
      );
    } catch (error, stackTrace) {
      StructuredLog.error(
        'asset_inspection_open_failed',
        error: error,
        stackTrace: stackTrace,
        fields: {'workOrderId': workOrderId},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this inspection.')),
        );
      }
    } finally {
      _openingInspectionIds.remove(workOrderId);
      if (mounted) setState(() {});
    }
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final AssetDetails asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        key: ValueKey('asset-result-${asset.id}'),
        onTap: onTap,
        title: Text(asset.assetTag),
        subtitle: Text(
          '${asset.assetType} · ${asset.siteName}\n${asset.serial}',
        ),
        isThreeLine: true,
        trailing: selected ? const Icon(Icons.check_circle) : null,
      ),
    );
  }
}

/// The scanner owns its controller internally, so mobile_scanner pauses and
/// resumes it with app lifecycle changes and disposes it when this route leaves.
class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen>
    with WidgetsBindingObserver {
  final _scannerController = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  final _manualCodeController = TextEditingController();
  bool _returnedCode = false;
  bool _shouldRunCamera = true;
  bool _cameraDisposeRequested = false;
  bool _cameraDisposed = false;
  Future<void> _cameraOperations = Future<void>.value();

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _shouldRunCamera =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reconcileCamera());
  }

  @override
  void dispose() {
    _returnedCode = true;
    WidgetsBinding.instance.removeObserver(this);
    _manualCodeController.dispose();
    _disposeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _returnedCode = true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Scan asset QR code'),
          actions: [
            IconButton(
              key: const ValueKey('cancel-qr-scan'),
              tooltip: 'Cancel scan',
              onPressed: _cancelScan,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: MobileScanner(
                controller: _scannerController,
                useAppLifecycleState: false,
                onDetect: _onDetect,
                onDetectError: (error, stackTrace) => StructuredLog.error(
                  'asset_qr_detection_failed',
                  error: error,
                  stackTrace: stackTrace,
                ),
                errorBuilder: (context, error) => _ScannerFallback(
                  controller: _manualCodeController,
                  message: _scannerErrorMessage(error),
                  onSubmit: _submitManualCode,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'Point the camera at an asset QR code. The code is resolved from this device’s local asset data.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _shouldRunCamera = true;
        _reconcileCamera();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _shouldRunCamera = false;
        _reconcileCamera();
    }
  }

  void _disposeCamera() {
    _cameraDisposeRequested = true;
    _shouldRunCamera = false;
    _reconcileCamera();
  }

  void _reconcileCamera() {
    _cameraOperations = _cameraOperations.then((_) => _applyCameraState());
    unawaited(_cameraOperations);
  }

  Future<void> _applyCameraState() async {
    if (_cameraDisposed) return;
    try {
      if (_cameraDisposeRequested) {
        if (_scannerController.value.isRunning) {
          await _scannerController.stop();
        }
        await _scannerController.dispose();
        _cameraDisposed = true;
        return;
      }

      if (_shouldRunCamera) {
        if (!_scannerController.value.isRunning &&
            !_scannerController.value.isStarting) {
          await _scannerController.start();
        }
        // Lifecycle or route state may change while start waits for camera
        // permission or native initialization. Reconcile that newer intent
        // only after the in-flight start has settled.
        if ((!_shouldRunCamera || _cameraDisposeRequested) &&
            _scannerController.value.isRunning) {
          await _scannerController.stop();
        }
      } else if (_scannerController.value.isRunning) {
        await _scannerController.stop();
      }
    } catch (error, stackTrace) {
      StructuredLog.error(
        _cameraDisposeRequested
            ? 'asset_qr_camera_dispose_failed'
            : _shouldRunCamera
            ? 'asset_qr_camera_start_failed'
            : 'asset_qr_camera_stop_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (_cameraDisposeRequested && !_cameraDisposed) {
        try {
          await _scannerController.dispose();
          _cameraDisposed = true;
        } catch (disposeError, disposeStackTrace) {
          StructuredLog.error(
            'asset_qr_camera_dispose_failed',
            error: disposeError,
            stackTrace: disposeStackTrace,
          );
        }
      }
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_returnedCode) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.trim().isEmpty) continue;
      _returnCode(value);
      return;
    }
  }

  void _submitManualCode() {
    final value = _manualCodeController.text;
    if (value.trim().isNotEmpty) _returnCode(value);
  }

  void _returnCode(String value) {
    if (_returnedCode || !mounted) return;
    _returnedCode = true;
    Navigator.of(context).pop(value);
  }

  void _cancelScan() {
    if (_returnedCode || !mounted) return;
    _returnedCode = true;
    Navigator.of(context).pop();
  }

  String _scannerErrorMessage(MobileScannerException error) {
    StructuredLog.warning(
      'asset_qr_camera_unavailable',
      fields: {'errorCode': error.errorCode.name},
    );
    return 'The camera could not start. Enter the QR code value below or cancel and search by serial number.';
  }
}

class _ScannerFallback extends StatelessWidget {
  const _ScannerFallback({
    required this.controller,
    required this.message,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String message;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('manual-qr-code-input'),
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'QR code value',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey('use-manual-qr-code'),
              onPressed: onSubmit,
              child: const Text('Use code'),
            ),
          ],
        ),
      ),
    );
  }
}
