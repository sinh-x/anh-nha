import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:photo_manager/photo_manager.dart';

import 'auth_store.dart';
import 'connectivity_monitor.dart';
import 'immich_api_client.dart';
import 'queue_notifier.dart';
import 'sync_queue_db.dart';
import 'tailscale_monitor.dart';

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
  final bool peerOnline;
  final bool running;
  final QueueStats queue;
  final List<SyncProgress> recent;

  const SyncSummary({
    required this.scanned,
    required this.uploaded,
    required this.dedupSkipped,
    required this.failed,
    required this.wifiOnly,
    required this.peerOnline,
    required this.running,
    required this.queue,
    required this.recent,
  });

  /// Convenience: pending count from the persistent queue (FR-3).
  int get pendingCount => queue.pending;
}

/// Callback signature for sync progress notifications.
typedef SyncProgressCallback = void Function(SyncSummary summary);

/// Core sync engine (FR-2, FR-3, FR-4).
///
/// Phase 3 adds a persistent SQLite-backed queue ([SyncQueueDb]), Tailscale
/// peer-awareness ([TailscaleMonitor]), retry with exponential backoff, and
/// a foreground notification ([QueueNotifier]) showing the queue status.
///
/// Sync is allowed only when ALL of the following hold:
///   1. Authenticated with the Immich server (FR-1).
///   2. Active network is WiFi (FR-8).
///   3. The laptop Immich peer is online over Tailscale (FR-4).
///
/// When the laptop is offline, scanned photos are enqueued and the engine
/// retries them on the next poll after the peer becomes reachable again
/// (NFR-2: sync begins within 60s of peer reachable).
class SyncEngine {
  final ImmichApiClient apiClient;
  final AuthStore authStore;
  final ConnectivityMonitor connectivity;
  final SyncQueueDb queueDb;
  final TailscaleMonitor tailscale;
  final QueueNotifier notifier;

  /// Maximum retry attempts per asset before it is left in `failed` state.
  static const maxRetries = 8;

  /// Base backoff delay for the first retry. Subsequent retries double the
  /// delay up to [maxBackoff].
  static const baseBackoff = Duration(seconds: 30);
  static const maxBackoff = Duration(hours: 1);

  bool _running = false;
  final List<SyncProgress> _recent = [];
  int _scanned = 0;
  int _uploaded = 0;
  int _dedupSkipped = 0;
  int _failed = 0;
  QueueStats _queue = QueueStats.empty();
  StreamSubscription<TailscalePeerState>? _peerSub;

  SyncEngine({
    required this.apiClient,
    required this.authStore,
    required this.connectivity,
    required this.queueDb,
    required this.tailscale,
    required this.notifier,
  }) {
    _peerSub = tailscale.changes.listen(_onPeerChange);
  }

  /// True while a sync pass is in flight.
  bool get isRunning => _running;

  /// Latest summary snapshot for the UI.
  SyncSummary get summary => SyncSummary(
        scanned: _scanned,
        uploaded: _uploaded,
        dedupSkipped: _dedupSkipped,
        failed: _failed,
        wifiOnly: connectivity.isWifi,
        peerOnline: tailscale.isPeerOnline,
        running: _running,
        queue: _queue,
        recent: List.unmodifiable(_recent),
      );

  /// Begin watching the Tailscale peer and refreshing queue stats. Should be
  /// called once at app startup, after [queueDb.open] and before the first
  /// sync pass.
  Future<void> start() async {
    await _refreshQueueStats();
    tailscale.start();
  }

  /// Stop watching the Tailscale peer.
  void stop() {
    tailscale.stop();
  }

  /// Release resources. Called from the app's dispose path.
  void dispose() {
    _peerSub?.cancel();
    tailscale.dispose();
  }

  /// React to a Tailscale peer-state change: when the laptop just came
  /// online, kick a sync pass to drain the queue (NFR-2).
  void _onPeerChange(TailscalePeerState state) {
    if (state.online && connectivity.isWifi && apiClient.isAuthenticated) {
      unawaited(_drainQueue());
    }
  }

