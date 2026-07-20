import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Raised when the Immich API returns an error or the response is unexpected.
class ImmichApiException implements Exception {
  final int statusCode;
  final String message;
  final String? body;

  ImmichApiException(this.statusCode, this.message, [this.body]);

  @override
  String toString() => 'ImmichApiException($statusCode): $message'
      '${body != null && body!.isNotEmpty ? ' — body: $body' : ''}';
}

/// Credentials used to authenticate with the Immich server.
class ImmichCredentials {
  final String serverUrl;
  final String email;
  final String password;
  final String? apiKey;

  const ImmichCredentials({
    required this.serverUrl,
    required this.email,
    required this.password,
    this.apiKey,
  });

  /// Normalize a user-typed server URL so it always has a scheme and no
  /// trailing slash. Empty input returns an empty string.
  static String normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}

/// Result of a successful login attempt.
class ImmichLoginResult {
  final String accessToken;
  final String userId;
  final String? name;

  const ImmichLoginResult({
    required this.accessToken,
    required this.userId,
    this.name,
  });
}

/// Item used both as the request payload for `/assets/bulk-upload-check`
/// and as the parsed response item.
///
/// **Request side** (sent to the server): `{id, checksum}` where `id` is the
/// local asset id and `checksum` is the base64-encoded SHA-1.
///
/// **Response side** (parsed from the server): `{id, action, assetId?,
/// isTrashed?, reason?}`. There is no `checksum` field and no `isArchived`
/// field in the response. An asset is "already on the server" when
/// `action == 'reject' && reason == 'duplicate'`; the existing asset's id is
/// in `assetId` (use it for the synced_assets record).
class BulkUploadCheckItem {
  /// Local asset id (request) / echoed id (response).
  final String id;

  /// Base64-encoded SHA-1 checksum (request side only; null on response
  /// items parsed via [fromJson]).
  final String? checksum;

  // Response-side fields (null on request items).
  final String? action;
  final String? assetId;
  final String? reason;
  final bool isTrashed;

  const BulkUploadCheckItem({
    required this.id,
    this.checksum,
    this.action,
    this.assetId,
    this.reason,
    this.isTrashed = false,
  });

  factory BulkUploadCheckItem.fromJson(Map<String, dynamic> json) {
    return BulkUploadCheckItem(
      id: json['id'] as String,
      action: json['action'] as String?,
      assetId: json['assetId'] as String?,
      reason: json['reason'] as String?,
      isTrashed: (json['isTrashed'] as bool?) ?? false,
    );
  }

  /// True when the server already has this asset (duplicate).
  bool get isDuplicate => action == 'reject' && reason == 'duplicate';
}

/// Result of a bulk upload check.
class BulkUploadCheckResult {
  final List<BulkUploadCheckItem> results;

  const BulkUploadCheckResult(this.results);

  /// Returns the IDs of assets the server already has. These should NOT be
  /// re-uploaded.
  Set<String> get existingIds =>
      results.where((item) => item.isDuplicate).map((item) => item.id).toSet();

  /// Map of local id → server asset id for duplicates (used to record the
  /// server-asset linkage for dedup-hit entries).
  Map<String, String> get duplicateServerIds => {
        for (final item in results)
          if (item.isDuplicate && item.assetId != null) item.id: item.assetId!,
      };
}

/// Minimal metadata about an uploaded asset as returned by Immich.
class UploadedAsset {
  final String id;
  final String? checksum;

  const UploadedAsset({required this.id, this.checksum});
}

/// Minimal asset metadata returned by Immich's search endpoint, used by the
/// dashboard to compute per-device totals and last-sync timestamps (FR-6),
/// and by the backup verifier to compare server-stored checksums against
/// local files (FR-7, Phase 6).
class ImmichAsset {
  final String id;
  final String deviceId;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final bool isFavorite;

  /// Server-stored SHA-1 checksum as base64, or null when Immich omits the
  /// field. Used by the backup verifier (FR-7).
  final String? checksumBase64;

  const ImmichAsset({
    required this.id,
    required this.deviceId,
    required this.createdAt,
    required this.modifiedAt,
    required this.isFavorite,
    this.checksumBase64,
  });

  factory ImmichAsset.fromJson(Map<String, dynamic> json) {
    return ImmichAsset(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      createdAt: DateTime.parse(json['fileCreatedAt'] as String),
      modifiedAt: DateTime.parse(json['fileModifiedAt'] as String),
      isFavorite: (json['isFavorite'] as bool?) ?? false,
      checksumBase64: json['checksum'] as String?,
    );
  }
}

