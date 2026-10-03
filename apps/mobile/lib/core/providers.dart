import 'dart:io';

import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:drift/native.dart';

/// The database is supplied during application bootstrap and is overrideable
/// for tests.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw StateError('AppDatabase must be supplied to ProviderScope.');
});

final workRepositoryProvider = Provider<WorkRepository>((ref) {
  return WorkRepository(ref.watch(appDatabaseProvider));
});

final assignedWorkProvider = StreamProvider<List<WorkOrderSummary>>((ref) {
  return ref.watch(workRepositoryProvider).watchAssignedWork();
});

final pendingMutationCountProvider = StreamProvider<int>((ref) {
  return ref.watch(workRepositoryProvider).watchPendingCount();
});

/// Opens the persistent local database used by the mobile application.
Future<AppDatabase> openApplicationDatabase() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final databaseFile = File(
    path.join(supportDirectory.path, 'fieldlens.sqlite'),
  );
  return AppDatabase(NativeDatabase.createInBackground(databaseFile));
}
