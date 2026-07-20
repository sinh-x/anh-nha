import 'package:flutter/material.dart';

import '../services/backup_verifier.dart';
import '../services/sync_queue_db.dart';

/// Backup integrity verification screen (FR-7, AC-5, Phase 6).
///
/// Shows per-photo verification status (match / mismatch / local missing /
/// server missing / error), a summary of the last batch run, and a "Verify
/// all" action that recomputes local SHA-256 checksums and compares them
/// against the Immich server's stored checksums. Mismatches are surfaced
/// prominently so the user can re-upload or investigate.
class VerificationScreen extends StatefulWidget {
  final BackupVerifier verifier;
  final SyncQueueDb queueDb;

  const VerificationScreen({
    super.key,
    required this.verifier,
    required this.queueDb,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  VerifySummary _summary = const VerifySummary.empty();
  List<VerificationResult> _results = const [];
  bool _loading = true;
  bool _verifying = false;
  int _completed = 0;
  int _verifyTotal = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCached();
  }

  Future<void> _loadCached() async {
    try {
      final summary = await widget.verifier.summaryFromDb();
      final results = await widget.verifier.recentResults();
      if (mounted) {
        setState(() {
          _summary = summary;
          _results = results;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _runVerifyAll() async {
    setState(() {
      _verifying = true;
      _error = null;
      _completed = 0;
      _verifyTotal = 0;
    });
    try {
      final summary = await widget.verifier.verifyAll(
        onProgress: (completed, total, last) {
          if (mounted) {
            setState(() {
              _completed = completed;
              _verifyTotal = total;
            });
          }
        },
      );
      final results = await widget.verifier.recentResults();
      if (mounted) {
        setState(() {
          _summary = summary;
          _results = results;
          _verifying = false;
        });
        final msg = summary.allOk
            ? 'All ${summary.total} photos verified — checksums match.'
            : 'Verification complete: ${summary.mismatched} mismatch'
                '${summary.mismatched == 1 ? '' : 'es'}, '
                '${summary.localMissing} local missing, '
                '${summary.serverMissing} server missing, '
                '${summary.errors} error'
                '${summary.errors == 1 ? '' : 's'}.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _verifying = false;
          _error = '$e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verification failed: $e')),
        );
      }
    }
  }

  Future<void> _reverifyOne(VerificationResult result) async {
    try {
      await widget.verifier.verifyOne(result.localId);
      final summary = await widget.verifier.summaryFromDb();
      final results = await widget.verifier.recentResults();
      if (mounted) {
        setState(() {
          _summary = summary;
          _results = results;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Re-verify failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup verification'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _verifying ? null : _loadCached,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SummaryBanner(summary: _summary),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _verifying ? null : _runVerifyAll,
                  icon: _verifying
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.verified),
                  label: Text(_verifying
                      ? 'Verifying $_completed/$_verifyTotal…'
                      : 'Verify all photos'),
                ),
                if (_verifying && _verifyTotal > 0) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _completed / _verifyTotal,
                  ),
                ],
                const SizedBox(height: 16),
                if (_error != null)
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Error: $_error',
                        style: TextStyle(color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ),
                Text('Per-photo status (${_results.length})',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_results.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(Icons.fact_check,
                              size: 48, color: theme.colorScheme.primary),
                          const SizedBox(height: 12),
                          Text(
                            'No verifications yet',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Tap "Verify all photos" to compare local '
                            'checksums against the Immich server\'s stored '
                            'checksums. Mismatches are flagged here.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  for (final r in _results)
                    _ResultTile(
                      result: r,
                      onReverify: () => _reverifyOne(r),
                    ),
              ],
            ),
    );
  }
}

/// Banner summarizing the last verification pass.
class _SummaryBanner extends StatelessWidget {
  final VerifySummary summary;

  const _SummaryBanner({required this.summary});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color bannerColor;
    final IconData bannerIcon;
    final String bannerText;
    if (summary.total == 0) {
      bannerColor = theme.colorScheme.surfaceContainerHighest;
      bannerIcon = Icons.fact_check;
      bannerText = 'No verifications run yet';
    } else if (summary.mismatched > 0 || summary.errors > 0) {
      bannerColor = theme.colorScheme.errorContainer;
      bannerIcon = Icons.warning;
      bannerText = summary.mismatched > 0
          ? '${summary.mismatched} checksum mismatch'
              '${summary.mismatched == 1 ? '' : 'es'} detected — '
              're-upload or investigate.'
          : '${summary.errors} verification error'
              '${summary.errors == 1 ? '' : 's'} occurred.';
    } else {
      bannerColor = theme.colorScheme.primaryContainer;
      bannerIcon = Icons.verified;
      bannerText = 'All ${summary.total} photos verified — checksums match.';
    }
    return Card(
      color: bannerColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(bannerIcon,
                size: 36,
                color: theme.colorScheme.onSurface),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bannerText,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${summary.matched} matched · '
                    '${summary.mismatched} mismatched · '
                    '${summary.localMissing} local missing · '
                    '${summary.serverMissing} server missing · '
                    '${summary.errors} error'
                    '${summary.errors == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-photo status row with the comparison outcome and a re-verify action.
class _ResultTile extends StatelessWidget {
  final VerificationResult result;
  final VoidCallback onReverify;

  const _ResultTile({required this.result, required this.onReverify});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = _statusVisual(result.status, theme);
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(result.filename),
      subtitle: Text(
        '$_shortChecksum(result.localChecksumBase64) vs '
        '${_shortChecksum(result.serverChecksumBase64 ?? "—")}\n'
        '$label · checked ${_formatDate(result.checkedAt)}',
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.refresh, size: 20),
        tooltip: 'Re-verify this photo',
        onPressed: onReverify,
      ),
    );
  }

  (IconData, Color, String) _statusVisual(
    VerifyStatus status,
    ThemeData theme,
  ) {
    switch (status) {
      case VerifyStatus.match:
        return (Icons.check_circle, theme.colorScheme.primary, 'Match');
      case VerifyStatus.mismatch:
        return (Icons.broken_image, theme.colorScheme.error, 'Mismatch');
      case VerifyStatus.localMissing:
        return (Icons.phonelink_erase, theme.colorScheme.outline,
            'Local copy deleted');
      case VerifyStatus.serverMissing:
        return (Icons.cloud_off, theme.colorScheme.error,
            'Server has no record');
      case VerifyStatus.error:
        return (Icons.error_outline, theme.colorScheme.error, 'Error');
    }
  }

  String _shortChecksum(String? checksum) {
    if (checksum == null || checksum.isEmpty) return '—';
    if (checksum.length <= 12) return checksum;
    return '${checksum.substring(0, 8)}…';
  }
}

String _formatDate(DateTime dt) {
  final y = dt.year;
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}