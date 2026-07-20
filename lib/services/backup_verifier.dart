import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'immich_api_client.dart';
import 'sync_queue_db.dart';

/// Outcome of a single asset verification, surfaced to the UI as a
/// per-photo status (FR-7, Phase 6).
class VerifyOutcome {
  final String localId;
  final String? serverAssetId;
  final String filename;
  final String? localChecksumBase64;
  final String? serverChecksumBase64;
  final VerifyStatus status;
  final String? error;

  const VerifyOutcome({
    required this.localId,
    this.serverAssetId,
    required this.filename,
    this.localChecksumBase64,
    this.serverChecksumBase64,
    required this.status,
    this.error,
  });

  VerificationResult toResult(DateTime checkedAt) {
    return VerificationResult(
      localId: localId,
      serverAssetId: serverAssetId,
      filename: filename,
      localChecksumBase64: localChecksumBase64 ?? '',
      serverChecksumBase64: serverChecksumBase64,
      status: status,
      checkedAt: checkedAt,
    );
  }
}

/// Aggregated verification summary surfaced to the UI (FR-7, Phase 6).
class VerifySummary {
  final int total;
  final int matched;
  final int mismatched;
  final int localMissing;
  final int serverMissing;
  final int errors;

  const VerifySummary({
    required this.total,
    required this.matched,
    required this.mismatched,
    required this.localMissing,
    required this.serverMissing,
    required this.errors,
  });

  const VerifySummary.empty()
      : total = 0,
        matched = 0,
        mismatched = 0,
        localMissing = 0,
        serverMissing = 0,
        errors = 0;

  int get checked =>
      matched + mismatched + localMissing + serverMissing + errors;

  bool get allOk => total > 0 && mismatched == 0 && errors == 0;
}

/// Progress callback emitted while a batch verification pass runs.
typedef VerifyProgressCallback = void Function(
  int completed,
  int total,
  VerifyOutcome last,
);

/// Backup integrity verifier (FR-7, Phase 6).
///
/// Compares the locally recomputed SHA-1 checksum of every synced asset
/// against the checksum the Immich server has on file. Mismatches are
/// flagged so the user can re-upload or investigate; missing local files
/// or missing server entries are reported separately.
///
/// Throughput target: NFR-4 — ≥ 50 photos/minute on a mid-range device.
/// SHA-1 over a typical 3–5 MB photo is well under a second on modern
/// phones, so the bottleneck is the server round-trip, not the hash.
class BackupVerifier {
  final ImmichApiClient _apiClient;
  final SyncQueueDb _queueDb;

  BackupVerifier(this._apiClient, this._queueDb);

