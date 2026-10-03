import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../core/providers.dart';
import '../../database/app_database.dart';
import 'file_system_media_store.dart';
import 'media_repository.dart';

Future<MediaRepository> openApplicationMediaRepository(AppDatabase db) async {
  final support = await getApplicationSupportDirectory();
  final files = FileSystemMediaStore(
    Directory(path.join(support.path, 'media')),
  );
  final repository = MediaRepository(db, files);
  await repository.recoverPending();
  return repository;
}

final mediaRepositoryProvider = FutureProvider<MediaRepository>((ref) {
  return openApplicationMediaRepository(ref.watch(appDatabaseProvider));
});

final inspectionMediaProvider =
    StreamProvider.family<List<MediaRecord>, String>((ref, draftId) async* {
      final repository = await ref.watch(mediaRepositoryProvider.future);
      yield* repository.watchForDraft(draftId);
    });
