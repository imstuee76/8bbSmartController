import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  List<Map<String, dynamic>> _tiles = [];
  DateTime? _lastLoadedAt;
  static const Map<String, IconData> _iconOptions = <String, IconData>{
    'auto': Icons.auto_awesome,
    'power': Icons.power_settings_new,
    'light': Icons.lightbulb_outline,
    'switch': Icons.toggle_on,
    'fan': Icons.mode_fan_off_outlined,
    'lamp': Icons.table_lamp_outlined,
    'strip': Icons.linear_scale,
    'scene': Icons.auto_fix_high,
    'timer': Icons.timer_outlined,
    'home': Icons.home_outlined,
    'garage': Icons.garage_outlined,
    'gate': Icons.sensor_door_outlined,
    'water': Icons.water_drop_outlined,
    'pool': Icons.pool_outlined,
    'speaker': Icons.speaker_outlined,
    'tv': Icons.tv_outlined,
    'music': Icons.music_note_outlined,
    'heater': Icons.local_fire_department_outlined,
    'camera': Icons.videocam_outlined,
    'security': Icons.shield_outlined,
  };

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
    setState(() {
      if (initial || _tiles.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
      _error = null;
    });
    try {
      final tiles = await widget.api.fetchTileData();
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
    if (tileType == 'weather') return Icons.cloud_outlined;
    if (tileType == 'spotify') return Icons.graphic_eq;
    final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
    if (type.contains('fan')) return Icons.mode_fan_off_outlined;
    if (type.contains('light')) return Icons.lightbulb_outline;
    if (type.contains('relay') || type.contains('switch')) return Icons.toggle_on;
    return Icons.sensors_outlined;
  }

  bool _isLightTile(Map<String, dynamic> tile) {
    final payload = (tile['payload'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final data = (tile['data'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    final type = (data['type'] ?? data['device_type'] ?? '').toString().toLowerCase();
    final channel = (payload['channel'] ?? '').toString().toLowerCase();
    return type.contains('light') || channel == 'light' || channel == 'rgb' || channel == 'rgbw' || channel == 'dimmer';
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

  Future<void> _sendDeviceState(
    String refId, {
    required bool cloudMode,
    required String label,
    required String channel,
    required String state,
  }) async {
    if (cloudMode) {
      final ok = await _confirmCloudWarning(label);
      if (!ok) return;
    }
    final lastLoadedAt = _lastLoadedAt;
    if (!_loading &&
        !_refreshing &&
        lastLoadedAt != null &&
        DateTime.now().difference(lastLoadedAt) > const Duration(minutes: 2)) {
      await _load();
    }
    await widget.api.sendDeviceCommand(
      deviceId: refId,
      channel: channel,
      state: state,
    );
    await _load();
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
    final automationCtl = TextEditingController(text: (payload['automation_note'] ?? '').toString());
    final timerCtl = TextEditingController(text: (payload['timer_note'] ?? '').toString());
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
                      const SizedBox(height: 8),
                      const Text('Touch hold or right-click on the card to open this menu again.'),
                    ],
                    if (panel == 'light') ...[
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
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'rgb', payload: {'r': 100, 'g': 76, 'b': 20, 'w': 0}),
                            child: const Text('Warm'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'rgb', payload: {'r': 40, 'g': 65, 'b': 100, 'w': 0}),
                            child: const Text('Cool'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'rgb', payload: {'r': 100, 'g': 0, 'b': 0, 'w': 0}),
                            child: const Text('Red'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'rgb', payload: {'r': 0, 'g': 0, 'b': 100, 'w': 0}),
                            child: const Text('Blue'),
                          ),
                          FilledButton.tonal(
                            onPressed: refId.isEmpty
                                ? null
                                : () => _sendLightPreset(refId, cloudMode: cloudMode, label: deviceLabel, channel: 'rgb', payload: {'r': 100, 'g': 100, 'b': 100, 'w': 0}),
                            child: const Text('Bright'),
                          ),
                        ],
                      ),
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tile options saved')));
    await _load();
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
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (automated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCEBED),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('Automated', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              if (automated) const SizedBox(width: 6),
              Text(
                mode,
                style: const TextStyle(fontSize: 12, color: Color(0xFF546E7A)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (showIp)
            Text(
              'IP ${(data['ip'] ?? data['host'] ?? '--').toString()}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF607D8B)),
            ),
          if (cloudMode)
            const Text(
              'Warning: cloud dependent',
              style: TextStyle(color: Colors.orange, fontSize: 12),
            ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                stateBool == true ? 'On' : stateBool == false ? 'Off' : channelValue.toString(),
                style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 22),
              ),
            ),
          ),
          if ((payload['show_status'] as bool?) ?? true)
            Text(
              'Status ${channelValue.toString()}',
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          const SizedBox(height: 8),
          if (refId.isNotEmpty && actionMode == 'toggle')
            SizedBox(
              width: double.infinity,
              child: FilledButton(
              onPressed: () => _sendDeviceState(
                refId,
                cloudMode: cloudMode,
                label: titleText,
                channel: channelKey,
                state: 'toggle',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: stateBool == null ? Colors.blueGrey : (stateBool ? Colors.green : Colors.red),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(42),
              ),
              child: Text(stateBool == true ? 'ON' : stateBool == false ? 'OFF' : 'TOGGLE'),
            ),
            ),
          if (refId.isNotEmpty && actionMode == 'on_off')
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _sendDeviceState(
                      refId,
                      cloudMode: cloudMode,
                      label: titleText,
                      channel: channelKey,
                      state: 'on',
                    ),
                    style: FilledButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                    child: const Text('ON'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _sendDeviceState(
                      refId,
                      cloudMode: cloudMode,
                      label: titleText,
                      channel: channelKey,
                      state: 'off',
                    ),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    child: const Text('OFF'),
                  ),
                ),
              ],
            ),
        ],
      );
    } else if (tileType == 'automation') {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Scene / automation trigger'),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Automation "${tile['label']}" triggered')),
              );
            },
            child: const Text('Run'),
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
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCEBED),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(tileIcon, color: const Color(0xFF0B7285), size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    titleText,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(child: content),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );

    if (tileType == 'device') {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPress: () => _configureDeviceTile(tile),
          onSecondaryTap: () => _configureDeviceTile(tile),
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
    if (_error != null) {
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
              final crossAxisCount = width >= 1750
                  ? 5
                  : width >= 1400
                      ? 4
                      : width >= 1050
                          ? 3
                          : width >= 700
                              ? 2
                              : 1;
              final ratio = width >= 1750 ? 1.6 : width >= 1400 ? 1.5 : 1.35;
              return GridView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: _tiles.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: ratio,
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
      ],
    );
  }
}
