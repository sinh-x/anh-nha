import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// Lifecycle state of a queued asset, persisted across app restarts (FR-3,
/// NFR-6).
enum QueueStatus { pending, uploading, uploaded, failed }

/// A locally-synced asset that has been uploaded to the server and whose
/// checksum was verified (FR-5). Rows persist after the upload queue entry is
/// removed so the space-saver tool can offer safe local deletion.
class SyncedAsset {
  final int? id;
  final String localId;
  final String filename;
  final String filePath;
  final String fileExtension;
  final String checksumBase64;
  final String? serverAssetId;
  final String? serverChecksumBase64;
  final bool checksumVerified;
  final DateTime syncedAt;
  final bool localDeleted;

  const SyncedAsset({
    this.id,
    required this.localId,
    required this.filename,
    required this.filePath,
    required this.fileExtension,
    required this.checksumBase64,
    this.serverAssetId,
    this.serverChecksumBase64,
    required this.checksumVerified,
    required this.syncedAt,
    this.localDeleted = false,
  });

  factory SyncedAsset.fromRow(Map<String, Object?> row) {
    return SyncedAsset(
      id: row['id'] as int?,
      localId: row['local_id'] as String,
      filename: row['filename'] as String,
      filePath: row['file_path'] as String,
      fileExtension: row['file_extension'] as String,
      checksumBase64: row['checksum_base64'] as String,
      serverAssetId: row['server_asset_id'] as String?,
      serverChecksumBase64: row['server_checksum_base64'] as String?,
      checksumVerified: (row['checksum_verified'] as int) == 1,
      syncedAt:
          DateTime.fromMillisecondsSinceEpoch(row['synced_at'] as int),
      localDeleted: (row['local_deleted'] as int) == 1,
    );
  }

  Map<String, Object?> toRow() {
    return {
      if (id != null) 'id': id,
      'local_id': localId,
      'filename': filename,
      'file_path': filePath,
      'file_extension': fileExtension,
      'checksum_base64': checksumBase64,
      'server_asset_id': serverAssetId,
      'server_checksum_base64': serverChecksumBase64,
      'checksum_verified': checksumVerified ? 1 : 0,
      'synced_at': syncedAt.millisecondsSinceEpoch,
      'local_deleted': localDeleted ? 1 : 0,
    };
  }

  SyncedAsset copyWith({bool? localDeleted}) {
    return SyncedAsset(
      id: id,
      localId: localId,
      filename: filename,
      filePath: filePath,
      fileExtension: fileExtension,
      checksumBase64: checksumBase64,
      serverAssetId: serverAssetId,
      serverChecksumBase64: serverChecksumBase64,
      checksumVerified: checksumVerified,
      syncedAt: syncedAt,
      localDeleted: localDeleted ?? this.localDeleted,
    );
  }
}

/// Extension methods to convert between the integer code stored in the DB and
/// the typed [QueueStatus] enum.
extension QueueStatusCode on QueueStatus {
  int get code => switch (this) {
        QueueStatus.pending => 0,
        QueueStatus.uploading => 1,
        QueueStatus.uploaded => 2,
        QueueStatus.failed => 3,
      };

  static QueueStatus fromCode(int code) => switch (code) {
        0 => QueueStatus.pending,
        1 => QueueStatus.uploading,
        2 => QueueStatus.uploaded,
        _ => QueueStatus.failed,
      };
}

/// Row in the persistent sync queue.
///
/// The queue survives app restarts and laptop-server outages of 30+ days
/// (NFR-6). Each row represents a single local asset that needs to be
/// uploaded to the Immich server. The `retryCount`/`nextAttemptAt` fields
/// drive the exponential backoff retry policy (NFR-2).
class QueueEntry {
  final int? id;
  final String localId;
  final String filename;
  final String filePath;
  final String fileExtension;
  final String checksumBase64;
  final String createdAtIso;
  final String modifiedAtIso;
  final QueueStatus status;
  final int retryCount;
  final String? lastError;
  final DateTime? nextAttemptAt;
  final DateTime updatedAt;

