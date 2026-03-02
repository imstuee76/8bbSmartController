import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/config_models.dart';
import '../models/device_models.dart';
import 'session_logger.dart';

class ApiService {
  ApiService(this.baseUrl) : _client = _LoggingClient(http.Client(), SessionLogger.instance);

  String baseUrl;
  String authToken = '';
  final http.Client _client;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');
  Map<String, String> _jsonHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authToken.isNotEmpty) {
      headers['X-Auth-Token'] = authToken;
    }
    return headers;
  }

  Future<List<SmartDevice>> fetchDevices() async {
    final res = await _client.get(_uri('/api/devices'));
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch devices: ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.whereType<Map<String, dynamic>>().map(SmartDevice.fromJson).toList();
  }

  Future<void> createDevice({
    required String name,
    required String type,
    String? host,
    String? passcode,
    String ipMode = 'dhcp',
    String? staticIp,
    String? gateway,
    String? subnetMask,
    Map<String, dynamic>? metadata,
  }) async {
    final payload = {
      'name': name,
      'type': type,
      'host': host,
      'passcode': passcode,
      'ip_mode': ipMode,
      'static_ip': staticIp,
      'gateway': gateway,
      'subnet_mask': subnetMask,
      'metadata': metadata ?? <String, dynamic>{},
      'channels': <Map<String, dynamic>>[],
    };
    final res = await _client.post(
      _uri('/api/devices'),
      headers: _jsonHeaders(),
      body: jsonEncode(payload),
    );
    if (res.statusCode != 200) {
      throw Exception('Create device failed: ${res.body}');
    }
  }

  Future<void> renameDevice(String deviceId, String name) async {
    final res = await _client.patch(
      _uri('/api/devices/$deviceId'),
      headers: _jsonHeaders(),
      body: jsonEncode({'name': name}),
    );
    if (res.statusCode != 200) {
      throw Exception('Rename failed: ${res.body}');
    }
  }

  Future<void> updateDevice(String deviceId, Map<String, dynamic> updates) async {
    final res = await _client.patch(
      _uri('/api/devices/$deviceId'),
      headers: _jsonHeaders(),
      body: jsonEncode(updates),
    );
    if (res.statusCode != 200) {
      throw Exception('Update device failed: ${res.body}');
    }
  }

  Future<void> deleteDevice(String deviceId) async {
    final res = await _client.delete(_uri('/api/devices/$deviceId'), headers: _jsonHeaders());
    if (res.statusCode != 200) {
      throw Exception('Delete failed: ${res.body}');
    }
  }

  Future<void> rescanDevice(String deviceId) async {
    final res = await _client.post(_uri('/api/devices/$deviceId/rescan'), headers: _jsonHeaders());
    if (res.statusCode != 200) {
      throw Exception('Rescan failed: ${res.body}');
    }
  }

  Future<void> upsertChannel({
    required String deviceId,
    required String channelKey,
    required String channelName,
    required String channelKind,
    Map<String, dynamic>? payload,
  }) async {
    final res = await _client.post(
      _uri('/api/devices/$deviceId/channels'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'channel_key': channelKey,
        'channel_name': channelName,
        'channel_kind': channelKind,
        'payload': payload ?? <String, dynamic>{},
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Upsert channel failed: ${res.body}');
    }
  }

  Future<List<Map<String, dynamic>>> scanNetwork({String? subnetHint, bool automationOnly = true}) async {
    final res = await _client.post(
      _uri('/api/discovery/scan'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'subnet_hint': subnetHint ?? '',
        'automation_only': automationOnly,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Scan failed: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['results'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<List<MainTile>> fetchTiles() async {
    final res = await _client.get(_uri('/api/main/tiles'));
    if (res.statusCode != 200) {
      throw Exception('Fetch tiles failed: ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.whereType<Map<String, dynamic>>().map(MainTile.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> fetchTileData() async {
    final res = await _client.get(_uri('/api/main/tile-data'));
    if (res.statusCode != 200) {
      throw Exception('Fetch tile data failed: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['tiles'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> addTile({
    required String tileType,
    required String label,
    String? refId,
    Map<String, dynamic>? payload,
  }) async {
    final res = await _client.post(
      _uri('/api/main/tiles'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'tile_type': tileType,
        'label': label,
        'ref_id': refId,
        'payload': payload ?? <String, dynamic>{},
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Add tile failed: ${res.body}');
    }
  }

  Future<void> removeTile(String tileId) async {
    final res = await _client.delete(_uri('/api/main/tiles/$tileId'), headers: _jsonHeaders());
    if (res.statusCode != 200) {
      throw Exception('Remove tile failed: ${res.body}');
    }
  }

  Future<void> updateTile({
    required String tileId,
    String? label,
    Map<String, dynamic>? payload,
  }) async {
    final body = <String, dynamic>{};
    if (label != null) {
      body['label'] = label;
    }
    if (payload != null) {
      body['payload'] = payload;
    }
    final res = await _client.patch(
      _uri('/api/main/tiles/$tileId'),
      headers: _jsonHeaders(),
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception('Update tile failed: ${res.body}');
    }
  }

  Future<DisplayConfig> fetchDisplayConfig() async {
    final res = await _client.get(_uri('/api/config/display'));
    if (res.statusCode != 200) {
      throw Exception('Display config failed: ${res.body}');
    }
    return DisplayConfig.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> saveDisplayConfig(DisplayConfig config) async {
    final res = await _client.put(
      _uri('/api/config/display'),
      headers: _jsonHeaders(),
      body: jsonEncode(config.toJson()),
    );
    if (res.statusCode != 200) {
      throw Exception('Save display failed: ${res.body}');
    }
  }

  Future<IntegrationsConfig> fetchIntegrationsConfig() async {
    final res = await _client.get(_uri('/api/config/integrations'));
    if (res.statusCode != 200) {
      throw Exception('Integrations config failed: ${res.body}');
    }
    return IntegrationsConfig.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> saveIntegrationsConfig(IntegrationsConfig config) async {
    final res = await _client.put(
      _uri('/api/config/integrations'),
      headers: _jsonHeaders(),
      body: jsonEncode(config.toJson()),
    );
    if (res.statusCode != 200) {
      throw Exception('Save integrations failed: ${res.body}');
    }
  }

  Future<List<String>> fetchFirmwareFiles() async {
    final res = await _client.get(_uri('/api/files/firmware'));
    if (res.statusCode != 200) {
      throw Exception('Fetch firmware files failed: ${res.body}');
    }
    return (jsonDecode(res.body) as List<dynamic>).map((e) => e.toString()).toList();
  }

  Future<String> createFlashJob({
    required String port,
    required String firmwareFilename,
    int baud = 921600,
    String? deviceId,
  }) async {
    final res = await _client.post(
      _uri('/api/flash/jobs'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'device_id': deviceId,
        'port': port,
        'baud': baud,
        'firmware_filename': firmwareFilename,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Create flash job failed: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['job_id'] ?? '').toString();
  }

  Future<Map<String, dynamic>> fetchFlashJob(String jobId) async {
    final res = await _client.get(_uri('/api/flash/jobs/$jobId'));
    if (res.statusCode != 200) {
      throw Exception('Fetch flash job failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> signOta({
    required String firmwareFilename,
    required String version,
    required String deviceType,
  }) async {
    final res = await _client.post(
      _uri('/api/ota/sign'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'firmware_filename': firmwareFilename,
        'version': version,
        'device_type': deviceType,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Sign OTA failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getDeviceStatus(String deviceId) async {
    final res = await _client.get(_uri('/api/devices/$deviceId/status'));
    if (res.statusCode != 200) {
      throw Exception('Device status failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendDeviceCommand({
    required String deviceId,
    required String channel,
    String? state,
    int? value,
    Map<String, dynamic>? payload,
  }) async {
    final res = await _client.post(
      _uri('/api/devices/$deviceId/command'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'channel': channel,
        'state': state,
        'value': value,
        'payload': payload ?? <String, dynamic>{},
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('Device command failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> pushOtaToDevice({
    required String deviceId,
    required String firmwareFilename,
    required String version,
  }) async {
    final res = await _client.post(
      _uri('/api/devices/$deviceId/ota/push'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'firmware_filename': firmwareFilename,
        'version': version,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('OTA push failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> spotifyNowPlaying() async {
    final res = await _client.get(_uri('/api/integrations/spotify/now-playing'));
    if (res.statusCode != 200) {
      throw Exception('Spotify now playing failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> spotifyAction(String action) async {
    final res = await _client.post(
      _uri('/api/integrations/spotify/action'),
      headers: _jsonHeaders(),
      body: jsonEncode({'action': action}),
    );
    if (res.statusCode != 200) {
      throw Exception('Spotify action failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> weatherCurrent() async {
    final res = await _client.get(_uri('/api/integrations/weather/current'));
    if (res.statusCode != 200) {
      throw Exception('Weather current failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> tuyaLocalScan({String subnetHint = ''}) async {
    final res = await _client.post(
      _uri('/api/integrations/tuya/local-scan'),
      headers: _jsonHeaders(),
      body: jsonEncode({'subnet_hint': subnetHint}),
    );
    if (res.statusCode != 200) {
      throw Exception('Tuya local scan failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> tuyaCloudDevices() async {
    final res = await _client.post(_uri('/api/integrations/tuya/cloud-devices'), headers: _jsonHeaders());
    if (res.statusCode != 200) {
      throw Exception('Tuya cloud scan failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> moesDiscoverLocal({String subnetHint = ''}) async {
    final res = await _client.post(
      _uri('/api/integrations/moes/discover-local'),
      headers: _jsonHeaders(),
      body: jsonEncode({'subnet_hint': subnetHint}),
    );
    if (res.statusCode != 200) {
      throw Exception('MOES local discover failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> moesDiscoverLights({
    String hubDeviceId = '',
    String hubIp = '',
    String hubMac = '',
    String hubLocalKey = '',
    String hubVersion = '',
    String subnetHint = '',
  }) async {
    final res = await _client.post(
      _uri('/api/integrations/moes/discover-lights'),
      headers: _jsonHeaders(),
      body: jsonEncode({
        'hub_device_id': hubDeviceId,
        'hub_ip': hubIp,
        'hub_mac': hubMac,
        'hub_local_key': hubLocalKey,
        'hub_version': hubVersion,
        'subnet_hint': subnetHint,
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('MOES lights discover failed: ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<bool> isAuthConfigured() async {
    final res = await _client.get(_uri('/api/auth/status'));
    if (res.statusCode != 200) {
      throw Exception('Fetch auth status failed: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['configured'] as bool?) ?? false;
  }

  Future<void> setupAdmin({required String username, required String password}) async {
    final res = await _client.post(
      _uri('/api/auth/setup'),
      headers: _jsonHeaders(),
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('Admin setup failed: ${res.body}');
    }
  }

  Future<String> login({required String username, required String password}) async {
    final res = await _client.post(
      _uri('/api/auth/login'),
      headers: _jsonHeaders(),
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('Login failed: ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    authToken = (body['token'] ?? '').toString();
    return authToken;
  }
}

class _LoggingClient extends http.BaseClient {
  _LoggingClient(this._inner, this._logger);

  final http.Client _inner;
  final SessionLogger _logger;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sid = _logger.sessionId.trim();
    if (sid.isNotEmpty && !request.headers.containsKey('X-8bb-Session-Id')) {
      request.headers['X-8bb-Session-Id'] = sid;
    }

    final started = DateTime.now().toUtc();
    final startMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final response = await _inner.send(request);
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
      unawaited(
        _logger.logActivity('http_request', <String, dynamic>{
          'method': request.method,
          'url': request.url.toString(),
          'status': response.statusCode,
          'duration_ms': elapsedMs,
          'started_at': started.toIso8601String(),
        }),
      );
      return response;
    } catch (error, stackTrace) {
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
      unawaited(
        _logger.logError(
          'http_request_failed',
          error,
          stackTrace: stackTrace,
          payload: <String, dynamic>{
            'method': request.method,
            'url': request.url.toString(),
            'duration_ms': elapsedMs,
            'started_at': started.toIso8601String(),
          },
        ),
      );
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
