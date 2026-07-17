import 'package:flutter/material.dart';

import 'services/auth_store.dart';
import 'services/connectivity_monitor.dart';
import 'services/immich_api_client.dart';
import 'services/queue_notifier.dart';
import 'services/sync_engine.dart';
import 'services/sync_queue_db.dart';
import 'services/tailscale_monitor.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/space_saver_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AnhNhaApp());
}

class AnhNhaApp extends StatefulWidget {
  const AnhNhaApp({super.key});

  @override
  State<AnhNhaApp> createState() => _AnhNhaAppState();
}

class _AnhNhaAppState extends State<AnhNhaApp> {
  late final ImmichApiClient _apiClient;
  late final AuthStore _authStore;
  late final ConnectivityMonitor _connectivity;
  late final SyncQueueDb _queueDb;
  late final TailscaleMonitor _tailscale;
  late final QueueNotifier _notifier;
  late final SyncEngine _syncEngine;
  bool _restoredSession = false;

  @override
  void initState() {
    super.initState();
    _apiClient = ImmichApiClient();
    _authStore = AuthStore(_apiClient);
    _connectivity = ConnectivityMonitor();
    _queueDb = SyncQueueDb();
    _tailscale = TailscaleMonitor();
    _notifier = QueueNotifier();
    _syncEngine = SyncEngine(
      apiClient: _apiClient,
      authStore: _authStore,
      connectivity: _connectivity,
      queueDb: _queueDb,
      tailscale: _tailscale,
      notifier: _notifier,
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _queueDb.open();
    await _notifier.init();
    final ok = await _authStore.load();
    if (ok) {
      final serverUrl = _apiClient.serverUrl;
      final peerIp = extractTailscaleIp(serverUrl);
      _tailscale.configurePeer(peerIp);
      await _syncEngine.start();
    }
    if (mounted) {
      setState(() {
        _restoredSession = ok;
      });
    }
  }

  @override
  void dispose() {
    _syncEngine.dispose();
    _apiClient.dispose();
    _connectivity.dispose();
    super.dispose();
  }

  void _onLoginSuccess() {
    final peerIp = extractTailscaleIp(_apiClient.serverUrl);
    _tailscale.configurePeer(peerIp);
    _syncEngine.start();
    setState(() => _restoredSession = true);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'anh-nha',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      initialRoute: _restoredSession ? '/home' : '/login',
      routes: {
        '/login': (context) => LoginScreen(
              authStore: _authStore,
              onLoginSuccess: _onLoginSuccess,
            ),
        '/home': (context) => HomeScreen(
              authStore: _authStore,
              syncEngine: _syncEngine,
              connectivity: _connectivity,
              tailscale: _tailscale,
            ),
        '/space-saver': (context) => SpaceSaverScreen(queueDb: _queueDb),
      },
    );
  }
}