  /// Run a single sync pass: scan the media store, enqueue anything new, and
  /// attempt to drain the queue if the peer is reachable.
  ///
  /// Throws if not authenticated. Returns immediately (after enqueueing) if
  /// not on WiFi or the peer is offline — queued photos persist and will be
  /// retried automatically when the peer comes back (FR-4, NFR-6).
  Future<SyncSummary> runOnce({SyncProgressCallback? onProgress}) async {
    if (_running) return summary;
    if (!apiClient.isAuthenticated) {
      throw StateError('Not authenticated — call login first');
    }
    _running = true;
    onProgress?.call(summary);
    try {
      final deviceId = await authStore.deviceId();
      await _scanAndEnqueue(deviceId, onProgress);
      final state = await connectivity.check();
      if (state.isWifi && tailscale.isPeerOnline) {
        await _drainQueue(onProgress: onProgress);
      }
      await _refreshQueueStats();
    } finally {
      _running = false;
      onProgress?.call(summary);
    }
    return summary;
  }

  /// Scan the media store and enqueue every asset not already known to the
  /// queue. Assets already uploaded are deduped against the server later in
  /// [_drainQueue].
  Future<void> _scanAndEnqueue(
    String deviceId,
    SyncProgressCallback? onProgress,
  ) async {
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(),
    );
    if (!permission.isAuth) return;
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

