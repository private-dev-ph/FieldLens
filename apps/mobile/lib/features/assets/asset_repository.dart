import 'package:drift/drift.dart';

import '../../database/app_database.dart';

/// Asset information needed to identify equipment before starting an
/// inspection.
class AssetDetails {
  const AssetDetails({
    required this.id,
    required this.serial,
    required this.assetTag,
    required this.qrValue,
    required this.assetType,
    required this.siteName,
  });

  final String id;
  final String serial;
  final String assetTag;
  final String qrValue;
  final String assetType;
  final String siteName;
}

/// A local data collision that requires a different identifier or repair.
class AmbiguousAssetQr extends StateError {
  AmbiguousAssetQr() : super('Multiple local assets match this QR identifier');
}

/// Resolves assets from the local database, including while offline.
class AssetRepository {
  AssetRepository(this.db);

  final AppDatabase db;

  /// Finds all exact serial matches, ignoring surrounding whitespace and case.
  ///
  /// Serial numbers can repeat across different sites, so the result is a
  /// sorted list rather than an arbitrarily selected asset.
  Future<List<AssetDetails>> searchBySerial(String serial) async {
    final normalizedSerial = serial.trim().toLowerCase();
    if (normalizedSerial.isEmpty) return const [];

    final query =
        db.select(db.assets).join([
            innerJoin(db.sites, db.sites.id.equalsExp(db.assets.siteId)),
          ])
          ..where(db.assets.serial.lower().equals(normalizedSerial))
          ..orderBy([
            OrderingTerm.asc(db.sites.name),
            OrderingTerm.asc(db.assets.assetTag),
          ]);

    return (await query.get())
        .map(
          (row) => _details(row.readTable(db.assets), row.readTable(db.sites)),
        )
        .toList(growable: false);
  }

  /// Resolves one asset from a `FIELDLENS://ASSET/<identifier>` QR payload.
  ///
  /// Scheme and host matching is case-insensitive. The identifier remains
  /// case-sensitive so it matches the stored URI path exactly.
  Future<AssetDetails?> resolveQr(String payload) async {
    final pathIdentifier = _validatedQrPath(payload);
    const prefix = 'FIELDLENS://ASSET/';
    final rows = await db
        .customSelect(
          '''
      SELECT assets.id, assets.serial, assets.asset_tag, assets.qr_value,
             assets.asset_type, sites.name AS site_name
      FROM assets
      INNER JOIN sites ON sites.id = assets.site_id
      WHERE lower(substr(assets.qr_value, 1, ?)) = ?
        AND substr(assets.qr_value, ? + 1) = ?
      LIMIT 2
      ''',
          variables: [
            Variable.withInt(prefix.length),
            Variable.withString(prefix.toLowerCase()),
            Variable.withInt(prefix.length),
            Variable.withString(pathIdentifier),
          ],
          readsFrom: {db.assets, db.sites},
        )
        .get();

    if (rows.isEmpty) return null;
    if (rows.length > 1) {
      throw AmbiguousAssetQr();
    }
    final row = rows.single;
    return AssetDetails(
      id: row.read<String>('id'),
      serial: row.read<String>('serial'),
      assetTag: row.read<String>('asset_tag'),
      qrValue: row.read<String>('qr_value'),
      assetType: row.read<String>('asset_type'),
      siteName: row.read<String>('site_name'),
    );
  }

  String _validatedQrPath(String payload) {
    const rawPrefix = 'FIELDLENS://ASSET/';
    if (payload.length <= rawPrefix.length ||
        payload.substring(0, rawPrefix.length).toLowerCase() !=
            rawPrefix.toLowerCase()) {
      throw const FormatException('Expected FIELDLENS://ASSET/<identifier>');
    }

    final pathIdentifier = payload.substring(rawPrefix.length);
    if (pathIdentifier.contains('%')) {
      throw const FormatException(
        'Percent-encoded asset identifiers are not supported',
      );
    }
    if (pathIdentifier.contains(RegExp(r'[/\\?#]'))) {
      throw const FormatException('Expected one asset identifier path segment');
    }

    late final String decodedIdentifier;
    try {
      decodedIdentifier = Uri.decodeComponent(pathIdentifier);
    } on FormatException {
      throw const FormatException('Malformed asset identifier encoding');
    }
    if (decodedIdentifier.isEmpty ||
        decodedIdentifier == '.' ||
        decodedIdentifier == '..' ||
        decodedIdentifier.contains('/') ||
        decodedIdentifier.contains('\\') ||
        decodedIdentifier.contains(RegExp(r'[\s\x00-\x1F\x7F]'))) {
      throw const FormatException('Invalid asset identifier');
    }

    late final Uri uri;
    try {
      uri = Uri.parse(payload);
    } on FormatException {
      throw const FormatException('Malformed FieldLens asset QR payload');
    }

    final path = uri.path;
    if (uri.scheme.toLowerCase() != 'fieldlens' ||
        uri.host.toLowerCase() != 'asset' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 1 ||
        uri.pathSegments.single != decodedIdentifier ||
        path.length <= 1) {
      throw const FormatException('Expected FIELDLENS://ASSET/<identifier>');
    }
    return pathIdentifier;
  }

  AssetDetails _details(Asset asset, Site site) => AssetDetails(
    id: asset.id,
    serial: asset.serial,
    assetTag: asset.assetTag,
    qrValue: asset.qrValue,
    assetType: asset.assetType,
    siteName: site.name,
  );
}
