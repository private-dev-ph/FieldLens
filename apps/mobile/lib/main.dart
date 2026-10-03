import 'dart:async';

import 'package:fieldlens_mobile/app.dart';
import 'package:fieldlens_mobile/core/environment.dart';
import 'package:fieldlens_mobile/core/providers.dart';
import 'package:fieldlens_mobile/core/structured_log.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/camera/media_providers.dart';
import 'package:fieldlens_mobile/features/camera/media_repository.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:fieldlens_mobile/features/inspections/inspection_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootstrapApp());
}

class _BootstrapApp extends StatefulWidget {
  const _BootstrapApp();

  @override
  State<_BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<_BootstrapApp> {
  MediaRepository? _mediaRepository;
  AppDatabase? _database;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    unawaited(_database?.close());
    super.dispose();
  }

  Future<void> _load() async {
    AppDatabase? openedDatabase;
    try {
      final database = await openApplicationDatabase();
      openedDatabase = database;
      final repository = WorkRepository(database);
      if (AppEnvironment.demoEnabled) {
        await repository.seedFactoryDemo();
        await InspectionRepository(database).seedFactoryTemplate();
      }
      final mediaRepository = await openApplicationMediaRepository(database);
      if (!mounted) {
        await database.close();
        return;
      }
      setState(() {
        _database = database;
        _mediaRepository = mediaRepository;
        _error = null;
        _loading = false;
      });
    } catch (error, stackTrace) {
      await openedDatabase?.close();
      StructuredLog.error(
        'application_bootstrap_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final database = _database;
    if (database != null) {
      return ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          mediaRepositoryProvider.overrideWith((ref) => _mediaRepository!),
        ],
        child: const FieldLensApp(),
      );
    }

    return MaterialApp(
      title: 'FieldLens',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF155E75)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _loading
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Preparing local FieldLens data…'),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.storage_outlined, size: 48),
                      const SizedBox(height: 12),
                      Text(
                        'Could not prepare local data',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text('$_error', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
