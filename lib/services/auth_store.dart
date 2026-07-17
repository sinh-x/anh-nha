import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'immich_api_client.dart';

/// Metadata for a stored Immich account (FR-10). The app supports multiple
/// family members each with their own Immich credentials. Only one account
/// is active at a time; switching accounts swaps the active session.
class StoredAccount {
  final String id;
  final String serverUrl;
  final String userId;
  final String? name;
  final DateTime savedAt;

  const StoredAccount({
    required this.id,
    required this.serverUrl,
    required this.userId,
    this.name,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverUrl': serverUrl,
        'userId': userId,
        'name': name,
        'savedAt': savedAt.toIso8601String(),
      };

  factory StoredAccount.fromJson(Map<String, dynamic> json) {
    return StoredAccount(
      id: json['id'] as String,
      serverUrl: json['serverUrl'] as String,
      userId: json['userId'] as String,
      name: json['name'] as String?,
      savedAt: DateTime.parse(json['savedAt'] as String),
    );
  }
}

/// Persists Immich auth + server configuration across app restarts (FR-1).
///
/// Phase 5 extends the store to support multiple user accounts (FR-10):
/// each family member can save their own Immich credentials and switch
/// between accounts without re-entering the password. Only one account is
/// active at a time; its access token is loaded into [ImmichApiClient].
///
/// Storage keys (all under SharedPreferences):
/// - "immich.active_account_id"  — id of the currently active account
/// - "immich.accounts"           — JSON array of `StoredAccount` metadata
/// - "immich.access_token.ACCOUNT_ID"  — per-account access token
/// - "immich.device_id"          — per-install UUID (shared across accounts)
/// - "immich.local_device_label" — optional human-readable label
class AuthStore {
  static const _keyActiveAccountId = 'immich.active_account_id';
  static const _keyAccounts = 'immich.accounts';
  static const _keyDeviceId = 'immich.device_id';
  static const _keyLocalDeviceLabel = 'immich.local_device_label';
  static const _keyTokenPrefix = 'immich.access_token.';

  final ImmichApiClient apiClient;
  final Uuid _uuid;

  AuthStore(this.apiClient, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Load the active account's state into the api client. Returns true if a
  /// previous login session was restored.
  Future<bool> load() async {
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_keyActiveAccountId);
    if (activeId == null) return false;
    final token = prefs.getString('$_keyTokenPrefix$activeId');
    if (token == null) return false;
    final account = await _findAccount(activeId);
    if (account == null) return false;
    apiClient.configureServer(account.serverUrl);
    apiClient.setAccessToken(token);
    return true;
  }

  /// Persist a freshly obtained access token after a successful login.
  /// Creates a new account entry if this user+server combo is new, or
  /// updates the existing entry's token. Sets the new account as active.
  Future<StoredAccount> saveLogin(ImmichLoginResult result, String serverUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await listAccounts();
    // Reuse an existing account if the same user+server is already stored.
    var account = accounts.firstWhere(
      (a) => a.userId == result.userId && a.serverUrl == serverUrl,
      orElse: () => StoredAccount(
        id: _uuid.v4(),
        serverUrl: serverUrl,
        userId: result.userId,
        name: result.name,
        savedAt: DateTime.now(),
      ),
    );
    if (account.name != result.name && result.name != null) {
      account = StoredAccount(
        id: account.id,
        serverUrl: account.serverUrl,
        userId: account.userId,
        name: result.name,
        savedAt: account.savedAt,
      );
    }
    await prefs.setString('$_keyTokenPrefix${account.id}', result.accessToken);
    await prefs.setString(_keyActiveAccountId, account.id);
    await _saveAccounts([...accounts.where((a) => a.id != account.id), account]);
    apiClient.configureServer(serverUrl);
    apiClient.setAccessToken(result.accessToken);
    return account;
  }

  /// Switch the active account to a previously-stored one. The caller must
  /// have a valid access token for the target account; if not, the caller
  /// should re-authenticate via [ImmichApiClient.login].
  Future<bool> switchAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final account = await _findAccount(accountId);
    if (account == null) return false;
    final token = prefs.getString('$_keyTokenPrefix$accountId');
    if (token == null) return false;
    await prefs.setString(_keyActiveAccountId, accountId);
    apiClient.configureServer(account.serverUrl);
    apiClient.setAccessToken(token);
    return true;
  }

  /// Remove an account and its stored token. If it was the active account,
  /// clears the active session from the api client.
  Future<void> removeAccount(String accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await listAccounts();
    await _saveAccounts(accounts.where((a) => a.id != accountId).toList());
    await prefs.remove('$_keyTokenPrefix$accountId');
    final activeId = prefs.getString(_keyActiveAccountId);
    if (activeId == accountId) {
      await prefs.remove(_keyActiveAccountId);
      apiClient.clearAccessToken();
    }
  }

  /// Clear all persisted auth state (full logout). Removes every account,
  /// every token, and the active-account pointer.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final accounts = await listAccounts();
    for (final account in accounts) {
      await prefs.remove('$_keyTokenPrefix${account.id}');
    }
    await prefs.remove(_keyAccounts);
    await prefs.remove(_keyActiveAccountId);
    apiClient.clearAccessToken();
  }

  /// Returns the stored user ID of the active account, or null.
  Future<String?> userId() async {
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_keyActiveAccountId);
    if (activeId == null) return null;
    final account = await _findAccount(activeId);
    return account?.userId;
  }

  /// Returns the stored name of the active account, or null.
  Future<String?> activeAccountName() async {
    final account = await activeAccount();
    return account?.name;
  }

  /// Returns the active [StoredAccount], or null if not logged in.
  Future<StoredAccount?> activeAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final activeId = prefs.getString(_keyActiveAccountId);
    if (activeId == null) return null;
    return _findAccount(activeId);
  }

  /// Returns all stored accounts, ordered most-recently-added first.
  Future<List<StoredAccount>> listAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyAccounts);
    if (raw == null || raw.isEmpty) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    final accounts = list
        .map((e) => StoredAccount.fromJson(e as Map<String, dynamic>))
        .toList();
    accounts.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return accounts;
  }

  /// Returns a stable per-device ID used in Immich upload metadata (FR-6).
  /// Created once on first access as a per-install UUID, shared across all
  /// accounts on this device. Immich uses this to group assets by source
  /// device, which is how the dashboard distinguishes "this phone" from
  /// "another family phone."
  Future<String> deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_keyDeviceId);
    if (id == null || id.isEmpty) {
      id = _uuid.v4();
      await prefs.setString(_keyDeviceId, id);
    }
    return id;
  }

  /// Set an optional human-readable label for this device (e.g. "Sinh's
  /// phone"). Surfaced on the dashboard so family members can tell phones
  /// apart.
  Future<void> setLocalDeviceLabel(String label) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLocalDeviceLabel, label);
  }

  /// Returns the stored local device label, or null if unset.
  Future<String?> localDeviceLabel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLocalDeviceLabel);
  }

  /// True if at least one stored account exists.
  Future<bool> hasStoredSession() async {
    final accounts = await listAccounts();
    return accounts.isNotEmpty;
  }

  Future<StoredAccount?> _findAccount(String id) async {
    final accounts = await listAccounts();
    for (final account in accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  Future<void> _saveAccounts(List<StoredAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyAccounts,
      jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
  }
}