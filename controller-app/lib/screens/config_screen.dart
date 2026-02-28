import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/config_models.dart';
import '../services/api_service.dart';
import '../services/local_store.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({
    super.key,
    required this.api,
    required this.store,
    required this.onServerUrlChanged,
  });

  final ApiService api;
  final LocalStore store;
  final ValueChanged<String> onServerUrlChanged;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _serverCtl = TextEditingController();

  final _spotifyIdCtl = TextEditingController();
  final _spotifySecretCtl = TextEditingController();
  final _spotifyRedirectCtl = TextEditingController();
  final _spotifyRefreshCtl = TextEditingController();
  final _spotifyDeviceCtl = TextEditingController();

  final _weatherProviderCtl = TextEditingController();
  final _weatherApiCtl = TextEditingController();
  final _weatherLocationCtl = TextEditingController();

  final _tuyaRegionCtl = TextEditingController();
  final _tuyaIdCtl = TextEditingController();
  final _tuyaSecretCtl = TextEditingController();
  final _moesHubIpCtl = TextEditingController();
  final _moesHubIdCtl = TextEditingController();
  final _moesHubKeyCtl = TextEditingController();
  final _moesHubVersionCtl = TextEditingController(text: '3.4');

  final _scanSubnetCtl = TextEditingController();
  final _otaKeyCtl = TextEditingController();
  final _automationLabelCtl = TextEditingController(text: 'Scene');
  final _adminUserCtl = TextEditingController();
  final _adminPassCtl = TextEditingController();

  String _resolution = '1920x1080';
  double _scale = 1.0;
  bool _loading = true;
  bool _saving = false;
  bool _authConfigured = false;
  String? _initError;
  String _integrationTestOutput = '';
  String _moesLastDiscoveredAt = '';
  String _moesLastLightScanAt = '';
  List<Map<String, dynamic>> _tuyaLocalDevices = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _tuyaCloudDevices = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _moesHubs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _moesLights = <Map<String, dynamic>>[];

  final _resolutionOptions = const [
    '1280x720',
    '1366x768',
    '1600x900',
    '1920x1080',
    '2560x1440',
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('socketexception')) {
      return 'Backend unreachable at ${widget.api.baseUrl}.\n'
          'Set the Windows flasher URL in Controller / API, then Save Config.';
    }
    return text;
  }

  Future<void> _init() async {
    _serverCtl.text = await widget.store.loadServerUrl();
    final token = await widget.store.loadAuthToken();
    widget.api.authToken = token;
    try {
      _authConfigured = await widget.api.isAuthConfigured();
      final display = await widget.api.fetchDisplayConfig();
      final integrations = await widget.api.fetchIntegrationsConfig();

      _resolution = display.resolution;
      _scale = display.scale;

      _spotifyIdCtl.text = integrations.spotify['client_id']?.toString() ?? '';
      _spotifySecretCtl.text = integrations.spotify['client_secret']?.toString() ?? '';
      _spotifyRedirectCtl.text = integrations.spotify['redirect_uri']?.toString() ?? '';
      _spotifyRefreshCtl.text = integrations.spotify['refresh_token']?.toString() ?? '';
      _spotifyDeviceCtl.text = integrations.spotify['device_id']?.toString() ?? '';

      _weatherProviderCtl.text = integrations.weather['provider']?.toString() ?? 'openweather';
      _weatherApiCtl.text = integrations.weather['api_key']?.toString() ?? '';
      _weatherLocationCtl.text = integrations.weather['location']?.toString() ?? '';

      _tuyaRegionCtl.text = integrations.tuya['cloud_region']?.toString() ?? '';
      _tuyaIdCtl.text = integrations.tuya['client_id']?.toString() ?? '';
      _tuyaSecretCtl.text = integrations.tuya['client_secret']?.toString() ?? '';
      _moesHubIpCtl.text = integrations.moes['hub_ip']?.toString() ?? '';
      _moesHubIdCtl.text = integrations.moes['hub_device_id']?.toString() ?? '';
      _moesHubKeyCtl.text = integrations.moes['hub_local_key']?.toString() ?? '';
      _moesHubVersionCtl.text = integrations.moes['hub_version']?.toString() ?? '3.4';
      _moesLastDiscoveredAt = integrations.moes['last_discovered_at']?.toString() ?? '';
      _moesLastLightScanAt = integrations.moes['last_light_scan_at']?.toString() ?? '';

      _scanSubnetCtl.text = integrations.scan['subnet_hint']?.toString() ?? '';
      _otaKeyCtl.text = integrations.ota['shared_key']?.toString() ?? '';
      _initError = null;
    } catch (e) {
      _initError = _friendlyError(e);
      _integrationTestOutput = _initError!;
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);

    await widget.store.saveServerUrl(_serverCtl.text.trim());
    widget.onServerUrlChanged(_serverCtl.text.trim());

    await widget.api.saveDisplayConfig(DisplayConfig(
      resolution: _resolution,
      orientation: 'landscape',
      scale: _scale,
    ));

    await widget.api.saveIntegrationsConfig(
      IntegrationsConfig(
        spotify: {
          'client_id': _spotifyIdCtl.text.trim(),
          'client_secret': _spotifySecretCtl.text.trim(),
          'redirect_uri': _spotifyRedirectCtl.text.trim(),
          'refresh_token': _spotifyRefreshCtl.text.trim(),
          'device_id': _spotifyDeviceCtl.text.trim(),
        },
        weather: {
          'provider': _weatherProviderCtl.text.trim(),
          'api_key': _weatherApiCtl.text.trim(),
          'location': _weatherLocationCtl.text.trim(),
          'units': 'metric',
        },
        tuya: {
          'cloud_region': _tuyaRegionCtl.text.trim(),
          'client_id': _tuyaIdCtl.text.trim(),
          'client_secret': _tuyaSecretCtl.text.trim(),
          'local_scan_enabled': true,
        },
        scan: {
          'subnet_hint': _scanSubnetCtl.text.trim(),
          'mdns_enabled': true,
        },
        moes: {
          'hub_ip': _moesHubIpCtl.text.trim(),
          'hub_device_id': _moesHubIdCtl.text.trim(),
          'hub_local_key': _moesHubKeyCtl.text.trim(),
          'hub_version': _moesHubVersionCtl.text.trim().isEmpty ? '3.4' : _moesHubVersionCtl.text.trim(),
          'last_discovered_at': _moesLastDiscoveredAt,
          'last_light_scan_at': _moesLastLightScanAt,
        },
        ota: {
          'shared_key': _otaKeyCtl.text.trim(),
        },
      ),
    );

    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Config saved')));
  }

  Future<void> _setupAdmin() async {
    await widget.api.setupAdmin(
      username: _adminUserCtl.text.trim(),
      password: _adminPassCtl.text.trim(),
    );
    setState(() {
      _authConfigured = true;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Admin configured. Login now.')));
  }

  Future<void> _login() async {
    final token = await widget.api.login(
      username: _adminUserCtl.text.trim(),
      password: _adminPassCtl.text.trim(),
    );
    await widget.store.saveAuthToken(token);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Login success')));
  }

  Future<void> _createSpotifyTile() async {
    await widget.api.addTile(tileType: 'spotify', label: 'Spotify Now Playing');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Spotify tile added to Main')));
  }

  Future<void> _createWeatherTile() async {
    await widget.api.addTile(tileType: 'weather', label: 'Weather');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Weather tile added to Main')));
  }

  Future<void> _createAutomationTile() async {
    final label = _automationLabelCtl.text.trim().isEmpty ? 'Automation' : _automationLabelCtl.text.trim();
    await widget.api.addTile(tileType: 'automation', label: label, payload: {'action': 'placeholder'});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Automation tile added to Main')));
  }

  Future<void> _testWeather() async {
    try {
      final result = await widget.api.weatherCurrent();
      setState(() {
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  Future<void> _testSpotify() async {
    try {
      final result = await widget.api.spotifyNowPlaying();
      setState(() {
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  Future<void> _testTuyaLocal() async {
    try {
      final result = await widget.api.tuyaLocalScan();
      setState(() {
        _tuyaLocalDevices = (result['devices'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  Future<void> _testTuyaCloud() async {
    try {
      final result = await widget.api.tuyaCloudDevices();
      setState(() {
        _tuyaCloudDevices = (result['devices'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  Future<void> _discoverMoesHubLocal() async {
    try {
      final result = await widget.api.moesDiscoverLocal(subnetHint: _scanSubnetCtl.text.trim());
      setState(() {
        _moesHubs = (result['hubs'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        _moesLastDiscoveredAt = DateTime.now().toUtc().toIso8601String();
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  Future<void> _discoverMoesLights() async {
    try {
      final result = await widget.api.moesDiscoverLights(
        hubDeviceId: _moesHubIdCtl.text.trim(),
        hubIp: _moesHubIpCtl.text.trim(),
        hubLocalKey: _moesHubKeyCtl.text.trim(),
        hubVersion: _moesHubVersionCtl.text.trim(),
      );
      setState(() {
        _moesLights = (result['lights'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList();
        _moesLastLightScanAt = DateTime.now().toUtc().toIso8601String();
        _integrationTestOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        _integrationTestOutput = e.toString();
      });
    }
  }

  void _useMoesHub(Map<String, dynamic> hub) {
    setState(() {
      if ((hub['ip'] ?? '').toString().isNotEmpty) {
        _moesHubIpCtl.text = (hub['ip'] ?? '').toString();
      }
      if ((hub['id'] ?? '').toString().isNotEmpty) {
        _moesHubIdCtl.text = (hub['id'] ?? '').toString();
      }
      if ((hub['version'] ?? '').toString().isNotEmpty) {
        _moesHubVersionCtl.text = (hub['version'] ?? '').toString();
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('MOES hub loaded into config fields')));
  }

  Future<void> _addMoesLightAsDevice(Map<String, dynamic> light) async {
    final lightName = (light['name'] ?? 'MOES RGB Light').toString();
    final lightId = (light['id'] ?? '').toString();
    final lightCid = (light['cid'] ?? light['id'] ?? '').toString();
    final category = (light['category'] ?? '').toString();

    await widget.api.createDevice(
      name: lightName,
      type: 'light_rgbw',
      host: _moesHubIpCtl.text.trim().isEmpty ? null : _moesHubIpCtl.text.trim(),
      metadata: {
        'provider': 'moes_bhubw',
        'source_name': 'MOES BHUB-W',
        'connection_mode': 'local_lan',
        'hub_ip': _moesHubIpCtl.text.trim(),
        'hub_device_id': _moesHubIdCtl.text.trim(),
        'hub_version': _moesHubVersionCtl.text.trim(),
        'moes_cid': lightCid,
        'tuya_device_id': lightId,
        'tuya_category': category,
      },
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added "$lightName" to Devices')));
  }

  Future<bool> _confirmCloudWarning({
    required String actionLabel,
    required String deviceName,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cloud Device Warning'),
        content: Text(
          '"$deviceName" uses cloud control.\n\n'
          '$actionLabel may fail if internet/cloud API is down and can be slower than local LAN control.\n\n'
          'Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    return result ?? false;
  }

  String _guessTuyaDeviceType(Map<String, dynamic> device) {
    final text = [
      device['name']?.toString() ?? '',
      device['category']?.toString() ?? '',
      device['product_name']?.toString() ?? '',
    ].join(' ').toLowerCase();
    if (text.contains('fan')) return 'fan';
    if (text.contains('rgbw')) return 'light_rgbw';
    if (text.contains('rgb')) return 'light_rgb';
    if (text.contains('dimmer')) return 'light_dimmer';
    if (text.contains('light') || text.contains('bulb') || text.contains('lamp')) return 'light_single';
    if (text.contains('switch') || text.contains('relay') || text.contains('plug')) return 'relay_switch';
    return 'relay_switch';
  }

  Future<String?> _promptOptionalLocalKey(String title) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Tuya local key (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  Future<void> _addTuyaLocalAsDevice(Map<String, dynamic> item) async {
    final deviceId = (item['id'] ?? '').toString();
    final ip = (item['ip'] ?? '').toString();
    final version = (item['version'] ?? '').toString();
    final productKey = (item['product_key'] ?? '').toString();
    final localKey = await _promptOptionalLocalKey('Add Tuya Local Device');
    if (localKey == null) return;

    final name = 'Tuya Local ${deviceId.isEmpty ? ip : deviceId.substring(deviceId.length > 6 ? deviceId.length - 6 : 0)}';
    await widget.api.createDevice(
      name: name,
      type: _guessTuyaDeviceType(item),
      host: ip.isEmpty ? null : ip,
      metadata: {
        'provider': 'tuya_local',
        'source_name': 'Tuya Local',
        'connection_mode': 'local_lan',
        'tuya_device_id': deviceId,
        'tuya_ip': ip,
        'tuya_version': version,
        'tuya_local_key': localKey,
        'tuya_product_key': productKey,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added Tuya Local device "$name"')));
  }

  Future<void> _addTuyaCloudAsDevice(Map<String, dynamic> item) async {
    final deviceId = (item['id'] ?? '').toString();
    final ip = (item['ip'] ?? item['local_ip'] ?? '').toString();
    final version = (item['version'] ?? '').toString();
    final category = (item['category'] ?? '').toString();
    final productName = (item['product_name'] ?? '').toString();
    final name = (item['name'] ?? 'Tuya Cloud Device').toString();
    final confirmed = await _confirmCloudWarning(
      actionLabel: 'Adding this device',
      deviceName: name,
    );
    if (!confirmed) return;

    await widget.api.createDevice(
      name: name,
      type: _guessTuyaDeviceType(item),
      host: ip.isEmpty ? null : ip,
      metadata: {
        'provider': 'tuya_cloud',
        'source_name': 'Tuya Cloud',
        'connection_mode': 'cloud',
        'tuya_device_id': deviceId,
        'tuya_ip': ip,
        'tuya_version': version,
        'tuya_category': category,
        'tuya_product_name': productName,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added Tuya Cloud device "$name"')));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          if (_initError != null)
            Card(
              color: const Color(0xFFFFF3E0),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_initError!),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _authConfigured ? 'Local Login (Configured)' : 'Local Login (First-time setup)',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextField(controller: _adminUserCtl, decoration: const InputDecoration(labelText: 'Admin username')),
                  TextField(
                    controller: _adminPassCtl,
                    decoration: const InputDecoration(labelText: 'Admin password'),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (!_authConfigured) FilledButton.tonal(onPressed: _setupAdmin, child: const Text('Setup admin')),
                      FilledButton(onPressed: _login, child: const Text('Login')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MOES BHUB-W Local Discovery', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  const Text('LAN mode only. No Tuya cloud required.'),
                  TextField(controller: _moesHubIpCtl, decoration: const InputDecoration(labelText: 'Hub IP (optional/manual)')),
                  TextField(controller: _moesHubIdCtl, decoration: const InputDecoration(labelText: 'Hub Device ID (optional)')),
                  TextField(
                    controller: _moesHubKeyCtl,
                    decoration: const InputDecoration(labelText: 'Hub Local Key (required for LAN control)'),
                    obscureText: true,
                  ),
                  TextField(controller: _moesHubVersionCtl, decoration: const InputDecoration(labelText: 'Hub protocol version (e.g. 3.4)')),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(onPressed: _discoverMoesHubLocal, child: const Text('Discover MOES Hub (LAN)')),
                      FilledButton.tonal(onPressed: _discoverMoesLights, child: const Text('Discover Hub RGB Lights')),
                    ],
                  ),
                  if (_moesHubs.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Hub candidates'),
                    ..._moesHubs.map(
                      (hub) => ListTile(
                        dense: true,
                        title: Text('${hub['ip'] ?? ''}  ${hub['hostname'] ?? ''}'),
                        subtitle: Text('Score ${hub['score'] ?? 0} | ${((hub['reasons'] as List<dynamic>?) ?? []).join(", ")}'),
                        trailing: TextButton(onPressed: () => _useMoesHub(hub), child: const Text('Use')),
                      ),
                    ),
                  ],
                  if (_moesLights.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Discovered RGB lights'),
                    ..._moesLights.map(
                      (light) => ListTile(
                        dense: true,
                        title: Text('${light['name'] ?? ''} (${light['cid'] ?? light['id'] ?? ''})'),
                        subtitle: Text('Category: ${light['category'] ?? ''}  Online: ${light['online'] ?? 'unknown'}'),
                        trailing: TextButton(
                          onPressed: () => _addMoesLightAsDevice(light),
                          child: const Text('Add Device'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Controller / API', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextField(controller: _serverCtl, decoration: const InputDecoration(labelText: 'Backend URL')),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _resolutionOptions.contains(_resolution) ? _resolution : _resolutionOptions.last,
                          items: _resolutionOptions
                              .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _resolution = value);
                            }
                          },
                          decoration: const InputDecoration(labelText: 'Touch resolution'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _scale,
                          min: 0.75,
                          max: 1.5,
                          divisions: 15,
                          label: _scale.toStringAsFixed(2),
                          onChanged: (v) => setState(() => _scale = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Spotify Credentials', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextField(controller: _spotifyIdCtl, decoration: const InputDecoration(labelText: 'Client ID')),
                  TextField(controller: _spotifySecretCtl, decoration: const InputDecoration(labelText: 'Client Secret')),
                  TextField(controller: _spotifyRedirectCtl, decoration: const InputDecoration(labelText: 'Redirect URI')),
                  TextField(controller: _spotifyRefreshCtl, decoration: const InputDecoration(labelText: 'Refresh Token')),
                  TextField(controller: _spotifyDeviceCtl, decoration: const InputDecoration(labelText: 'Spotify Device ID')),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(onPressed: _createSpotifyTile, child: const Text('Add Spotify tile to Main')),
                      FilledButton.tonal(onPressed: _testSpotify, child: const Text('Test Spotify')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Weather Credentials', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextField(controller: _weatherProviderCtl, decoration: const InputDecoration(labelText: 'Provider')),
                  TextField(controller: _weatherApiCtl, decoration: const InputDecoration(labelText: 'API key')),
                  TextField(controller: _weatherLocationCtl, decoration: const InputDecoration(labelText: 'Location')),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(onPressed: _createWeatherTile, child: const Text('Add Weather tile to Main')),
                      FilledButton.tonal(onPressed: _testWeather, child: const Text('Test Weather')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Tuya Credentials', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextField(controller: _tuyaRegionCtl, decoration: const InputDecoration(labelText: 'Cloud region')),
                  TextField(controller: _tuyaIdCtl, decoration: const InputDecoration(labelText: 'Client ID')),
                  TextField(controller: _tuyaSecretCtl, decoration: const InputDecoration(labelText: 'Client Secret')),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(onPressed: _testTuyaLocal, child: const Text('Scan Tuya Local')),
                      FilledButton.tonal(onPressed: _testTuyaCloud, child: const Text('Scan Tuya Cloud')),
                    ],
                  ),
                  if (_tuyaLocalDevices.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Tuya Local discovered'),
                    ..._tuyaLocalDevices.map(
                      (item) => ListTile(
                        dense: true,
                        title: Text('${item['id'] ?? ''}'),
                        subtitle: Text('IP: ${item['ip'] ?? ''}  Version: ${item['version'] ?? ''}'),
                        trailing: TextButton(
                          onPressed: () => _addTuyaLocalAsDevice(item),
                          child: const Text('Add Device'),
                        ),
                      ),
                    ),
                  ],
                  if (_tuyaCloudDevices.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const Text('Tuya Cloud discovered'),
                    ..._tuyaCloudDevices.map(
                      (item) => ListTile(
                        dense: true,
                        title: Text('${item['name'] ?? ''} (${item['id'] ?? ''})'),
                        subtitle: Text('Category: ${item['category'] ?? ''}  Online: ${item['online'] ?? ''}'),
                        trailing: TextButton(
                          onPressed: () => _addTuyaCloudAsDevice(item),
                          child: const Text('Add Device'),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Network + OTA Config', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextField(controller: _scanSubnetCtl, decoration: const InputDecoration(labelText: 'Subnet hint (optional)')),
                  TextField(controller: _otaKeyCtl, decoration: const InputDecoration(labelText: 'OTA shared signing key')),
                  const SizedBox(height: 8),
                  TextField(controller: _automationLabelCtl, decoration: const InputDecoration(labelText: 'Automation tile label')),
                  OutlinedButton(onPressed: _createAutomationTile, child: const Text('Add Automation tile to Main')),
                ],
              ),
            ),
          ),
          if (_integrationTestOutput.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    _integrationTestOutput,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Save Config'),
            ),
          )
        ],
      ),
    );
  }
}