  QueueEntry({
    this.id,
    required this.localId,
    required this.filename,
    required this.filePath,
    required this.fileExtension,
    required this.checksumBase64,
    required this.createdAtIso,
    required this.modifiedAtIso,
    required this.status,
    required this.retryCount,
    this.lastError,
    this.nextAttemptAt,
    required this.updatedAt,
  });

  /// True when the entry is waiting to be retried and its backoff window has
  /// elapsed. Used by the sync engine to pick the next batch of work.
  bool get isRetryDue {
    if (status != QueueStatus.pending) return false;
    if (nextAttemptAt == null) return true;
    return DateTime.now().isAfter(nextAttemptAt!);
  }

  factory QueueEntry.fromRow(Map<String, Object?> row) {
    final nextAttemptRaw = row['next_attempt_at'] as int?;
    return QueueEntry(
      id: row['id'] as int?,
      localId: row['local_id'] as String,
      filename: row['filename'] as String,
      filePath: row['file_path'] as String,
      fileExtension: row['file_extension'] as String,
      checksumBase64: row['checksum_base64'] as String,
      createdAtIso: row['created_at_iso'] as String,
      modifiedAtIso: row['modified_at_iso'] as String,
      status: QueueStatusCode.fromCode(row['status'] as int),
      retryCount: row['retry_count'] as int,
      lastError: row['last_error'] as String?,
      nextAttemptAt:
          nextAttemptRaw == null ? null : DateTime.fromMillisecondsSinceEpoch(nextAttemptRaw),
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  Map<String, Object?> toRow() {
    return {
      if (id != null) 'id': id,
      'local_id': localId,
      'filename': filename,
      'file_path': filePath,
      'file_extension': fileExtension,
      'checksum_base64': checksumBase64,
      'created_at_iso': createdAtIso,
      'modified_at_iso': modifiedAtIso,
      'status': status.code,
      'retry_count': retryCount,
      'last_error': lastError,
      'next_attempt_at': nextAttemptAt?.millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  QueueEntry copyWith({
    QueueStatus? status,
    int? retryCount,
    String? lastError,
    DateTime? nextAttemptAt,
  }) {
    return QueueEntry(
      id: id,
      localId: localId,
      filename: filename,
      filePath: filePath,
      fileExtension: fileExtension,
      checksumBase64: checksumBase64,
      createdAtIso: createdAtIso,
      modifiedAtIso: modifiedAtIso,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      updatedAt: DateTime.now(),
    );
  }
}

/// Aggregated queue stats surfaced to the UI and foreground notification
/// (FR-3).
class QueueStats {
  final int pending;
  final int uploading;
  final int uploaded;
  final int failed;
  final int total;

  const QueueStats({
    required this.pending,
    required this.uploading,
    required this.uploaded,
    required this.failed,
    required this.total,
  });

  const QueueStats.empty()
      : pending = 0,
        uploading = 0,
        uploaded = 0,
        failed = 0,
        total = 0;

  factory QueueStats.fromRows(List<Map<String, Object?>> rows) {
    var pending = 0, uploading = 0, uploaded = 0, failed = 0;
    for (final row in rows) {
      final status = QueueStatusCode.fromCode(row['status'] as int);
      switch (status) {
        case QueueStatus.pending:
          pending++;
          break;
        case QueueStatus.uploading:
          uploading++;
          break;
        case QueueStatus.uploaded:
          uploaded++;
          break;
        case QueueStatus.failed:
          failed++;
          break;
      }
    }
    return QueueStats(
      pending: pending,
      uploading: uploading,
      uploaded: uploaded,
      failed: failed,
      total: rows.length,
    );
  }
}

/// Outcome of a single backup-verification check (FR-7, Phase 6).
enum VerifyStatus { match, mismatch, localMissing, serverMissing, error }

/// Extension methods to convert between the integer code stored in the DB
/// and the typed [VerifyStatus] enum.
extension VerifyStatusCode on VerifyStatus {
  int get code => switch (this) {
        VerifyStatus.match => 0,
        VerifyStatus.mismatch => 1,
        VerifyStatus.localMissing => 2,
        VerifyStatus.serverMissing => 3,
        VerifyStatus.error => 4,
      };

  static VerifyStatus fromCode(int code) => switch (code) {
        0 => VerifyStatus.match,
        1 => VerifyStatus.mismatch,
        2 => VerifyStatus.localMissing,
        3 => VerifyStatus.serverMissing,
        _ => VerifyStatus.error,
      };
}

/// Persistent record of a single backup-verification check (FR-7).
///
/// Each row records the outcome of one verification pass over a single
/// synced asset: the locally recomputed SHA-1 checksum, the server's
/// stored checksum, the comparison status, and when the check ran.
class VerificationResult {
  final int? id;
  final String localId;
  final String? serverAssetId;
  final String filename;
  final String localChecksumBase64;
  final String? serverChecksumBase64;
  final VerifyStatus status;
  final DateTime checkedAt;

  const VerificationResult({
    this.id,
    required this.localId,
    this.serverAssetId,
    required this.filename,
    required this.localChecksumBase64,
    this.serverChecksumBase64,
    required this.status,
    required this.checkedAt,
  });

  factory VerificationResult.fromRow(Map<String, Object?> row) {
    return VerificationResult(
      id: row['id'] as int?,
      localId: row['local_id'] as String,
      serverAssetId: row['server_asset_id'] as String?,
      filename: row['filename'] as String,
      localChecksumBase64: row['local_checksum_base64'] as String,
      serverChecksumBase64: row['server_checksum_base64'] as String?,
      status: VerifyStatusCode.fromCode(row['status'] as int),
      checkedAt:
          DateTime.fromMillisecondsSinceEpoch(row['checked_at'] as int),
    );
  }

  Map<String, Object?> toRow() {
    return {
      if (id != null) 'id': id,
      'local_id': localId,
      'server_asset_id': serverAssetId,
      'filename': filename,
      'local_checksum_base64': localChecksumBase64,
      'server_checksum_base64': serverChecksumBase64,
      'status': status.code,
      'checked_at': checkedAt.millisecondsSinceEpoch,
    };
  }
}

/// Per-device statistics tracked locally for the dashboard (FR-6).
///
/// Each row represents the last-known stats for a single device that has
/// uploaded to this user's Immich library. The local device's row is
/// updated after every sync pass; remote devices' rows are refreshed from
/// server-side asset queries (see [DeviceRegistry]).
class DeviceStats {
  final String deviceId;
  final String? deviceLabel;
  final DateTime? lastSyncAt;
  final int pendingCount;
  final int totalSyncedCount;
  final DateTime updatedAt;

  const DeviceStats({
    required this.deviceId,
    this.deviceLabel,
    this.lastSyncAt,
    required this.pendingCount,
    required this.totalSyncedCount,
    required this.updatedAt,
  });

  factory DeviceStats.fromRow(Map<String, Object?> row) {
    final lastSyncRaw = row['last_sync_at'] as int?;
    return DeviceStats(
      deviceId: row['device_id'] as String,
      deviceLabel: row['device_label'] as String?,
      lastSyncAt: lastSyncRaw == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSyncRaw),
      pendingCount: row['pending_count'] as int,
      totalSyncedCount: row['total_synced_count'] as int,
      updatedAt:
          DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  Map<String, Object?> toRow() {
    return {
      'device_id': deviceId,
      'device_label': deviceLabel,
      'last_sync_at': lastSyncAt?.millisecondsSinceEpoch,
      'pending_count': pendingCount,
      'total_synced_count': totalSyncedCount,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  DeviceStats copyWith({
    String? deviceLabel,
    DateTime? lastSyncAt,
    int? pendingCount,
    int? totalSyncedCount,
  }) {
    return DeviceStats(
      deviceId: deviceId,
      deviceLabel: deviceLabel ?? this.deviceLabel,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      pendingCount: pendingCount ?? this.pendingCount,
      totalSyncedCount: totalSyncedCount ?? this.totalSyncedCount,
      updatedAt: DateTime.now(),
    );
  }
}

/// Persistent SQLite-backed sync queue (FR-3, NFR-6).
///
/// The queue stores one row per local asset awaiting upload. It is the single
/// source of truth for "what still needs to sync" and survives app restarts
/// and laptop outages of 30+ days. The schema is intentionally minimal so the
/// DB stays small even with thousands of queued photos.
class SyncQueueDb {
  static const _dbName = 'anh_nha_queue.db';
  static const _schemaVersion = 5;

  Database? _db;

  /// Open (or create) the queue database. Must be called once at app startup
  /// before any other method. Idempotent — safe to call multiple times.
  Future<void> open() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    _db = await openDatabase(
      path,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createQueueTable(db);
    await _createSyncedAssetsTable(db);
    await _createDeviceStatsTable(db);
    await _createVerificationResultsTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSyncedAssetsTable(db);
    }
    if (oldVersion < 3) {
      await _createDeviceStatsTable(db);
    }
    if (oldVersion < 4) {
      await _createVerificationResultsTable(db);
    }
    if (oldVersion < 5) {
      // CR-3: checksums were previously computed with SHA-256, but Immich
      // uses SHA-1. Clear all stored checksums so they get recomputed with
      // the correct algorithm on the next sync/verify pass. Also drop
      // synced_assets rows so the space-saver does not offer deletions
      // justified by a stale (wrong-algorithm) checksum match.
      await db.execute('UPDATE queue SET checksum_base64 = ""');
      await db.delete('synced_assets');
      await db.delete('verification_results');
    }
  }

  Future<void> _createQueueTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT NOT NULL UNIQUE,
        filename TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_extension TEXT NOT NULL,
        checksum_base64 TEXT NOT NULL,
        created_at_iso TEXT NOT NULL,
        modified_at_iso TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at INTEGER,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_queue_status ON queue(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_queue_local_id ON queue(local_id)',
    );
  }

  /// Table of assets that have been uploaded AND checksum-verified (FR-5).
  /// Used by the space-saver tool to list safe-to-delete local photos.
  Future<void> _createSyncedAssetsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS synced_assets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT NOT NULL UNIQUE,
        filename TEXT NOT NULL,
        file_path TEXT NOT NULL,
        file_extension TEXT NOT NULL,
        checksum_base64 TEXT NOT NULL,
        server_asset_id TEXT,
        server_checksum_base64 TEXT,
        checksum_verified INTEGER NOT NULL DEFAULT 0,
        synced_at INTEGER NOT NULL,
        local_deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_synced_local_id ON synced_assets(local_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_synced_deleted ON synced_assets(local_deleted)',
    );
  }

  /// Table of per-device sync statistics for the dashboard (FR-6). Each row
  /// is keyed by the Immich `deviceId` (the stable per-install UUID sent on
  /// every upload). The local device updates its own row after each sync
  /// pass; remote devices' rows are refreshed from server-side asset counts.
  Future<void> _createDeviceStatsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS device_stats (
        device_id TEXT PRIMARY KEY,
        device_label TEXT,
        last_sync_at INTEGER,
        pending_count INTEGER NOT NULL DEFAULT 0,
        total_synced_count INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// Table of per-asset backup-verification results (FR-7, Phase 6).
  ///
  /// Each row records the outcome of one verification check of a single
  /// synced asset: the locally recomputed SHA-1 checksum, the server's
  /// stored checksum (as reported by `POST /api/search/metadata`), the
  /// comparison outcome, and the timestamp of the check. Rows are keyed by
  /// `server_asset_id` (or `local_id` when no server id is known) so
  /// repeated verifications of the same asset update in place rather than
  /// accumulate.
  Future<void> _createVerificationResultsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS verification_results (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT NOT NULL,
        server_asset_id TEXT,
        filename TEXT NOT NULL,
        local_checksum_base64 TEXT NOT NULL,
        server_checksum_base64 TEXT,
        status INTEGER NOT NULL,
        checked_at INTEGER NOT NULL,
        UNIQUE(server_asset_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_verify_status ON verification_results(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_verify_local_id ON verification_results(local_id)',
    );
  }

  Database get _dbRef {
    final db = _db;
    if (db == null) {
      throw StateError('SyncQueueDb not opened — call open() first');
    }
    return db;
  }

  /// Insert a new pending entry, or no-op if `localId` is already queued.
  /// Returns true when a new row was inserted.
  Future<bool> enqueue(QueueEntry entry) async {
    try {
      await _dbRef.insert(
        'queue',
        entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return true;
    } on DatabaseException catch (_) {
      return false;
    }
  }

  /// Bulk-insert pending entries, ignoring duplicates by `local_id`.
  Future<void> enqueueAll(List<QueueEntry> entries) async {
    if (entries.isEmpty) return;
    final batch = _dbRef.batch();
    for (final entry in entries) {
      batch.insert(
        'queue',
        entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Fetch all rows matching `status`, ordered by id (insertion order).
  Future<List<QueueEntry>> listByStatus(QueueStatus status) async {
    final rows = await _dbRef.query(
      'queue',
      where: 'status = ?',
      whereArgs: [status.code],
      orderBy: 'id ASC',
    );
    return rows.map(QueueEntry.fromRow).toList();
  }

  /// Fetch the next batch of pending entries whose backoff window has
  /// elapsed, ordered oldest-first.
  Future<List<QueueEntry>> listRetryDue({int limit = 50}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await _dbRef.query(
      'queue',
      where:
          'status = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
      whereArgs: [QueueStatus.pending.code, now],
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(QueueEntry.fromRow).toList();
  }

  /// Update an entry's status, retry count, error and next attempt time.
  Future<void> update(QueueEntry entry) async {
    if (entry.id == null) return;
    await _dbRef.update(
      'queue',
      entry.toRow(),
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  /// Mark an entry as successfully uploaded and remove it from the active
  /// queue. Uploaded rows are deleted to keep the DB small; the Immich server
  /// is the source of truth for uploaded assets.
  Future<void> markUploaded(int id) async {
    await _dbRef.delete('queue', where: 'id = ?', whereArgs: [id]);
  }

  /// Remove all rows regardless of status. Used by tests and the logout flow.
  Future<void> clear() async {
    await _dbRef.delete('queue');
    await _dbRef.delete('synced_assets');
    await _dbRef.delete('device_stats');
    await _dbRef.delete('verification_results');
  }

  /// Aggregate counts by status, surfaced to the UI and foreground
  /// notification (FR-3).
  Future<QueueStats> stats() async {
    final rows = await _dbRef.query('queue', columns: ['status']);
    return QueueStats.fromRows(rows);
  }

  /// Total number of rows in the queue (all statuses).
  Future<int> count() async {
    final rows = await _dbRef.rawQuery('SELECT COUNT(*) AS c FROM queue');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  // --- Synced assets (FR-5) -----------------------------------------------

  /// Record a synced+verified asset, or no-op if `localId` is already known.
  Future<void> markSynced(SyncedAsset asset) async {
    await _dbRef.insert(
      'synced_assets',
      asset.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Fetch all synced assets whose local file has NOT been deleted yet.
  Future<List<SyncedAsset>> listDeletable() async {
    final rows = await _dbRef.query(
      'synced_assets',
      where: 'local_deleted = 0',
      orderBy: 'synced_at DESC',
    );
    return rows.map(SyncedAsset.fromRow).toList();
  }

  /// Fetch all synced assets regardless of local deletion state.
  Future<List<SyncedAsset>> listAllSynced() async {
    final rows = await _dbRef.query(
      'synced_assets',
      orderBy: 'synced_at DESC',
    );
    return rows.map(SyncedAsset.fromRow).toList();
  }

  /// Mark a synced asset as locally deleted (after the space-saver removed
  /// the local copy).
  Future<void> markLocallyDeleted(int id) async {
    await _dbRef.update(
      'synced_assets',
      {'local_deleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Remove all synced-asset rows (used by logout flow / tests).
  Future<void> clearSynced() async {
    await _dbRef.delete('synced_assets');
  }

  /// Total count of synced assets (verified).
  Future<int> syncedCount() async {
    final rows =
        await _dbRef.rawQuery('SELECT COUNT(*) AS c FROM synced_assets');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Count of synced assets already locally deleted.
  Future<int> locallyDeletedCount() async {
    final rows = await _dbRef
        .rawQuery('SELECT COUNT(*) AS c FROM synced_assets WHERE local_deleted = 1');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  // --- Device stats (FR-6) ------------------------------------------------

  /// Upsert a device's stats row. Creates the row if the device is new,
  /// otherwise updates the existing row in place.
  Future<void> upsertDeviceStats(DeviceStats stats) async {
    await _dbRef.insert(
      'device_stats',
      stats.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Fetch stats for a single device, or null if not tracked yet.
  Future<DeviceStats?> deviceStats(String deviceId) async {
    final rows = await _dbRef.query(
      'device_stats',
      where: 'device_id = ?',
      whereArgs: [deviceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DeviceStats.fromRow(rows.first);
  }

  /// Fetch all tracked device stats, ordered by most-recently-synced first.
  Future<List<DeviceStats>> allDeviceStats() async {
    final rows = await _dbRef.query(
      'device_stats',
      orderBy: 'last_sync_at DESC',
    );
    return rows.map(DeviceStats.fromRow).toList();
  }

  /// Remove a device's stats row (used by logout / account removal).
  Future<void> clearDeviceStats(String deviceId) async {
    await _dbRef.delete(
      'device_stats',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  /// Remove all device stats rows (used by full logout / tests).
  Future<void> clearAllDeviceStats() async {
    await _dbRef.delete('device_stats');
  }

  // --- Verification results (FR-7, Phase 6) ------------------------------

  /// Upsert a verification result. The row is keyed by `server_asset_id`
  /// when present, otherwise by `local_id`. Repeated verifications of the
  /// same asset update the existing row in place rather than accumulate.
  Future<void> upsertVerificationResult(VerificationResult result) async {
    await _dbRef.insert(
      'verification_results',
      result.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Bulk-upsert a batch of verification results.
  Future<void> upsertVerificationResults(
    List<VerificationResult> results,
  ) async {
    if (results.isEmpty) return;
    final batch = _dbRef.batch();
    for (final r in results) {
      batch.insert(
        'verification_results',
        r.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Fetch all verification results, ordered most-recently-checked first.
  Future<List<VerificationResult>> listVerificationResults() async {
    final rows = await _dbRef.query(
      'verification_results',
      orderBy: 'checked_at DESC',
    );
    return rows.map(VerificationResult.fromRow).toList();
  }

  /// Count verification results grouped by status. Returns a map keyed by
  /// [VerifyStatus]. Used by the verifier UI to render summary cards.
  Future<Map<VerifyStatus, int>> verificationCounts() async {
    final rows = await _dbRef.rawQuery(
      'SELECT status, COUNT(*) AS c FROM verification_results GROUP BY status',
    );
    final out = <VerifyStatus, int>{};
    for (final row in rows) {
      final code = row['status'] as int;
      final count = row['c'] as int;
      out[VerifyStatusCode.fromCode(code)] = count;
    }
    return out;
  }

  /// Total number of verification results recorded.
  Future<int> verificationTotal() async {
    final rows = await _dbRef
        .rawQuery('SELECT COUNT(*) AS c FROM verification_results');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Remove all verification results (used by logout / tests).
  Future<void> clearVerificationResults() async {
    await _dbRef.delete('verification_results');
  }

  /// Close the database. Safe to call multiple times.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}