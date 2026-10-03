import 'dart:io';
import 'dart:typed_data';

/// Verified filesystem metadata; binary evidence never enters SQLite.
class StoredPhoto {
  const StoredPhoto({
    required this.originalPath,
    required this.thumbnailPath,
    required this.mimeType,
    required this.byteLength,
    required this.thumbnailByteLength,
    required this.sha256,
    required this.thumbnailSha256,
    required this.width,
    required this.height,
  });

  final String originalPath;
  final String thumbnailPath;
  final String mimeType;
  final int byteLength;
  final int thumbnailByteLength;
  final String sha256;
  final String thumbnailSha256;
  final int width;
  final int height;
}

/// Files are addressed only by UUID, beneath an app-owned media directory.
abstract interface class MediaFileStore {
  Future<StoredPhoto> writePhoto(String mediaId, Uint8List bytes);

  /// Finds durable originals and repairs a missing thumbnail after interruption.
  /// Returns null when no complete, valid original can be recovered.
  Future<StoredPhoto?> recoverPhoto(String mediaId);

  File originalFile(String mediaId);
  File thumbnailFile(String mediaId);
}
