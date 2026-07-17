import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Snapshot of Tailscale peer reachability for the laptop running the
/// Immich server (FR-4).
class TailscalePeerState {
  /// True when the configured laptop peer is online and reachable over
  /// Tailscale right now.
  final bool online;

  /// Human-readable host name of the peer (when available from the local
  /// API), used for the UI status line.
  final String? hostName;

  /// Tailscale 100.x.y.z IPv4 address of the peer, if known.
  final String? peerAddress;

  /// When this snapshot was last refreshed.
  final DateTime? checkedAt;

  const TailscalePeerState({
    required this.online,
    this.hostName,
    this.peerAddress,
    this.checkedAt,
  });

  static const TailscalePeerState unknown = TailscalePeerState(
    online: false,
    hostName: null,
    peerAddress: null,
    checkedAt: null,
  );

  TailscalePeerState copyWith({
    bool? online,
    String? hostName,
    String? peerAddress,
    DateTime? checkedAt,
  }) {
    return TailscalePeerState(
      online: online ?? this.online,
      hostName: hostName ?? this.hostName,
      peerAddress: peerAddress ?? this.peerAddress,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

/// Monitors the laptop Immich-server peer via the Tailscale local API
/// (FR-4, NFR-2).
///
/// The Tailscale local API runs on every device running `tailscaled` and is
/// reachable at the special address `100.100.100.100:41112`. On Android the
/// Tailscale app exposes the same API. We poll it on a configurable interval
/// (default 30s per NFR-2) to detect when the laptop peer becomes reachable,
/// which is the trigger for resuming sync.
///
/// The local API returns a JSON list of peers. Each peer has an `Online`
/// boolean, `HostName`, and `TailscaleIPs` array. We match the configured
/// laptop peer by its Tailscale IP (the same 100.x.y.z the user entered as
/// the Immich server URL). Matching by IP is the most stable identifier
/// across Tailscale reconnects and avoids ambiguity when multiple peers share
/// a host name.
class TailscaleMonitor {
  /// Default local API endpoint for the Tailscale daemon on any platform.
  static const defaultLocalApiUrl = 'http://100.100.100.100:41112';

  /// Default polling interval (NFR-2: sync should begin within 60s of peer
  /// becoming reachable; 30s polling keeps the worst case under 60s).
  static const defaultPollInterval = Duration(seconds: 30);

  final http.Client _httpClient;
  final String _localApiUrl;
  final Duration _pollInterval;

  /// The Tailscale IP of the laptop peer to watch. When null the monitor is
  /// disabled and reports offline. Mutable so [configurePeer] can update it
  /// after construction (the IP is derived from the stored Immich server URL,
  /// which is only known after session restore/login).
  String? _peerIp;

  Timer? _timer;
  TailscalePeerState _state = TailscalePeerState.unknown;
  final StreamController<TailscalePeerState> _controller =
      StreamController<TailscalePeerState>.broadcast();

  TailscaleMonitor({
    http.Client? httpClient,
    String localApiUrl = defaultLocalApiUrl,
    Duration pollInterval = defaultPollInterval,
    String? peerIp,
  })  : _httpClient = httpClient ?? http.Client(),
        _localApiUrl = localApiUrl,
        _pollInterval = pollInterval,
        _peerIp = peerIp;

  /// Latest cached peer state.
  TailscalePeerState get state => _state;

  /// Stream of peer-state updates. Emits whenever a poll completes.
  Stream<TailscalePeerState> get changes => _controller.stream;

  /// True when the configured laptop peer is currently online.
  bool get isPeerOnline => _state.online;

  /// Update the laptop peer IP to watch. Resets cached state to unknown and
  /// triggers an immediate refresh if polling is active.
  void configurePeer(String? peerIp) {
    if (peerIp == _peerIp) return;
    _peerIp = peerIp;
    _state = TailscalePeerState.unknown;
    if (_timer != null) {
      unawaited(_refresh());
    }
  }

  /// Start polling the Tailscale local API on the configured interval.
  /// Performs an immediate refresh, then repeats every [_pollInterval].
  void start() {
    if (_timer != null) return;
    unawaited(_refresh());
    _timer = Timer.periodic(_pollInterval, (_) => _refresh());
  }

  /// Stop polling. The last cached state is retained.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Query the Tailscale local API once and update cached state.
  Future<TailscalePeerState> refresh() => _refresh();

  Future<TailscalePeerState> _refresh() async {
    final peerIp = _peerIp;
    if (peerIp == null || peerIp.isEmpty) {
      _emit(const TailscalePeerState(
        online: false,
        checkedAt: null,
      ));
      return _state;
    }
    try {
      final response = await _httpClient.get(
        Uri.parse('$_localApiUrl/localapi/v0/status'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _emit(TailscalePeerState(
          online: false,
          peerAddress: peerIp,
          checkedAt: DateTime.now(),
        ));
        return _state;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final peers = body['Peer'] as Map<String, dynamic>? ?? {};
      TailscalePeerState? found;
      for (final peer in peers.values) {
        final map = peer as Map<String, dynamic>;
        final ips = (map['TailscaleIPs'] as List<dynamic>?) ?? [];
        if (!ips.contains(peerIp)) continue;
        found = TailscalePeerState(
          online: (map['Online'] as bool?) ?? false,
          hostName: map['HostName'] as String?,
          peerAddress: peerIp,
          checkedAt: DateTime.now(),
        );
        break;
      }
      _emit(found ??
          TailscalePeerState(
            online: false,
            peerAddress: peerIp,
            checkedAt: DateTime.now(),
          ));
    } on Exception {
      _emit(TailscalePeerState(
        online: false,
        peerAddress: peerIp,
        checkedAt: DateTime.now(),
      ));
    }
    return _state;
  }

  void _emit(TailscalePeerState state) {
    _state = state;
    if (!_controller.isClosed) _controller.add(state);
  }

  /// Stop polling and release resources. Safe to call multiple times.
  void dispose() {
    stop();
    _controller.close();
    _httpClient.close();
  }
}

/// Extracts the Tailscale 100.x.y.z IPv4 address (if any) from a server URL
/// the user typed in the login screen. Used to auto-configure the
/// [TailscaleMonitor] peer IP from the stored Immich server URL.
String? extractTailscaleIp(String serverUrl) {
  final trimmed = serverUrl.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return null;
  final host = uri.host;
  final parts = host.split('.');
  if (parts.length == 4 && parts.first == '100') {
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
    }
    return host;
  }
  return null;
}