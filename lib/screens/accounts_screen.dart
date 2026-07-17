import 'package:flutter/material.dart';

import '../services/auth_store.dart';

/// Account management screen (FR-10).
///
/// Lists all stored Immich accounts, allows switching the active account,
/// removing accounts, and adding a new account (which navigates to the
/// login screen). Only one account is active at a time; switching clears
/// the in-memory API client state and loads the target account's token.
class AccountsScreen extends StatefulWidget {
  final AuthStore authStore;
  final VoidCallback onAccountSwitched;
  final VoidCallback onAddAccount;

  const AccountsScreen({
    super.key,
    required this.authStore,
    required this.onAccountSwitched,
    required this.onAddAccount,
  });

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<StoredAccount> _accounts = const [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final accounts = await widget.authStore.listAccounts();
    final active = await widget.authStore.activeAccount();
    if (mounted) {
      setState(() {
        _accounts = accounts;
        _activeId = active?.id;
        _loading = false;
      });
    }
  }

  Future<void> _switch(StoredAccount account) async {
    final ok = await widget.authStore.switchAccount(account.id);
    if (ok) {
      widget.onAccountSwitched();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Switched to ${account.name ?? account.userId}')),
        );
        Navigator.of(context).popUntil(ModalRoute.withName('/home'));
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Switch failed — token may be expired')),
        );
      }
    }
  }

  Future<void> _remove(StoredAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text(
          'Remove ${account.name ?? account.userId} from this device? '
          'Uploaded photos on the server are not affected.',
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.authStore.removeAccount(account.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Stored accounts (FR-10)',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final account in _accounts)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        account.id == _activeId
                            ? Icons.check_circle
                            : Icons.person_outline,
                        color: account.id == _activeId
                            ? theme.colorScheme.primary
                            : null,
                      ),
                      title: Text(account.name ?? account.userId),
                      subtitle: Text(account.serverUrl),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (account.id != _activeId)
                            IconButton(
                              icon: const Icon(Icons.swap_horiz),
                              tooltip: 'Switch to this account',
                              onPressed: () => _switch(account),
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Remove',
                            onPressed: () => _remove(account),
                          ),
                        ],
                      ),
                      onTap: account.id == _activeId ? null : () => _switch(account),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.onAddAccount,
                  icon: const Icon(Icons.add),
                  label: const Text('Add account'),
                ),
              ],
            ),
    );
  }
}