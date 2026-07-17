import 'dart:async';

import 'immich_api_client.dart';
import 'sync_queue_db.dart';

/// Per-device dashboard snapshot surfaced to the UI (FR-6).
///
/// Combines server-derived stats (total synced count, last sync timestamp)
/// with local queue stats (pending count) for the local device.
class DeviceDashboardEntry {
  /// Stable Immich device ID (per-install UUID sent on every upload).
  final String deviceId;

  /// Human-readable label for the device, if known.
  final String? deviceLabel;

  /// Last time this device synced an asset to the server, or null if it
  /// never has.
  final DateTime? lastSyncAt;

  /// Number of photos still pending in this device's local sync queue. Only
  /// the local device's queue is known precisely; remote devices report 0
  /// (their queue lives on their own phone).
  final int pendingCount;

  /// Total number of assets this device has uploaded to the server,
  /// according to the Immich server.
  final int totalSyncedCount;

  /// True when this device is the one running the app right now.
  final bool isLocal;

  const DeviceDashboardEntry({
    required this.deviceId,
    this.deviceLabel,
    this.lastSyncAt,
    required this.pendingCount,
    required this.totalSyncedCount,
    required this.isLocal,
  });
}

/// Aggregates per-device sync statistics for the dashboard (FR-6).
///
/// The dashboard needs three numbers per device:
///   1. Last sync timestamp
///   2. Pending queue size
///   3. Total synced count
///
/// Sources:
/// - **Total synced count** + **last sync timestamp**: queried from the
///   Immich server via [ImmichApiClient.listAssets] (which pages through
///   `POST /api/search/metadata`). Each asset records the `deviceId` that
///   uploaded it, so we group assets by device ID to get per-device totals
///   and the most recent `fileModifiedAt` as a proxy for last sync time.
/// - **Pending queue size**: only the local device's queue is known (from
///   [SyncQueueDb.stats]); remote devices' queues live on their own phones
///   and are not exposed by the Immich API, so they are reported as 0.
///
/// Results are cached locally in the `device_stats` SQLite table so the
/// dashboard can render immediately on app start and refresh in the
/// background.
class DeviceRegistry {
  final ImmichApiClient _apiClient;
  final SyncQueueDb _queueDb;

  /// Cached device label for the local device, if set via [setLocalLabel].
  String? _localDeviceLabel;

  DeviceRegistry(this._apiClient, this._queueDb);

  /// Set a human-readable label for the local device so the dashboard can
  /// show "Sinh's phone" instead of a bare UUID.
  void setLocalLabel(String label) {
    _localDeviceLabel = label;
  }

  /// Refresh per-device stats from the Immich server and update the local
  /// cache. Returns the full dashboard entry list ordered by most-recently
  /// synced first.
  ///
  /// [localDeviceId] is the per-install UUID of this phone; its pending
  /// queue count is filled from the local [SyncQueueDb]. [localPendingCount]
  /// overrides the server-derived pending count for the local device (the
  /// server has no knowledge of the local queue).
  Future<List<DeviceDashboardEntry>> refresh({
    required String localDeviceId,
    required int localPendingCount,
  }) async {
    final List<ImmichAsset> assets;
    try {
      assets = await _apiClient.listAssets();
    } on Exception {
      // Server unreachable — return cached stats so the dashboard still
      // renders with the last-known data. Broadened from
      // `on ImmichApiException` so socket/timeout/HTTP-client errors also
      // engage the fallback.
      return _cachedEntries(
        localDeviceId: localDeviceId,
        localPendingCount: localPendingCount,
      );
    }

    // Group assets by deviceId → (count, latestModifiedAt).
    final byDevice = <String, _DeviceAggregate>{};
    for (final asset in assets) {
      final agg = byDevice.putIfAbsent(
        asset.deviceId,
        () => _DeviceAggregate(deviceId: asset.deviceId),
      );
      agg.count++;
      if (asset.modifiedAt.isAfter(agg.latest)) {
        agg.latest = asset.modifiedAt;
      }
    }

    // Upsert each device's stats into the local cache.
    final now = DateTime.now();
    for (final agg in byDevice.values) {
      final isLocal = agg.deviceId == localDeviceId;
      final existing = await _queueDb.deviceStats(agg.deviceId);
      await _queueDb.upsertDeviceStats(DeviceStats(
        deviceId: agg.deviceId,
        deviceLabel: isLocal
            ? _localDeviceLabel ?? existing?.deviceLabel
            : existing?.deviceLabel,
        lastSyncAt: agg.latest.toUtc(),
        pendingCount: isLocal ? localPendingCount : existing?.pendingCount ?? 0,
        totalSyncedCount: agg.count,
        updatedAt: now,
      ));
    }

    // Also ensure the local device has a row even if it has uploaded nothing
    // yet (so the dashboard shows it with zero counts).
    if (!byDevice.containsKey(localDeviceId)) {
      final existing = await _queueDb.deviceStats(localDeviceId);
      await _queueDb.upsertDeviceStats(DeviceStats(
        deviceId: localDeviceId,
        deviceLabel: _localDeviceLabel ?? existing?.deviceLabel,
        lastSyncAt: existing?.lastSyncAt,
        pendingCount: localPendingCount,
        totalSyncedCount: existing?.totalSyncedCount ?? 0,
        updatedAt: now,
      ));
    }

    return _entriesFromCache(localDeviceId, localPendingCount);
  }

  /// Build dashboard entries from the locally cached stats, without
  /// hitting the server. Used when the server is unreachable or for the
  /// initial fast render.
  Future<List<DeviceDashboardEntry>> _cachedEntries({
    required String localDeviceId,
    required int localPendingCount,
  }) async {
    return _entriesFromCache(localDeviceId, localPendingCount);
  }

  Future<List<DeviceDashboardEntry>> _entriesFromCache(
    String localDeviceId,
    int localPendingCount,
  ) async {
    final rows = await _queueDb.allDeviceStats();
    // Override the local device's pending count with the live value.
    return rows.map((stats) {
      final isLocal = stats.deviceId == localDeviceId;
      return DeviceDashboardEntry(
        deviceId: stats.deviceId,
        deviceLabel: stats.deviceLabel,
        lastSyncAt: stats.lastSyncAt,
        pendingCount: isLocal ? localPendingCount : stats.pendingCount,
        totalSyncedCount: stats.totalSyncedCount,
        isLocal: isLocal,
      );
    }).toList();
  }

  /// Quick read of cached stats without a server round-trip. Used for the
  /// initial dashboard render before [refresh] completes.
  Future<List<DeviceDashboardEntry>> cachedEntries({
    required String localDeviceId,
    required int localPendingCount,
  }) async {
    return _entriesFromCache(localDeviceId, localPendingCount);
  }
}

/// Mutable accumulator used while grouping assets by device ID.
class _DeviceAggregate {
  final String deviceId;
  int count = 0;
  DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);

  _DeviceAggregate({required this.deviceId});
}