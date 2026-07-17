import 'package:connectivity_plus/connectivity_plus.dart';

/// Connectivity state of the device relevant to upload gating.
enum NetworkType { wifi, mobile, ethernet, none, other }

/// Snapshot of current connectivity state.
class ConnectivityState {
  final NetworkType type;
  final bool isWifi;

  const ConnectivityState({required this.type, required this.isWifi});

  /// Reduce the connectivity_plus v6 list-of-results to a single type. The
  /// platform can report multiple active transports simultaneously; we treat
  /// any WiFi entry as "on WiFi" and prefer that signal over others.
  static NetworkType _fromResults(List<ConnectivityResult> results) {
    if (results.isEmpty) return NetworkType.none;
    if (results.contains(ConnectivityResult.wifi)) return NetworkType.wifi;
    if (results.contains(ConnectivityResult.mobile)) return NetworkType.mobile;
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkType.ethernet;
    }
    if (results.contains(ConnectivityResult.none)) return NetworkType.none;
    return NetworkType.other;
  }

  factory ConnectivityState.fromResults(List<ConnectivityResult> results) {
    final type = _fromResults(results);
    return ConnectivityState(type: type, isWifi: type == NetworkType.wifi);
  }
}

/// Monitors device connectivity and enforces the WiFi-only upload rule (FR-8).
///
/// Phase 3 will extend this with Tailscale peer reachability polling. For
/// Phase 2 we only check that the active network is WiFi before allowing any
/// uploads.
class ConnectivityMonitor {
  final Connectivity _connectivity = Connectivity();

  ConnectivityState _current = const ConnectivityState(
    type: NetworkType.other,
    isWifi: false,
  );

  ConnectivityMonitor() {
    _connectivity.onConnectivityChanged.listen((results) {
      _current = ConnectivityState.fromResults(results);
    });
  }

  /// Latest cached connectivity state. Updated by the stream listener.
  ConnectivityState get current => _current;

  /// True only when the active network is WiFi (FR-8).
  bool get isWifi => _current.isWifi;

  /// Returns true if uploads are allowed right now. Currently that means WiFi
  /// only; Phase 3 will additionally require Tailscale peer reachability.
  bool get uploadsAllowed => isWifi;

  /// Read the current connectivity state on demand (awaited).
  Future<ConnectivityState> check() async {
    final results = await _connectivity.checkConnectivity();
    _current = ConnectivityState.fromResults(results);
    return _current;
  }

  /// Dispose internal subscriptions. Safe to call multiple times.
  void dispose() {
    // connectivity_plus does not expose a close() — listeners are GC'd.
  }
}