    final entries = <QueueEntry>[];
    for (final asset in assets) {
      final file = await asset.originFile;
      if (file == null) continue;
      final info = await _AssetInfo.fromAsset(asset, file);
      entries.add(QueueEntry(
        localId: info.localId,
        filename: info.filename,
        filePath: info.filePath,
        fileExtension: info.extension,
        checksumBase64: info.checksumBase64,
        createdAtIso: info.createdAt.toUtc().toIso8601String(),
        modifiedAtIso: info.modifiedAt.toUtc().toIso8601String(),
        status: QueueStatus.pending,
        retryCount: 0,
        updatedAt: DateTime.now(),
      ));
    }
    if (entries.isEmpty) return;
    await queueDb.enqueueAll(entries);
    await _refreshQueueStats();
    onProgress?.call(summary);
  }

  /// Drain the persistent queue: upload each retry-due pending asset with
  /// dedup and exponential backoff on failure (FR-3, NFR-2).
  Future<void> _drainQueue({SyncProgressCallback? onProgress}) async {
    if (!apiClient.isAuthenticated) return;
    final pending = await queueDb.listRetryDue(limit: 100);
    if (pending.isEmpty) return;

    final deviceId = await authStore.deviceId();

    final dedupItems = pending
        .map((e) => BulkUploadCheckItem(
              id: e.localId,
              checksum: e.checksumBase64,
            ))
        .toList();
    Set<String> existingIds;
    try {
      final result = await apiClient.checkBulkUpload(dedupItems);
      existingIds = result.existingIds;
    } on Exception {
      // Dedup check is best-effort; if the server is unreachable we proceed
      // and let the upload itself surface the error into the retry loop.
      existingIds = const {};
    }

    var passUploaded = 0;
    for (final entry in pending) {
      if (existingIds.contains(entry.localId)) {
        _dedupSkipped++;
        await queueDb.markUploaded(entry.id!);
        await queueDb.markSynced(SyncedAsset(
          localId: entry.localId,
          filename: entry.filename,
          filePath: entry.filePath,
          fileExtension: entry.fileExtension,
          checksumBase64: entry.checksumBase64,
          serverChecksumBase64: entry.checksumBase64,
          checksumVerified: true,
          syncedAt: DateTime.now(),
        ));
        _track(SyncProgress(
          localId: entry.localId,
          filename: entry.filename,
          status: SyncStatus.dedupHit,
        ));
        onProgress?.call(summary);
        continue;
      }
      final progress = SyncProgress(
        localId: entry.localId,
        filename: entry.filename,
        status: SyncStatus.uploading,
      );
      _track(progress);
      onProgress?.call(summary);
      try {
        final uploaded = await apiClient.uploadAsset(
          localId: entry.localId,
          deviceId: deviceId,
          filePath: entry.filePath,
          fileExtension: entry.fileExtension,
          fileCreatedAt: DateTime.parse(entry.createdAtIso),
          fileModifiedAt: DateTime.parse(entry.modifiedAtIso),
          isFavorite: false,
          checksumBase64: entry.checksumBase64,
        );
        _uploaded++;
        passUploaded++;
        await queueDb.markUploaded(entry.id!);
        // FR-5: only mark as verified when the server-returned checksum
        // matches the locally computed one. If the server omits the
        // checksum field, mark as unverified so the space-saver will not
        // offer it for deletion.
        final serverChecksum = uploaded.checksum;
        final verified = serverChecksum != null &&
            serverChecksum.isNotEmpty &&
            _constantTimeEquals(serverChecksum, entry.checksumBase64);
        await queueDb.markSynced(SyncedAsset(
          localId: entry.localId,
          filename: entry.filename,
          filePath: entry.filePath,
          fileExtension: entry.fileExtension,
          checksumBase64: entry.checksumBase64,
          serverAssetId: uploaded.id,
          serverChecksumBase64: serverChecksum,
          checksumVerified: verified,
          syncedAt: DateTime.now(),
        ));
        _track(progress.copyWith(status: SyncStatus.uploaded));
      } catch (e) {
        _failed++;
        final nextRetry = entry.retryCount + 1;
        if (nextRetry >= maxRetries) {
          await queueDb.update(entry.copyWith(
            status: QueueStatus.failed,
            retryCount: nextRetry,
            lastError: '$e',
          ));
        } else {
          final backoff = _backoffFor(nextRetry);
          await queueDb.update(entry.copyWith(
            status: QueueStatus.pending,
            retryCount: nextRetry,
            lastError: '$e',
            nextAttemptAt: DateTime.now().add(backoff),
          ));
        }
        _track(progress.copyWith(status: SyncStatus.failed, error: '$e'));
      }
      onProgress?.call(summary);
    }
    await _refreshQueueStats();
    // After draining, if any uploads succeeded in this pass, bump the local
    // device's last-sync timestamp to "now" so the dashboard reflects the
    // freshest sync (FR-6).
    if (passUploaded > 0) {
      await _bumpLocalLastSync();
    }
  }

  Future<void> _bumpLocalLastSync() async {
    try {
      final deviceId = await authStore.deviceId();
      final existing = await queueDb.deviceStats(deviceId);
      if (existing == null) return;
      await queueDb.upsertDeviceStats(existing.copyWith(
        lastSyncAt: DateTime.now(),
      ));
    } on Exception {
      // Best-effort.
    }
  }

  /// Exponential backoff schedule: base * 2^(retry-1), capped at maxBackoff.
  Duration _backoffFor(int retry) {
    final multiplier = 1 << (retry - 1);
    final delay = baseBackoff * multiplier;
    return delay > maxBackoff ? maxBackoff : delay;
  }

  /// Constant-time string comparison to avoid timing-side-channel checksum
  /// comparison. Returns true when [a] and [b] are equal.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _refreshQueueStats() async {
    _queue = await queueDb.stats();
    await notifier.update(
      pending: _queue.pending,
      failed: _queue.failed,
      peerOnline: tailscale.isPeerOnline,
    );
    await _recordLocalDeviceStats();
  }

  /// Update the local device's row in the `device_stats` table (FR-6) with
  /// the latest pending count and total synced count. Called after every
  /// queue stats refresh so the dashboard has fresh data without an extra
  /// server round-trip.
  Future<void> _recordLocalDeviceStats() async {
    try {
      final deviceId = await authStore.deviceId();
      final label = await authStore.localDeviceLabel();
      final syncedCount = await queueDb.syncedCount();
      final existing = await queueDb.deviceStats(deviceId);
      await queueDb.upsertDeviceStats(DeviceStats(
        deviceId: deviceId,
        deviceLabel: label ?? existing?.deviceLabel,
        lastSyncAt: syncedCount > 0
            ? (existing?.lastSyncAt ?? DateTime.now())
            : existing?.lastSyncAt,
        pendingCount: _queue.pending,
        totalSyncedCount: syncedCount,
        updatedAt: DateTime.now(),
      ));
    } on Exception {
      // Stats tracking is best-effort; never block sync on it.
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