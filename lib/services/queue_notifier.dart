import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Displays and updates an ongoing foreground notification showing the
/// current sync-queue status (FR-3).
///
/// The notification is shown as an ongoing (non-dismissible) notification
/// while there are pending items in the queue, and updated whenever the
/// queue stats change. It is cancelled once the queue drains completely.
///
/// Note: this is a foreground notification shown while the app process is
/// alive — it keeps the user informed of queue status without requiring a
/// full Android foreground service. Background scheduling of the sync pass
/// itself is a future-phase concern (the plan's technical approach mentions
/// WorkManager for a later phase).
class QueueNotifier {
  static const _channelId = 'anh_nha_queue';
  static const _channelName = 'Sync queue';
  static const _notificationId = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Initialize the notification plugin and create the channel. Must be
  /// called once at app startup, before [update]. Idempotent.
  Future<void> init() async {
    if (_initialized) return;
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(initSettings);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: 'Shows the current photo sync queue status',
            importance: Importance.low,
            showBadge: false,
          ),
        );
    _initialized = true;
  }

  /// Refresh the foreground notification to reflect the supplied queue
  /// stats. Shows an ongoing notification when `pending > 0` and cancels it
  /// when the queue is empty.
  Future<void> update({
    required int pending,
    required int failed,
    required bool peerOnline,
  }) async {
    if (!_initialized) return;
    if (pending == 0 && failed == 0) {
      await _plugin.cancel(_notificationId);
      return;
    }
    final title = peerOnline
        ? 'Syncing $pending photo${pending == 1 ? '' : 's'}'
        : 'Waiting for server — $pending photo${pending == 1 ? '' : 's'} queued';
    final body = StringBuffer();
    if (pending > 0) {
      body.write('$pending pending');
    }
    if (failed > 0) {
      if (body.isNotEmpty) body.write(' • ');
      body.write('$failed failed');
    }
    if (!peerOnline) {
      if (body.isNotEmpty) body.write(' • ');
      body.write('server offline');
    }
    await _plugin.show(
      _notificationId,
      title,
      body.toString(),
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          ongoing: true,
          priority: Priority.low,
          importance: Importance.low,
          showWhen: false,
          category: AndroidNotificationCategory.progress,
        ),
      ),
    );
  }

  /// Cancel the notification (e.g. on logout).
  Future<void> cancel() async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId);
  }
}