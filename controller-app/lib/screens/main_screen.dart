import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/device_models.dart';
import '../services/api_service.dart';
import '../services/session_logger.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.api});

  final ApiService api;

  @override
  MainScreenState createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  List<Map<String, dynamic>> _tiles = [];
  final Set<String> _groupActionBusy = <String>{};
  final Set<String> _tileActionBusy = <String>{};
  DateTime? _lastLoadedAt;
  static const Map<String, IconData> _iconOptions = <String, IconData>{
    'auto': Icons.auto_awesome,
    'power': Icons.power_settings_new,
    'light': Icons.lightbulb_outline,
    'switch': Icons.toggle_on,
    'fan': Icons.toys,
    'lamp': Icons.lightbulb_outline,
    'strip': Icons.linear_scale,
    'scene': Icons.auto_fix_high,
    'timer': Icons.timer,
    'home': Icons.home,
    'garage': Icons.home,
    'gate': Icons.meeting_room,
    'water': Icons.opacity,
    'pool': Icons.pool,
    'speaker': Icons.speaker,
    'tv': Icons.tv,
    'music': Icons.music_note,
    'heater': Icons.whatshot,
    'camera': Icons.videocam,
    'security': Icons.security,
  };
  static const List<Map<String, String>> _lightScenes = <Map<String, String>>[
    {'id': '1', 'label': 'Relax'},
    {'id': '2', 'label': 'Focus'},
    {'id': '3', 'label': 'Party'},
    {'id': '4', 'label': 'Night'},
  ];

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
    WidgetsBinding.instance.addObserver(this);
    _load(initial: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final lastLoadedAt = _lastLoadedAt;
    if (_loading || _refreshing) return;
    if (lastLoadedAt == null || DateTime.now().difference(lastLoadedAt) > const Duration(seconds: 20)) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool initial = false}) async {
    if (!mounted) return;
    final showInitialLoader = initial && _tiles.isEmpty;
    setState(() {
      if (showInitialLoader) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });

    final tileDataFuture = widget.api.fetchTileData();
    if (showInitialLoader) {
      unawaited(() async {
        try {
          final shellTiles = await widget.api.fetchTiles();
          if (!mounted) return;
          if (_tiles.isNotEmpty && !_loading) return;
          setState(() {
            _tiles = shellTiles.map(_shellTileToDisplayTile).toList(growable: false);
            _loading = false;
            _refreshing = true;
            _lastLoadedAt = DateTime.now();
          });
        } catch (_) {
          // Keep the loader visible and let the full tile-data request report the error.
        }
      }());
    }

    try {
      final tiles = await tileDataFuture;
      if (!mounted) return;
      setState(() {
        _tiles = tiles;
        _lastLoadedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyError(e);
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _runSpotifyAction(String action) async {
    await widget.api.spotifyAction(action);
    await _load();
  }

  Map<String, dynamic> _shellTileToDisplayTile(MainTile tile) {
    final payload = Map<String, dynamic>.from(tile.payload);
    final tileType = tile.tileType;
    final fallbackType = tileType == 'device'
        ? ((payload['device_type'] ?? payload['type'] ?? '').toString().trim())
        : tileType == 'group'
            ? ((payload['group_kind'] ?? 'switch').toString().trim())
            : tileType;
    final channelKey = (payload['channel'] ?? 'relay1').toString().trim();
    final placeholderOutputs = <String, dynamic>{};
    if (tileType == 'device') {
      placeholderOutputs[channelKey] = null;
      if (channelKey == 'light' || channelKey == 'power') {
        placeholderOutputs['power'] = null;
        placeholderOutputs['light'] = null;
      }
    }
    return <String, dynamic>{
      'id': tile.id,
      'tile_type': tile.tileType,
      'ref_id': tile.refId ?? '',
      'label': tile.label,
      'payload': payload,
      'data': <String, dynamic>{
        'type': fallbackType,
        'device_type': fallbackType,
        'mode': (payload['mode'] ?? 'local_lan').toString(),
        'provider': (payload['provider'] ?? '').toString(),
        'ip': (payload['ip'] ?? payload['host'] ?? '').toString(),
        'host': (payload['host'] ?? '').toString(),
        if (tileType == 'device') 'outputs': placeholderOutputs,
        if (tileType == 'group')
          'member_count': (payload['members'] as List<dynamic>?)?.length ?? 0,
        if (tileType == 'group')
          'members': payload['members'] ?? const <dynamic>[],
        if (tileType == 'group')
          'group_kind': (payload['group_kind'] ?? 'switch').toString(),
        if (tileType == 'group') 'group_state': 'unknown',
        if (tileType == 'automation')
          'group_name': (payload['group_name'] ?? '').toString(),
        if (tileType == 'automation')
          'requested_state': (payload['state'] ?? 'toggle').toString(),
        if (tileType == 'automation')
          'member_count': ((payload['members'] as List<dynamic>?)?.length ?? 0),
      },
      'error': null,
    };
  }

  String _deviceDisplayName(Map<String, dynamic> tile) {
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final label = (tile['label'] ?? '').toString().trim();
    final channelName = (payload['channel_name'] ?? '').toString().trim();
    if (channelName.isNotEmpty) return channelName;
    return label;
  }

  IconData _iconForTile(Map<String, dynamic> tile) {
    final tileType = (tile['tile_type'] ?? '').toString();
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final iconKey = (payload['icon_key'] ?? '').toString().trim();
    if (iconKey.isNotEmpty && _iconOptions.containsKey(iconKey)) {
      return _iconOptions[iconKey]!;
    }
    if (tileType == 'weather') return Icons.cloud;
    if (tileType == 'spotify') return Icons.graphic_eq;
    if (tileType == 'automation') return Icons.auto_awesome;
    final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
    if (type.contains('fan')) return Icons.toys;
    if (type.contains('light')) return Icons.lightbulb_outline;
    if (type.contains('relay') || type.contains('switch')) return Icons.toggle_on;
    return Icons.settings_remote;
  }

  bool _isLightTile(Map<String, dynamic> tile) {
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final capabilities = (data['capabilities'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
    final channel = (payload['channel'] ?? '').toString().toLowerCase();
    return (capabilities['supports_light'] as bool?) == true ||
        (capabilities['supports_rgb'] as bool?) == true ||
        type.contains('light') ||
        channel == 'light' ||
        channel == 'rgb' ||
        channel == 'rgbw' ||
        channel == 'dimmer';
  }

  bool _isAutomated(Map<String, dynamic> tile) {
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return (payload['automation_enabled'] as bool?) == true || (payload['timers_enabled'] as bool?) == true;
  }

  Future<void> _sendLightPreset(
    String refId, {
    required bool cloudMode,
    required String label,
    required String channel,
    String state = 'set',
    int? value,
    Map<String, dynamic>? payload,
  }) async {
    if (cloudMode) {
      final ok = await _confirmCloudWarning(label);
      if (!ok) return;
    }
    await widget.api.sendDeviceCommand(
      deviceId: refId,
      channel: channel,
      state: state,
      value: value,
      payload: payload,
    );
    await _load();
  }

  Future<void> _showLightDesigner({
    required String refId,
    required bool cloudMode,
    required String label,
    required bool isRgbw,
  }) async {
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
            title: Text('Light Control: $label'),
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
                    Slider(value: hue, min: 0, max: 360, onChanged: (v) => setDialogState(() => hue = v)),
                    Text('Saturation ${(saturation * 100).round()}%'),
                    Slider(value: saturation, min: 0, max: 1, onChanged: (v) => setDialogState(() => saturation = v)),
                    Text('Colour Brightness ${(value * 100).round()}%'),
                    Slider(value: value, min: 0.1, max: 1, onChanged: (v) => setDialogState(() => value = v)),
                    Text('Output Brightness ${brightness.round()}%'),
                    Slider(value: brightness, min: 1, max: 100, onChanged: (v) => setDialogState(() => brightness = v)),
                    if (isRgbw) ...[
                      Text('White ${whiteLevel.round()}%'),
                      Slider(value: whiteLevel, min: 0, max: 100, onChanged: (v) => setDialogState(() => whiteLevel = v)),
                      Text('White Temp ${colorTemp.round()}%'),
                      Slider(value: colorTemp, min: 0, max: 100, onChanged: (v) => setDialogState(() => colorTemp = v)),
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
                                await _sendLightPreset(
                                  refId,
                                  cloudMode: cloudMode,
                                  label: label,
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
                    await _sendLightPreset(
                      refId,
                      cloudMode: cloudMode,
                      label: label,
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
                  await _sendLightPreset(
                    refId,
                    cloudMode: cloudMode,
                    label: label,
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

  Future<bool> _confirmCloudWarning(String label) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cloud Device Warning'),
        content: Text(
          '"$label" is cloud-connected.\n\n'
          'Control may fail if internet/cloud API is unavailable and can be slower than local LAN.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    return result ?? false;
  }

  bool? _asBoolState(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    if (text == 'on' || text == 'true' || text == '1' || text == 'yes') return true;
    if (text == 'off' || text == 'false' || text == '0' || text == 'no') return false;
    return null;
  }

  void _applyOptimisticDeviceTileState({
    required String refId,
    required String channel,
    required String state,
    bool? previousState,
  }) {
    if (!mounted) return;
    setState(() {
      _tiles = _tiles.map((tile) {
        if ((tile['tile_type'] ?? '').toString() != 'device') return tile;
        if ((tile['ref_id'] ?? '').toString().trim() != refId) return tile;
        final payload = Map<String, dynamic>.from((tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
        final tileChannel = (payload['channel'] ?? 'relay1').toString().trim();
        if (tileChannel != channel) return tile;
        final data = Map<String, dynamic>.from((tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
        final outputs = Map<String, dynamic>.from((data['outputs'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
        bool? nextState;
        if (state == 'on') nextState = true;
        if (state == 'off') nextState = false;
        if (state == 'toggle') nextState = previousState == null ? null : !previousState;
        if (nextState != null) {
          outputs[channel] = nextState;
          if (channel == 'power' || channel == 'light') {
            outputs['power'] = nextState;
            outputs['light'] = nextState;
          }
          data['outputs'] = outputs;
          return {
            ...tile,
            'data': data,
            'error': null,
          };
        }
        return tile;
      }).toList(growable: false);
      _lastLoadedAt = DateTime.now();
    });
  }

  void _applyOptimisticGroupTileState({
    required String tileId,
    required String state,
  }) {
    if (!mounted) return;
    setState(() {
      _tiles = _tiles.map((tile) {
        if ((tile['id'] ?? '').toString().trim() != tileId) return tile;
        if ((tile['tile_type'] ?? '').toString() != 'group') return tile;
        final data = Map<String, dynamic>.from((tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{});
        if (state == 'on') {
          data['group_state'] = 'on';
          data['outputs'] = {
            ...(data['outputs'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
            'power': true,
            'light': true,
          };
        } else if (state == 'off') {
          data['group_state'] = 'off';
          data['outputs'] = {
            ...(data['outputs'] as Map<String, dynamic>? ?? const <String, dynamic>{}),
            'power': false,
            'light': false,
          };
        }
        return {
          ...tile,
          'data': data,
          'error': null,
        };
      }).toList(growable: false);
      _lastLoadedAt = DateTime.now();
    });
  }

  Future<void> _sendDeviceState(
    String refId, {
    String? tileId,
    bool? currentState,
    required bool cloudMode,
    required String label,
    required String channel,
    required String state,
  }) async {
    final busyKey = '${tileId ?? refId}::$channel';
    if (_tileActionBusy.contains(busyKey)) return;
    if (cloudMode) {
      final ok = await _confirmCloudWarning(label);
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() {
      _tileActionBusy.add(busyKey);
    });
    _applyOptimisticDeviceTileState(refId: refId, channel: channel, state: state, previousState: currentState);
    unawaited(
      SessionLogger.instance.logActivity('main_tile_command_started', <String, dynamic>{
        'device_id': refId,
        'tile_id': tileId ?? '',
        'channel': channel,
        'state': state,
        'cloud_mode': cloudMode,
        'label': label,
      }),
    );
    try {
      await widget.api.sendDeviceCommand(
        deviceId: refId,
        channel: channel,
        state: state,
      );
      unawaited(
        SessionLogger.instance.logActivity('main_tile_command_finished', <String, dynamic>{
          'device_id': refId,
          'tile_id': tileId ?? '',
          'channel': channel,
          'state': state,
        }),
      );
      unawaited(_load());
    } catch (e) {
      if (!mounted) return;
      unawaited(
        SessionLogger.instance.logError(
          'main_tile_command_failed',
          e,
          payload: <String, dynamic>{
            'device_id': refId,
            'tile_id': tileId ?? '',
            'channel': channel,
            'state': state,
            'cloud_mode': cloudMode,
            'label': label,
          },
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      unawaited(_load());
    } finally {
      if (mounted) {
        setState(() {
          _tileActionBusy.remove(busyKey);
        });
      }
    }
  }

  List<Map<String, String>> _groupCandidatesForDevice(SmartDevice device) {
    if (device.channels.isNotEmpty) {
      return device.channels
          .map(
            (channel) => <String, String>{
              'channel': channel.channelKey,
              'label': '${device.name} - ${channel.channelName}',
              'device_name': device.name,
              'channel_name': channel.channelName,
              'kind': channel.channelKind,
            },
          )
          .toList(growable: false);
    }

    final type = device.type.toLowerCase().trim();
    final channel = type.contains('light')
        ? 'light'
        : type.contains('fan')
            ? 'fan_power'
            : 'power';
    return [
      <String, String>{
        'channel': channel,
        'label': device.name,
        'device_name': device.name,
        'channel_name': channel,
        'kind': type,
      },
    ];
  }

  Future<void> _sendGroupState(Map<String, dynamic> tile, String state) async {
    final tileId = (tile['id'] ?? '').toString().trim();
    if (tileId.isEmpty || _groupActionBusy.contains(tileId)) return;
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final label = (tile['label'] ?? 'Group').toString();
    final mode = (data['mode'] ?? '').toString().toLowerCase();
    final cloudCount = (data['cloud_count'] as num?)?.toInt() ?? 0;
    if (mode.contains('cloud') || cloudCount > 0) {
      final ok = await _confirmCloudWarning(label);
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() {
      _groupActionBusy.add(tileId);
    });
    _applyOptimisticGroupTileState(tileId: tileId, state: state);
    unawaited(
      SessionLogger.instance.logActivity('group_tile_command_started', <String, dynamic>{
        'tile_id': tileId,
        'state': state,
        'label': label,
      }),
    );
    try {
      final result = await widget.api.sendGroupTileAction(tileId: tileId, state: state);
      if (!mounted) return;
      final okCount = (result['ok_count'] as num?)?.toInt() ?? 0;
      final errorCount = (result['error_count'] as num?)?.toInt() ?? 0;
      unawaited(
        SessionLogger.instance.logActivity('group_tile_command_finished', <String, dynamic>{
          'tile_id': tileId,
          'state': state,
          'label': label,
          'ok_count': okCount,
          'error_count': errorCount,
        }),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Group "$label": $okCount ok, $errorCount failed')),
      );
      unawaited(_load());
    } catch (e) {
      if (!mounted) return;
      unawaited(
        SessionLogger.instance.logError(
          'group_tile_command_failed',
          e,
          payload: <String, dynamic>{
            'tile_id': tileId,
            'state': state,
            'label': label,
          },
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      unawaited(_load());
    } finally {
      if (mounted) {
        setState(() {
          _groupActionBusy.remove(tileId);
        });
      }
    }
  }

  Future<void> _runAutomationTile(Map<String, dynamic> tile) async {
    final tileId = (tile['id'] ?? '').toString().trim();
    if (tileId.isEmpty || _tileActionBusy.contains(tileId)) return;
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final requestedState = (payload['state'] ?? 'toggle').toString().trim();
    setState(() {
      _tileActionBusy.add(tileId);
    });
    try {
      await widget.api.runAutomationTile(tileId: tileId, state: requestedState);
      if (!mounted) return;
      unawaited(_load());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Automation "${tile['label']}" ran')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    } finally {
      if (mounted) {
        setState(() {
          _tileActionBusy.remove(tileId);
        });
      }
    }
  }

  Future<void> _openCreateGroupDialog() async {
    List<SmartDevice> devices;
    try {
      devices = await widget.api.fetchDevices();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
      return;
    }
    if (!mounted) return;

    final nameCtl = TextEditingController();
    var groupKind = 'switch';
    final selected = <String, bool>{};
    final candidates = <Map<String, String>>[];
    for (final device in devices) {
      for (final item in _groupCandidatesForDevice(device)) {
        candidates.add({
          'device_id': device.id,
          'device_name': device.name,
          'channel': item['channel'] ?? '',
          'label': item['label'] ?? device.name,
          'channel_name': item['channel_name'] ?? '',
          'kind': item['kind'] ?? '',
        });
      }
    }

    final created = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Create Group'),
            content: SizedBox(
              width: 720,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtl,
                    decoration: const InputDecoration(
                      labelText: 'Group name',
                      hintText: 'Example: Lounge Lights',
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: groupKind,
                    decoration: const InputDecoration(labelText: 'Group type'),
                    items: const [
                      DropdownMenuItem(value: 'switch', child: Text('Switch Group')),
                      DropdownMenuItem(value: 'light', child: Text('Light Group')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setLocal(() {
                        groupKind = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text('Select devices or channels'),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 320,
                    child: ListView(
                      shrinkWrap: true,
                      children: candidates.map((item) {
                        final key = '${item['device_id']}::${item['channel']}';
                        final checked = selected[key] ?? false;
                        return CheckboxListTile(
                          value: checked,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(item['label'] ?? ''),
                          subtitle: Text('Device: ${item['device_name']}  Channel: ${item['channel']}'),
                          onChanged: (value) {
                            setLocal(() {
                              selected[key] = value ?? false;
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
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save Group')),
            ],
          ),
        );
      },
    );
    if (created != true) return;

    final groupName = nameCtl.text.trim();
    final members = candidates
        .where((item) => selected['${item['device_id']}::${item['channel']}'] == true)
        .map(
          (item) => <String, dynamic>{
            'device_id': item['device_id'],
            'device_name': item['device_name'],
            'channel': item['channel'],
            'label': item['label'],
          },
        )
        .toList(growable: false);
    if (groupName.isEmpty || members.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group name and at least one device/channel are required')),
      );
      return;
    }

    try {
      await widget.api.addTile(
        tileType: 'group',
        label: groupName,
        payload: {
          'group_kind': groupKind,
          'members': members,
          'icon_key': groupKind == 'light' ? 'light' : 'switch',
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Group "$groupName" added to Main')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendlyError(e))));
    }
  }

  Future<void> openCreateGroupDialog() => _openCreateGroupDialog();

  Future<void> openAutomationDialog() => _openAutomationDialog();

  Future<void> _openAutomationDialog() async {
    final automationTiles = _tiles.where((tile) {
      if ((tile['tile_type'] ?? '').toString() == 'automation') return true;
      final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      return (payload['automation_enabled'] as bool?) == true || (payload['timers_enabled'] as bool?) == true;
    }).toList(growable: false);
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Automation'),
        content: SizedBox(
          width: 520,
          height: 320,
          child: automationTiles.isEmpty
              ? const Center(
                  child: Text('No automation/timer tiles saved yet.\nLong-press a Main card to configure Automation or Timers.'),
                )
              : ListView(
                  children: automationTiles.map((tile) {
                    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
                    final tileType = (tile['tile_type'] ?? '').toString();
                    final automationTarget = (payload['group_name'] ?? '').toString().trim();
                    final requestedState = (payload['state'] ?? 'toggle').toString().trim();
                    final automation = (payload['automation_note'] ?? '').toString().trim();
                    final timer = (payload['timer_note'] ?? '').toString().trim();
                    return ListTile(
                      title: Text((tile['label'] ?? 'Tile').toString()),
                      subtitle: Text(
                        tileType == 'automation'
                            ? 'Group: ${automationTarget.isEmpty ? '(not set)' : automationTarget}\n'
                                'Action: ${requestedState.isEmpty ? '(not set)' : requestedState}'
                            : 'Automation: ${automation.isEmpty ? '(not set)' : automation}\n'
                                'Timers: ${timer.isEmpty ? '(not set)' : timer}',
                      ),
                      trailing: tileType == 'automation'
                          ? FilledButton.tonal(
                              onPressed: () => _runAutomationTile(tile),
                              child: const Text('Run'),
                            )
                          : null,
                    );
                  }).toList(growable: false),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _configureDeviceTile(Map<String, dynamic> tile) async {
    final tileId = (tile['id'] ?? '').toString().trim();
    if (tileId.isEmpty) return;
    final payload = Map<String, dynamic>.from((tile['payload'] as Map<String, dynamic>?) ?? <String, dynamic>{});
    final refId = (tile['ref_id'] ?? '').toString().trim();
    final data = (tile['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final cloudMode =
        (data['mode'] ?? 'local_lan').toString().toLowerCase().contains('cloud') || (data['provider'] ?? '').toString() == 'tuya_cloud';
    final deviceLabel = _deviceDisplayName(tile);
    var actionMode = (payload['action_mode'] ?? 'toggle').toString() == 'on_off' ? 'on_off' : 'toggle';
    var iconKey = (payload['icon_key'] ?? '').toString().trim();
    var showIp = (payload['show_ip'] as bool?) ?? false;
    var showStatus = (payload['show_status'] as bool?) ?? true;
    var automationEnabled = (payload['automation_enabled'] as bool?) ?? false;
    var timersEnabled = (payload['timers_enabled'] as bool?) ?? false;
    Map<String, dynamic> automationData = <String, dynamic>{};
    try {
      automationData = await widget.api.fetchTileAutomation(tileId);
    } catch (_) {}
    final savedRules = (automationData['rules'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    Map<String, dynamic>? automationRule;
    Map<String, dynamic>? timerRule;
    for (final rule in savedRules) {
      final kind = (rule['rule_kind'] ?? '').toString();
      if (kind == 'automation' && automationRule == null) automationRule = rule;
      if (kind == 'timer' && timerRule == null) timerRule = rule;
    }
    final automationCtl = TextEditingController(
      text: (automationRule?['label'] ?? payload['automation_note'] ?? '').toString(),
    );
    final timerCtl = TextEditingController(
      text: (timerRule?['label'] ?? payload['timer_note'] ?? '').toString(),
    );
    final automationStartCtl = TextEditingController(
      text: ((automationRule?['schedule'] as Map<String, dynamic>?)?['start'] ?? '').toString(),
    );
    final automationEndCtl = TextEditingController(
      text: ((automationRule?['schedule'] as Map<String, dynamic>?)?['end'] ?? '').toString(),
    );
    final timerStartCtl = TextEditingController(
      text: ((timerRule?['schedule'] as Map<String, dynamic>?)?['start'] ?? '').toString(),
    );
    final timerEndCtl = TextEditingController(
      text: ((timerRule?['schedule'] as Map<String, dynamic>?)?['end'] ?? '').toString(),
    );
    Map<String, dynamic> iconCatalog = <String, dynamic>{};
    try {
      iconCatalog = await widget.api.fetchIconCatalog();
    } catch (_) {}
    final customIcons = (iconCatalog['custom'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    var panel = 'general';

    final action = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: Text(deviceLabel),
            content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(label: const Text('General'), selected: panel == 'general', onSelected: (_) => setLocal(() => panel = 'general')),
                        if (_isLightTile(tile))
                          ChoiceChip(label: const Text('Light'), selected: panel == 'light', onSelected: (_) => setLocal(() => panel = 'light')),
                        ChoiceChip(
                          label: Text(automationEnabled ? 'Automated' : 'Automation'),
                          selected: panel == 'automation',
                          onSelected: (_) => setLocal(() => panel = 'automation'),
                        ),
                        ChoiceChip(label: const Text('Timers'), selected: panel == 'timers', onSelected: (_) => setLocal(() => panel = 'timers')),
                        ChoiceChip(label: const Text('Remove'), selected: panel == 'remove', onSelected: (_) => setLocal(() => panel = 'remove')),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (panel == 'general') ...[
                      const Text('Control Buttons'),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        value: actionMode,
                        items: const [
                          DropdownMenuItem(value: 'toggle', child: Text('Toggle button')),
                          DropdownMenuItem(value: 'on_off', child: Text('Separate ON + OFF')),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setLocal(() => actionMode = v);
                          }
                        },
                      ),
                      const SizedBox(height: 10),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: showStatus,
                        onChanged: (v) => setLocal(() => showStatus = v ?? true),
                        title: const Text('Show Status'),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: showIp,
                        onChanged: (v) => setLocal(() => showIp = v ?? false),
                        title: const Text('Show IP'),
                      ),
                      const SizedBox(height: 10),
                      const Text('Icon'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _iconOptions.entries
                            .map(
                              (entry) => InkWell(
                                onTap: () => setLocal(() => iconKey = entry.key),
                                child: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: iconKey == entry.key ? const Color(0xFF0B7285) : const Color(0xFFDCEBED),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(entry.value, color: iconKey == entry.key ? Colors.white : const Color(0xFF0F3A40)),
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                      if (customIcons.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Text('Custom Icons'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: customIcons
                              .map(
                                (item) => ChoiceChip(
                                  label: Text((item['label'] ?? item['key'] ?? '').toString()),
                                  selected: iconKey == (item['key'] ?? '').toString(),
                                  onSelected: (_) => setLocal(() => iconKey = (item['key'] ?? '').toString()),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ],
                      const SizedBox(height: 8),
                      const Text('Touch hold or right-click on the card to open this menu again.'),
                    ],
                    if (panel == 'light') ...[
                      ...() {
                        final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
                        final tileChannel = (payload['channel'] ?? '').toString().toLowerCase();
                        final isRgbw = type.contains('rgbw') || tileChannel == 'rgbw';
                        return <Widget>[
                      const Text('Light Quick Controls'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'light', state: 'on'),
                            child: const Text('Light On'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'light', state: 'off'),
                            child: const Text('Light Off'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'dimmer', value: 25),
                            child: const Text('25%'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'dimmer', value: 60),
                            child: const Text('60%'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'dimmer', value: 100),
                            child: const Text('100%'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text('Scenes'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: isRgbw ? 'rgbw' : 'rgb', payload: {'r': 100, 'g': 76, 'b': 20, 'w': 0}),
                            child: const Text('Warm'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: isRgbw ? 'rgbw' : 'rgb', payload: {'r': 40, 'g': 65, 'b': 100, 'w': 0}),
                            child: const Text('Cool'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: isRgbw ? 'rgbw' : 'rgb', payload: {'r': 100, 'g': 0, 'b': 0, 'w': 0}),
                            child: const Text('Red'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: isRgbw ? 'rgbw' : 'rgb', payload: {'r': 0, 'g': 0, 'b': 100, 'w': 0}),
                            child: const Text('Blue'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: isRgbw ? 'rgbw' : 'rgb', payload: {'r': 100, 'g': 100, 'b': 100, 'w': 0}),
                            child: const Text('Bright'),
                          ),
                          ..._lightScenes.map(
                            (scene) => FilledButton.tonal(
                              onPressed: refId.isEmpty
                                  ? null
                                  : () => _sendLightPreset(
                                        refId,
                                        cloudMode: cloudMode,
                                        label: deviceLabel,
                                        channel: 'scene',
                                        state: 'scene',
                                        payload: {'scene': scene['id']},
                                      ),
                              child: Text(scene['label']!),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _showLightDesigner(
                                      refId: refId,
                                      cloudMode: cloudMode,
                                      label: deviceLabel,
                                      isRgbw: isRgbw,
                                    ),
                            icon: const Icon(Icons.palette_outlined),
                            label: const Text('Colour / Scenes'),
                          ),
                        ],
                      ),
                        ];
                      }(),
                    ],
                    if (panel == 'automation') ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: automationEnabled,
                        onChanged: (v) => setLocal(() => automationEnabled = v),
                        title: const Text('Automated'),
                        subtitle: const Text('Show this tile as automated on Main'),
                      ),
                      TextField(
                        controller: automationCtl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Automation note',
                          hintText: 'Example: Sunset scene, occupancy, pool mode',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: automationStartCtl, decoration: const InputDecoration(labelText: 'Start HH:MM'))),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: automationEndCtl, decoration: const InputDecoration(labelText: 'End HH:MM'))),
                        ],
                      ),
                    ],
                    if (panel == 'timers') ...[
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: timersEnabled,
                        onChanged: (v) => setLocal(() => timersEnabled = v),
                        title: const Text('Timers'),
                        subtitle: const Text('Show timer state on this tile'),
                      ),
                      TextField(
                        controller: timerCtl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Timer note',
                          hintText: 'Example: ON 6:00pm, OFF 11:00pm',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: timerStartCtl, decoration: const InputDecoration(labelText: 'Start HH:MM'))),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: timerEndCtl, decoration: const InputDecoration(labelText: 'End HH:MM'))),
                        ],
                      ),
                    ],
                    if (panel == 'remove') ...[
                      const Text('Remove this tile from Main.'),
                      const SizedBox(height: 10),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red.shade50, foregroundColor: Colors.red.shade800),
                        onPressed: () => Navigator.pop(context, 'remove'),
                        child: const Text('Remove Tile'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, 'cancel'), child: const Text('Close')),
              if (panel != 'remove') FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
            ],
          ),
        );
      },
    );
    if (action == null || action == 'cancel') return;
    if (action == 'remove') {
      await widget.api.removeTile(tileId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tile removed')));
      await _load();
      return;
    }

    final newPayload = <String, dynamic>{
      ...payload,
      'action_mode': actionMode,
      'show_ip': showIp,
      'show_status': showStatus,
      'icon_key': iconKey,
      'automation_enabled': automationEnabled,
      'automation_note': automationCtl.text.trim(),
      'timers_enabled': timersEnabled,
      'timer_note': timerCtl.text.trim(),
    };
    await widget.api.updateTile(tileId: tileId, payload: newPayload);
    await widget.api.saveTileAutomation(
      tileId: tileId,
      defaultChannelKey: (payload['channel'] ?? 'relay1').toString(),
      rules: [
        {
          'id': automationRule?['id'],
          'rule_kind': 'automation',
          'label': automationCtl.text.trim(),
          'enabled': automationEnabled,
          'schedule': {
            'start': automationStartCtl.text.trim(),
            'end': automationEndCtl.text.trim(),
          },
          'payload': {'note': automationCtl.text.trim()},
        },
        {
          'id': timerRule?['id'],
          'rule_kind': 'timer',
          'label': timerCtl.text.trim(),
          'enabled': timersEnabled,
          'schedule': {
            'start': timerStartCtl.text.trim(),
            'end': timerEndCtl.text.trim(),
          },
          'payload': {'note': timerCtl.text.trim()},
        },
      ],
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tile options saved')));
    await _load();
  }

  Future<void> _configureGroupTile(Map<String, dynamic> tile) async {
    final tileId = (tile['id'] ?? '').toString().trim();
    if (tileId.isEmpty) return;
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final members = (data['members'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final action = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text((tile['label'] ?? 'Group').toString()),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Type: ${(data['group_kind'] ?? 'switch').toString()}'),
              Text('Members: ${(data['member_count'] ?? members.length).toString()}'),
              const SizedBox(height: 10),
              const Text('Included devices'),
              const SizedBox(height: 6),
              SizedBox(
                height: 280,
                child: ListView(
                  shrinkWrap: true,
                  children: members
                      .map(
                        (member) => ListTile(
                          dense: true,
                          title: Text((member['name'] ?? member['device_name'] ?? '').toString()),
                          subtitle: Text('Channel: ${(member['channel'] ?? '').toString()}'),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'close'), child: const Text('Close')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, 'remove'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade50, foregroundColor: Colors.red.shade800),
            child: const Text('Remove Group'),
          ),
        ],
      ),
    );
    if (action != 'remove') return;
    await widget.api.removeTile(tileId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Group removed')));
    await _load();
  }

  Map<String, dynamic> _tileCapabilities(Map<String, dynamic> tile) {
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return (data['capabilities'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
  }

  bool _tileSupportsLight(Map<String, dynamic> tile) {
    if (!_isLightTile(tile)) return false;
    final capabilities = _tileCapabilities(tile);
    return (capabilities['supports_light'] as bool?) == true || (capabilities['supports_rgb'] as bool?) == true;
  }

  bool _tileSupportsFan(Map<String, dynamic> tile) {
    final capabilities = _tileCapabilities(tile);
    if ((capabilities['supports_fan'] as bool?) == true) return true;
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final channel = (payload['channel'] ?? '').toString().toLowerCase();
    return type.contains('fan') || channel.contains('fan');
  }

  Widget _tileConnectionBadge(bool cloudMode) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: cloudMode ? const Color(0xFFFFF3E0) : const Color(0xFFE7F6EC),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        cloudMode ? Icons.cloud : Icons.lan,
        size: 14,
        color: cloudMode ? const Color(0xFFE67E22) : const Color(0xFF2E7D32),
      ),
    );
  }

  Widget _tileStateVisual(Map<String, dynamic> tile, bool? stateBool, Color statusColor) {
    if (_tileSupportsLight(tile)) {
      final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final outputs = (data['outputs'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final r = outputs['rgb_r'];
      final g = outputs['rgb_g'];
      final b = outputs['rgb_b'];
      Color fill;
      if (r is num && g is num && b is num) {
        fill = Color.fromARGB(255, r.clamp(0, 255).toInt(), g.clamp(0, 255).toInt(), b.clamp(0, 255).toInt());
      } else {
        fill = Colors.white;
      }
      return Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          gradient: (r is num && g is num && b is num)
              ? null
              : const LinearGradient(
                  colors: [Color(0xFFFF5F6D), Color(0xFFFFC371), Color(0xFF4FACFE), Color(0xFF43E97B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          color: (r is num && g is num && b is num) ? fill : null,
          border: Border.all(color: Colors.black12),
          boxShadow: stateBool == true ? [BoxShadow(color: statusColor.withOpacity(0.28), blurRadius: 12, spreadRadius: 1)] : null,
        ),
      );
    }
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Icon(
        stateBool == true ? Icons.power_settings_new : stateBool == false ? Icons.power_off : Icons.help_outline,
        size: 18,
        color: statusColor,
      ),
    );
  }

  Future<void> _showFanDesigner({
    required String refId,
    required bool cloudMode,
    required String label,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Fan Control: $label'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: () async {
                await _sendLightPreset(refId, cloudMode: cloudMode, label: label, channel: 'fan_power', state: 'on');
                if (mounted && context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Fan On'),
            ),
            FilledButton.tonal(
              onPressed: () async {
                await _sendLightPreset(refId, cloudMode: cloudMode, label: label, channel: 'fan_power', state: 'off');
                if (mounted && context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Fan Off'),
            ),
            OutlinedButton(
              onPressed: () async {
                await _sendLightPreset(refId, cloudMode: cloudMode, label: label, channel: 'fan_speed', value: 1);
                if (mounted && context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Low'),
            ),
            OutlinedButton(
              onPressed: () async {
                await _sendLightPreset(refId, cloudMode: cloudMode, label: label, channel: 'fan_speed', value: 2);
                if (mounted && context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Med'),
            ),
            OutlinedButton(
              onPressed: () async {
                await _sendLightPreset(refId, cloudMode: cloudMode, label: label, channel: 'fan_speed', value: 3);
                if (mounted && context.mounted) Navigator.of(context).pop();
              },
              child: const Text('High'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _buildTileCard(Map<String, dynamic> tile) {
    final tileType = (tile['tile_type'] ?? '').toString();
    final label = (tile['label'] ?? '').toString();
    final refId = (tile['ref_id'] ?? '').toString();
    final data = (tile['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final error = tile['error']?.toString();
    final titleText = tileType == 'device' ? _deviceDisplayName(tile) : label;
    final tileIcon = _iconForTile(tile);

    Widget content;
    if (error != null && error.isNotEmpty) {
      content = Text('Error: $error', style: const TextStyle(color: Colors.red));
    } else if (tileType == 'weather') {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${data['location'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('${data['temp'] ?? '--'}°  ${data['description'] ?? ''}'),
          Text('Feels ${data['feels_like'] ?? '--'}°  Humidity ${data['humidity'] ?? '--'}%'),
        ],
      );
    } else if (tileType == 'spotify') {
      final track = (data['track'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${track['name'] ?? 'No track'}', maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${track['artists'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: [
              IconButton(onPressed: () => _runSpotifyAction('previous'), icon: const Icon(Icons.skip_previous)),
              IconButton(
                onPressed: () => _runSpotifyAction((data['is_playing'] ?? false) ? 'pause' : 'play'),
                icon: Icon((data['is_playing'] ?? false) ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(onPressed: () => _runSpotifyAction('next'), icon: const Icon(Icons.skip_next)),
            ],
          )
        ],
      );
    } else if (tileType == 'device') {
      final outputs = (data['outputs'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      final provider = (data['provider'] ?? '').toString();
      final mode = (data['mode'] ?? 'local_lan').toString();
      final channelKey = (payload['channel'] ?? 'relay1').toString();
      final channelValue = outputs[channelKey] ?? outputs['relay1'] ?? outputs['light'] ?? outputs['power'] ?? '--';
      final cloudMode = mode.toLowerCase().contains('cloud') || provider == 'tuya_cloud';
      final actionMode = (payload['action_mode'] ?? 'toggle').toString() == 'on_off' ? 'on_off' : 'toggle';
      final showIp = (payload['show_ip'] as bool?) ?? false;
      final stateBool = _asBoolState(channelValue);
      final statusColor = stateBool == null ? Colors.blueGrey : (stateBool ? Colors.green : Colors.red);
      final automated = _isAutomated(tile);
      final tileId = (tile['id'] ?? '').toString().trim();
      final statusText = stateBool == true ? 'On' : stateBool == false ? 'Off' : channelValue.toString();
      final busy = _tileActionBusy.contains('$tileId::$channelKey');
      final supportsLight = _tileSupportsLight(tile);
      final supportsFan = _tileSupportsFan(tile);
      final showExtra = supportsLight || supportsFan;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _tileStateVisual(tile, stateBool, statusColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (automated)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDCEBED),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text('Auto', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
                          ),
                        if (automated) const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            statusText,
                            style: TextStyle(color: statusColor, fontWeight: FontWeight.w800, fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      showIp ? 'IP ${(data['ip'] ?? data['host'] ?? '--').toString()}' : mode,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF607D8B)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _tileConnectionBadge(cloudMode),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 34,
                  child: actionMode == 'toggle'
                      ? FilledButton(
                          onPressed: busy
                              ? null
                              : () => _sendDeviceState(
                                    refId,
                                    tileId: tileId,
                                    currentState: stateBool,
                                    cloudMode: cloudMode,
                                    label: titleText,
                                    channel: channelKey,
                                    state: stateBool == true ? 'off' : stateBool == false ? 'on' : 'toggle',
                                  ),
                          style: FilledButton.styleFrom(
                            backgroundColor: stateBool == null ? Colors.blueGrey : (stateBool ? Colors.green : Colors.red),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                          child: Icon(
                            busy ? Icons.more_horiz : stateBool == true ? Icons.toggle_on : stateBool == false ? Icons.toggle_off : Icons.power_settings_new,
                            size: 20,
                          ),
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => _sendDeviceState(
                                          refId,
                                          tileId: tileId,
                                          currentState: stateBool,
                                          cloudMode: cloudMode,
                                          label: titleText,
                                          channel: channelKey,
                                          state: 'on',
                                        ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                ),
                                child: const Text('On'),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => _sendDeviceState(
                                          refId,
                                          tileId: tileId,
                                          currentState: stateBool,
                                          cloudMode: cloudMode,
                                          label: titleText,
                                          channel: channelKey,
                                          state: 'off',
                                        ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                ),
                                child: const Text('Off'),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              if (showExtra) ...[
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 34,
                    child: OutlinedButton(
                      onPressed: refId.isEmpty
                          ? null
                          : () => supportsLight
                              ? _showLightDesigner(
                                    refId: refId,
                                    cloudMode: cloudMode,
                                    label: titleText,
                                    isRgbw: ((data['type'] ?? data['device_type'] ?? '').toString().toLowerCase().contains('rgbw') ||
                                        channelKey.toLowerCase() == 'rgbw'),
                                  )
                              : _showFanDesigner(
                                    refId: refId,
                                    cloudMode: cloudMode,
                                    label: titleText,
                                  ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      child: const Text('Extra'),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (cloudMode || ((payload['show_status'] as bool?) ?? true)) ...[
            const SizedBox(height: 6),
            Text(
              cloudMode
                  ? 'Cloud'
                  : ((payload['show_status'] as bool?) ?? true)
                      ? 'Status ${channelValue.toString()}'
                      : mode,
              style: TextStyle(
                color: cloudMode ? Colors.orange.shade700 : const Color(0xFF607D8B),
                fontWeight: cloudMode ? FontWeight.w600 : FontWeight.w500,
                fontSize: 10.5,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      );
    } else if (tileType == 'group') {
      final mode = (data['mode'] ?? 'local_lan').toString();
      final memberCount = (data['member_count'] as num?)?.toInt() ?? 0;
      final groupState = (data['group_state'] ?? 'unknown').toString().toLowerCase();
      final busy = _groupActionBusy.contains((tile['id'] ?? '').toString());
      final stateBool = groupState == 'on'
          ? true
          : groupState == 'off'
              ? false
              : null;
      final statusColor = groupState == 'mixed'
          ? Colors.orange
          : stateBool == null
              ? Colors.blueGrey
              : (stateBool ? Colors.green : Colors.red);
      final actionState = stateBool == true ? 'off' : 'on';
      final actionLabel = busy
          ? '...'
          : stateBool == true
              ? 'ALL OFF'
              : stateBool == false
                  ? 'ALL ON'
                  : 'SET ON';
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            mode,
            style: const TextStyle(fontSize: 11, color: Color(0xFF546E7A)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  groupState == 'mixed'
                      ? 'Mixed'
                      : stateBool == true
                          ? 'On'
                          : stateBool == false
                              ? 'Off'
                              : 'Unknown',
                  style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 20),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$memberCount item${memberCount == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF607D8B)),
          ),
          const Spacer(),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: busy ? null : () => _sendGroupState(tile, actionState),
              style: FilledButton.styleFrom(
                backgroundColor: statusColor,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(38),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              child: Text(actionLabel),
            ),
          ),
        ],
      );
    } else if (tileType == 'automation') {
      final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final mode = (data['mode'] ?? 'manual').toString();
      final targetName = (data['group_name'] ?? payload['group_name'] ?? '').toString();
      final requestedState = (data['requested_state'] ?? payload['state'] ?? 'toggle').toString().toUpperCase();
      final memberCount = (data['member_count'] as num?)?.toInt() ?? 0;
      final busy = _tileActionBusy.contains((tile['id'] ?? '').toString());
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            mode,
            style: const TextStyle(fontSize: 11, color: Color(0xFF546E7A)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            targetName.isEmpty ? 'Automation' : targetName,
            style: const TextStyle(fontWeight: FontWeight.w700),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            '$requestedState  |  $memberCount item${memberCount == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF607D8B)),
          ),
          const Spacer(),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: busy ? null : () => _runAutomationTile(tile),
              child: Text(busy ? 'Running...' : 'Run'),
            ),
          ),
        ],
      );
    } else {
      content = Text('Tile type: $tileType');
    }

    final baseCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCEBED),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(tileIcon, color: const Color(0xFF0B7285), size: 16),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    titleText,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 14, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(child: content),
          ],
        ),
      ),
    );

    if (tileType == 'device' || tileType == 'group') {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () => tileType == 'group' ? _configureGroupTile(tile) : _configureDeviceTile(tile),
          onSecondaryTap: () => tileType == 'group' ? _configureGroupTile(tile) : _configureDeviceTile(tile),
          child: baseCard,
        ),
      );
    }
    return baseCard;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _tiles.isEmpty) {
      return Center(child: Text('Error: $_error'));
    }
    if (_tiles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.dashboard_customize_outlined, size: 60),
            SizedBox(height: 8),
            Text('No tiles yet. Add device, Spotify, or Weather tiles from Devices/Config.'),
          ],
        ),
      );
    }

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              const spacing = 6.0;
              final targetTileWidth = width >= 1500 ? 210.0 : width >= 1100 ? 185.0 : width >= 800 ? 205.0 : 270.0;
              final crossAxisCount = math.min(5, math.max(1, ((width + spacing) / (targetTileWidth + spacing)).floor()));
              final mainAxisExtent = width >= 1500 ? 138.0 : width >= 1100 ? 130.0 : width >= 800 ? 136.0 : 168.0;
              return GridView.builder(
                padding: const EdgeInsets.all(6),
                itemCount: _tiles.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  mainAxisExtent: mainAxisExtent,
                ),
                itemBuilder: (context, index) => _buildTileCard(_tiles[index]),
              );
            },
          ),
        ),
        if (_refreshing)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_error != null && _tiles.isNotEmpty)
          Positioned(
            top: 10,
            left: 12,
            right: 12,
            child: IgnorePointer(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFCC80)),
                  ),
                  child: Text(
                    'Live refresh warning: $_error',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF8A4B00), fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