/// Thin REST client for the Immich server API.
///
/// Implements just the endpoints anh-nha needs in Phase 2:
/// - POST /auth/login            (FR-1)
/// - POST /auth/validateToken     (session validation)
/// - POST /assets/bulk-upload-check (FR-2 dedup)
/// - POST /assets                 (FR-2 upload)
///
/// The Immich project ships a generated Dart OpenAPI SDK in
/// `mobile/openapi`, but it is not published to pub.dev and pulling it in
/// would bloat the APK with ~200 generated classes we don't need. This thin
/// client covers the same REST contract while keeping the dependency surface
/// small — important for the <30 MB APK target (NFR-1) and F-Droid review.
class ImmichApiClient {
  final http.Client _httpClient;
  String _serverUrl;
  String? _accessToken;

  ImmichApiClient({http.Client? httpClient, String serverUrl = ''})
      : _httpClient = httpClient ?? http.Client(),
        _serverUrl = serverUrl;

  /// Current configured server base URL (no trailing slash).
  String get serverUrl => _serverUrl;

  /// Updates the server base URL. Does not re-authenticate.
  void configureServer(String url) {
    _serverUrl = ImmichCredentials.normalizeUrl(url);
  }

  /// Sets the access token directly (e.g. restored from storage).
  void setAccessToken(String token) {
    _accessToken = token;
  }

  /// Clears any cached access token.
  void clearAccessToken() {
    _accessToken = null;
  }

  /// Returns true if an access token is currently cached.
  bool get isAuthenticated => _accessToken != null;

  /// Build the full URL for an API path.
  Uri _uri(String path) {
    final base = _serverUrl;
    if (base.isEmpty) {
      throw StateError('Server URL not configured');
    }
    final separator = path.startsWith('/') ? '' : '/';
    return Uri.parse('$base$separator$path');
  }

