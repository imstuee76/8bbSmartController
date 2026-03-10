import 'package:shared_preferences/shared_preferences.dart';

class LocalStore {
  static const _serverUrlKey = 'server_url';
  static const _authTokenKey = 'auth_token';
  static const _devicesScanHintKey = 'devices_scan_hint';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  String _normalizeServerUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) {
      return '';
    }
    if (!value.contains('://')) {
      value = 'http://$value';
    }

    Uri uri;
    try {
      uri = Uri.parse(value);
    } catch (_) {
      return input.trim();
    }

    var host = uri.host.trim();
    if (host.isEmpty && uri.path.isNotEmpty) {
      host = uri.path.trim();
    }
    if (host.isEmpty) {
      return input.trim();
    }

    final scheme = uri.scheme.trim().isEmpty ? 'http' : uri.scheme.trim();
    final port = uri.hasPort ? uri.port : 1111;
    final normalized = Uri(scheme: scheme, host: host, port: port).toString();
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  String _defaultServerUrl() {
    final queryHint = _normalizeServerUrl(Uri.base.queryParameters['backend'] ?? '');
    if (queryHint.isNotEmpty) {
      return queryHint;
    }

    final host = Uri.base.host.trim();
    if (host.isNotEmpty && host != 'localhost' && host != '127.0.0.1') {
      final scheme = Uri.base.scheme.trim().isEmpty ? 'http' : Uri.base.scheme.trim();
      final normalized = Uri(scheme: scheme, host: host, port: 1111).toString();
      return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
    }
    return 'http://127.0.0.1:1111';
  }

  Future<String> loadServerUrl() async {
    final prefs = await _prefs();
    final current = _normalizeServerUrl((prefs.getString(_serverUrlKey) ?? '').trim());
    if (current.isNotEmpty) {
      if ((prefs.getString(_serverUrlKey) ?? '').trim() != current) {
        await prefs.setString(_serverUrlKey, current);
      }
      return current;
    }
    final fallback = _defaultServerUrl();
    await prefs.setString(_serverUrlKey, fallback);
    return fallback;
  }

  Future<void> saveServerUrl(String value) async {
    final prefs = await _prefs();
    final normalized = _normalizeServerUrl(value);
    await prefs.setString(_serverUrlKey, normalized.isEmpty ? value.trim() : normalized);
  }

  Future<String> loadAuthToken() async {
    final prefs = await _prefs();
    return prefs.getString(_authTokenKey) ?? '';
  }

  Future<void> saveAuthToken(String value) async {
    final prefs = await _prefs();
    await prefs.setString(_authTokenKey, value);
  }

  Future<String> loadDevicesScanHint() async {
    final prefs = await _prefs();
    return (prefs.getString(_devicesScanHintKey) ?? '').trim();
  }

  Future<void> saveDevicesScanHint(String value) async {
    final prefs = await _prefs();
    await prefs.setString(_devicesScanHintKey, value.trim());
  }
}
