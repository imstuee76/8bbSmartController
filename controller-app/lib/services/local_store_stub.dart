class LocalStore {
  static final Map<String, String> _store = <String, String>{};

  Future<String> loadServerUrl() async {
    return _store['server_url'] ?? 'http://127.0.0.1:1111';
  }

  Future<void> saveServerUrl(String value) async {
    _store['server_url'] = value.trim();
  }

  Future<String> loadAuthToken() async {
    return _store['auth_token'] ?? '';
  }

  Future<void> saveAuthToken(String value) async {
    _store['auth_token'] = value;
  }

  Future<String> loadDevicesScanHint() async {
    return (_store['devices_scan_hint'] ?? '').trim();
  }

  Future<void> saveDevicesScanHint(String value) async {
    _store['devices_scan_hint'] = value.trim();
  }
}
