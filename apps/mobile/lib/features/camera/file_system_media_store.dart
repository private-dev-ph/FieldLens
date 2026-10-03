import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'media_file_store.dart';

/// Stores captured JPEG evidence under a caller-provided app-private root.
///
/// Each media UUID owns one directory containing `original.jpg` and
/// `thumbnail.jpg`. File data is flushed to a same-directory temporary file
/// before an atomic rename makes it visible at its final path.
class FileSystemMediaStore implements MediaFileStore {
  FileSystemMediaStore(Directory rootDirectory)
    : _requestedRootPath = p.normalize(p.absolute(rootDirectory.path));

  static const int maxPhotoBytes = 24 * 1024 * 1024;
  static const int maxPhotoPixels = 20 * 1000 * 1000;
  static const int thumbnailLongestEdge = 256;
  static const int thumbnailQuality = 75;

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static const _uuid = Uuid();

  final String _requestedRootPath;
  Future<String>? _rootPathFuture;
  final Map<String, Future<void>> _locks = {};

  @override
  File originalFile(String mediaId) =>
      File(p.join(_requestedRootPath, _validatedId(mediaId), 'original.jpg'));

  @override
  File thumbnailFile(String mediaId) =>
      File(p.join(_requestedRootPath, _validatedId(mediaId), 'thumbnail.jpg'));

  @override
  Future<StoredPhoto> writePhoto(String mediaId, Uint8List bytes) async {
    final id = _validatedId(mediaId);
    if (bytes.isEmpty) throw const FormatException('Photo is empty');
    if (bytes.length > maxPhotoBytes) {
      throw const FormatException('Photo exceeds the 24 MiB size limit');
    }
    final originalBytes = Uint8List.fromList(bytes);

    return _withLock(id, () async {
      final processed = await _processInIsolate(originalBytes);
      final directory = (await _mediaDirectory(id, create: true))!;
      final original = File(p.join(directory.path, 'original.jpg'));
      final thumbnail = File(p.join(directory.path, 'thumbnail.jpg'));

      if (await _assertRegularOrAbsent(original)) {
        if (await original.length() != originalBytes.length) {
          throw StateError('Evidence UUID already contains different bytes');
        }
        final existingBytes = await original.readAsBytes();
        if (!_sameBytes(existingBytes, originalBytes)) {
          throw StateError('Evidence UUID already contains different bytes');
        }
        await _atomicWrite(
          directory,
          'thumbnail.jpg',
          processed.thumbnailBytes,
          replace: true,
        );
        return _metadata(
          id,
          originalBytes,
          processed.thumbnailBytes,
          processed,
        );
      }

      await _assertRegularOrAbsent(thumbnail);
      // Commit the derived file first. If interrupted before the original
      // rename, recovery ignores the thumbnail because no durable original
      // exists. Once the original appears, both files are complete.
      await _atomicWrite(
        directory,
        'thumbnail.jpg',
        processed.thumbnailBytes,
        replace: true,
      );
      await _atomicWrite(
        directory,
        'original.jpg',
        originalBytes,
        replace: false,
      );
      return _metadata(id, originalBytes, processed.thumbnailBytes, processed);
    });
  }

  @override
  Future<StoredPhoto?> recoverPhoto(String mediaId) async {
    final id = _validatedId(mediaId);
    return _withLock(id, () async {
      final directory = await _mediaDirectory(id, create: false);
      if (directory == null) return null;

      final original = File(p.join(directory.path, 'original.jpg'));
      if (!await _assertRegularOrAbsent(original)) return null;
      if (await original.length() > maxPhotoBytes) return null;
      final originalBytes = await original.readAsBytes();
      if (originalBytes.isEmpty || originalBytes.length > maxPhotoBytes) {
        return null;
      }

      late final _ProcessedPhoto processed;
      try {
        processed = await _processInIsolate(originalBytes);
      } on FormatException {
        return null;
      }

      final thumbnailBytes = processed.thumbnailBytes;
      final thumbnail = File(p.join(directory.path, 'thumbnail.jpg'));
      if (await _assertRegularOrAbsent(thumbnail)) {
        if (await thumbnail.length() != thumbnailBytes.length) {
          await _atomicWrite(
            directory,
            'thumbnail.jpg',
            thumbnailBytes,
            replace: true,
          );
        } else {
          final currentThumbnail = await thumbnail.readAsBytes();
          if (!_sameBytes(currentThumbnail, thumbnailBytes)) {
            await _atomicWrite(
              directory,
              'thumbnail.jpg',
              thumbnailBytes,
              replace: true,
            );
          }
        }
      } else {
        await _atomicWrite(
          directory,
          'thumbnail.jpg',
          thumbnailBytes,
          replace: false,
        );
      }
      return _metadata(id, originalBytes, thumbnailBytes, processed);
    });
  }

