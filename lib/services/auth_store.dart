import 'package:shared_preferences/shared_preferences.dart';

import 'immich_api_client.dart';

/// Persists Immich auth + server configuration across app restarts (FR-1).
///
/// Storage keys (all under SharedPreferences):
/// - "immich.server_url"
/// - "immich.access_token"
/// - "immich.user_id"
/// - "immich.device_id"  (created once, reused for all uploads)
class AuthStore {
  static const _keyServerUrl = 'immich.server_url';
  static const _keyAccessToken = 'immich.access_token';
  static const _keyUserId = 'immich.user_id';
  static const _keyDeviceId = 'immich.device_id';

  final ImmichApiClient apiClient;

  AuthStore(this.apiClient);

  /// Load persisted state into the api client. Returns true if a previous
  /// login session was restored.
  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString(_keyServerUrl);
    final token = prefs.getString(_keyAccessToken);
    if (serverUrl == null || token == null) return false;
    apiClient.configureServer(serverUrl);
    apiClient.setAccessToken(token);
    return true;
  }

  /// Persist a freshly obtained access token after a successful login.
  Future<void> saveLogin(ImmichLoginResult result, String serverUrl) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyServerUrl, serverUrl);
    await prefs.setString(_keyAccessToken, result.accessToken);
    await prefs.setString(_keyUserId, result.userId);
    apiClient.configureServer(serverUrl);
    apiClient.setAccessToken(result.accessToken);
  }

  /// Clear all persisted auth state (logout).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyServerUrl);
    await prefs.remove(_keyAccessToken);
    await prefs.remove(_keyUserId);
    apiClient.clearAccessToken();
  }

  /// Returns the stored user ID, or null if not logged in.
  Future<String?> userId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserId);
  }

  /// Returns a stable per-device ID used in Immich upload metadata. Created
  /// on first access so multiple uploads from the same device share an ID.
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceId);
    if (id == null || id.isEmpty) {
      // Use the stored userId as a stable device identifier. In a single-user
      // setup this is sufficient; multi-account support (FR-10) lands in a
      // later phase with a proper per-install UUID.
      id = prefs.getString(_keyUserId) ?? 'anh-nha-device';
      await prefs.setString(_keyDeviceId, id);
    }
    return id;
  }

  /// True if a server URL + access token are persisted.
  Future<bool> hasStoredSession() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyServerUrl) != null &&
        prefs.getString(_keyAccessToken) != null;
  }
}