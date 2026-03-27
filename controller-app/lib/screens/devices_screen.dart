import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/config_models.dart';
import '../models/device_models.dart';
import '../services/api_service.dart';
import '../services/local_store.dart';

enum _DeviceSection { esp32, tuya, moes }
enum _TuyaScanFilter { all, localOnly, cloudOnly }
enum _DeviceSort { group, alphaAsc, alphaDesc, connected, ipAsc }

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
  static const List<String> _groupColorChoices = <String>[
    '#2E7D32',
    '#1565C0',
    '#6A1B9A',
    '#EF6C00',
    '#C62828',
    '#00838F',
    '#455A64',
    '#5D4037',
  ];
  static const List<Map<String, String>> _lightScenes = <Map<String, String>>[
    {'id': '1', 'label': 'Relax'},
    {'id': '2', 'label': 'Focus'},
    {'id': '3', 'label': 'Party'},
    {'id': '4', 'label': 'Night'},
  ];

  bool _loading = true;
  bool _scanning = false;
  _DeviceSection _activeSection = _DeviceSection.esp32;
  _TuyaScanFilter _tuyaScanFilter = _TuyaScanFilter.all;
  _DeviceSort _deviceSort = _DeviceSort.group;
  String? _error;
  List<SmartDevice> _devices = [];
  List<Map<String, dynamic>> _scanResults = [];
  List<GroupConfig> _groups = <GroupConfig>[];
  final Map<String, Map<String, dynamic>> _deviceStatusCache = <String, Map<String, dynamic>>{};
  final Set<String> _statusLoading = <String>{};
  final Set<String> _channelCommandBusy = <String>{};
  final TextEditingController _subnetCtl = TextEditingController();
  final TextEditingController _scanSearchCtl = TextEditingController();
  String _statusOutput = '';

  String _friendlyError(Object error) {
    if (error is ApiResponseException) {
      final message = error.message.trim();
      if (message.isNotEmpty) {
        return message;
      }
    }
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('socketexception')) {
      return 'Backend unreachable at ${widget.api.baseUrl}.\n'
          'Check: backend is running on Windows/Linux server, URL/port are correct, and firewall allows TCP 1111.';
    }
    return text;
  }

  Future<bool> _confirmCloudFallbackForDevice({
    required String action,
    required SmartDevice device,
    required DeviceCommandFallbackException error,
  }) async {
    final detail = error.detail ?? const <String, dynamic>{};
    final localError = (detail['local_error'] ?? '').toString().trim();
    final message = localError.isNotEmpty
        ? '"${device.name}" failed local control.\n\n$localError\n\nTry cloud for $action?'
        : '"${device.name}" failed local control.\n\nTry cloud for $action?';
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cloud Fallback'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Try Cloud')),
        ],
      ),
    );
    return result ?? false;
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
      final results = await Future.wait<dynamic>([
        widget.api.fetchDevices(),
        widget.api.fetchDisplayConfig(),
      ]);
      _devices = (results[0] as List<SmartDevice>);
      _groups = (results[1] as DisplayConfig).groups;
      _error = null;
    } catch (e) {
      _devices = <SmartDevice>[];
      _groups = <GroupConfig>[];
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
      final availableModes = (row['available_modes'] as List<dynamic>? ?? const <dynamic>[])
          .map((value) => value.toString().trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toSet();
      final hasLocalKey = (row['local_key'] ?? '').toString().trim().isNotEmpty;
      final hasLocalMode = availableModes.contains('local_lan') || mode == 'local_lan' || provider == 'tuya_local' || hasLocalKey;
      final hasCloudMode = availableModes.contains('cloud') || mode == 'cloud' || provider == 'tuya_cloud';
      final isLocal = mode == 'local_lan' || provider == 'tuya_local';
      return <String, dynamic>{
        'name': row['name'] ?? '',
        'ip': row['ip'] ?? '',
        'hostname': '',
        'mac': row['mac'] ?? '',
        'device_hint': row['category'] ?? row['product_name'] ?? (isLocal ? 'tuya_local' : 'tuya_cloud'),
        'provider_hint': 'tuya',
        'mode': isLocal ? 'local_lan' : 'cloud',
        'score': isLocal ? 10 : 8,
        'tuya_device_id': row['id'] ?? '',
        'supports_local': hasLocalMode,
        'supports_cloud': hasCloudMode,
        'local_name': hasLocalMode ? (row['name'] ?? '') : '',
        'local_ip': hasLocalMode ? (row['ip'] ?? '') : '',
        'local_mac': hasLocalMode ? (row['mac'] ?? '') : '',
        'local_version': hasLocalMode ? (row['version'] ?? '') : '',
        'local_key': hasLocalMode ? (row['local_key'] ?? '') : '',
        'local_product_key': hasLocalMode ? (row['product_key'] ?? '') : '',
        'cloud_name': hasCloudMode ? (row['name'] ?? '') : '',
        'cloud_ip': hasCloudMode ? (row['ip'] ?? '') : '',
        'cloud_mac': hasCloudMode ? (row['mac'] ?? '') : '',
        'cloud_version': hasCloudMode ? (row['version'] ?? '') : '',
        'cloud_local_key': hasCloudMode ? (row['local_key'] ?? '') : '',
        'cloud_product_key': hasCloudMode ? (row['product_key'] ?? '') : '',
        'source': row['source'] ?? '',
        'channel_names': row['channel_names'] ?? row['switch_names'] ?? row['gang_names'] ?? row['dp_names'] ?? row['dps_names'] ?? const <String, dynamic>{},
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
      current['supports_local'] = (current['supports_local'] as bool? ?? false) || (row['supports_local'] as bool? ?? false);
      current['supports_cloud'] = (current['supports_cloud'] as bool? ?? false) || (row['supports_cloud'] as bool? ?? false);
      row.forEach((field, value) {
        if ((current[field] == null || current[field].toString().trim().isEmpty) &&
            value != null &&
            value.toString().trim().isNotEmpty) {
          current[field] = value;
        }
      });
      final localName = (current['local_name'] ?? '').toString().trim();
      final cloudName = (current['cloud_name'] ?? '').toString().trim();
      if ((current['name'] ?? '').toString().trim().isEmpty) {
        current['name'] = localName.isNotEmpty ? localName : cloudName;
      }
      if ((current['ip'] ?? '').toString().trim().isEmpty) {
        current['ip'] = (current['local_ip'] ?? '').toString().trim().isNotEmpty
            ? current['local_ip']
            : current['cloud_ip'];
      }
      if ((current['mac'] ?? '').toString().trim().isEmpty) {
        current['mac'] = (current['local_mac'] ?? '').toString().trim().isNotEmpty
            ? current['local_mac']
            : current['cloud_mac'];
      }
    }
    return merged.values.toList(growable: false);
  }

  bool _tuyaSupportsLocal(Map<String, dynamic> item) => (item['supports_local'] as bool?) ?? false;

  bool _tuyaSupportsCloud(Map<String, dynamic> item) => (item['supports_cloud'] as bool?) ?? false;

  bool _matchesTuyaScanFilter(Map<String, dynamic> item) {
    switch (_tuyaScanFilter) {
      case _TuyaScanFilter.all:
        return true;
      case _TuyaScanFilter.localOnly:
        return _tuyaSupportsLocal(item);
      case _TuyaScanFilter.cloudOnly:
        return _tuyaSupportsCloud(item);
    }
  }

  String _tuyaFilterLabel(_TuyaScanFilter filter) {
    switch (filter) {
      case _TuyaScanFilter.all:
        return 'All';
      case _TuyaScanFilter.localOnly:
        return 'Local';
      case _TuyaScanFilter.cloudOnly:
        return 'Cloud';
    }
  }

  String _scanDisplayName(Map<String, dynamic> item) {
    final name = (item['name'] ?? '').toString().trim();
    if (name.isNotEmpty) return name;
    final localName = (item['local_name'] ?? '').toString().trim();
    if (localName.isNotEmpty) return localName;
    final cloudName = (item['cloud_name'] ?? '').toString().trim();
    if (cloudName.isNotEmpty) return cloudName;
    return (item['ip'] ?? '').toString().trim();
  }

  String _scanChannelName(Map<String, dynamic> item, String channelKey) {
    final raw = item['channel_names'];
    final key = channelKey.trim();
    final suffix = _suffixNumber(key);
    if (raw is Map) {
      final candidates = <String>[
        key,
        key.toLowerCase(),
        'dp_$suffix',
        'switch_$suffix',
        'relay$suffix',
        suffix > 0 ? suffix.toString() : '',
      ].where((value) => value.isNotEmpty).toList(growable: false);
      for (final candidate in candidates) {
        final value = raw[candidate];
        final text = value?.toString().trim() ?? '';
        if (text.isNotEmpty) return text;
      }
    }
    if (raw is List && suffix > 0 && suffix <= raw.length) {
      final value = raw[suffix - 1];
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return _fallbackChannelName(channelKey);
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
    _scanSearchCtl.dispose();
    super.dispose();
  }

  bool _matchesScanSearch(Map<String, dynamic> item) {
    final query = _scanSearchCtl.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final blob = [
      item['name'],
      item['ip'],
      item['hostname'],
      item['mac'],
      item['device_hint'],
      item['provider_hint'],
      item['tuya_device_id'],
      item['local_name'],
      item['cloud_name'],
      item['local_ip'],
      item['cloud_ip'],
    ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
    return blob.contains(query);
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
    if (_tuyaSupportsLocal(item) && _tuyaSupportsCloud(item)) return false;
    final mode = (item['mode'] ?? '').toString().trim().toLowerCase();
    if (mode.contains('cloud')) return true;
    final provider = _scanProviderOf(item);
    return provider == 'tuya_cloud';
  }

  IconData _connectionIconForScan(Map<String, dynamic> item) {
    if (_tuyaSupportsLocal(item) && _tuyaSupportsCloud(item)) return Icons.compare_arrows;
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

  List<GroupConfig> _groupsForMember(String deviceId, String channel) {
    final key = channel.trim();
    return _groups
        .where(
          (group) => group.members.any(
            (member) => member.deviceId == deviceId && member.channel.trim() == key,
          ),
        )
        .toList(growable: false);
  }

  List<GroupConfig> _groupsForDevice(SmartDevice device) {
    return _groups.where((group) => group.members.any((member) => member.deviceId == device.id)).toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  String _primaryGroupNameForDevice(SmartDevice device) {
    final groups = _groupsForDevice(device);
    if (groups.isEmpty) return '';
    return groups.first.name;
  }

  Widget _buildDeviceGroupChips(SmartDevice device) {
    final matches = _groupsForDevice(device);
    if (matches.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: matches
          .map(
            (group) => Chip(
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              avatar: CircleAvatar(
                radius: 7,
                backgroundColor: _colorFromHex(group.color),
              ),
              label: Text(group.name),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildMemberGroupChips(String deviceId, String channel) {
    final matches = _groupsForMember(deviceId, channel);
    if (matches.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: matches
            .map(
              (group) => Chip(
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                avatar: CircleAvatar(
                  radius: 7,
                  backgroundColor: _colorFromHex(group.color),
                ),
                label: Text(group.name),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Color _colorFromHex(String raw, {Color fallback = const Color(0xFF4CAF50)}) {
    var value = raw.trim().replaceAll('#', '');
    if (value.isEmpty) return fallback;
    if (value.length == 6) value = 'FF$value';
    if (value.length != 8) return fallback;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return fallback;
    return Color(parsed);
  }

  bool _deviceOnline(SmartDevice device) {
    if (_deviceStatusCache.containsKey(device.id)) return true;
    final lastSeen = (device.lastSeenAt ?? '').trim();
    return lastSeen.isNotEmpty;
  }

  String _deviceIp(SmartDevice device) {
    final status = _deviceStatusCache[device.id];
    final network = (status?['network'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final staIp = (network['sta_ip'] ?? '').toString().trim();
    if (staIp.isNotEmpty) return staIp;
    final ip = (status?['ip'] ?? device.metadata['tuya_ip'] ?? device.host ?? '').toString().trim();
    return ip;
  }

  String _devicePowerSummary(SmartDevice device) {
    final status = _deviceStatusCache[device.id];
    final outputs = (status?['outputs'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final light = _asBoolState(outputs['light']);
    final power = _asBoolState(outputs['power']);
    if (light != null) return light ? 'On' : 'Off';
    if (power != null) return power ? 'On' : 'Off';
    final channels = _inferQuickChannels(device);
    final onCount = channels.where((channel) => channel.state == true).length;
    final offCount = channels.where((channel) => channel.state == false).length;
    if (onCount > 0 && offCount == 0) return 'On';
    if (offCount > 0 && onCount == 0) return 'Off';
    if (onCount > 0 || offCount > 0) return 'Mixed';
    return 'Unknown';
  }

  String _deviceSortLabel(_DeviceSort sort) {
    switch (sort) {
      case _DeviceSort.group:
        return 'Group';
      case _DeviceSort.alphaAsc:
        return 'A-Z';
      case _DeviceSort.alphaDesc:
        return 'Z-A';
      case _DeviceSort.connected:
        return 'Connected';
      case _DeviceSort.ipAsc:
        return 'IP';
    }
  }

  int _compareIpStrings(String a, String b) {
    final aa = a.split('.').map((part) => int.tryParse(part) ?? -1).toList(growable: false);
    final bb = b.split('.').map((part) => int.tryParse(part) ?? -1).toList(growable: false);
    for (var i = 0; i < 4; i += 1) {
      final av = i < aa.length ? aa[i] : -1;
      final bv = i < bb.length ? bb[i] : -1;
      final cmp = av.compareTo(bv);
      if (cmp != 0) return cmp;
    }
    return a.compareTo(b);
  }

  List<SmartDevice> _visibleDevices() {
    final items = _devices.where((d) => _matchesSection(d, _activeSection)).toList(growable: false);
    items.sort((a, b) {
      switch (_deviceSort) {
        case _DeviceSort.group:
          final groupCmp = _primaryGroupNameForDevice(a).toLowerCase().compareTo(_primaryGroupNameForDevice(b).toLowerCase());
          if (groupCmp != 0) return groupCmp;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _DeviceSort.alphaAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _DeviceSort.alphaDesc:
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case _DeviceSort.connected:
          final onlineCmp = (_deviceOnline(b) ? 1 : 0).compareTo(_deviceOnline(a) ? 1 : 0);
          if (onlineCmp != 0) return onlineCmp;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _DeviceSort.ipAsc:
          return _compareIpStrings(_deviceIp(a), _deviceIp(b));
      }
    });
    return items;
  }

  int _suffixNumber(String key) {
    final m = RegExp(r'(\d+)$').firstMatch(key);
    if (m == null) return -1;
    return int.tryParse(m.group(1) ?? '') ?? -1;
  }

  bool _isExplicitSwitchChannelKey(String key, [dynamic outputValue]) {
    final k = key.toLowerCase().trim();
    if (k.isEmpty) return false;
    if (RegExp(r'^(relay|switch|channel|out|gang)[_-]?\d+$').hasMatch(k)) return true;
    if (RegExp(r'^dp_\d+$').hasMatch(k)) return outputValue is bool;
    return false;
  }

  bool _isLikelyRelayKey(String key) {
    final k = key.toLowerCase().trim();
    if (k.isEmpty) return false;
    if (RegExp(r'^(relay|switch|channel|out|gang)[_-]?\d+$').hasMatch(k)) return true;
    if (k == 'power') return true;
    return false;
  }

  bool _isLikelyRelayKind(String kind) {
    final k = kind.toLowerCase().trim();
    return k.contains('relay') ||
        k.contains('switch') ||
        k.contains('group') ||
        k.contains('combined') ||
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

  bool _supportsRelayQuickControls(SmartDevice device, Map<String, dynamic>? status) {
    final type = device.type.toLowerCase().trim();
    if (type.contains('relay') || type.contains('switch') || type.contains('plug') || type.contains('socket')) {
      return true;
    }
    final capabilities = (status?['capabilities'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    if (capabilities['supports_relays'] == true) return true;
    return false;
  }

  bool? _combinedStateFromMemberChannels(Map<String, dynamic> outputs, List<dynamic> members) {
    var onCount = 0;
    var offCount = 0;
    for (final raw in members) {
      final key = raw.toString().trim();
      if (key.isEmpty) continue;
      final state = _asBoolState(outputs[key]);
      if (state == true) {
        onCount += 1;
      } else if (state == false) {
        offCount += 1;
      }
    }
    if (onCount > 0 && offCount == 0) return true;
    if (offCount > 0 && onCount == 0) return false;
    return null;
  }

  String _slugChannelKey(String value) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'combined_switch' : cleaned;
  }

  List<_QuickChannel> _inferQuickChannels(SmartDevice device) {
    final status = _deviceStatusCache[device.id];
    final outputs = (status?['outputs'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final supportsRelayQuickControls = _supportsRelayQuickControls(device, status);

    if (!supportsRelayQuickControls && _isLightDevice(device)) {
      return const <_QuickChannel>[];
    }

    final channelNameByKey = <String, String>{};
    final channelKindByKey = <String, String>{};
    final channelPayloadByKey = <String, Map<String, dynamic>>{};
    for (final ch in device.channels) {
      channelNameByKey[ch.channelKey] = ch.channelName;
      channelKindByKey[ch.channelKey] = ch.channelKind;
      channelPayloadByKey[ch.channelKey] = ch.payload;
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
        continue;
      }
      if (supportsRelayQuickControls && _isExplicitSwitchChannelKey(key, outputs[key])) {
        discoveredKeys.add(key);
      }
    }

    final hasExplicitSwitchChannels = discoveredKeys.any((key) => _isExplicitSwitchChannelKey(key, outputs[key]));
    if (hasExplicitSwitchChannels) {
      discoveredKeys.removeWhere((key) {
        final lower = key.toLowerCase().trim();
        return lower == 'power' || lower == 'light' || lower == 'relay_status';
      });
    }

    if (discoveredKeys.isEmpty && supportsRelayQuickControls) {
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
      final payload = channelPayloadByKey[key] ?? const <String, dynamic>{};
      final memberChannels = (payload['member_channels'] as List<dynamic>? ?? const <dynamic>[]);
      final state = memberChannels.isNotEmpty ? _combinedStateFromMemberChannels(outputs, memberChannels) : _asBoolState(outputs[key]);
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

  Future<void> _combineQuickChannels(SmartDevice device) async {
    final candidates = _inferQuickChannels(device)
        .where((channel) => channel.kind.toLowerCase().trim() != 'group')
        .toList(growable: false);
    if (candidates.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Need at least 2 switch/relay channels to combine')),
      );
      return;
    }

    final nameCtl = TextEditingController();
    final selected = <String, bool>{for (final channel in candidates) channel.key: false};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: Text('Combine Channels for ${device.name}'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtl,
                    decoration: const InputDecoration(
                      labelText: 'Combined name',
                      hintText: 'Example: Front Lights',
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 280,
                    child: ListView(
                      shrinkWrap: true,
                      children: candidates.map((channel) {
                        final checked = selected[channel.key] ?? false;
                        return CheckboxListTile(
                          value: checked,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(channel.name),
                          subtitle: Text('Key: ${channel.key}'),
                          onChanged: (value) {
                            setLocal(() {
                              selected[channel.key] = value ?? false;
                            });
                          },
                        );
                      }).toList(growable: false),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save Combined')),
            ],
          ),
        );
      },
    );
    if (saved != true) return;

    final name = nameCtl.text.trim();
    final memberChannels = candidates.where((channel) => selected[channel.key] == true).map((channel) => channel.key).toList(growable: false);
    if (name.isEmpty || memberChannels.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and at least 2 channels are required')),
      );
      return;
    }

    final channelKey = 'group_${_slugChannelKey(name)}';
    try {
      await widget.api.upsertChannel(
        deviceId: device.id,
        channelKey: channelKey,
        channelName: name,
        channelKind: 'group',
        payload: {
          'member_channels': memberChannels,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Combined control "$name" saved')),
      );
      await _refresh();
      await _loadDeviceStatus(device, showOutput: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
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
        state: channel.state == true ? 'off' : channel.state == false ? 'on' : 'toggle',
        allowCloudFallback: false,
      );
      if (!mounted) return;
      await _loadDeviceStatus(device, showOutput: false);
    } on DeviceCommandFallbackException catch (fallbackError) {
      if (!mounted) return;
      final ok = await _confirmCloudFallbackForDevice(
        action: 'this channel',
        device: device,
        error: fallbackError,
      );
      if (!ok) return;
      await widget.api.sendDeviceCommand(
        deviceId: device.id,
        channel: channel.key,
        state: channel.state == true ? 'off' : channel.state == false ? 'on' : 'toggle',
        allowCloudFallback: true,
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

  bool _isLightDevice(SmartDevice device) {
    final type = device.type.toLowerCase().trim();
    return type.contains('light') || type.contains('rgb');
  }

  Future<void> _sendLightCommand(
    SmartDevice device, {
    required String channel,
    required String state,
    int? value,
    Map<String, dynamic>? payload,
  }) async {
    if (_isCloudMode(device)) {
      final ok = await _confirmCloudUse('Controlling this light', device);
      if (!ok) return;
    }
    try {
      await widget.api.sendDeviceCommand(
        deviceId: device.id,
        channel: channel,
        state: state,
        value: value,
        payload: payload,
        allowCloudFallback: false,
      );
      if (!mounted) return;
      await _loadDeviceStatus(device, showOutput: false);
    } on DeviceCommandFallbackException catch (fallbackError) {
      if (!mounted) return;
      final ok = await _confirmCloudFallbackForDevice(
        action: 'this light',
        device: device,
        error: fallbackError,
      );
      if (!ok) return;
      await widget.api.sendDeviceCommand(
        deviceId: device.id,
        channel: channel,
        state: state,
        value: value,
        payload: payload,
        allowCloudFallback: true,
      );
      if (!mounted) return;
      await _loadDeviceStatus(device, showOutput: false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Future<void> _showLightDesigner(SmartDevice device) async {
    final type = device.type.toLowerCase().trim();
    final isRgbw = type.contains('rgbw');
    final initial = HSVColor.fromColor(isRgbw ? const Color(0xFFFFF4D6) : const Color(0xFFFF7A30));
    var hue = initial.hue;
    var saturation = initial.saturation;
    var value = initial.value;
    var brightness = 100.0;
    var whiteLevel = isRgbw ? 70.0 : 0.0;
    var colorTemp = 0.0;

    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = HSVColor.fromAHSV(1, hue, saturation, value).toColor();
          return AlertDialog(
            title: Text('Light Control: ${device.name}'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 64,
                      decoration: BoxDecoration(
                        color: preview,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.black12),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Hue ${hue.round()}'),
                    Slider(
                      value: hue,
                      min: 0,
                      max: 360,
                      onChanged: (v) => setDialogState(() => hue = v),
                    ),
                    Text('Saturation ${(saturation * 100).round()}%'),
                    Slider(
                      value: saturation,
                      min: 0,
                      max: 1,
                      onChanged: (v) => setDialogState(() => saturation = v),
                    ),
                    Text('Colour Brightness ${(value * 100).round()}%'),
                    Slider(
                      value: value,
                      min: 0.1,
                      max: 1,
                      onChanged: (v) => setDialogState(() => value = v),
                    ),
                    Text('Output Brightness ${brightness.round()}%'),
                    Slider(
                      value: brightness,
                      min: 1,
                      max: 100,
                      onChanged: (v) => setDialogState(() => brightness = v),
                    ),
                    if (isRgbw) ...[
                      Text('White ${whiteLevel.round()}%'),
                      Slider(
                        value: whiteLevel,
                        min: 0,
                        max: 100,
                        onChanged: (v) => setDialogState(() => whiteLevel = v),
                      ),
                      Text('White Temp ${colorTemp.round()}%'),
                      Slider(
                        value: colorTemp,
                        min: 0,
                        max: 100,
                        onChanged: (v) => setDialogState(() => colorTemp = v),
                      ),
                    ],
                    const SizedBox(height: 8),
                    const Text('Scenes / Effects', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _lightScenes
                          .map(
                            (scene) => FilledButton.tonal(
                              onPressed: () async {
                                await _sendLightCommand(
                                  device,
                                  channel: 'scene',
                                  state: 'scene',
                                  payload: {'scene': scene['id']},
                                );
                                if (mounted && context.mounted) Navigator.of(context).pop();
                              },
                              child: Text(scene['label']!),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
              if (isRgbw)
                OutlinedButton(
                  onPressed: () async {
                    await _sendLightCommand(
                      device,
                      channel: 'rgbw',
                      state: 'set',
                      payload: {
                        'mode': 'white',
                        'white': whiteLevel.round(),
                        'color_temp': colorTemp.round(),
                      },
                    );
                    if (mounted && context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Apply White'),
                ),
              FilledButton(
                onPressed: () async {
                  final rgb = HSVColor.fromAHSV(1, hue, saturation, value).toColor();
                  await _sendLightCommand(
                    device,
                    channel: isRgbw ? 'rgbw' : 'rgb',
                    state: 'set',
                    payload: {
                      'r': rgb.red,
                      'g': rgb.green,
                      'b': rgb.blue,
                      'w': isRgbw ? whiteLevel.round() : 0,
                      'brightness': brightness.round(),
                    },
                  );
                  if (mounted && context.mounted) Navigator.of(context).pop();
                },
                child: const Text('Apply Colour'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDeviceStatusStrip(SmartDevice device) {
    final online = _deviceOnline(device);
    final ip = _deviceIp(device);
    final power = _devicePowerSummary(device);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(online ? Icons.check_circle : Icons.cloud_off, size: 18, color: online ? Colors.green : Colors.redAccent),
              const SizedBox(width: 6),
              Text('Device ${online ? 'online' : 'unknown'}'),
            ],
          ),
          Text('IP: ${ip.isEmpty ? '(not set)' : ip}'),
          Text('Power: $power'),
        ],
      ),
    );
  }

  Widget _buildLightControls(SmartDevice device) {
    if (!_isLightDevice(device)) return const SizedBox.shrink();
    final type = device.type.toLowerCase().trim();
    final isRgbw = type.contains('rgbw');
    final isRgb = type.contains('rgb');
    final primaryMember = _buildPrimaryDeviceGroupMember(device);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 4),
          child: Text('Light Controls', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        _buildMemberGroupChips(device.id, primaryMember.channel),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => _sendLightCommand(device, channel: 'light', state: 'on'),
              child: const Text('Light ON'),
            ),
            OutlinedButton(
              onPressed: () => _sendLightCommand(device, channel: 'light', state: 'off'),
              child: const Text('Light OFF'),
            ),
            OutlinedButton(
              onPressed: () => _sendLightCommand(
                device,
                channel: type.contains('dimmer') ? 'dimmer' : 'light',
                state: 'set',
                value: 25,
              ),
              child: const Text('25%'),
            ),
            OutlinedButton(
              onPressed: () => _sendLightCommand(
                device,
                channel: type.contains('dimmer') ? 'dimmer' : 'light',
                state: 'set',
                value: 50,
              ),
              child: const Text('50%'),
            ),
            OutlinedButton(
              onPressed: () => _sendLightCommand(
                device,
                channel: type.contains('dimmer') ? 'dimmer' : 'light',
                state: 'set',
                value: 100,
              ),
              child: const Text('100%'),
            ),
          ],
        ),
        if (isRgb)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _sendLightCommand(
                    device,
                    channel: isRgbw ? 'rgbw' : 'rgb',
                    state: 'set',
                    payload: {
                      'r': 100,
                      'g': 0,
                      'b': 0,
                      'w': 0,
                    },
                  ),
                  child: const Text('Red'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendLightCommand(
                    device,
                    channel: isRgbw ? 'rgbw' : 'rgb',
                    state: 'set',
                    payload: {
                      'r': 0,
                      'g': 100,
                      'b': 0,
                      'w': 0,
                    },
                  ),
                  child: const Text('Green'),
                ),
                FilledButton.tonal(
                  onPressed: () => _sendLightCommand(
                    device,
                    channel: isRgbw ? 'rgbw' : 'rgb',
                    state: 'set',
                    payload: {
                      'r': 0,
                      'g': 0,
                      'b': 100,
                      'w': 0,
                    },
                  ),
                  child: const Text('Blue'),
                ),
                if (isRgbw)
                  FilledButton.tonal(
                    onPressed: () => _sendLightCommand(
                      device,
                      channel: 'rgbw',
                      state: 'set',
                      payload: {
                        'r': 0,
                        'g': 0,
                        'b': 0,
                        'w': 100,
                      },
                    ),
                    child: const Text('White'),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _showLightDesigner(device),
                icon: const Icon(Icons.palette_outlined),
                label: const Text('Colour / Scenes'),
              ),
              OutlinedButton.icon(
                onPressed: () => _showAssignMemberGroupsDialog(
                  title: 'Assign Light to Groups',
                  member: _buildPrimaryDeviceGroupMember(device),
                ),
                icon: const Icon(Icons.device_hub_outlined),
                label: const Text('Groups'),
              ),
              ..._lightScenes.map(
                (scene) => OutlinedButton(
                  onPressed: () => _sendLightCommand(
                    device,
                    channel: 'scene',
                    state: 'scene',
                    payload: {'scene': scene['id']},
                  ),
                  child: Text(scene['label']!),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
    final macCtl = TextEditingController();
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
                TextField(controller: macCtl, decoration: const InputDecoration(labelText: 'MAC address (optional)')),
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
                  mac: macCtl.text.trim().isEmpty ? null : macCtl.text.trim(),
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

  Future<void> _saveGroupsConfig() async {
    final current = await widget.api.fetchDisplayConfig();
    current.groups = _groups;
    await widget.api.saveDisplayConfig(current);
  }

  String _slugId(String raw) {
    final cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'group_${DateTime.now().millisecondsSinceEpoch}' : cleaned;
  }

  Future<GroupConfig?> _openGroupEditor({
    GroupConfig? existing,
    String initialName = '',
    String initialKind = 'mixed',
  }) async {
    final nameCtl = TextEditingController(text: existing?.name ?? initialName);
    var selectedColor = (existing?.color.isNotEmpty ?? false) ? existing!.color : _groupColorChoices.first;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Group' : 'Edit Group'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Group name'),
                ),
                const SizedBox(height: 12),
                const Text('Group colour'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _groupColorChoices.map((hex) {
                    final color = _colorFromHex(hex);
                    final selected = hex == selectedColor;
                    return InkWell(
                      onTap: () => setDialogState(() => selectedColor = hex),
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: selected ? Colors.white : Colors.black26,
                            width: selected ? 3 : 1,
                          ),
                        ),
                      ),
                    );
                  }).toList(growable: false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true) return null;
    final name = nameCtl.text.trim();
    if (name.isEmpty) return null;
    return GroupConfig(
      id: existing?.id.isNotEmpty == true ? existing!.id : _slugId(name),
      name: name,
      color: selectedColor,
      kind: existing?.kind.isNotEmpty == true ? existing!.kind : initialKind,
      members: existing?.members ?? const <GroupMemberConfig>[],
    );
  }

  Future<GroupConfig?> _ensureGroupFromPrompt({String initialName = '', String initialKind = 'mixed'}) async {
    final created = await _openGroupEditor(initialName: initialName, initialKind: initialKind);
    if (created == null) return null;
    final next = <GroupConfig>[
      ..._groups.where((group) => group.id != created.id),
      created,
    ];
    setState(() {
      _groups = next;
    });
    await _saveGroupsConfig();
    return created;
  }

  String _groupKindForChannelKind(String rawKind) {
    final kind = rawKind.trim().toLowerCase();
    if (kind.contains('light') || kind.contains('rgb') || kind.contains('dimmer') || kind.contains('bulb')) return 'light';
    if (kind.contains('fan')) return 'fan';
    return 'switch';
  }

  GroupMemberConfig _buildGroupMemberForChannel(SmartDevice device, _QuickChannel channel) {
    return GroupMemberConfig(
      deviceId: device.id,
      channel: channel.key,
      label: '${device.name} - ${channel.name}',
      deviceName: device.name,
      channelName: channel.name,
      kind: channel.kind,
      commandPayload: const <String, dynamic>{},
    );
  }

  GroupMemberConfig _buildPrimaryDeviceGroupMember(SmartDevice device) {
    final type = device.type.trim().toLowerCase();
    var channel = 'power';
    var channelName = device.name;
    var kind = type;
    if (type.contains('rgbw')) {
      channel = 'rgbw';
      channelName = 'Light';
      kind = 'light_rgbw';
    } else if (type.contains('rgb')) {
      channel = 'rgb';
      channelName = 'Light';
      kind = 'light_rgb';
    } else if (type.contains('light') || type.contains('dimmer')) {
      channel = 'light';
      channelName = 'Light';
      kind = type.contains('dimmer') ? 'light_dimmer' : 'light';
    } else if (type.contains('fan')) {
      channel = 'fan';
      channelName = 'Fan';
      kind = 'fan';
    }
    return GroupMemberConfig(
      deviceId: device.id,
      channel: channel,
      label: device.name,
      deviceName: device.name,
      channelName: channelName,
      kind: kind,
      commandPayload: const <String, dynamic>{},
    );
  }

  bool _groupContainsMember(GroupConfig group, GroupMemberConfig member) {
    return group.members.any((item) => item.deviceId == member.deviceId && item.channel == member.channel);
  }

  GroupConfig _groupWithMembership(GroupConfig group, GroupMemberConfig member, bool include) {
    final members = group.members
        .where((item) => !(item.deviceId == member.deviceId && item.channel == member.channel))
        .toList(growable: true);
    if (include) {
      members.add(member);
    }
    return GroupConfig(
      id: group.id,
      name: group.name,
      color: group.color,
      kind: group.kind,
      members: members,
    );
  }

  Future<void> _showAssignMemberGroupsDialog({
    required String title,
    required GroupMemberConfig member,
  }) async {
    var tempGroups = _groups
        .map(
          (group) => GroupConfig(
            id: group.id,
            name: group.name,
            color: group.color,
            kind: group.kind,
            members: List<GroupMemberConfig>.from(group.members),
          ),
        )
        .toList(growable: true);
    final memberKind = _groupKindForChannelKind(member.kind);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${member.deviceName}  |  ${member.channelName.isEmpty ? member.channel : member.channelName}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                if (tempGroups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No groups yet. Create one, then save.'),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: tempGroups.map((group) {
                        final selected = _groupContainsMember(group, member);
                        return CheckboxListTile(
                          value: selected,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          secondary: CircleAvatar(
                            radius: 9,
                            backgroundColor: _colorFromHex(group.color),
                          ),
                          title: Text(group.name),
                          subtitle: Text('${group.kind}  |  ${group.members.length} member(s)'),
                          onChanged: (value) {
                            setDialogState(() {
                              tempGroups = tempGroups
                                  .map((item) => item.id == group.id ? _groupWithMembership(item, member, value ?? false) : item)
                                  .toList(growable: true);
                            });
                          },
                        );
                      }).toList(growable: false),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final created = await _openGroupEditor(
                        initialName: member.channelName.isEmpty ? member.deviceName : member.channelName,
                        initialKind: memberKind,
                      );
                      if (created == null) return;
                      setDialogState(() {
                        tempGroups = [
                          ...tempGroups.where((group) => group.id != created.id),
                          GroupConfig(
                            id: created.id,
                            name: created.name,
                            color: created.color,
                            kind: created.kind,
                            members: [member],
                          ),
                        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('New group'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    setState(() {
      _groups = tempGroups;
    });
    await _saveGroupsConfig();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Group membership saved')),
    );
  }

  Future<void> _showAssignGroupDialog(SmartDevice device) async {
    await _showAssignMemberGroupsDialog(
      title: 'Assign Primary Control Groups: ${device.name}',
      member: _buildPrimaryDeviceGroupMember(device),
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

  Future<void> _findNewIpForDevice(SmartDevice device) async {
    try {
      final result = await widget.api.refreshDeviceIp(
        device.id,
        subnetHint: _subnetCtl.text.trim(),
      );
      if (!mounted) return;
      await _refresh();
      final updated = (result['updated'] as bool?) ?? false;
      final oldHost = (result['old_host'] ?? '').toString();
      final newHost = (result['new_host'] ?? '').toString();
      setState(() {
        _statusOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updated
                ? 'IP updated: ${oldHost.isEmpty ? '(empty)' : oldHost} -> $newHost'
                : 'IP unchanged: $newHost',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      setState(() {
        _statusOutput = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _assignMacAddress(SmartDevice device) async {
    final macCtl = TextEditingController(text: device.mac ?? '');
    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Assign MAC: ${device.name}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Host/IP: ${device.host ?? '(not set)'}'),
              const SizedBox(height: 8),
              TextField(
                controller: macCtl,
                decoration: const InputDecoration(
                  labelText: 'MAC address',
                  hintText: 'aa:bb:cc:dd:ee:ff',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'auto'),
            child: const Text('Auto From Host'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'manual'),
            child: const Text('Save MAC'),
          ),
        ],
      ),
    );
    if (action == null) return;

    try {
      late final Map<String, dynamic> result;
      if (action == 'auto') {
        result = await widget.api.assignDeviceMac(
          device.id,
          lookupFromHost: true,
          subnetHint: _subnetCtl.text.trim(),
        );
      } else {
        final mac = macCtl.text.trim();
        if (mac.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a MAC or use Auto From Host.')),
          );
          return;
        }
        result = await widget.api.assignDeviceMac(
          device.id,
          mac: mac,
          lookupFromHost: false,
          subnetHint: _subnetCtl.text.trim(),
        );
      }
      if (!mounted) return;
      await _refresh();
      final newMac = (result['new_mac'] ?? '').toString();
      final updated = (result['updated'] as bool?) ?? false;
      setState(() {
        _statusOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updated ? 'MAC assigned: $newMac' : 'MAC unchanged: $newMac'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);
      setState(() {
        _statusOutput = msg;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
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
              try {
                await widget.api.sendDeviceCommand(
                  deviceId: device.id,
                  channel: channelCtl.text.trim(),
                  state: state,
                  value: int.tryParse(valueCtl.text.trim()),
                  allowCloudFallback: false,
                );
              } on DeviceCommandFallbackException catch (fallbackError) {
                if (!context.mounted) return;
                final ok = await _confirmCloudFallbackForDevice(
                  action: 'advanced control',
                  device: device,
                  error: fallbackError,
                );
                if (!ok) return;
                await widget.api.sendDeviceCommand(
                  deviceId: device.id,
                  channel: channelCtl.text.trim(),
                  state: state,
                  value: int.tryParse(valueCtl.text.trim()),
                  allowCloudFallback: true,
                );
              }
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

  Future<void> _showAdvancedDetails(SmartDevice device) async {
    final nameCtl = TextEditingController(text: device.name);
    final typeCtl = TextEditingController(text: device.type);
    final hostCtl = TextEditingController(text: device.host ?? '');
    final macCtl = TextEditingController(text: device.mac ?? '');
    final staticIpCtl = TextEditingController(text: device.staticIp ?? '');
    final gatewayCtl = TextEditingController(text: device.gateway ?? '');
    final subnetCtl = TextEditingController(text: device.subnetMask ?? '');
    final metadataCtl = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(device.metadata),
    );
    var ipMode = (device.ipMode == 'static') ? 'static' : 'dhcp';
    final channelsPretty = const JsonEncoder.withIndent('  ')
        .convert(device.channels.map((c) => c.toJson()).toList());

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Advanced: ${device.name}'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Device ID: ${device.id}', style: const TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Name')),
                  TextField(controller: typeCtl, decoration: const InputDecoration(labelText: 'Type')),
                  TextField(controller: hostCtl, decoration: const InputDecoration(labelText: 'Host/IP')),
                  TextField(controller: macCtl, decoration: const InputDecoration(labelText: 'MAC')),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: ipMode,
                    decoration: const InputDecoration(labelText: 'IP Mode'),
                    items: const [
                      DropdownMenuItem(value: 'dhcp', child: Text('dhcp')),
                      DropdownMenuItem(value: 'static', child: Text('static')),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() {
                          ipMode = v;
                        });
                      }
                    },
                  ),
                  TextField(controller: staticIpCtl, decoration: const InputDecoration(labelText: 'Static IP')),
                  TextField(controller: gatewayCtl, decoration: const InputDecoration(labelText: 'Gateway')),
                  TextField(controller: subnetCtl, decoration: const InputDecoration(labelText: 'Subnet mask')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: metadataCtl,
                    minLines: 6,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: 'Metadata JSON',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Channels (read-only)', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(channelsPretty, style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            FilledButton(
              onPressed: () async {
                Map<String, dynamic> metadata;
                try {
                  final raw = metadataCtl.text.trim();
                  if (raw.isEmpty) {
                    metadata = <String, dynamic>{};
                  } else {
                    final decoded = jsonDecode(raw);
                    if (decoded is! Map<String, dynamic>) {
                      throw const FormatException('Metadata must be a JSON object');
                    }
                    metadata = decoded;
                  }
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Invalid metadata JSON: $e')),
                  );
                  return;
                }
                try {
                  await widget.api.updateDevice(
                    device.id,
                    {
                      'name': nameCtl.text.trim(),
                      'type': typeCtl.text.trim(),
                      'host': hostCtl.text.trim(),
                      'mac': macCtl.text.trim(),
                      'ip_mode': ipMode,
                      'static_ip': staticIpCtl.text.trim(),
                      'gateway': gatewayCtl.text.trim(),
                      'subnet_mask': subnetCtl.text.trim(),
                      'metadata': metadata,
                    },
                  );
                  if (!mounted) return;
                  Navigator.pop(context);
                  await _refresh();
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    const SnackBar(content: Text('Advanced details saved')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(this.context).showSnackBar(
                    SnackBar(content: Text(_friendlyError(e))),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
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

  String _scanSuggestedGroupKind(Map<String, dynamic> item) {
    final guessedType = _guessDeviceType(item).toLowerCase();
    if (guessedType.contains('light') || guessedType.contains('rgb')) return 'light';
    if (guessedType.contains('fan')) return 'fan';
    return 'switch';
  }

  Future<void> _addScannedDevice(
    Map<String, dynamic> item, {
    String? forceProvider,
    GroupConfig? group,
  }) async {
    final provider = (forceProvider ?? _scanProviderOf(item)).trim().toLowerCase();
    final section = _sectionFromScanProvider(provider);
    if (section != _activeSection) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scan item is from another provider section.')),
      );
      return;
    }

    final host = provider == 'tuya_local'
        ? ((item['local_ip'] ?? item['ip']) ?? '').toString().trim()
        : provider == 'tuya_cloud'
            ? ((item['cloud_ip'] ?? item['ip']) ?? '').toString().trim()
            : (item['ip'] ?? '').toString().trim();
    final mac = provider == 'tuya_local'
        ? ((item['local_mac'] ?? item['mac']) ?? '').toString().trim()
        : provider == 'tuya_cloud'
            ? ((item['cloud_mac'] ?? item['mac']) ?? '').toString().trim()
            : (item['mac'] ?? '').toString().trim();
    final nameRaw = provider == 'tuya_local'
        ? ((item['local_name'] ?? item['name']) ?? '').toString().trim()
        : provider == 'tuya_cloud'
            ? ((item['cloud_name'] ?? item['name']) ?? '').toString().trim()
            : (item['name'] ?? '').toString().trim();
    final displayName = nameRaw.isNotEmpty
        ? nameRaw
        : (host.isNotEmpty ? host : '${_sectionLabel(_activeSection)} Device');

    if (provider == 'moes_bhubw' && (item['moes_cid'] ?? '').toString().trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This is a MOES hub. Add MOES lights (with CID) for direct control.')),
      );
      return;
    }

    final connectionMode = provider == 'tuya_cloud' || _scanIsCloud(item) ? 'cloud' : 'local_lan';
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
      metadata['tuya_version'] = (provider == 'tuya_local' ? item['local_version'] : item['cloud_version'] ?? item['local_version'] ?? item['tuya_version'])
          .toString()
          .trim();
      metadata['version'] = metadata['tuya_version'];
      metadata['tuya_product_key'] = (provider == 'tuya_local' ? item['local_product_key'] : item['cloud_product_key'] ?? item['local_product_key'] ?? item['tuya_product_key'])
          .toString()
          .trim();
      metadata['product_key'] = metadata['tuya_product_key'];
      metadata['tuya_local_key'] = (provider == 'tuya_local' ? item['local_key'] : item['cloud_local_key'] ?? item['local_key']).toString().trim();
      metadata['local_key'] = metadata['tuya_local_key'];
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
      final createdDevice = await widget.api.createDevice(
        name: displayName,
        type: _guessDeviceType(item),
        host: host.isEmpty ? null : host,
        mac: mac.isEmpty ? null : mac,
        passcode: null,
        metadata: metadata,
      );
      await _seedScannedDeviceChannels(createdDevice, item);
      if (group != null) {
        final member = _buildPrimaryDeviceGroupMember(createdDevice);
        final nextGroups = _groups
            .map((item) => item.id == group.id ? _groupWithMembership(item, member, true) : item)
            .toList(growable: false);
        setState(() {
          _groups = nextGroups;
        });
        await _saveGroupsConfig();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added device: $displayName')));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Future<void> _seedScannedDeviceChannels(SmartDevice device, Map<String, dynamic> item) async {
    try {
      final status = await widget.api.getDeviceStatus(device.id);
      final outputs = (status['outputs'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      if (outputs.isEmpty) return;

      final channelSpecs = <Map<String, String>>[];
      final seen = <String>{};
      for (final entry in outputs.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        if (!_isExplicitSwitchChannelKey(key, entry.value)) continue;
        if (!seen.add(key)) continue;
        channelSpecs.add({
          'channel_key': key,
          'channel_name': _scanChannelName(item, key),
          'channel_kind': 'relay',
        });
      }

      for (final spec in channelSpecs) {
        await widget.api.upsertChannel(
          deviceId: device.id,
          channelKey: spec['channel_key']!,
          channelName: spec['channel_name']!,
          channelKind: spec['channel_kind']!,
          payload: const <String, dynamic>{},
        );
      }
    } catch (_) {
      // Best effort only. Device add should still succeed when status probing is unavailable.
    }
  }

  Future<void> _showScanProviderMenu(
    BuildContext context,
    Offset anchor,
    Map<String, dynamic> item, {
    required String provider,
  }) async {
    final isLocal = provider == 'tuya_local' || provider == 'local_lan';
    final providerLabel = isLocal ? 'Lan' : 'Cloud';
    final groupPrefix = isLocal ? 'local_group:' : 'cloud_group:';
    final directValue = isLocal ? 'local_direct' : 'cloud_direct';
    final newGroupValue = isLocal ? 'local_new_group' : 'cloud_new_group';
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: directValue,
        child: Text('Add $providerLabel device'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        enabled: false,
        value: '__groups_header__',
        child: Text('Add in group'),
      ),
      ..._groups.map(
        (group) => PopupMenuItem<String>(
          value: '$groupPrefix${group.id}',
          child: Text(group.name),
        ),
      ),
      PopupMenuItem<String>(
        value: newGroupValue,
        child: const Text('New group'),
      ),
    ];

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: items,
    );
    if (selected == null) return;

    Future<GroupConfig?> resolveGroup(String id) async {
      if (id == '__new__') {
        return _ensureGroupFromPrompt(
          initialName: _scanDisplayName(item),
          initialKind: _scanSuggestedGroupKind(item),
        );
      }
      for (final group in _groups) {
        if (group.id == id) return group;
      }
      return null;
    }

    if (selected == directValue) {
      await _addScannedDevice(item, forceProvider: provider);
      return;
    }
    if (selected == newGroupValue) {
      final group = await resolveGroup('__new__');
      if (group == null) return;
      await _addScannedDevice(item, forceProvider: provider, group: group);
      return;
    }
    if (selected.startsWith(groupPrefix)) {
      final group = await resolveGroup(selected.substring(groupPrefix.length));
      if (group == null) return;
      await _addScannedDevice(item, forceProvider: provider, group: group);
    }
  }

  Future<void> _showScanContextMenu(
    BuildContext context,
    Offset globalPosition,
    Map<String, dynamic> item,
  ) async {
    final supportsLocal = _activeSection != _DeviceSection.tuya || _tuyaSupportsLocal(item);
    final supportsCloud = _activeSection == _DeviceSection.tuya && _tuyaSupportsCloud(item);
    final entries = <PopupMenuEntry<String>>[];

    if (supportsLocal) {
      entries.add(const PopupMenuItem<String>(value: 'local_direct', child: Text('Add Local')));
      for (final group in _groups) {
        entries.add(
          PopupMenuItem<String>(
            value: 'local_group:${group.id}',
            child: Text('Add Local to ${group.name}'),
          ),
        );
      }
      entries.add(const PopupMenuItem<String>(value: 'local_new_group', child: Text('New Group + Add Local')));
    }

    if (supportsCloud) {
      if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
      entries.add(const PopupMenuItem<String>(value: 'cloud_direct', child: Text('Add Cloud')));
      for (final group in _groups) {
        entries.add(
          PopupMenuItem<String>(
            value: 'cloud_group:${group.id}',
            child: Text('Add Cloud to ${group.name}'),
          ),
        );
      }
      entries.add(const PopupMenuItem<String>(value: 'cloud_new_group', child: Text('New Group + Add Cloud')));
    }

    if (entries.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: entries,
    );
    if (selected == null) return;

    Future<GroupConfig?> resolveGroup(String id) async {
      if (id == '__new__') {
        return _ensureGroupFromPrompt(
          initialName: _scanDisplayName(item),
          initialKind: _scanSuggestedGroupKind(item),
        );
      }
      for (final group in _groups) {
        if (group.id == id) return group;
      }
      return null;
    }

    if (selected == 'local_direct') {
      await _addScannedDevice(item, forceProvider: _activeSection == _DeviceSection.tuya ? 'tuya_local' : null);
      return;
    }
    if (selected == 'cloud_direct') {
      await _addScannedDevice(item, forceProvider: 'tuya_cloud');
      return;
    }
    if (selected == 'local_new_group') {
      final group = await resolveGroup('__new__');
      if (group == null) return;
      await _addScannedDevice(
        item,
        forceProvider: _activeSection == _DeviceSection.tuya ? 'tuya_local' : null,
        group: group,
      );
      return;
    }
    if (selected == 'cloud_new_group') {
      final group = await resolveGroup('__new__');
      if (group == null) return;
      await _addScannedDevice(item, forceProvider: 'tuya_cloud', group: group);
      return;
    }
    if (selected.startsWith('local_group:')) {
      final group = await resolveGroup(selected.substring('local_group:'.length));
      if (group == null) return;
      await _addScannedDevice(
        item,
        forceProvider: _activeSection == _DeviceSection.tuya ? 'tuya_local' : null,
        group: group,
      );
      return;
    }
    if (selected.startsWith('cloud_group:')) {
      final group = await resolveGroup(selected.substring('cloud_group:'.length));
      if (group == null) return;
      await _addScannedDevice(item, forceProvider: 'tuya_cloud', group: group);
    }
  }

  Future<void> _showScanGroupDialog(Map<String, dynamic> item, {required String provider}) async {
    final selectedId = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Add ${_scanDisplayName(item)} to group'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ..._groups.map(
                (group) => ListTile(
                  dense: true,
                  leading: CircleAvatar(backgroundColor: _colorFromHex(group.color), radius: 9),
                  title: Text(group.name),
                  onTap: () => Navigator.pop(context, group.id),
                ),
              ),
              const Divider(),
              ListTile(
                dense: true,
                leading: const Icon(Icons.add),
                title: const Text('New group'),
                onTap: () => Navigator.pop(context, '__new__'),
              ),
            ],
          ),
        ),
      ),
    );
    if (selectedId == null) return;
    GroupConfig? group;
    if (selectedId == '__new__') {
      group = await _ensureGroupFromPrompt(
        initialName: _scanDisplayName(item),
        initialKind: _scanSuggestedGroupKind(item),
      );
    } else {
      for (final candidate in _groups) {
        if (candidate.id == selectedId) {
          group = candidate;
          break;
        }
      }
    }
    if (group == null) return;
    await _addScannedDevice(item, forceProvider: provider, group: group);
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
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDeviceStatusStrip(device),
            if (_isLightDevice(device)) _buildLightControls(device),
            if (!_isLightDevice(device))
              const Text('No relay/switch channels detected yet. Tap Status once to detect channels.'),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDeviceStatusStrip(device),
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
                        _buildMemberGroupChips(device.id, channel.key),
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
                    onPressed: () => _showAssignMemberGroupsDialog(
                      title: 'Assign ${channel.name} to Groups',
                      member: _buildGroupMemberForChannel(device, channel),
                    ),
                    child: const Text('Groups'),
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
        _buildLightControls(device),
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
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 150,
                              child: DropdownButtonFormField<_DeviceSort>(
                                value: _deviceSort,
                                decoration: const InputDecoration(labelText: 'Sort'),
                                items: _DeviceSort.values
                                    .map(
                                      (sort) => DropdownMenuItem<_DeviceSort>(
                                        value: sort,
                                        child: Text(_deviceSortLabel(sort)),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() {
                                    _deviceSort = value;
                                  });
                                },
                              ),
                            ),
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
                                      final deviceGroups = _groupsForDevice(d);
                                      return ExpansionTile(
                                        onExpansionChanged: (expanded) {
                                          if (expanded) {
                                            _loadDeviceStatus(d, showOutput: false);
                                          }
                                        },
                                        title: Row(
                                          children: [
                                            if (deviceGroups.isNotEmpty)
                                              Container(
                                                width: 10,
                                                height: 10,
                                                margin: const EdgeInsets.only(right: 8),
                                                decoration: BoxDecoration(
                                                  color: _colorFromHex(deviceGroups.first.color),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            Expanded(
                                              child: Text(
                                                d.name,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Icon(
                                              _connectionIconForDevice(d),
                                              color: _connectionColorForDevice(d),
                                            ),
                                          ],
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
                                                    Chip(label: Text(source)),
                                                    Chip(label: Text(mode)),
                                                    Chip(label: Text(d.host ?? d.mac ?? 'No host yet')),
                                                  ],
                                                ),
                                                if (deviceGroups.isNotEmpty) ...[
                                                  const SizedBox(height: 8),
                                                  _buildDeviceGroupChips(d),
                                                ],
                                                const SizedBox(height: 8),
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    OutlinedButton(onPressed: () => _renameDevice(d), child: const Text('Rename')),
                                                    OutlinedButton(onPressed: () => _showAssignGroupDialog(d), child: const Text('Primary Groups')),
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
                                                    OutlinedButton(onPressed: () => _combineQuickChannels(d), child: const Text('Combine Switches')),
                                                    if (isEspFirmware) OutlinedButton(onPressed: () => _pushOtaDialog(d), child: const Text('Push OTA')),
                                                    OutlinedButton(onPressed: () => _showAdvancedDetails(d), child: const Text('Advanced')),
                                                    OutlinedButton(
                                                      onPressed: () async {
                                                        await widget.api.rescanDevice(d.id);
                                                        await _refresh();
                                                      },
                                                      child: const Text('Rescan'),
                                                    ),
                                                    OutlinedButton(
                                                      onPressed: () => _assignMacAddress(d),
                                                      child: const Text('Assign MAC'),
                                                    ),
                                                    OutlinedButton(
                                                      onPressed: () => _findNewIpForDevice(d),
                                                      child: const Text('Find New IP'),
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
                  if (_activeSection == _DeviceSection.tuya)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _TuyaScanFilter.values
                            .map(
                              (filter) => ChoiceChip(
                                label: Text(_tuyaFilterLabel(filter)),
                                selected: _tuyaScanFilter == filter,
                                onSelected: (selected) {
                                  if (!selected) return;
                                  setState(() {
                                    _tuyaScanFilter = filter;
                                  });
                                },
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                          child: TextField(
                            controller: _scanSearchCtl,
                            decoration: const InputDecoration(
                              labelText: 'Search found devices',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        ..._scanResults.where(_scanMatchesActiveSection).where((item) {
                          if (_activeSection != _DeviceSection.tuya) return true;
                          return _matchesTuyaScanFilter(item);
                        }).where(_matchesScanSearch).map(
                          (item) => Builder(
                            builder: (tileContext) => GestureDetector(
                              onSecondaryTapDown: (details) => _showScanContextMenu(tileContext, details.globalPosition, item),
                              child: ListTile(
                                dense: true,
                                leading: Icon(
                                  _connectionIconForScan(item),
                                  color: _tuyaSupportsLocal(item) && _tuyaSupportsCloud(item)
                                      ? Colors.blue
                                      : (_scanIsCloud(item) ? Colors.orange : Colors.green),
                                ),
                                title: Text(_scanDisplayName(item)),
                                subtitle: Text(
                                  _activeSection == _DeviceSection.tuya
                                      ? 'Local: ${_tuyaSupportsLocal(item) ? 'yes' : 'no'}  Cloud: ${_tuyaSupportsCloud(item) ? 'yes' : 'no'}  '
                                          'Local IP: ${(item['local_ip'] ?? item['ip'] ?? '').toString()}  MAC: ${(item['local_mac'] ?? item['mac'] ?? '').toString()}\n'
                                          'Device ID: ${(item['tuya_device_id'] ?? '').toString()}  '
                                          'Hint: ${item['device_hint'] ?? item['provider_hint'] ?? 'unknown'}'
                                      : 'IP: ${item['ip'] ?? ''}  Host: ${item['hostname'] ?? ''}  MAC: ${item['mac'] ?? ''}\n'
                                          'Hint: ${item['device_hint'] ?? item['provider_hint'] ?? 'unknown'}'
                                          '  Score: ${item['score'] ?? 0}  Mode: ${item['mode'] ?? 'local_lan'}',
                                ),
                                trailing: _activeSection == _DeviceSection.tuya
                                    ? Wrap(
                                        spacing: 4,
                                        children: [
                                          if (_tuyaSupportsLocal(item))
                                            Builder(
                                              builder: (iconContext) => IconButton(
                                                tooltip: 'Lan options',
                                                icon: const Icon(Icons.lan),
                                                onPressed: () async {
                                                  final box = iconContext.findRenderObject() as RenderBox?;
                                                  if (box == null) return;
                                                  final anchor = box.localToGlobal(box.size.bottomRight(Offset.zero));
                                                  await _showScanProviderMenu(
                                                    iconContext,
                                                    anchor,
                                                    item,
                                                    provider: 'tuya_local',
                                                  );
                                                },
                                              ),
                                            ),
                                          if (_tuyaSupportsCloud(item))
                                            Builder(
                                              builder: (iconContext) => IconButton(
                                                tooltip: 'Cloud options',
                                                icon: const Icon(Icons.cloud),
                                                onPressed: () async {
                                                  final box = iconContext.findRenderObject() as RenderBox?;
                                                  if (box == null) return;
                                                  final anchor = box.localToGlobal(box.size.bottomRight(Offset.zero));
                                                  await _showScanProviderMenu(
                                                    iconContext,
                                                    anchor,
                                                    item,
                                                    provider: 'tuya_cloud',
                                                  );
                                                },
                                              ),
                                            ),
                                        ],
                                      )
                                    : Wrap(
                                        spacing: 4,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline),
                                            onPressed: () => _addScannedDevice(item),
                                          ),
                                          IconButton(
                                            tooltip: 'Add to Group',
                                            icon: const Icon(Icons.device_hub),
                                            onPressed: () => _showScanGroupDialog(item, provider: _scanProviderOf(item)),
                                          ),
                                        ],
                                      ),
                              ),
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
