import 'package:flutter/material.dart';

import '../services/space_saver.dart';
import '../services/sync_queue_db.dart';

/// Space-saver tool screen (FR-5, AC-2).
///
/// Shows storage statistics (freed space, remaining queue, reclaimable
/// space), lists synced+checksum-verified photos, and offers a one-tap
/// "Free Space" action with a confirmation dialog. Only photos whose local
/// checksum was verified against the server are shown — enforcing the
/// "only deletes after checksum verification" rule.
class SpaceSaverScreen extends StatefulWidget {
  final SyncQueueDb queueDb;

  const SpaceSaverScreen({super.key, required this.queueDb});

  @override
  State<SpaceSaverScreen> createState() => _SpaceSaverScreenState();
}

class _SpaceSaverScreenState extends State<SpaceSaverScreen> {
  late final SpaceSaver _spaceSaver;
  SpaceSaverStats _stats = const SpaceSaverStats.empty();
  List<SyncedAsset> _deletable = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _spaceSaver = SpaceSaver(widget.queueDb);
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final stats = await _spaceSaver.gatherStats();
      final deletable = await _spaceSaver.listDeletable();
      if (mounted) {
        setState(() {
          _stats = stats;
          _deletable = deletable;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load: $e')),
        );
      }
    }
  }

  Future<void> _freeAll() async {
    if (_deletable.isEmpty) return;
    final confirmed = await _confirmDelete(_deletable.length, _stats.reclaimableBytes);
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final result = await _spaceSaver.freeSpace(_deletable);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.deleted == result.requested
                  ? 'Freed ${_formatBytes(result.freedBytes)} '
                      'by deleting ${result.deleted} photo'
                      '${result.deleted == 1 ? '' : 's'}.'
                  : 'Deleted ${result.deleted}/${result.requested} photos. '
                      '${result.failedIds.length} failed.',
            ),
          ),
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmDelete(int count, int bytes) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Free space'),
        content: Text(
          'Delete $count local cop'
          '${count == 1 ? 'y' : 'ies'} of synced photos and reclaim '
          '${_formatBytes(bytes)}?\n\n'
          'The server keeps the originals. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Delete local copies'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Space saver'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _StatCard(
                  icon: Icons.cloud_done,
                  label: 'Safe to delete',
                  value: '${_stats.deletableCount} photo'
                      '${_stats.deletableCount == 1 ? '' : 's'}',
                  sub: 'Reclaim ${_formatBytes(_stats.reclaimableBytes)}',
                  highlight: _stats.deletableCount > 0,
                ),
                const SizedBox(height: 12),
                _StatCard(
                  icon: Icons.delete_sweep,
                  label: 'Already freed',
                  value: '${_stats.freedCount} photo'
                      '${_stats.freedCount == 1 ? '' : 's'}',
                ),
                const SizedBox(height: 12),
                _StatCard(
                  icon: Icons.queue,
                  label: 'Still queued (not synced)',
                  value: '${_stats.queuePending}',
                  sub: _stats.queuePending > 0
                      ? 'Wait for sync before freeing'
                      : null,
                ),
                const SizedBox(height: 24),
                if (_deletable.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(Icons.check_circle,
                              size: 48, color: theme.colorScheme.primary),
                          const SizedBox(height: 12),
                          Text(
                            'Nothing to free yet',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _stats.queuePending > 0
                                ? 'Sync your photos first — once they are '
                                  'uploaded and verified, they will appear '
                                  'here for safe deletion.'
                                : 'Synced photos with verified checksums '
                                  'will appear here.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : _freeAll,
                    icon: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_forever),
                    label: Text(
                      _busy
                          ? 'Deleting…'
                          : 'Free ${_formatBytes(_stats.reclaimableBytes)}',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Synced photos (${_deletable.length})',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final asset in _deletable)
                    ListTile(
                      leading: const Icon(Icons.photo),
                      title: Text(asset.filename),
                      subtitle: Text(
                        'Verified · synced ${_formatDate(asset.syncedAt)}',
                      ),
                      trailing: const Icon(Icons.verified, size: 18),
                    ),
                ],
              ],
            ),
    );
  }
}

/// Formats a byte count into a human-readable string (e.g. "12.3 MB").
String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return size < 10
      ? '${size.toStringAsFixed(1)} ${units[unit]}'
      : '${size.toStringAsFixed(0)} ${units[unit]}';
}

/// Formats a DateTime as a short local date string.
String _formatDate(DateTime dt) {
  final y = dt.year;
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final bool highlight;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? theme.colorScheme.primary : null;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(label, style: theme.textTheme.bodyMedium),
        subtitle: Text(value,
            style: theme.textTheme.titleMedium?.copyWith(color: color)),
        trailing: sub == null
            ? null
            : Text(sub!, style: theme.textTheme.bodySmall),
      ),
    );
  }
}