import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/device_registry.dart';
import '../services/immich_api_client.dart';
import '../services/sync_queue_db.dart';

/// Multi-device dashboard screen (FR-6, AC-4).
///
/// Shows per-device stats for every device that has uploaded to this user's
/// Immich library:
///   - Device label (or ID if unlabeled)
///   - Last sync timestamp
///   - Pending queue size (local device only; remote devices report 0)
///   - Total synced count (from the Immich server)
///
/// The local device is highlighted. Remote devices are discovered from the
/// server's asset list — each asset records the `deviceId` that uploaded it,
/// so the dashboard can show "the other family phone" without any direct
/// device-to-device communication.
class DashboardScreen extends StatefulWidget {
  final DeviceRegistry deviceRegistry;
  final SyncQueueDb queueDb;
  final AuthStore authStore;

  const DashboardScreen({
    super.key,
    required this.deviceRegistry,
    required this.queueDb,
    required this.authStore,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<DeviceDashboardEntry> _entries = const [];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String? _localDeviceId;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final deviceId = await widget.authStore.deviceId();
    final label = await widget.authStore.localDeviceLabel();
    if (!mounted) return;
    setState(() => _localDeviceId = deviceId);
    widget.deviceRegistry.setLocalLabel(label ?? '');
    // Fast initial render from the local cache, then refresh from server.
    await _loadFromCache(localPendingCount: await _pendingCount());
    await _refresh();
  }

  Future<int> _pendingCount() async {
    final stats = await widget.queueDb.stats();
    return stats.pending;
  }

  Future<void> _loadFromCache({required int localPendingCount}) async {
    if (_localDeviceId == null) return;
    final entries = await widget.deviceRegistry.cachedEntries(
      localDeviceId: _localDeviceId!,
      localPendingCount: localPendingCount,
    );
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (_localDeviceId == null) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final pending = await _pendingCount();
      final entries = await widget.deviceRegistry.refresh(
        localDeviceId: _localDeviceId!,
        localPendingCount: pending,
      );
      if (mounted) {
        setState(() {
          _entries = entries;
          _refreshing = false;
        });
      }
    } on ImmichApiException catch (e) {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _setLabel() async {
    final controller = TextEditingController();
    final existing = await widget.authStore.localDeviceLabel();
    controller.text = existing ?? '';
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device label'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Label',
            hintText: 'e.g. Sinh\'s phone',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    await widget.authStore.setLocalDeviceLabel(result);
    widget.deviceRegistry.setLocalLabel(result);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.label_outline),
            tooltip: 'Set device label',
            onPressed: _setLabel,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Family devices',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Per-device sync status for your Immich library '
                    '(FR-6, AC-4).',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Could not refresh from server: $_error. '
                          'Showing last known stats.',
                          style: TextStyle(
                              color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ),
                  if (_entries.isEmpty && !_refreshing)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.devices,
                                size: 48, color: theme.colorScheme.primary),
                            const SizedBox(height: 12),
                            Text(
                              'No devices yet',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Sync a photo from a phone and it will appear '
                              'here. Each phone that uploads to your Immich '
                              'library is tracked by its device ID.',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    for (final entry in _entries)
                      _DeviceCard(entry: entry),
                ],
              ),
            ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceDashboardEntry entry;

  const _DeviceCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = entry.isLocal ? theme.colorScheme.primary : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(entry.isLocal ? Icons.phone_android : Icons.phone_iphone,
                    color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.deviceLabel?.isNotEmpty == true
                            ? entry.deviceLabel!
                            : _shortId(entry.deviceId),
                        style: theme.textTheme.titleMedium
                            ?.copyWith(color: color),
                      ),
                      if (entry.deviceLabel?.isNotEmpty == true)
                        Text(
                          _shortId(entry.deviceId),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (entry.isLocal)
                  Chip(
                    label: const Text('This phone'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _StatRow(
              icon: Icons.schedule,
              label: 'Last sync',
              value: entry.lastSyncAt == null
                  ? 'Never'
                  : _formatDateTime(entry.lastSyncAt!),
            ),
            _StatRow(
              icon: Icons.hourglass_empty,
              label: 'Pending queue',
              value: '${entry.pendingCount}',
            ),
            _StatRow(
              icon: Icons.cloud_done,
              label: 'Total synced',
              value: '${entry.totalSyncedCount}',
            ),
          ],
        ),
      ),
    );
  }

  String _shortId(String id) {
    if (id.length <= 8) return id;
    return '${id.substring(0, 8)}…';
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year;
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}