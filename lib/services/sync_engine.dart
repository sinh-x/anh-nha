import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:photo_manager/photo_manager.dart';

import 'auth_store.dart';
import 'connectivity_monitor.dart';
import 'immich_api_client.dart';

/// Status of a single asset in the sync pipeline.
enum SyncStatus { pending, dedupHit, uploading, uploaded, failed }

/// Snapshot of a single asset's progress through the sync pipeline.
class SyncProgress {
  final String localId;
  final String filename;
  final SyncStatus status;
  final String? error;
  final DateTime? updatedAt;

  const SyncProgress({
    required this.localId,
    required this.filename,
    required this.status,
    this.error,
    this.updatedAt,
  });

  SyncProgress copyWith({
    SyncStatus? status,
    String? error,
    DateTime? updatedAt,
  }) {
    return SyncProgress(
      localId: localId,
      filename: filename,
      status: status ?? this.status,
      error: error,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Aggregated snapshot used by the UI to render the sync screen.
class SyncSummary {
  final int scanned;
  final int uploaded;
  final int dedupSkipped;
  final int failed;
  final bool wifiOnly;
  final bool running;
  final List<SyncProgress> recent;

  const SyncSummary({
    required this.scanned,
    required this.uploaded,
    required this.dedupSkipped,
    required this.failed,
    required this.wifiOnly,
    required this.running,
    required this.recent,
  });
}

/// Callback signature for sync progress notifications.
typedef SyncProgressCallback = void Function(SyncSummary summary);

/// Core sync engine (FR-2).
///
/// Responsibilities:
///   1. Scan the device media store for photos not yet uploaded.
///   2. Compute SHA-256 checksums for dedup.
///   3. Ask the server which checksums already exist (bulk-upload-check).
///   4. Upload the remaining assets.
///   5. Skip all work when not on WiFi (FR-8).
///
/// Phase 3 will extend this with a persistent queue + Tailscale peer check.
class SyncEngine {
  final ImmichApiClient apiClient;
  final AuthStore authStore;
  final ConnectivityMonitor connectivity;

  bool _running = false;
  final List<SyncProgress> _recent = [];
  int _scanned = 0;
  int _uploaded = 0;
  int _dedupSkipped = 0;
  int _failed = 0;

  SyncEngine({
    required this.apiClient,
    required this.authStore,
    required this.connectivity,
  });

  /// True while a sync pass is in flight.
  bool get isRunning => _running;

  /// Latest summary snapshot for the UI.
  SyncSummary get summary => SyncSummary(
        scanned: _scanned,
        uploaded: _uploaded,
        dedupSkipped: _dedupSkipped,
        failed: _failed,
        wifiOnly: connectivity.isWifi,
        running: _running,
        recent: List.unmodifiable(_recent),
      );

  /// Run a single sync pass. Returns the final summary.
  ///
  /// Throws if not authenticated. Returns immediately if not on WiFi.
  Future<SyncSummary> runOnce({SyncProgressCallback? onProgress}) async {
    if (_running) return summary;
    if (!apiClient.isAuthenticated) {
      throw StateError('Not authenticated — call login first');
    }
    final state = await connectivity.check();
    if (!state.isWifi) {
      onProgress?.call(summary);
      return summary;
    }
    _running = true;
    onProgress?.call(summary);
    try {
      final deviceId = await authStore.deviceId();
      await _scanAndUpload(deviceId, onProgress);
    } finally {
      _running = false;
      onProgress?.call(summary);
    }
    return summary;
  }

  /// Scan media store, dedup, and upload. Updates internal counters.
  Future<void> _scanAndUpload(
    String deviceId,
    SyncProgressCallback? onProgress,
  ) async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(),
    );
    if (!permission.isAuth) {
      return;
    }
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: true,
    );
    if (albums.isEmpty) return;
    final all = albums.first;
    final total = await all.assetCountAsync;
    final int pageSize = 200;
    final int totalPages = (total / pageSize).ceil();
    final List<AssetEntity> assets = [];
    for (var i = 0; i < totalPages; i++) {
      final page = await all.getAssetListPaged(page: i, size: pageSize);
      assets.addAll(page);
    }
    _scanned = assets.length;
    onProgress?.call(summary);

    final fileInfos = <_AssetInfo>[];
    for (final asset in assets) {
      final file = await asset.originFile;
      if (file == null) continue;
      final info = await _AssetInfo.fromAsset(asset, file);
      fileInfos.add(info);
    }
    if (fileInfos.isEmpty) return;

    final dedupItems = fileInfos
        .map((info) => BulkUploadCheckItem(
              id: info.localId,
              checksum: info.checksumBase64,
            ))
        .toList();
    final existing = await apiClient.checkBulkUpload(dedupItems);
    final existingIds = existing.existingIds;

    for (final info in fileInfos) {
      final progress = SyncProgress(
        localId: info.localId,
        filename: info.filename,
        status: SyncStatus.pending,
      );
      _track(progress);
      onProgress?.call(summary);

      if (existingIds.contains(info.localId)) {
        _dedupSkipped++;
        _track(progress.copyWith(status: SyncStatus.dedupHit));
        onProgress?.call(summary);
        continue;
      }
      try {
        _track(progress.copyWith(status: SyncStatus.uploading));
        onProgress?.call(summary);
        await apiClient.uploadAsset(
          localId: info.localId,
          deviceId: deviceId,
          filePath: info.filePath,
          fileExtension: info.extension,
          fileCreatedAt: info.createdAt,
          fileModifiedAt: info.modifiedAt,
          isFavorite: false,
          checksumBase64: info.checksumBase64,
        );
        _uploaded++;
        _track(progress.copyWith(status: SyncStatus.uploaded));
      } catch (e) {
        _failed++;
        _track(progress.copyWith(status: SyncStatus.failed, error: '$e'));
      }
      onProgress?.call(summary);
    }
  }

  void _track(SyncProgress progress) {
    _recent.insert(0, progress);
    if (_recent.length > 50) _recent.removeLast();
  }
}

/// Bundle of metadata needed to upload a single asset.
class _AssetInfo {
  final String localId;
  final String filename;
  final String filePath;
  final String extension;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final String checksumBase64;

  _AssetInfo({
    required this.localId,
    required this.filename,
    required this.filePath,
    required this.extension,
    required this.createdAt,
    required this.modifiedAt,
    required this.checksumBase64,
  });

  static Future<_AssetInfo> fromAsset(AssetEntity asset, File file) async {
    final bytes = await file.readAsBytes();
    final hash = sha256.convert(bytes);
    final checksum = base64Encode(hash.bytes);
    final stat = await file.stat();
    final ext = (asset.title?.split('.').last ?? 'jpg').toLowerCase();
    final filename = asset.title ?? '${asset.id}.$ext';
    return _AssetInfo(
      localId: asset.id,
      filename: filename,
      filePath: file.path,
      extension: ext,
      createdAt: asset.createDateTime,
      modifiedAt: stat.modified,
      checksumBase64: checksum,
    );
  }
}