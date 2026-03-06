import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/device_models.dart';
import '../services/api_service.dart';
import '../services/local_store.dart';

enum _DeviceSection { esp32, tuya, moes }

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.api, required this.store});

  final ApiService api;
  final LocalStore store;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _QuickChannel {
  final String key;
  final String name;
  final String kind;
  final bool? state;

  const _QuickChannel({
    required this.key,
    required this.name,
    required this.kind,
    required this.state,
  });
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  bool _scanning = false;
  _DeviceSection _activeSection = _DeviceSection.esp32;
  String? _error;
  List<SmartDevice> _devices = [];
  List<Map<String, dynamic>> _scanResults = [];
  final Map<String, Map<String, dynamic>> _deviceStatusCache = <String, Map<String, dynamic>>{};
  final Set<String> _statusLoading = <String>{};
  final Set<String> _channelCommandBusy = <String>{};
  final TextEditingController _subnetCtl = TextEditingController();
  String _statusOutput = '';

  String _friendlyError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('socketexception')) {
      return 'Backend unreachable at ${widget.api.baseUrl}.\n'
          'Check: backend is running on Windows/Linux server, URL/port are correct, and firewall allows TCP 1111.';
    }
    return text;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedScanHint();
    _refresh();
  }

  Future<void> _loadSavedScanHint() async {
    try {
      final hint = await widget.store.loadDevicesScanHint();
      if (!mounted) return;
      setState(() {
        _subnetCtl.text = hint;
      });
    } catch (_) {}
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _devices = await widget.api.fetchDevices();
      _error = null;
    } catch (e) {
      _devices = <SmartDevice>[];
      _error = _friendlyError(e);
      _statusOutput = _error!;
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _statusOutput = 'Scanning ${_sectionLabel(_activeSection)} devices...';
    });
    try {
      await widget.store.saveDevicesScanHint(_subnetCtl.text.trim());
      if (_activeSection == _DeviceSection.esp32) {
        await _scanEsp32();
      } else if (_activeSection == _DeviceSection.tuya) {
        await _scanTuya();
      } else {
        await _scanMoes();
      }
    } catch (e) {
      setState(() {
        _error = _friendlyError(e);
        _statusOutput = _error!;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<void> _scanEsp32() async {
    final results = await widget.api.scanNetwork(
      subnetHint: _subnetCtl.text.trim(),
      automationOnly: true,
    );
    final filtered = results.where((item) {
      final provider = _scanProviderOf(item);
      return _sectionFromScanProvider(provider) == _DeviceSection.esp32;
    }).toList(growable: false);
    setState(() {
      _scanResults = filtered;
      _error = null;
      _statusOutput = 'ESP32 scan found ${filtered.length} candidate device(s).';
    });
  }

  Future<void> _scanTuya() async {
    final subnetHint = _subnetCtl.text.trim();
    var fromFileRows = <Map<String, dynamic>>[];
    try {
      final fileResult = await widget.api.tuyaDevicesFile();
      fromFileRows = _mapTuyaRows(
        (fileResult['devices'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .toList(growable: false),
      );
    } catch (_) {}

    final result = await widget.api.tuyaScanAndSave(subnetHint: subnetHint);
    var scanRows = _mapTuyaRows(
      (result['devices'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false),
    );
    var merged = _mergeTuyaScanRows(scanRows, fromFileRows);

    final localCount = (result['local_count'] as num?)?.toInt() ?? 0;
    final cloudCount = (result['cloud_count'] as num?)?.toInt() ?? 0;
    final savedCount = (result['saved_count'] as num?)?.toInt() ?? merged.length;
    final existingOnlyCount = (result['existing_only_count'] as num?)?.toInt() ?? 0;
    final existingFileCount = (result['existing_file_count'] as num?)?.toInt() ?? 0;
    final localLanScanCount = (result['local_lan_scan_count'] as num?)?.toInt() ?? 0;
    final localFileFallbackCount = (result['local_file_fallback_count'] as num?)?.toInt() ?? 0;
    final localScanEnabled = (result['local_scan_enabled'] as bool?) ?? true;
    final localScanDevicesFile = (result['local_scan_devices_file'] ?? '').toString();
    final localScanDevicesFileCount = (result['local_scan_devices_file_count'] as num?)?.toInt() ?? 0;
    final cloudError = (result['cloud_error'] ?? '').toString();
    final fileName = (result['file_name'] ?? 'devices.json').toString();
    final cfgPresence = (result['cloud_cfg_presence'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    final cfgSummary =
        'cloud_region=${(cfgPresence['cloud_region'] as bool?) == true ? 'yes' : 'no'}, '
        'client_id=${(cfgPresence['client_id'] as bool?) == true ? 'yes' : 'no'}, '
        'client_secret=${(cfgPresence['client_secret'] as bool?) == true ? 'yes' : 'no'}, '
        'api_device_id=${(cfgPresence['api_device_id'] as bool?) == true ? 'yes' : 'no'}';
    final fileDiag = (result['devices_file_diagnostics'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    final fileRows = (fileDiag['files'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final fileDiagLine = fileRows.isEmpty
        ? ''
        : fileRows
            .map((row) {
              final path = (row['path'] ?? '').toString();
              final exists = (row['exists'] as bool?) ?? false;
              final size = (row['size_bytes'] as num?)?.toInt() ?? 0;
              return '${exists ? '[OK]' : '[MISS]'} $path (${size}B)';
            })
            .join('\n');
    var loadedFromFile = false;

    // Safety net: if scan result is empty, load current devices.json content directly.
    if (merged.isEmpty) {
      try {
        final fromFile = await widget.api.tuyaDevicesFile();
        final fallbackRows = _mapTuyaRows(
          (fromFile['devices'] as List<dynamic>? ?? const <dynamic>[])
              .whereType<Map<String, dynamic>>()
              .toList(growable: false),
        );
        merged = _mergeTuyaScanRows(merged, fallbackRows);
        loadedFromFile = merged.isNotEmpty;
      } catch (_) {}
    }

    setState(() {
      _scanResults = merged;
      _error = null;
      _statusOutput =
          'Tuya scan+save complete: $savedCount device(s) stored in $fileName.'
          '\nLocal: $localCount | Cloud: $cloudCount'
          '\nLAN detected: $localLanScanCount | File fallback matches: $localFileFallbackCount'
          '\nLocal scan enabled: ${localScanEnabled ? 'yes' : 'no'}'
          '\nLocal scan file hint: ${localScanDevicesFile.isEmpty ? '(none)' : localScanDevicesFile} ($localScanDevicesFileCount rows)'
          '\nCloud credential fields present: $cfgSummary'
          '${existingFileCount > 0 ? '\nExisting file entries: $existingFileCount (retained: $existingOnlyCount)' : ''}'
          '${loadedFromFile ? '\nLoaded from existing devices.json fallback.' : ''}'
          '${fromFileRows.isNotEmpty ? '\nPreloaded from devices.json: ${fromFileRows.length}' : ''}'
          '${fileDiagLine.isNotEmpty ? '\nFiles checked:\n$fileDiagLine' : ''}'
          '${cloudError.isNotEmpty ? '\nCloud query warning: $cloudError' : ''}';
    });
  }

  Future<void> _loadTuyaFromSavedFile() async {
    final result = await widget.api.tuyaDevicesFile();
    final rows = (result['devices'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final mapped = _mapTuyaRows(rows);
    final fileDiag = (result['devices_file_diagnostics'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    final fileRows = (fileDiag['files'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final fileDiagLine = fileRows.isEmpty
        ? ''
        : '\nFiles checked:\n${fileRows.map((row) {
            final path = (row['path'] ?? '').toString();
            final exists = (row['exists'] as bool?) ?? false;
            final size = (row['size_bytes'] as num?)?.toInt() ?? 0;
            return '${exists ? '[OK]' : '[MISS]'} $path (${size}B)';
          }).join('\n')}';
    if (!mounted) return;
    setState(() {
      _scanResults = mapped.where((item) => _scanMatchesActiveSection(item)).toList(growable: false);
      _statusOutput = 'Loaded ${mapped.length} Tuya device(s) from ${(result['file_name'] ?? 'devices.json').toString()}.'
          '$fileDiagLine';
    });
  }

  Future<void> _loadTuyaFromSavedFileSafe() async {
    try {
      await _loadTuyaFromSavedFile();
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      setState(() {
        _statusOutput = 'Failed to load Tuya devices file.\n$msg';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  List<Map<String, dynamic>> _mapTuyaRows(List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      final mode = (row['mode'] ?? '').toString().toLowerCase().trim();
      final provider = (row['provider'] ?? '').toString().trim();
      final isLocal = mode == 'local_lan' || provider == 'tuya_local';
      return <String, dynamic>{
        'name': row['name'] ?? (isLocal ? 'Tuya Local' : 'Tuya Cloud'),
        'ip': row['ip'] ?? '',
        'hostname': '',
        'mac': row['mac'] ?? '',
        'device_hint': row['category'] ?? row['product_name'] ?? (isLocal ? 'tuya_local' : 'tuya_cloud'),
        'provider_hint': isLocal ? 'tuya_local' : 'tuya_cloud',
        'mode': isLocal ? 'local_lan' : 'cloud',
        'score': isLocal ? 10 : 8,
        'tuya_device_id': row['id'] ?? '',
        'tuya_version': row['version'] ?? '',
        'tuya_local_key': row['local_key'] ?? '',
        'tuya_product_key': row['product_key'] ?? '',
        'source': row['source'] ?? '',
      };
    }).toList(growable: false);
  }

  List<Map<String, dynamic>> _mergeTuyaScanRows(
    List<Map<String, dynamic>> primary,
    List<Map<String, dynamic>> secondary,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    for (final row in [...primary, ...secondary]) {
      final key = _tuyaRowIdentity(row);
      if (!merged.containsKey(key)) {
        merged[key] = Map<String, dynamic>.from(row);
        continue;
      }
      final current = merged[key]!;
      row.forEach((field, value) {
        if ((current[field] == null || current[field].toString().trim().isEmpty) &&
            value != null &&
            value.toString().trim().isNotEmpty) {
          current[field] = value;
        }
      });
    }
    return merged.values.toList(growable: false);
  }

  String _tuyaRowIdentity(Map<String, dynamic> row) {
    final devId = (row['tuya_device_id'] ?? row['id'] ?? '').toString().trim();
    if (devId.isNotEmpty) return 'id:$devId';
    final mac = (row['mac'] ?? '').toString().trim().toLowerCase();
    if (mac.isNotEmpty) return 'mac:$mac';
    final ip = (row['ip'] ?? '').toString().trim();
    if (ip.isNotEmpty) return 'ip:$ip';
    final name = (row['name'] ?? '').toString().trim().toLowerCase();
    if (name.isNotEmpty) return 'name:$name';
    return 'row:${row.hashCode}';
  }

  Future<void> _scanMoes() async {
    final subnetHint = _subnetCtl.text.trim();
    final merged = <Map<String, dynamic>>[];
    String lightsError = '';

    final hubs = await widget.api.moesDiscoverLocal(subnetHint: subnetHint);
    final hubRows = (hubs['hubs'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    for (final row in hubRows) {
      merged.add({
        'name': row['name'] ?? 'MOES BHUB-W',
        'ip': row['ip'] ?? '',
        'hostname': row['hostname'] ?? '',
        'mac': row['mac'] ?? '',
        'device_hint': 'moes_hub',
        'provider_hint': 'moes_bhubw',
        'mode': 'local_lan',
        'score': row['score'] ?? 9,
        'moes_hub_id': row['id'] ?? '',
        'moes_hub_version': row['version'] ?? '',
      });
    }

    try {
      final lights = await widget.api.moesDiscoverLights(subnetHint: subnetHint);
      final lightRows = (lights['lights'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      for (final row in lightRows) {
        merged.add({
          'name': row['name'] ?? 'MOES Light',
          'ip': row['hub_ip'] ?? lights['selected_hub_ip'] ?? '',
          'hostname': '',
          'mac': '',
          'device_hint': row['category'] ?? 'light_rgb',
          'provider_hint': 'moes_bhubw',
          'mode': 'local_lan',
          'score': 10,
          'moes_cid': row['cid'] ?? row['id'] ?? '',
          'moes_hub_id': row['gateway_id'] ?? lights['selected_hub_device_id'] ?? '',
          'moes_hub_version': row['hub_version'] ?? lights['selected_hub_version'] ?? '',
          'moes_hub_ip': row['hub_ip'] ?? lights['selected_hub_ip'] ?? '',
        });
      }
    } catch (e) {
      lightsError = _friendlyError(e);
    }

    setState(() {
      _scanResults = merged;
      _error = null;
      _statusOutput =
          'MOES scan found ${merged.length} item(s). Hubs: ${hubRows.length}.'
          '${lightsError.isNotEmpty ? '\nLight discovery failed: $lightsError' : ''}';
    });
  }

  @override
  void dispose() {
    _subnetCtl.dispose();
    super.dispose();
  }

  String _providerOf(SmartDevice device) {
    return (device.metadata['provider'] ?? 'esp_firmware').toString().trim().toLowerCase();
  }

  String _sourceOf(SmartDevice device) {
    final source = (device.metadata['source_name'] ?? '').toString().trim();
    if (source.isNotEmpty) return source;
    final provider = _providerOf(device);
    if (provider == 'moes_bhubw') return 'MOES BHUB-W';
    if (provider == 'tuya_local') return 'Tuya Local';
    if (provider == 'tuya_cloud') return 'Tuya Cloud';
    return '8bb Firmware';
  }

  String _modeOf(SmartDevice device) {
    final mode = (device.metadata['connection_mode'] ?? '').toString().trim();
    if (mode.isNotEmpty) return mode;
    final provider = _providerOf(device);
    if (provider == 'tuya_cloud') return 'cloud';
    return 'local_lan';
  }

  bool _isCloudMode(SmartDevice device) {
    final mode = _modeOf(device).toLowerCase();
    final provider = _providerOf(device);
    return mode.contains('cloud') || provider == 'tuya_cloud';
  }

  String _sectionLabel(_DeviceSection section) {
    switch (section) {
      case _DeviceSection.esp32:
        return 'ESP32';
      case _DeviceSection.tuya:
        return 'Tuya';
      case _DeviceSection.moes:
        return 'Moes';
    }
  }

  bool _matchesSection(SmartDevice device, _DeviceSection section) {
    final provider = _providerOf(device);
    switch (section) {
      case _DeviceSection.esp32:
        return provider.isEmpty ||
            provider == 'esp_firmware' ||
            (!provider.startsWith('tuya') && provider != 'moes_bhubw');
      case _DeviceSection.tuya:
        return provider.startsWith('tuya');
      case _DeviceSection.moes:
        return provider == 'moes_bhubw';
    }
  }

  IconData _connectionIconForDevice(SmartDevice device) {
    return _isCloudMode(device) ? Icons.cloud : Icons.lan;
  }

  Color _connectionColorForDevice(SmartDevice device) {
    return _isCloudMode(device) ? Colors.orange : Colors.green;
  }

  String _scanProviderOf(Map<String, dynamic> item) {
    final provider = (item['provider_hint'] ?? item['provider'] ?? '').toString().trim().toLowerCase();
    if (provider.isNotEmpty) return provider;
    final mode = (item['mode'] ?? '').toString().trim().toLowerCase();
    if (mode.contains('cloud')) return 'tuya_cloud';
    return 'esp_firmware';
  }

  bool _scanIsCloud(Map<String, dynamic> item) {
    final mode = (item['mode'] ?? '').toString().trim().toLowerCase();
    if (mode.contains('cloud')) return true;
    final provider = _scanProviderOf(item);
    return provider == 'tuya_cloud';
  }

  IconData _connectionIconForScan(Map<String, dynamic> item) {
    return _scanIsCloud(item) ? Icons.cloud : Icons.lan;
  }

  _DeviceSection _sectionFromScanProvider(String provider) {
    final p = provider.toLowerCase().trim();
    if (p == 'moes_bhubw') return _DeviceSection.moes;
    if (p.startsWith('tuya')) return _DeviceSection.tuya;
    return _DeviceSection.esp32;
  }

  bool _scanMatchesActiveSection(Map<String, dynamic> item) {
    final provider = _scanProviderOf(item);
    return _sectionFromScanProvider(provider) == _activeSection;
  }

  List<SmartDevice> _visibleDevices() {
    return _devices.where((d) => _matchesSection(d, _activeSection)).toList(growable: false);
  }

  int _suffixNumber(String key) {
    final m = RegExp(r'(\d+)$').firstMatch(key);
    if (m == null) return -1;
    return int.tryParse(m.group(1) ?? '') ?? -1;
  }

  bool _isLikelyRelayKey(String key) {
    final k = key.toLowerCase().trim();
    if (k.isEmpty) return false;
    if (RegExp(r'^(relay|switch|channel|out|gang|dp)[_-]?\d+$').hasMatch(k)) return true;
    if (k == 'power') return true;
    return false;
  }

  bool _isLikelyRelayKind(String kind) {
    final k = kind.toLowerCase().trim();
    return k.contains('relay') ||
        k.contains('switch') ||
        k.contains('toggle') ||
        k.contains('power') ||
        k.contains('channel');
  }

  bool? _asBoolState(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    if (text.isEmpty) return null;
    if (text == 'on' || text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'off' || text == 'false' || text == '0' || text == 'no') return false;
    return null;
  }

  String _fallbackChannelName(String key) {
    final idx = _suffixNumber(key);
    if (key.toLowerCase().startsWith('relay') && idx > 0) return 'Relay $idx';
    if (key.toLowerCase().startsWith('switch') && idx > 0) return 'Switch $idx';
    if (key.toLowerCase().startsWith('channel') && idx > 0) return 'Channel $idx';
    if (key.toLowerCase().startsWith('out') && idx > 0) return 'Output $idx';
    if (key.toLowerCase().startsWith('dp_') && idx > 0) return 'Channel $idx';
    if (key.toLowerCase() == 'power') return 'Power';
    return key;
  }

  int _relayCountFromDevice(SmartDevice device, Map<String, dynamic>? status) {
    final rawCandidates = <dynamic>[
      status?['relay_count'],
      device.metadata['relay_count'],
      device.metadata['switch_count'],
      device.metadata['channel_count'],
    ];
    for (final raw in rawCandidates) {
      final value = int.tryParse(raw?.toString() ?? '');
      if (value != null && value > 0 && value <= 16) {
        return value;
      }
    }
    if (device.type == 'relay_switch') return 4;
    return 1;
  }

  List<String> _defaultRelayKeys(SmartDevice device, Map<String, dynamic>? status) {
    final count = _relayCountFromDevice(device, status);
    return List<String>.generate(count, (i) => 'relay${i + 1}');
  }

  List<_QuickChannel> _inferQuickChannels(SmartDevice device) {
    final status = _deviceStatusCache[device.id];
    final outputs = (status?['outputs'] as Map<String, dynamic>?) ?? <String, dynamic>{};

    final channelNameByKey = <String, String>{};
    final channelKindByKey = <String, String>{};
    for (final ch in device.channels) {
      channelNameByKey[ch.channelKey] = ch.channelName;
      channelKindByKey[ch.channelKey] = ch.channelKind;
    }

    final discoveredKeys = <String>{};
    for (final ch in device.channels) {
      if (_isLikelyRelayKind(ch.channelKind) || _isLikelyRelayKey(ch.channelKey)) {
        discoveredKeys.add(ch.channelKey);
      }
    }
    for (final key in outputs.keys) {
      if (_isLikelyRelayKey(key)) {
        discoveredKeys.add(key);
      }
    }

    if (discoveredKeys.isEmpty) {
      for (final key in _defaultRelayKeys(device, status)) {
        discoveredKeys.add(key);
      }
    }

    final sorted = discoveredKeys.toList(growable: false)
      ..sort((a, b) {
        final an = _suffixNumber(a);
        final bn = _suffixNumber(b);
        if (an != -1 && bn != -1) return an.compareTo(bn);
        if (an != -1) return -1;
        if (bn != -1) return 1;
        return a.compareTo(b);
      });

    return sorted.map((key) {
      final state = _asBoolState(outputs[key]);
      return _QuickChannel(
        key: key,
        name: channelNameByKey[key]?.trim().isNotEmpty == true
            ? channelNameByKey[key]!
            : _fallbackChannelName(key),
        kind: channelKindByKey[key] ?? 'relay',
        state: state,
      );
    }).toList(growable: false);
  }

  Future<void> _loadDeviceStatus(SmartDevice device, {bool showOutput = false}) async {
    if (_statusLoading.contains(device.id)) return;
    setState(() {
      _statusLoading.add(device.id);
    });
    try {
      final status = await widget.api.getDeviceStatus(device.id);
      if (!mounted) return;
      setState(() {
        _deviceStatusCache[device.id] = status;
        if (showOutput) {
          _statusOutput = const JsonEncoder.withIndent('  ').convert(status);
        }
      });
    } catch (e) {
      if (!mounted) return;
      if (showOutput) {
        setState(() {
          _statusOutput = _friendlyError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _statusLoading.remove(device.id);
        });
      }
    }
  }

  Future<void> _toggleQuickChannel(SmartDevice device, _QuickChannel channel) async {
    final busyKey = '${device.id}:${channel.key}';
    if (_channelCommandBusy.contains(busyKey)) return;
    if (_isCloudMode(device)) {
      final ok = await _confirmCloudUse('Controlling this channel', device);
      if (!ok) return;
    }
    setState(() {
      _channelCommandBusy.add(busyKey);
    });
    try {
      await widget.api.sendDeviceCommand(
        deviceId: device.id,
        channel: channel.key,
        state: 'toggle',
      );
      if (!mounted) return;
      await _loadDeviceStatus(device, showOutput: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    } finally {
      if (mounted) {
        setState(() {
          _channelCommandBusy.remove(busyKey);
        });
      }
    }
  }

  Future<void> _addChannelToMain(SmartDevice device, _QuickChannel channel) async {
    if (_isCloudMode(device)) {
      final ok = await _confirmCloudUse('Adding this channel to Main', device);
      if (!ok) return;
    }
    try {
      await widget.api.addTile(
        tileType: 'device',
        refId: device.id,
        label: '${device.name} - ${channel.name}',
        payload: {
          'channel': channel.key,
          'channel_name': channel.name,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${channel.name}" to Main')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  DeviceChannel? _findDeviceChannel(SmartDevice device, String key) {
    for (final ch in device.channels) {
      if (ch.channelKey == key) return ch;
    }
    return null;
  }

  Future<void> _renameQuickChannel(SmartDevice device, _QuickChannel channel) async {
    final ctl = TextEditingController(text: channel.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Rename ${channel.name}'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(labelText: 'Relay button name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;

    final newName = ctl.text.trim();
    if (newName.isEmpty) return;

    final existing = _findDeviceChannel(device, channel.key);
    try {
      await widget.api.upsertChannel(
        deviceId: device.id,
        channelKey: channel.key,
        channelName: newName,
        channelKind: existing?.channelKind ?? channel.kind,
        payload: existing?.payload ?? <String, dynamic>{},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Relay name saved')));
      await _refresh();
      await _loadDeviceStatus(device, showOutput: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Future<bool> _confirmCloudUse(String action, SmartDevice device) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cloud Device Warning'),
        content: Text(
          '"${device.name}" is a cloud-connected device (${_sourceOf(device)}).\n\n'
          '$action may fail if internet/cloud API is unavailable and can be slower than local LAN.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _openCreateDialog({String presetHost = ''}) async {
    final nameCtl = TextEditingController();
    final hostCtl = TextEditingController(text: presetHost);
    final passCtl = TextEditingController();
    final staticIpCtl = TextEditingController();
    final gatewayCtl = TextEditingController();
    final subnetCtl = TextEditingController();
    String selectedType = 'relay_switch';
    String ipMode = 'dhcp';

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Device'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Device name')),
                TextField(controller: hostCtl, decoration: const InputDecoration(labelText: 'Device host/IP')),
                TextField(
                  controller: passCtl,
                  decoration: const InputDecoration(labelText: 'Device passcode'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedType,
                  items: const [
                    DropdownMenuItem(value: 'relay_switch', child: Text('Relay Switch')),
                    DropdownMenuItem(value: 'light_single', child: Text('Light Single')),
                    DropdownMenuItem(value: 'light_dimmer', child: Text('Light Dimmer')),
                    DropdownMenuItem(value: 'light_rgb', child: Text('Light RGB')),
                    DropdownMenuItem(value: 'light_rgbw', child: Text('Light RGBW')),
                    DropdownMenuItem(value: 'fan', child: Text('Fan')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      selectedType = value;
                    }
                  },
                  decoration: const InputDecoration(labelText: 'Device type'),
                ),
                DropdownButtonFormField<String>(
                  value: ipMode,
                  items: const [
                    DropdownMenuItem(value: 'dhcp', child: Text('DHCP')),
                    DropdownMenuItem(value: 'static', child: Text('Static IP')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      ipMode = value;
                    }
                  },
                  decoration: const InputDecoration(labelText: 'IP mode'),
                ),
                TextField(controller: staticIpCtl, decoration: const InputDecoration(labelText: 'Static IP (optional)')),
                TextField(controller: gatewayCtl, decoration: const InputDecoration(labelText: 'Gateway (optional)')),
                TextField(controller: subnetCtl, decoration: const InputDecoration(labelText: 'Subnet mask (optional)')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                await widget.api.createDevice(
                  name: nameCtl.text.trim(),
                  type: selectedType,
                  host: hostCtl.text.trim().isEmpty ? null : hostCtl.text.trim(),
                  passcode: passCtl.text.trim().isEmpty ? null : passCtl.text.trim(),
                  ipMode: ipMode,
                  staticIp: staticIpCtl.text.trim().isEmpty ? null : staticIpCtl.text.trim(),
                  gateway: gatewayCtl.text.trim().isEmpty ? null : gatewayCtl.text.trim(),
                  subnetMask: subnetCtl.text.trim().isEmpty ? null : subnetCtl.text.trim(),
                  metadata: {
                    'provider': 'esp_firmware',
                    'source_name': '8bb Firmware',
                    'connection_mode': 'local_lan',
                  },
                );
                if (!context.mounted) return;
                Navigator.pop(context);
                await _refresh();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _renameDevice(SmartDevice device) async {
    final ctl = TextEditingController(text: device.name);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename device'),
          content: TextField(controller: ctl),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                await widget.api.renameDevice(device.id, ctl.text.trim());
                if (!context.mounted) return;
                Navigator.pop(context);
                await _refresh();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _setPasscode(SmartDevice device) async {
    final ctl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Set Passcode: ${device.name}'),
        content: TextField(
          controller: ctl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'New passcode'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await widget.api.updateDevice(device.id, {'passcode': ctl.text.trim()});
              if (!mounted) return;
              Navigator.pop(context);
              await _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _runStatus(SmartDevice device) async {
    await _loadDeviceStatus(device, showOutput: true);
  }

  Future<void> _runControlDialog(SmartDevice device) async {
    final channelCtl = TextEditingController(text: 'relay1');
    final valueCtl = TextEditingController(text: '0');
    String state = 'toggle';
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Send Command: ${device.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: channelCtl, decoration: const InputDecoration(labelText: 'Channel')),
              DropdownButtonFormField<String>(
                value: state,
                items: const [
                  DropdownMenuItem(value: 'toggle', child: Text('toggle')),
                  DropdownMenuItem(value: 'on', child: Text('on')),
                  DropdownMenuItem(value: 'off', child: Text('off')),
                  DropdownMenuItem(value: 'set', child: Text('set')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    state = v;
                  }
                },
                decoration: const InputDecoration(labelText: 'State'),
              ),
              TextField(controller: valueCtl, decoration: const InputDecoration(labelText: 'Value (0-100/int)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await widget.api.sendDeviceCommand(
                deviceId: device.id,
                channel: channelCtl.text.trim(),
                state: state,
                value: int.tryParse(valueCtl.text.trim()),
              );
              if (!mounted) return;
              Navigator.pop(context);
              await _runStatus(device);
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _pushOtaDialog(SmartDevice device) async {
    final firmwareCtl = TextEditingController();
    final versionCtl = TextEditingController(text: '1.0.0');
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Push OTA: ${device.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: firmwareCtl, decoration: const InputDecoration(labelText: 'Firmware filename (.bin)')),
              TextField(controller: versionCtl, decoration: const InputDecoration(labelText: 'Version')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final result = await widget.api.pushOtaToDevice(
                deviceId: device.id,
                firmwareFilename: firmwareCtl.text.trim(),
                version: versionCtl.text.trim(),
              );
              if (!mounted) return;
              Navigator.pop(context);
              setState(() {
                _statusOutput = const JsonEncoder.withIndent('  ').convert(result);
              });
            },
            child: const Text('Push OTA'),
          ),
        ],
      ),
    );
  }

  Future<void> _editChannelDialog(SmartDevice device) async {
    final keyCtl = TextEditingController(text: 'relay1');
    final nameCtl = TextEditingController(text: 'Relay 1');
    final kindCtl = TextEditingController(text: 'relay');
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Channel Setup: ${device.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: keyCtl, decoration: const InputDecoration(labelText: 'Channel key (e.g. relay1)')),
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Channel name')),
              TextField(controller: kindCtl, decoration: const InputDecoration(labelText: 'Channel kind')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await widget.api.upsertChannel(
                deviceId: device.id,
                channelKey: keyCtl.text.trim(),
                channelName: nameCtl.text.trim(),
                channelKind: kindCtl.text.trim(),
              );
              if (!mounted) return;
              Navigator.pop(context);
              await _refresh();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showAdvancedDetails(SmartDevice device) {
    final pretty = const JsonEncoder.withIndent('  ').convert({
      'id': device.id,
      'name': device.name,
      'type': device.type,
      'host': device.host,
      'mac': device.mac,
      'ip_mode': device.ipMode,
      'static_ip': device.staticIp,
      'gateway': device.gateway,
      'subnet_mask': device.subnetMask,
      'metadata': device.metadata,
      'channels': device.channels.map((c) => c.toJson()).toList(),
    });
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Advanced details'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(pretty, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ),
      ),
    );
  }

  String _guessDeviceType(Map<String, dynamic> scanItem) {
    final hint = (scanItem['device_hint'] ?? '').toString().toLowerCase();
    final name = (scanItem['name'] ?? '').toString().toLowerCase();
    final blob = '$hint $name';
    if (blob.contains('fan')) return 'fan';
    if (blob.contains('rgbw')) return 'light_rgbw';
    if (blob.contains('rgb') || blob.contains('colour') || blob.contains('color')) return 'light_rgb';
    if (blob.contains('dimmer')) return 'light_dimmer';
    if (blob.contains('light') || blob.contains('bulb') || blob.contains('lamp')) return 'light_single';
    if (blob.contains('switch') || blob.contains('relay') || blob.contains('plug') || blob.contains('socket')) {
      return 'relay_switch';
    }
    return 'relay_switch';
  }

  Future<void> _addScannedDevice(Map<String, dynamic> item) async {
    final provider = _scanProviderOf(item);
    final section = _sectionFromScanProvider(provider);
    if (section != _activeSection) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scan item is from another provider section.')),
      );
      return;
    }

    final host = (item['ip'] ?? '').toString().trim();
    final nameRaw = (item['name'] ?? '').toString().trim();
    final displayName = nameRaw.isNotEmpty
        ? nameRaw
        : (host.isNotEmpty ? host : '${_sectionLabel(_activeSection)} Device');

    if (provider == 'moes_bhubw' && (item['moes_cid'] ?? '').toString().trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This is a MOES hub. Add MOES lights (with CID) for direct control.')),
      );
      return;
    }

    final connectionMode = _scanIsCloud(item) ? 'cloud' : 'local_lan';
    final metadata = <String, dynamic>{
      'provider': provider,
      'source_name': provider == 'moes_bhubw'
          ? 'MOES BHUB-W'
          : (provider == 'tuya_cloud'
              ? 'Tuya Cloud'
              : (provider == 'tuya_local' ? 'Tuya Local' : '8bb Firmware')),
      'connection_mode': connectionMode,
    };

    if (provider.startsWith('tuya')) {
      metadata['tuya_device_id'] = (item['tuya_device_id'] ?? '').toString().trim();
      metadata['id'] = (item['tuya_device_id'] ?? '').toString().trim();
      metadata['tuya_ip'] = host;
      metadata['ip'] = host;
      metadata['tuya_version'] = (item['tuya_version'] ?? '').toString().trim();
      metadata['version'] = (item['tuya_version'] ?? '').toString().trim();
      metadata['tuya_product_key'] = (item['tuya_product_key'] ?? '').toString().trim();
      metadata['product_key'] = (item['tuya_product_key'] ?? '').toString().trim();
      metadata['tuya_local_key'] = (item['tuya_local_key'] ?? '').toString().trim();
      metadata['local_key'] = (item['tuya_local_key'] ?? '').toString().trim();
    } else if (provider == 'moes_bhubw') {
      metadata['moes_cid'] = (item['moes_cid'] ?? '').toString().trim();
      metadata['cid'] = (item['moes_cid'] ?? '').toString().trim();
      metadata['tuya_device_id'] = (item['moes_cid'] ?? '').toString().trim();
      metadata['hub_device_id'] = (item['moes_hub_id'] ?? '').toString().trim();
      metadata['hub_ip'] = (item['moes_hub_ip'] ?? host).toString().trim();
      metadata['hub_version'] = (item['moes_hub_version'] ?? '').toString().trim();
      metadata['hub_mac'] = (item['mac'] ?? '').toString().trim();
    }

    try {
      await widget.api.createDevice(
        name: displayName,
        type: _guessDeviceType(item),
        host: host.isEmpty ? null : host,
        passcode: null,
        metadata: metadata,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added device: $displayName')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Widget _buildQuickControls(SmartDevice device) {
    final statusLoading = _statusLoading.contains(device.id);
    final channels = _inferQuickChannels(device);
    if (statusLoading && !_deviceStatusCache.containsKey(device.id)) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Loading relay status...'),
          ],
        ),
      );
    }

    if (channels.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('No relay/switch channels detected yet. Tap Status once to detect channels.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 4),
          child: Text('Relay / Switch Controls', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        ...channels.map((channel) {
          final busy = _channelCommandBusy.contains('${device.id}:${channel.key}');
          final stateText = channel.state == null ? 'Unknown' : (channel.state! ? 'On' : 'Off');
          final stateColor = channel.state == null
              ? Colors.grey
              : (channel.state! ? Colors.green : Colors.redAccent);
          final buttonColor = channel.state == null
              ? Colors.blueGrey
              : (channel.state! ? Colors.green : Colors.red);
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text('Key: ${channel.key}'),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      stateText,
                      style: TextStyle(color: stateColor, fontWeight: FontWeight.w600),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: busy ? null : () => _toggleQuickChannel(device, channel),
                    style: FilledButton.styleFrom(
                      backgroundColor: buttonColor,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(
                      busy
                          ? '...'
                          : (channel.state == true ? 'ON' : channel.state == false ? 'OFF' : 'TOGGLE'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => _renameQuickChannel(device, channel),
                    child: const Text('Rename'),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () => _addChannelToMain(device, channel),
                    child: const Text('Add to Main'),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _DeviceSection.values
                              .map(
                                (section) => ChoiceChip(
                                  label: Text(_sectionLabel(section)),
                                  selected: _activeSection == section,
                                  onSelected: (selected) {
                                    if (!selected) return;
                                    setState(() {
                                      _activeSection = section;
                                      _scanResults = _scanResults
                                          .where((item) => _scanMatchesActiveSection(item))
                                          .toList(growable: false);
                                    });
                                    if (section == _DeviceSection.tuya) {
                                      _loadTuyaFromSavedFileSafe();
                                    }
                                  },
                                ),
                              )
                              .toList(growable: false),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton(onPressed: () => _openCreateDialog(), child: const Text('Add Device')),
                            const SizedBox(width: 8),
                            OutlinedButton(onPressed: _refresh, child: const Text('Refresh')),
                            const Spacer(),
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: _subnetCtl,
                                decoration: const InputDecoration(labelText: 'Subnet or IP hint'),
                                onSubmitted: (value) => widget.store.saveDevicesScanHint(value),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: _scanning ? null : _scan,
                              child: Text(_scanning ? 'Scanning...' : 'Scan ${_sectionLabel(_activeSection)}'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Showing: ${_sectionLabel(_activeSection)} devices',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(_error!),
                                ),
                              )
                            : Builder(
                                builder: (context) {
                                  final visibleDevices = _visibleDevices();
                                  if (visibleDevices.isEmpty) {
                                    return Center(
                                      child: Text('No ${_sectionLabel(_activeSection)} devices yet.'),
                                    );
                                  }
                                  return ListView.builder(
                                    itemCount: visibleDevices.length,
                                    itemBuilder: (context, index) {
                                      final d = visibleDevices[index];
                                      final provider = _providerOf(d);
                                      final source = _sourceOf(d);
                                      final mode = _modeOf(d);
                                      final isEspFirmware = provider == 'esp_firmware';
                                      return ExpansionTile(
                                        leading: Icon(
                                          _connectionIconForDevice(d),
                                          color: _connectionColorForDevice(d),
                                        ),
                                        onExpansionChanged: (expanded) {
                                          if (expanded) {
                                            _loadDeviceStatus(d, showOutput: false);
                                          }
                                        },
                                        title: Text('${d.name} (${d.type})'),
                                        subtitle: Text(
                                          '${d.host ?? d.mac ?? 'No host yet'}\nSource: $source  Mode: $mode',
                                        ),
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    OutlinedButton(onPressed: () => _renameDevice(d), child: const Text('Rename')),
                                                    OutlinedButton(onPressed: () => _setPasscode(d), child: const Text('Set Passcode')),
                                                    OutlinedButton(
                                                      onPressed: () async {
                                                        if (_isCloudMode(d)) {
                                                          final ok = await _confirmCloudUse('Adding this to Main', d);
                                                          if (!ok) return;
                                                        }
                                                        await widget.api.addTile(tileType: 'device', refId: d.id, label: d.name);
                                                        if (!context.mounted) return;
                                                        ScaffoldMessenger.of(context)
                                                            .showSnackBar(const SnackBar(content: Text('Added full device tile to Main')));
                                                      },
                                                      child: const Text('Add Device to Main'),
                                                    ),
                                                    OutlinedButton(onPressed: () => _runStatus(d), child: const Text('Status')),
                                                    OutlinedButton(
                                                      onPressed: () async {
                                                        if (_isCloudMode(d)) {
                                                          final ok = await _confirmCloudUse('Advanced control', d);
                                                          if (!ok) return;
                                                        }
                                                        await _runControlDialog(d);
                                                      },
                                                      child: const Text('Advanced Control'),
                                                    ),
                                                    OutlinedButton(onPressed: () => _editChannelDialog(d), child: const Text('Name Buttons')),
                                                    if (isEspFirmware) OutlinedButton(onPressed: () => _pushOtaDialog(d), child: const Text('Push OTA')),
                                                    OutlinedButton(onPressed: () => _showAdvancedDetails(d), child: const Text('Advanced')),
                                                    OutlinedButton(
                                                      onPressed: () async {
                                                        await widget.api.rescanDevice(d.id);
                                                        await _refresh();
                                                      },
                                                      child: const Text('Rescan'),
                                                    ),
                                                    FilledButton.tonal(
                                                      onPressed: () async {
                                                        await widget.api.deleteDevice(d.id);
                                                        await _refresh();
                                                      },
                                                      child: const Text('Remove'),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 8),
                                                _buildQuickControls(d),
                                              ],
                                            ),
                                          )
                                        ],
                                      );
                                    },
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Card(
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Scan + Output', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        ..._scanResults.where(_scanMatchesActiveSection).map(
                          (item) => ListTile(
                            dense: true,
                            leading: Icon(
                              _connectionIconForScan(item),
                              color: _scanIsCloud(item) ? Colors.orange : Colors.green,
                            ),
                            title: Text(
                              (item['name']?.toString().trim().isNotEmpty ?? false)
                                  ? item['name'].toString()
                                  : (item['ip']?.toString() ?? ''),
                            ),
                            subtitle: Text(
                              'IP: ${item['ip'] ?? ''}  Host: ${item['hostname'] ?? ''}  MAC: ${item['mac'] ?? ''}\n'
                              'Hint: ${item['device_hint'] ?? item['provider_hint'] ?? 'unknown'}'
                              '  Score: ${item['score'] ?? 0}  Mode: ${item['mode'] ?? 'local_lan'}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => _addScannedDevice(item),
                            ),
                          ),
                        ),
                        const Divider(),
                        if (_statusOutput.isNotEmpty)
                          SelectableText(
                            _statusOutput,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),
        )
      ],
    );
  }
}