  Future<T> _withLock<T>(String id, Future<T> Function() action) async {
    final previous = _locks[id] ?? Future<void>.value();
    final release = Completer<void>();
    final releaseFuture = release.future;
    _locks[id] = releaseFuture;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_locks[id], releaseFuture)) _locks.remove(id);
    }
  }

  Future<Directory?> _mediaDirectory(String id, {required bool create}) async {
    final rootPath = await _rootPath();
    final path = p.join(rootPath, id);
    if (!p.isWithin(rootPath, path)) {
      throw StateError('Media path escaped its app-private root');
    }
    var directory = Directory(path);
    var type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw StateError('Media directories cannot be symbolic links');
    }
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      await directory.create();
      type = await FileSystemEntity.type(path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('Media UUID path is not a directory');
    }

    final resolvedPath = await directory.resolveSymbolicLinks();
    if (!p.isWithin(rootPath, resolvedPath)) {
      throw StateError('Media directory resolves outside its app-private root');
    }
    directory = Directory(resolvedPath);
    return directory;
  }

  Future<String> _rootPath() {
    final cached = _rootPathFuture;
    if (cached != null) return cached;

    late final Future<String> attempt;
    attempt = _initializeRoot().catchError((Object error, StackTrace stack) {
      if (identical(_rootPathFuture, attempt)) _rootPathFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
    _rootPathFuture = attempt;
    return attempt;
  }

  Future<String> _initializeRoot() async {
    final requestedRoot = Directory(_requestedRootPath);
    var type = await FileSystemEntity.type(
      _requestedRootPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw StateError('App-private media root cannot be a symbolic link');
    }
    if (type == FileSystemEntityType.notFound) {
      await requestedRoot.create(recursive: true);
      type = await FileSystemEntity.type(
        _requestedRootPath,
        followLinks: false,
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw StateError('App-private media root is not a directory');
    }
    return requestedRoot.resolveSymbolicLinks();
  }

  Future<bool> _assertRegularOrAbsent(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw StateError('Media evidence paths must be regular files');
    }
    return true;
  }

  Future<void> _atomicWrite(
    Directory directory,
    String filename,
    Uint8List bytes, {
    required bool replace,
  }) async {
    final destination = File(p.join(directory.path, filename));
    final existed = await _assertRegularOrAbsent(destination);
    if (existed && !replace) {
      throw StateError('Evidence file already exists');
    }

    final temporary = File(
      p.join(directory.path, '.$filename.${_uuid.v4()}.tmp'),
    );
    try {
      await _writeAndFlush(temporary, bytes);
      final nowExists = await _assertRegularOrAbsent(destination);
      if (nowExists && !replace) {
        throw StateError('Evidence file appeared during write');
      }
      await temporary.rename(destination.path);
    } finally {
      if (await _assertRegularOrAbsent(temporary)) {
        await temporary.delete();
      }
    }
  }

  Future<void> _writeAndFlush(File file, Uint8List bytes) async {
    RandomAccessFile? handle;
    try {
      await file.create(exclusive: true);
      handle = await file.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle?.close();
    }
  }

  Future<_ProcessedPhoto> _processInIsolate(Uint8List bytes) =>
      Isolate.run(() => _processJpeg(bytes));

  StoredPhoto _metadata(
    String id,
    Uint8List originalBytes,
    Uint8List thumbnailBytes,
    _ProcessedPhoto processed,
  ) => StoredPhoto(
    originalPath: '$id/original.jpg',
    thumbnailPath: '$id/thumbnail.jpg',
    mimeType: 'image/jpeg',
    byteLength: originalBytes.length,
    thumbnailByteLength: thumbnailBytes.length,
    sha256: sha256.convert(originalBytes).toString(),
    thumbnailSha256: sha256.convert(thumbnailBytes).toString(),
    width: processed.width,
    height: processed.height,
  );

  static String _validatedId(String mediaId) {
    if (!_uuidPattern.hasMatch(mediaId)) {
      throw ArgumentError.value(mediaId, 'mediaId', 'Must be a UUID');
    }
    return mediaId.toLowerCase();
  }
}

class _ProcessedPhoto {
  const _ProcessedPhoto({
    required this.thumbnailBytes,
    required this.width,
    required this.height,
  });

  final Uint8List thumbnailBytes;
  final int width;
  final int height;
}

_ProcessedPhoto _processJpeg(Uint8List bytes) {
  final decoder = image.JpegDecoder();
  late final image.DecodeInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Photo is not a valid JPEG image');
  }
  if (info == null || info.width <= 0 || info.height <= 0) {
    throw const FormatException('Photo is not a valid JPEG image');
  }
  if (info.width * info.height > FileSystemMediaStore.maxPhotoPixels) {
    throw const FormatException('Photo exceeds the 20 megapixel limit');
  }

  late final image.Image decoded;
  try {
    final result = decoder.decode(bytes);
    if (result == null) {
      throw const FormatException('Photo JPEG could not be decoded');
    }
    decoded = result;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Photo JPEG is corrupt or incomplete');
  }

  try {
    final oriented = image.bakeOrientation(decoded);
    late final image.Image thumbnail;
    if (oriented.width >= oriented.height &&
        oriented.width > FileSystemMediaStore.thumbnailLongestEdge) {
      thumbnail = image.copyResize(
        oriented,
        width: FileSystemMediaStore.thumbnailLongestEdge,
        interpolation: image.Interpolation.average,
      );
    } else if (oriented.height > FileSystemMediaStore.thumbnailLongestEdge) {
      thumbnail = image.copyResize(
        oriented,
        height: FileSystemMediaStore.thumbnailLongestEdge,
        interpolation: image.Interpolation.average,
      );
    } else {
      thumbnail = oriented;
    }

    return _ProcessedPhoto(
      thumbnailBytes: Uint8List.fromList(
        image.encodeJpg(
          thumbnail,
          quality: FileSystemMediaStore.thumbnailQuality,
        ),
      ),
      width: info.width,
      height: info.height,
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Photo JPEG could not be processed');
  }
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