  /// Run a batch verification pass over every synced asset recorded in the
  /// local `synced_assets` table. Returns the aggregated [VerifySummary].
  ///
  /// For each synced asset:
  ///   1. Look up the server-side asset by `serverAssetId` to fetch its
  ///      current `checksum` field.
  ///   2. Recompute the local file's SHA-256 (skip if the local copy was
  ///      already deleted by the space-saver — reported as `localMissing`).
  ///   3. Compare the two checksums (constant-time) and record the outcome.
  ///
  /// Results are persisted to the `verification_results` table so the UI can
  /// render the most recent status for each photo without re-running the
  /// check.
  Future<VerifySummary> verifyAll({
    VerifyProgressCallback? onProgress,
  }) async {
    final synced = await _queueDb.listAllSynced();

    // Fetch the server's asset list once and index by serverAssetId so we
    // avoid one round-trip per photo. Immich's `POST /api/search/metadata`
    // (paged via [ImmichApiClient.listAssets]) returns every asset for the
    // authenticated user with its `checksum` field populated.
    final Map<String, ImmichAsset> serverById;
    try {
      final serverAssets = await _apiClient.listAssets();
      serverById = {
        for (final a in serverAssets) a.id: a,
      };
    } on Exception {
      // Server unreachable — record an error outcome for every asset so
      // the UI surfaces the failure rather than silently passing. Broadened
      // from `on ImmichApiException` so socket/timeout/HTTP-client errors
      // also engage the fallback.
      final now = DateTime.now();
      final outcomes = <VerificationResult>[];
      for (final asset in synced) {
        outcomes.add(VerifyOutcome(
          localId: asset.localId,
          serverAssetId: asset.serverAssetId,
          filename: asset.filename,
          status: VerifyStatus.error,
          error: 'Server unreachable',
        ).toResult(now));
      }
      await _queueDb.upsertVerificationResults(outcomes);
      return _summarize(outcomes);
    }

    final results = <VerificationResult>[];
    final total = synced.length;
    var completed = 0;
    for (final asset in synced) {
      final outcome = await _verifyOne(asset, serverById);
      final checkedAt = DateTime.now();
      results.add(outcome.toResult(checkedAt));
      completed++;
      onProgress?.call(completed, total, outcome);
      // Persist in batches to avoid holding all results in memory for very
      // large libraries — flush every 50 photos.
      if (results.length >= 50) {
        await _queueDb.upsertVerificationResults(results);
        results.clear();
      }
    }
    if (results.isNotEmpty) {
      await _queueDb.upsertVerificationResults(results);
    }

    final all = await _queueDb.listVerificationResults();
    return _summarizeFromDb(all);
  }

  /// Verify a single synced asset against the server's record.
  Future<VerifyOutcome> _verifyOne(
    SyncedAsset asset,
    Map<String, ImmichAsset> serverById,
  ) async {
    final serverAssetId = asset.serverAssetId;
    final server = serverAssetId == null ? null : serverById[serverAssetId];
    final serverChecksum = server?.checksumBase64;

    // Locally deleted by the space-saver: the local copy is gone, which is
    // expected after a free-space pass. Report as `localMissing` so the UI
    // can show "local copy deleted" rather than treating it as a backup
    // integrity failure.
    if (asset.localDeleted) {
      return VerifyOutcome(
        localId: asset.localId,
        serverAssetId: serverAssetId,
        filename: asset.filename,
        localChecksumBase64: asset.checksumBase64,
        serverChecksumBase64: serverChecksum,
        status: VerifyStatus.localMissing,
      );
    }

    // Server has no record of this asset — either it was deleted on the
    // server, or the serverAssetId was never recorded. Flag it so the user
    // can re-upload.
    if (server == null) {
      return VerifyOutcome(
        localId: asset.localId,
        serverAssetId: serverAssetId,
        filename: asset.filename,
        localChecksumBase64: asset.checksumBase64,
        serverChecksumBase64: null,
        status: VerifyStatus.serverMissing,
      );
    }

    // Recompute the local file's SHA-1. If the file is gone (e.g. deleted
    // out-of-band), report `localMissing`.
    final file = File(asset.filePath);
    final exists = await file.exists();
    if (!exists) {
      return VerifyOutcome(
        localId: asset.localId,
        serverAssetId: serverAssetId,
        filename: asset.filename,
        localChecksumBase64: null,
        serverChecksumBase64: serverChecksum,
        status: VerifyStatus.localMissing,
      );
    }
    String localChecksum;
    try {
      final bytes = await file.readAsBytes();
      final hash = sha1.convert(bytes);
      localChecksum = base64Encode(hash.bytes);
    } catch (e) {
      return VerifyOutcome(
        localId: asset.localId,
        serverAssetId: serverAssetId,
        filename: asset.filename,
        localChecksumBase64: null,
        serverChecksumBase64: serverChecksum,
        status: VerifyStatus.error,
        error: '$e',
      );
    }

    // Server checksum missing — can't compare. Flag so the user knows the
    // server did not report a checksum for this asset.
    if (serverChecksum == null || serverChecksum.isEmpty) {
      return VerifyOutcome(
        localId: asset.localId,
        serverAssetId: serverAssetId,
        filename: asset.filename,
        localChecksumBase64: localChecksum,
        serverChecksumBase64: null,
        status: VerifyStatus.serverMissing,
      );
    }

    final match =
        _constantTimeEquals(localChecksum, serverChecksum);
    return VerifyOutcome(
      localId: asset.localId,
      serverAssetId: serverAssetId,
      filename: asset.filename,
      localChecksumBase64: localChecksum,
      serverChecksumBase64: serverChecksum,
      status: match ? VerifyStatus.match : VerifyStatus.mismatch,
    );
  }

