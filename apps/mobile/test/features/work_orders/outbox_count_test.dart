import 'dart:async';

import 'package:drift/native.dart';
import 'package:fieldlens_mobile/database/app_database.dart';
import 'package:fieldlens_mobile/features/work_orders/work_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queue count emits initially and after a committed mutation', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = WorkRepository(db);
    await repository.seedFactoryDemo();
    final counts = StreamIterator(repository.watchPendingCount());
    addTearDown(counts.cancel);
    expect(await counts.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(counts.current, 0);
    await repository.setStatus(
      '40000000-0000-4000-8000-000000000001',
      'in_progress',
    );
    expect(await counts.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect(counts.current, 1);
    expect(await repository.pendingCount(), 1);
  });
}