  /// Default headers including auth when available.
  Map<String, String> _headers({Map<String, String>? extra}) {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      ...?extra,
    };
    return headers;
  }

  /// Authenticate with email/password and cache the access token.
  ///
  /// Immich endpoint: POST /api/auth/login
  /// Body: {"email": ..., "password": ...}
  /// Returns: {"accessToken": "...", "userId": "...", "name": "..."}
  Future<ImmichLoginResult> login(ImmichCredentials creds) async {
    final url = ImmichCredentials.normalizeUrl(creds.serverUrl);
    _serverUrl = url;
    final response = await _httpClient.post(
      Uri.parse('$url/api/auth/login'),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: jsonEncode({
        'email': creds.email,
        'password': creds.password,
      }),
    );

    if (response.statusCode != 201 && response.statusCode != 200) {
      throw ImmichApiException(
        response.statusCode,
        'Login failed',
        response.body,
      );
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final token = body['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw ImmichApiException(
        response.statusCode,
        'Login response missing accessToken',
        response.body,
      );
    }
    _accessToken = token;
    return ImmichLoginResult(
      accessToken: token,
      userId: body['userId'] as String,
      name: body['name'] as String?,
    );
  }

  /// Validate that the cached access token is still accepted by the server.
  /// Immich endpoint: POST /api/auth/validateToken
  Future<bool> validateToken() async {
    if (_accessToken == null) return false;
    final response = await _httpClient.post(
      _uri('/api/auth/validateToken'),
      headers: _headers(),
    );
    return response.statusCode == 200;
  }

  /// Send a pre-computed list of asset checksums to the server to learn which
  /// ones already exist (and so should not be re-uploaded).
  ///
  /// Immich endpoint: POST /api/assets/bulk-upload-check
  /// Body: {"assets": [{"id": "<local-id>", "checksum": "<base64 sha1>"}]}
  Future<BulkUploadCheckResult> checkBulkUpload(
    List<BulkUploadCheckItem> assets,
  ) async {
    final response = await _httpClient.post(
      _uri('/api/assets/bulk-upload-check'),
      headers: _headers(extra: {'Content-Type': 'application/json'}),
      body: jsonEncode({
        'assets': assets
            .map((a) => {
                  'id': a.id,
                  'checksum': a.checksum,
                })
            .toList(),
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ImmichApiException(
        response.statusCode,
        'bulk-upload-check failed',
        response.body,
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = (body['results'] as List<dynamic>)
        .map((e) => BulkUploadCheckItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return BulkUploadCheckResult(results);
  }

  /// Upload a single asset to Immich using the multipart form-data contract.
  ///
  /// Immich endpoint: POST /api/assets
  /// Required fields: assetData (file), deviceAssetId, deviceId, fileCreatedAt,
  /// fileModifiedAt, isFavorite, fileExtension.
  Future<UploadedAsset> uploadAsset({
    required String localId,
    required String deviceId,
    required String filePath,
    required String fileExtension,
    required DateTime fileCreatedAt,
    required DateTime fileModifiedAt,
    required bool isFavorite,
    String? checksumBase64,
  }) async {
    final fileBytes = await File(filePath).readAsBytes();
    return uploadAssetBytes(
      localId: localId,
      deviceId: deviceId,
      bytes: fileBytes,
      fileExtension: fileExtension,
      fileCreatedAt: fileCreatedAt,
      fileModifiedAt: fileModifiedAt,
      isFavorite: isFavorite,
      checksumBase64: checksumBase64,
      originalFileName: _basename(filePath),
    );
  }

  /// Upload an asset from an in-memory byte buffer.
  Future<UploadedAsset> uploadAssetBytes({
    required String localId,
    required String deviceId,
    required Uint8List bytes,
    required String fileExtension,
    required DateTime fileCreatedAt,
    required DateTime fileModifiedAt,
    required bool isFavorite,
    String? checksumBase64,
    required String originalFileName,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      _uri('/api/assets'),
    )
      ..headers['Authorization'] = 'Bearer $_accessToken'
      ..fields['deviceAssetId'] = localId
      ..fields['deviceId'] = deviceId
      ..fields['fileCreatedAt'] = fileCreatedAt.toUtc().toIso8601String()
      ..fields['fileModifiedAt'] = fileModifiedAt.toUtc().toIso8601String()
      ..fields['isFavorite'] = isFavorite.toString()
      ..fields['fileExtension'] = fileExtension
      ..fields['originalFileName'] = originalFileName
      ..files.add(
        http.MultipartFile.fromBytes(
          'assetData',
          bytes,
          filename: originalFileName,
        ),
      );

    final streamedResponse = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 201 && response.statusCode != 200) {
      throw ImmichApiException(
        response.statusCode,
        'Upload failed',
        response.body,
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return UploadedAsset(
      id: body['id'] as String,
      checksum: body['checksum'] as String?,
    );
  }

  /// List assets for the authenticated user, optionally filtered by
  /// `deviceId`. Pages through Immich's `POST /api/search/metadata` endpoint
  /// (the legacy `GET /api/assets` list route does not exist in current
  /// Immich). Used by the dashboard to compute per-device totals and
  /// last-sync timestamps (FR-6), and by the backup verifier (FR-7).
  ///
  /// The response shape is `{albums: {...}, assets: {items: [...], nextPage: N?}}`.
  /// We page until `nextPage` is null. [pageSize] controls the per-request
  /// batch size (Immich default/max is 1000).
  Future<List<ImmichAsset>> listAssets({
    String? deviceId,
    int pageSize = 1000,
  }) async {
    final out = <ImmichAsset>[];
    int? page;
    do {
      final body = <String, Object?>{
        'size': pageSize,
        'page': page ?? 0,
      };
      if (deviceId != null && deviceId.isNotEmpty) {
        body['deviceId'] = deviceId;
      }
      final response = await _httpClient.post(
        _uri('/api/search/metadata'),
        headers: _headers(extra: {'Content-Type': 'application/json'}),
        body: jsonEncode(body),
      );
      if (response.statusCode != 200) {
        throw ImmichApiException(
          response.statusCode,
          'search/metadata failed',
          response.body,
        );
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final assetsBlock = decoded['assets'] as Map<String, dynamic>? ?? {};
      final items = (assetsBlock['items'] as List<dynamic>?) ?? [];
      for (final e in items) {
        out.add(ImmichAsset.fromJson(e as Map<String, dynamic>));
      }
      final next = assetsBlock['nextPage'];
      page = next == null ? null : (next is int ? next : int.tryParse('$next'));
    } while (page != null);
    return out;
  }

  /// Close the underlying HTTP client. Safe to call multiple times.
  void dispose() {
    _httpClient.close();
  }

  String _basename(String path) {
    final lastSlash = path.lastIndexOf(Platform.pathSeparator);
    if (lastSlash < 0) return path;
    return path.substring(lastSlash + 1);
  }
}