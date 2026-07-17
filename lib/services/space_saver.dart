import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'sync_queue_db.dart';

/// Storage statistics shown on the space-saver screen (FR-5).
class SpaceSaverStats {
  /// Number of synced+verified photos whose local copy can be safely
  /// deleted.
  final int deletableCount;

  /// Total bytes reclaimable by deleting the deletable local copies.
  final int reclaimableBytes;

  /// Number of photos already freed (locally deleted) since install.
  final int freedCount;

  /// Total bytes already freed by the space-saver.
  final int freedBytes;

  /// Number of photos still pending in the sync queue (not yet uploaded).
  final int queuePending;

  const SpaceSaverStats({
    required this.deletableCount,
    required this.reclaimableBytes,
    required this.freedCount,
    required this.freedBytes,
    required this.queuePending,
  });

  const SpaceSaverStats.empty()
      : deletableCount = 0,
        reclaimableBytes = 0,
        freedCount = 0,
        freedBytes = 0,
        queuePending = 0;
}

/// Result of a free-space operation.
class FreeSpaceResult {
  final int requested;
  final int deleted;
  final int freedBytes;
  final List<String> failedIds;

  const FreeSpaceResult({
    required this.requested,
    required this.deleted,
    required this.freedBytes,
    required this.failedIds,
  });
}

/// Space-saver tool (FR-5).
///
/// Lists photos that have been uploaded to the Immich server AND whose
/// checksum was verified, then safely deletes the local copies via
/// `photo_manager`. Only assets with `checksumVerified == true` and
/// `localDeleted == false` are offered for deletion — this enforces the
/// "only deletes after checksum verification" rule from FR-5.
class SpaceSaver {
  final SyncQueueDb _queueDb;

  SpaceSaver(this._queueDb);

  /// Gather storage statistics for the space-saver UI.
  Future<SpaceSaverStats> gatherStats() async {
    final deletable = await _queueDb.listDeletable();
    final freedCount = await _queueDb.locallyDeletedCount();
    final queueStats = await _queueDb.stats();

    var reclaimableBytes = 0;
    for (final asset in deletable) {
      reclaimableBytes += await _fileSize(asset.filePath);
    }

    return SpaceSaverStats(
      deletableCount: deletable.length,
      reclaimableBytes: reclaimableBytes,
      freedCount: freedCount,
      freedBytes: 0,
      queuePending: queueStats.pending,
    );
  }

  /// Return the list of synced+verified assets that are safe to delete
  /// locally. The UI presents these to the user for confirmation before
  /// calling [freeSpace].
  Future<List<SyncedAsset>> listDeletable() async {
    return _queueDb.listDeletable();
  }

  /// Delete the local copies of the supplied synced assets. Only assets
  /// whose `checksumVerified` flag is true are deleted; unverified assets
  /// are skipped (FR-5).
  ///
  /// Returns a [FreeSpaceResult] describing how many were deleted, how many
  /// bytes were freed, and which local IDs could not be deleted.
  Future<FreeSpaceResult> freeSpace(List<SyncedAsset> assets) async {
    final verified = assets.where((a) => a.checksumVerified).toList();
    if (verified.isEmpty) {
      return FreeSpaceResult(
        requested: assets.length,
        deleted: 0,
        freedBytes: 0,
        failedIds: const [],
      );
    }

    var freedBytes = 0;
    for (final asset in verified) {
      freedBytes += await _fileSize(asset.filePath);
    }

    final localIds = verified.map((a) => a.localId).toList();
    final failedIds = <String>[];
    try {
      final result = await PhotoManager.editor.deleteWithIds(localIds);
      failedIds.addAll(result);
    } on Exception {
      // If the batch call throws entirely, treat all as failed.
      failedIds.addAll(localIds);
    }

    final deletedCount = localIds.length - failedIds.length;
    final deletedIds = localIds.where((id) => !failedIds.contains(id));

    for (final asset in verified) {
      if (failedIds.contains(asset.localId)) continue;
      if (asset.id == null) continue;
      await _queueDb.markLocallyDeleted(asset.id!);
    }

    if (deletedIds.isEmpty) {
      freedBytes = 0;
    } else {
      final deletedSet = deletedIds.toSet();
      var actualFreed = 0;
      for (final asset in verified) {
        if (deletedSet.contains(asset.localId)) {
          actualFreed += await _fileSize(asset.filePath);
        }
      }
      freedBytes = actualFreed;
    }

    return FreeSpaceResult(
      requested: assets.length,
      deleted: deletedCount,
      freedBytes: freedBytes,
      failedIds: failedIds,
    );
  }

  /// Best-effort local file size lookup. Returns 0 when the file is gone or
  /// cannot be stat'd.
  Future<int> _fileSize(String filePath) async {
    try {
      final file = File(filePath);
      final stat = await file.stat();
      return stat.size;
    } on Exception {
      return 0;
    }
  }
}