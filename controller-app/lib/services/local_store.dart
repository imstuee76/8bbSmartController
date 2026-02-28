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
    final env = await DataPaths.loadEnvMap();
    for (final key in keys) {
      final value = (env[key] ?? '').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
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
    final fromEnv = await _envValue(['CONTROLLER_BACKEND_URL', 'BACKEND_URL']);
    if (fromEnv.isNotEmpty) {
      final currentSaved = (settings[_serverUrlKey] ?? '').toString().trim();
      if (currentSaved != fromEnv) {
        settings[_serverUrlKey] = fromEnv;
        await _writeSettings(settings);
      }
      return fromEnv;
    }

    final current = (settings[_serverUrlKey] ?? '').toString().trim();
    if (current.isNotEmpty) {
      return current;
    }

    final legacy = (await _legacyPref(_serverUrlKey)).trim();
    if (legacy.isNotEmpty) {
      settings[_serverUrlKey] = legacy;
      await _writeSettings(settings);
      return legacy;
    }
    return 'http://127.0.0.1:8088';
  }

  Future<void> saveServerUrl(String value) async {
    final settings = await _readSettings();
    settings[_serverUrlKey] = value.trim();
    await _writeSettings(settings);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_serverUrlKey, value.trim());
    } catch (_) {}
  }

  Future<String> loadAuthToken() async {
    final settings = await _readSettings();
    final current = (settings[_authTokenKey] ?? '').toString();
    if (current.isNotEmpty) {
      return current;
    }

    final fromEnv = await _envValue(['CONTROLLER_AUTH_TOKEN', 'AUTH_TOKEN']);
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