  /// Re-verify a single asset by its local ID. Looks up the latest synced
  /// record and runs the comparison. Returns the outcome, also persisted.
  Future<VerifyOutcome> verifyOne(String localId) async {
    final all = await _queueDb.listAllSynced();
    final asset = all.firstWhere(
      (a) => a.localId == localId,
      orElse: () => throw StateError('No synced asset for $localId'),
    );

    final Map<String, ImmichAsset> serverById;
    try {
      final serverAssets = await _apiClient.listAssets();
      serverById = {for (final a in serverAssets) a.id: a};
    } on Exception {
      final outcome = VerifyOutcome(
        localId: asset.localId,
        serverAssetId: asset.serverAssetId,
        filename: asset.filename,
        status: VerifyStatus.error,
        error: 'Server unreachable',
      );
      await _queueDb.upsertVerificationResult(outcome.toResult(DateTime.now()));
      return outcome;
    }

    final outcome = await _verifyOne(asset, serverById);
    await _queueDb.upsertVerificationResult(outcome.toResult(DateTime.now()));
    return outcome;
  }

  /// Build a [VerifySummary] from a list of outcomes (in-memory).
  VerifySummary _summarize(List<VerificationResult> results) {
    var matched = 0, mismatched = 0, localMissing = 0, serverMissing = 0,
        errors = 0;
    for (final r in results) {
      switch (r.status) {
        case VerifyStatus.match:
          matched++;
          break;
        case VerifyStatus.mismatch:
          mismatched++;
          break;
        case VerifyStatus.localMissing:
          localMissing++;
          break;
        case VerifyStatus.serverMissing:
          serverMissing++;
          break;
        case VerifyStatus.error:
          errors++;
          break;
      }
    }
    return VerifySummary(
      total: results.length,
      matched: matched,
      mismatched: mismatched,
      localMissing: localMissing,
      serverMissing: serverMissing,
      errors: errors,
    );
  }

  /// Build a [VerifySummary] from the persisted `verification_results`
  /// table. Used to render the screen without re-running the check.
  Future<VerifySummary> summaryFromDb() async {
    final all = await _queueDb.listVerificationResults();
    return _summarizeFromDb(all);
  }

  VerifySummary _summarizeFromDb(List<VerificationResult> results) {
    var matched = 0, mismatched = 0, localMissing = 0, serverMissing = 0,
        errors = 0;
    for (final r in results) {
      switch (r.status) {
        case VerifyStatus.match:
          matched++;
          break;
        case VerifyStatus.mismatch:
          mismatched++;
          break;
        case VerifyStatus.localMissing:
          localMissing++;
          break;
        case VerifyStatus.serverMissing:
          serverMissing++;
          break;
        case VerifyStatus.error:
          errors++;
          break;
      }
    }
    return VerifySummary(
      total: results.length,
      matched: matched,
      mismatched: mismatched,
      localMissing: localMissing,
      serverMissing: serverMissing,
      errors: errors,
    );
  }

  /// Load the most recent persisted per-photo results, ordered newest-first.
  Future<List<VerificationResult>> recentResults() async {
    return _queueDb.listVerificationResults();
  }

  /// Constant-time string comparison to avoid timing side-channels when
  /// comparing checksums. Returns true when [a] and [b] are equal.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}