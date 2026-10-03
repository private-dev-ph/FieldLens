import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:fieldlens_mobile/features/camera/file_system_media_store.dart';

void main() {
  const mediaId = '10000000-0000-4000-8000-000000000001';
  late Directory root;
  late FileSystemMediaStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fieldlens_media_test_');
    store = FileSystemMediaStore(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'preserves JPEG bytes and records dimensions and verified hashes',
    () async {
      final bytes = _jpeg(512, 256, image.ColorRgb8(32, 110, 210));

      final stored = await store.writePhoto(mediaId, bytes);

      expect(await store.originalFile(mediaId).readAsBytes(), bytes);
      expect(stored.originalPath, '$mediaId/original.jpg');
      expect(stored.thumbnailPath, '$mediaId/thumbnail.jpg');
      expect(stored.mimeType, 'image/jpeg');
      expect(stored.byteLength, bytes.length);
      expect(stored.sha256, sha256.convert(bytes).toString());
      final thumbnailBytes = await store.thumbnailFile(mediaId).readAsBytes();
      expect(stored.thumbnailByteLength, thumbnailBytes.length);
      expect(stored.thumbnailSha256, sha256.convert(thumbnailBytes).toString());
      final thumbnail = image.decodeJpg(thumbnailBytes)!;
      expect(thumbnail.width, 256);
      expect(thumbnail.height, 128);
    },
  );

  test(
    'bakes EXIF orientation into the thumbnail and reports source dimensions',
    () async {
      final source = image.Image(width: 512, height: 256);
      image.fill(source, color: image.ColorRgb8(20, 120, 40));
      source.exif.imageIfd.orientation = 6;
      final bytes = Uint8List.fromList(image.encodeJpg(source, quality: 90));

      final stored = await store.writePhoto(mediaId, bytes);
      final thumbnail = image.decodeJpg(
        await store.thumbnailFile(mediaId).readAsBytes(),
      )!;

      expect(stored.width, 512);
      expect(stored.height, 256);
      expect(thumbnail.width, 128);
      expect(thumbnail.height, 256);
      expect(thumbnail.exif.imageIfd.orientation, anyOf(isNull, 1));
    },
  );

  test(
    'same UUID and same bytes safely replay; different bytes are refused',
    () async {
      final bytes = _jpeg(64, 32, image.ColorRgb8(1, 2, 3));
      final first = await store.writePhoto(mediaId, bytes);
      final replay = await store.writePhoto(mediaId, bytes);
      expect(replay.sha256, first.sha256);
      expect(replay.thumbnailSha256, first.thumbnailSha256);

      final different = _jpeg(64, 32, image.ColorRgb8(4, 5, 6));
      await expectLater(store.writePhoto(mediaId, different), throwsStateError);
      expect(await store.originalFile(mediaId).readAsBytes(), bytes);
    },
  );

  test(
    'root initialization can recover after the root becomes a directory',
    () async {
      final invalidRoot = File('${root.path}/media-root');
      await invalidRoot.writeAsString('blocks directory creation');
      final retryingStore = FileSystemMediaStore(Directory(invalidRoot.path));
      final bytes = _jpeg(40, 20, image.ColorRgb8(12, 34, 56));

      await expectLater(
        retryingStore.writePhoto(mediaId, bytes),
        throwsStateError,
      );

      await invalidRoot.delete();
      await Directory(invalidRoot.path).create();
      final stored = await retryingStore.writePhoto(mediaId, bytes);

      expect(await retryingStore.originalFile(mediaId).readAsBytes(), bytes);
      expect(stored.sha256, sha256.convert(bytes).toString());
    },
  );

  test(
    'recovery repairs a missing or corrupt thumbnail after restart',
    () async {
      final bytes = _jpeg(320, 180, image.ColorRgb8(70, 90, 120));
      final originalMetadata = await store.writePhoto(mediaId, bytes);
      await store.thumbnailFile(mediaId).delete();

      final restartedStore = FileSystemMediaStore(root);
      final recovered = await restartedStore.recoverPhoto(mediaId);
      expect(recovered?.sha256, originalMetadata.sha256);
      expect(await restartedStore.thumbnailFile(mediaId).exists(), isTrue);
      final repairedBytes = await restartedStore
          .thumbnailFile(mediaId)
          .readAsBytes();
      expect(
        recovered?.thumbnailSha256,
        sha256.convert(repairedBytes).toString(),
      );

      await restartedStore.thumbnailFile(mediaId).writeAsBytes([1, 2, 3]);
      final repairedAgain = await restartedStore.recoverPhoto(mediaId);
      expect(repairedAgain?.thumbnailSha256, recovered?.thumbnailSha256);
      expect(
        image.decodeJpg(
          await restartedStore.thumbnailFile(mediaId).readAsBytes(),
        ),
        isNotNull,
      );
    },
  );

  test(
    'recovery repairs an oversized thumbnail without changing original',
    () async {
      final originalBytes = _jpeg(640, 360, image.ColorRgb8(32, 68, 104));
      final stored = await store.writePhoto(mediaId, originalBytes);
      await store
          .thumbnailFile(mediaId)
          .writeAsBytes(Uint8List(FileSystemMediaStore.maxPhotoBytes + 1));

      final recovered = await FileSystemMediaStore(root).recoverPhoto(mediaId);

      expect(recovered?.sha256, stored.sha256);
      expect(await store.originalFile(mediaId).readAsBytes(), originalBytes);
      final repairedThumbnail = await store
          .thumbnailFile(mediaId)
          .readAsBytes();
      expect(recovered?.thumbnailByteLength, repairedThumbnail.length);
      expect(repairedThumbnail.length, lessThan(1024 * 1024));
      expect(
        recovered?.thumbnailSha256,
        sha256.convert(repairedThumbnail).toString(),
      );
    },
  );

  test('recovery ignores temporary-only and corrupt originals', () async {
    final idDirectory = Directory('${root.path}/$mediaId');
    await idDirectory.create();
    await File(
      '${idDirectory.path}/.original.pending.tmp',
    ).writeAsBytes(_jpeg(20, 20, image.ColorRgb8(0, 0, 0)));
    expect(await store.recoverPhoto(mediaId), isNull);

    await File(
      '${idDirectory.path}/original.jpg',
    ).writeAsBytes([0xff, 0xd8, 0, 0]);
    expect(await store.recoverPhoto(mediaId), isNull);
  });

  test(
    'recovery rejects oversized originals before reading their contents',
    () async {
      final idDirectory = Directory('${root.path}/$mediaId');
      await idDirectory.create();
      final oversizedOriginal = File('${idDirectory.path}/original.jpg');
      await oversizedOriginal.writeAsBytes(
        Uint8List(FileSystemMediaStore.maxPhotoBytes + 1),
      );

      expect(await store.recoverPhoto(mediaId), isNull);
      expect(await store.thumbnailFile(mediaId).exists(), isFalse);
    },
  );

  test(
    'rejects empty, non-JPEG, corrupt, oversized, and excessive-pixel inputs',
    () async {
      await expectLater(
        store.writePhoto(mediaId, Uint8List(0)),
        throwsFormatException,
      );
      await expectLater(
        store.writePhoto(mediaId, Uint8List.fromList([1, 2, 3, 4])),
        throwsFormatException,
      );
      await expectLater(
        store.writePhoto(mediaId, Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9])),
        throwsFormatException,
      );
      await expectLater(
        store.writePhoto(
          mediaId,
          Uint8List.fromList([0xff, 0xd8, 0xff, 0xc0, 0xff]),
        ),
        throwsFormatException,
      );
      await expectLater(
        store.writePhoto(
          mediaId,
          Uint8List(FileSystemMediaStore.maxPhotoBytes + 1),
        ),
        throwsFormatException,
      );

      final excessivePixelJpeg = _withJpegDimensions(
        _jpeg(4, 4, image.ColorRgb8(8, 9, 10)),
        5000,
        5000,
      );
      await expectLater(
        store.writePhoto(mediaId, excessivePixelJpeg),
        throwsFormatException,
      );
      expect(await store.originalFile(mediaId).exists(), isFalse);
    },
  );

  test('UUID paths reject traversal and non-UUID identifiers', () async {
    const invalidIds = [
      '../outside',
      'not-a-uuid',
      '',
      '10000000-0000-4000-8000-000000000001/..',
    ];
    for (final id in invalidIds) {
      expect(() => store.originalFile(id), throwsArgumentError);
      await expectLater(store.recoverPhoto(id), throwsArgumentError);
    }
  });

  test('symbolic links cannot redirect a media UUID directory', () async {
    if (Platform.isWindows) return;
    final outside = await Directory.systemTemp.createTemp(
      'fieldlens_media_outside_',
    );
    addTearDown(() async => outside.delete(recursive: true));
    await Link('${root.path}/$mediaId').create(outside.path);

    await expectLater(
      store.writePhoto(mediaId, _jpeg(10, 10, image.ColorRgb8(1, 1, 1))),
      throwsStateError,
    );
  });
}

Uint8List _jpeg(int width, int height, image.Color color) {
  final source = image.Image(width: width, height: height);
  image.fill(source, color: color);
  return Uint8List.fromList(image.encodeJpg(source, quality: 90));
}

Uint8List _withJpegDimensions(Uint8List source, int width, int height) {
  final bytes = Uint8List.fromList(source);
  var offset = 2;
  while (offset + 8 < bytes.length) {
    while (bytes[offset] == 0xff) {
      offset++;
    }
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) break;
    if (marker == 0xd8 ||
        marker == 0x01 ||
        (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (const {
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    }.contains(marker)) {
      bytes[offset + 3] = (height >> 8) & 0xff;
      bytes[offset + 4] = height & 0xff;
      bytes[offset + 5] = (width >> 8) & 0xff;
      bytes[offset + 6] = width & 0xff;
      return bytes;
    }
    offset += segmentLength;
  }
  throw StateError('Generated JPEG has no start-of-frame marker');
}
