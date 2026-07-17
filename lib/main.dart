import 'package:flutter/material.dart';

import 'services/auth_store.dart';
import 'services/connectivity_monitor.dart';
import 'services/immich_api_client.dart';
import 'services/sync_engine.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() {
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
  late final SyncEngine _syncEngine;
  bool _restoredSession = false;

  @override
  void initState() {
    super.initState();
    _apiClient = ImmichApiClient();
    _authStore = AuthStore(_apiClient);
    _connectivity = ConnectivityMonitor();
    _syncEngine = SyncEngine(
      apiClient: _apiClient,
      authStore: _authStore,
      connectivity: _connectivity,
    );
    _authStore.load().then((ok) {
      if (mounted) setState(() => _restoredSession = ok);
    });
  }

  @override
  void dispose() {
    _apiClient.dispose();
    _connectivity.dispose();
    super.dispose();
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
        '/login': (context) => LoginScreen(authStore: _authStore),
        '/home': (context) => HomeScreen(
              authStore: _authStore,
              syncEngine: _syncEngine,
              connectivity: _connectivity,
            ),
      },
    );
  }
}