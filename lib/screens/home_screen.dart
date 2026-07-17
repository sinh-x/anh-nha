import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/connectivity_monitor.dart';
import '../services/sync_engine.dart';
import '../services/immich_api_client.dart';

/// Home screen showing sync status, WiFi-only indicator, and a manual sync
/// button (FR-2, FR-8).
class HomeScreen extends StatefulWidget {
  final AuthStore authStore;
  final SyncEngine syncEngine;
  final ConnectivityMonitor connectivity;

  const HomeScreen({
    super.key,
    required this.authStore,
    required this.syncEngine,
    required this.connectivity,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  SyncSummary _summary = const SyncSummary(
    scanned: 0,
    uploaded: 0,
    dedupSkipped: 0,
    failed: 0,
    wifiOnly: false,
    running: false,
    recent: [],
  );
  String? _userId;

  @override
  void initState() {
    super.initState();
    widget.authStore.userId().then((id) {
      if (mounted) setState(() => _userId = id);
    });
  }

  Future<void> _runSync() async {
    try {
      await widget.syncEngine.runOnce(onProgress: (s) {
        if (mounted) setState(() => _summary = s);
      });
      if (mounted) setState(() => _summary = widget.syncEngine.summary);
    } on ImmichApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: ${e.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync error: $e')),
        );
      }
    }
  }

  Future<void> _logout() async {
    await widget.authStore.clear();
    if (mounted) Navigator.of(context).pushReplacementNamed('/login');
  }

  @override
  Widget build(BuildContext context) {
    final wifi = _summary.wifiOnly;
    return Scaffold(
      appBar: AppBar(
        title: const Text('anh-nha'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: _logout,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_userId != null)
            ListTile(
              leading: const Icon(Icons.person),
              title: Text('User ID: $_userId'),
              dense: true,
            ),
          _StatusTile(
            icon: wifi ? Icons.wifi : Icons.signal_wifi_off,
            label: 'Network',
            value: wifi ? 'WiFi (uploads allowed)' : 'Not WiFi (uploads blocked)',
            ok: wifi,
          ),
          _StatusTile(
            icon: Icons.cloud_upload,
            label: 'Scanned photos',
            value: '${_summary.scanned}',
          ),
          _StatusTile(
            icon: Icons.cloud_done,
            label: 'Uploaded',
            value: '${_summary.uploaded}',
            ok: _summary.uploaded > 0,
          ),
          _StatusTile(
            icon: Icons.copy,
            label: 'Skipped (dedup)',
            value: '${_summary.dedupSkipped}',
          ),
          _StatusTile(
            icon: Icons.error_outline,
            label: 'Failed',
            value: '${_summary.failed}',
            ok: _summary.failed == 0,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _summary.running ? null : _runSync,
            icon: _summary.running
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(_summary.running ? 'Syncing…' : 'Sync now'),
          ),
          const SizedBox(height: 16),
          if (_summary.recent.isNotEmpty) ...[
            Text('Recent activity', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final p in _summary.recent.take(10))
              ListTile(
                dense: true,
                leading: Icon(_iconFor(p.status)),
                title: Text(p.filename),
                subtitle: Text(_labelFor(p.status)),
              ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(SyncStatus status) {
    switch (status) {
      case SyncStatus.pending:
        return Icons.hourglass_empty;
      case SyncStatus.dedupHit:
        return Icons.copy;
      case SyncStatus.uploading:
        return Icons.cloud_upload;
      case SyncStatus.uploaded:
        return Icons.cloud_done;
      case SyncStatus.failed:
        return Icons.error_outline;
    }
  }

  String _labelFor(SyncStatus status) {
    switch (status) {
      case SyncStatus.pending:
        return 'Pending';
      case SyncStatus.dedupHit:
        return 'Skipped (already on server)';
      case SyncStatus.uploading:
        return 'Uploading…';
      case SyncStatus.uploaded:
        return 'Uploaded';
      case SyncStatus.failed:
        return 'Failed';
    }
  }
}

class _StatusTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool ok;

  const _StatusTile({
    required this.icon,
    required this.label,
    required this.value,
    this.ok = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = ok ? null : Theme.of(context).colorScheme.error;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      trailing: Text(value, style: TextStyle(color: color)),
    );
  }
}