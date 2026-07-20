import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/immich_api_client.dart';

/// Login screen (FR-1).
///
/// Collects server URL + email + password, authenticates against Immich, and
/// persists the access token via [AuthStore]. On success navigates to the
/// home screen.
class LoginScreen extends StatefulWidget {
  final AuthStore authStore;
  final VoidCallback onLoginSuccess;

  const LoginScreen({
    super.key,
    required this.authStore,
    required this.onLoginSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _serverController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final creds = ImmichCredentials(
        serverUrl: _serverController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      final result = await widget.authStore.apiClient.login(creds);
      await widget.authStore.saveLogin(result, creds.serverUrl.trim());
      widget.onLoginSuccess();
      if (mounted) {
        // Pop back to home if a previous route exists (add-account flow),
        // otherwise replace the login route.
        final canPop = Navigator.of(context).canPop();
        if (canPop) {
          Navigator.of(context).popUntil(ModalRoute.withName('/home'));
        } else {
          Navigator.of(context).pushReplacementNamed('/home');
        }
      }
    } on ImmichApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('anh-nha — Login')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _serverController,
                    decoration: const InputDecoration(
                      labelText: 'Immich server URL',
                      hintText: 'http://100.x.y.z:2283',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 24),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Log in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}