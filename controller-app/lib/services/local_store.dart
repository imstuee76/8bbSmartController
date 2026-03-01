import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'data_paths.dart';

class LocalStore {
  static const _serverUrlKey = 'server_url';
  static const _authTokenKey = 'auth_token';
  static const _settingsFileName = 'controller_settings.json';

  Future<File> _settingsFile() async {
    final dir = await DataPaths.dataDir();
    final file = File('${dir.path}${Platform.pathSeparator}$_settingsFileName');
    if (!await file.exists()) {
      await file.writeAsString('{}');
    }
    return file;
  }

  Future<Map<String, dynamic>> _readSettings() async {
    final file = await _settingsFile();
    try {
      final raw = await file.readAsString();
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  Future<void> _writeSettings(Map<String, dynamic> settings) async {
    final file = await _settingsFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(settings));
  }

  Future<String> _envValue(List<String> keys) async {
    final processEnv = Platform.environment;
    for (final key in keys) {
      final value = (processEnv[key] ?? '').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }

    final env = await DataPaths.loadEnvMap();
    for (final key in keys) {
      final value = (env[key] ?? '').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

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

    String host = uri.host.trim();
    if (host.isEmpty && uri.path.isNotEmpty) {
      host = uri.path.trim();
    }
    if (host.isEmpty) {
      return input.trim();
    }

    final scheme = uri.scheme.trim().isEmpty ? 'http' : uri.scheme.trim();
    final port = uri.hasPort ? uri.port : 8088;
    final normalized = Uri(
      scheme: scheme,
      host: host,
      port: port,
    ).toString();
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  Future<String> _legacyPref(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<String> loadServerUrl() async {
    final settings = await _readSettings();
    final fromEnv = await _envValue([
      'CONTROLLER_BACKEND_URL',
      'SMART_CONTROLLER_BACKEND_URL',
      'BACKEND_URL',
    ]);
    if (fromEnv.isNotEmpty) {
      final normalized = _normalizeServerUrl(fromEnv);
      final currentSaved = (settings[_serverUrlKey] ?? '').toString().trim();
      if (normalized.isNotEmpty && currentSaved != normalized) {
        settings[_serverUrlKey] = normalized;
        await _writeSettings(settings);
      }
      return normalized.isEmpty ? fromEnv : normalized;
    }

    final current = _normalizeServerUrl((settings[_serverUrlKey] ?? '').toString().trim());
    if (current.isNotEmpty) {
      if ((settings[_serverUrlKey] ?? '').toString().trim() != current) {
        settings[_serverUrlKey] = current;
        await _writeSettings(settings);
      }
      return current;
    }

    final legacy = _normalizeServerUrl((await _legacyPref(_serverUrlKey)).trim());
    if (legacy.isNotEmpty) {
      settings[_serverUrlKey] = legacy;
      await _writeSettings(settings);
      return legacy;
    }
    return 'http://127.0.0.1:8088';
  }

  Future<void> saveServerUrl(String value) async {
    final normalized = _normalizeServerUrl(value);
    final settings = await _readSettings();
    settings[_serverUrlKey] = normalized.isEmpty ? value.trim() : normalized;
    await _writeSettings(settings);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_serverUrlKey, normalized.isEmpty ? value.trim() : normalized);
    } catch (_) {}
  }

  Future<String> loadAuthToken() async {
    final settings = await _readSettings();
    final current = (settings[_authTokenKey] ?? '').toString();
    if (current.isNotEmpty) {
      return current;
    }

    final fromEnv = await _envValue([
      'CONTROLLER_AUTH_TOKEN',
      'SMART_CONTROLLER_AUTH_TOKEN',
      'AUTH_TOKEN',
    ]);
    if (fromEnv.isNotEmpty) {
      settings[_authTokenKey] = fromEnv;
      await _writeSettings(settings);
      return fromEnv;
    }

    final legacy = await _legacyPref(_authTokenKey);
    if (legacy.isNotEmpty) {
      settings[_authTokenKey] = legacy;
      await _writeSettings(settings);
      return legacy;
    }
    return '';
  }

  Future<void> saveAuthToken(String value) async {
    final settings = await _readSettings();
    settings[_authTokenKey] = value;
    await _writeSettings(settings);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_authTokenKey, value);
    } catch (_) {}
  }
}
