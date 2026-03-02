import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tiles = [];

  String _friendlyError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('socketexception')) {
      return 'Backend unreachable at ${widget.api.baseUrl}.\n'
          'Check: backend is running on Windows, URL/port are correct, and firewall allows TCP 8088.';
    }
    return text;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tiles = await widget.api.fetchTileData();
      setState(() {
        _tiles = tiles;
      });
    } catch (e) {
      setState(() {
        _error = _friendlyError(e);
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _runSpotifyAction(String action) async {
    await widget.api.spotifyAction(action);
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

    var actionMode = (payload['action_mode'] ?? 'toggle').toString() == 'on_off' ? 'on_off' : 'toggle';
    var showIp = (payload['show_ip'] as bool?) ?? false;
    var showStatus = (payload['show_status'] as bool?) ?? true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) => AlertDialog(
            title: const Text('Device Tile Options'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  const SizedBox(height: 8),
                  const Text('Tip: Hold this tile for 5 seconds to open this menu again.'),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
            ],
          ),
        );
      },
    );

    if (saved != true) return;

    final newPayload = <String, dynamic>{
      ...payload,
      'action_mode': actionMode,
      'show_ip': showIp,
      'show_status': showStatus,
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
      final source = (data['source_name'] ?? provider).toString();
      final channelKey = (payload['channel'] ?? 'relay1').toString();
      final channelName = (payload['channel_name'] ?? channelKey).toString();
      final channelValue = outputs[channelKey] ?? outputs['relay1'] ?? outputs['light'] ?? outputs['power'] ?? '--';
      final cloudMode = mode.toLowerCase().contains('cloud') || provider == 'tuya_cloud';
      final actionMode = (payload['action_mode'] ?? 'toggle').toString() == 'on_off' ? 'on_off' : 'toggle';
      final showIp = (payload['show_ip'] as bool?) ?? false;
      final showStatus = (payload['show_status'] as bool?) ?? true;
      final stateBool = _asBoolState(channelValue);
      final statusColor = stateBool == null ? Colors.grey : (stateBool ? Colors.green : Colors.red);
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Type: ${(data['type'] ?? data['device_type'] ?? '').toString()}'),
          Text('Source: $source'),
          Text('Mode: $mode'),
          Text('Channel: $channelName'),
          if (showIp) Text('IP: ${(data['ip'] ?? data['host'] ?? '--').toString()}'),
          if (cloudMode)
            const Text(
              'Warning: cloud dependent',
              style: TextStyle(color: Colors.orange),
            ),
          if (showStatus)
            Text(
              'State: ${channelValue.toString()}',
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
            ),
          const SizedBox(height: 8),
          if (refId.isNotEmpty && actionMode == 'toggle')
            FilledButton(
              onPressed: () => _sendDeviceState(
                refId,
                cloudMode: cloudMode,
                label: label,
                channel: channelKey,
                state: 'toggle',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: stateBool == null ? Colors.blueGrey : (stateBool ? Colors.green : Colors.red),
                foregroundColor: Colors.white,
              ),
              child: Text(stateBool == true ? 'ON' : stateBool == false ? 'OFF' : 'Toggle'),
            ),
          if (refId.isNotEmpty && actionMode == 'on_off')
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _sendDeviceState(
                      refId,
                      cloudMode: cloudMode,
                      label: label,
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
                      label: label,
                      channel: channelKey,
                      state: 'off',
                    ),
                    style: FilledButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    child: const Text('OFF'),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 6),
          const Text('Hold 5s to configure this tile', style: TextStyle(fontSize: 12)),
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tileType.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(child: content),
            Align(
              alignment: Alignment.bottomRight,
              child: IconButton(
                tooltip: 'Remove tile',
                onPressed: () async {
                  await widget.api.removeTile((tile['id'] ?? '').toString());
                  await _load();
                },
                icon: const Icon(Icons.delete_outline),
              ),
            )
          ],
        ),
      ),
    );

    if (tileType == 'device') {
      return _HoldToConfigure(
        holdDuration: const Duration(seconds: 5),
        onHoldComplete: () => _configureDeviceTile(tile),
        child: baseCard,
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

    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _tiles.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.45,
        ),
        itemBuilder: (context, index) => _buildTileCard(_tiles[index]),
      ),
    );
  }
}

class _HoldToConfigure extends StatefulWidget {
  const _HoldToConfigure({
    required this.child,
    required this.onHoldComplete,
    required this.holdDuration,
  });

  final Widget child;
  final VoidCallback onHoldComplete;
  final Duration holdDuration;

  @override
  State<_HoldToConfigure> createState() => _HoldToConfigureState();
}

class _HoldToConfigureState extends State<_HoldToConfigure> {
  Timer? _holdTimer;
  bool _fired = false;

  void _start() {
    _cancel();
    _fired = false;
    _holdTimer = Timer(widget.holdDuration, () {
      _fired = true;
      widget.onHoldComplete();
    });
  }

  void _cancel() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (_) => _start(),
      onPointerUp: (_) {
        if (!_fired) {
          _cancel();
        }
      },
      onPointerMove: (_) {
        if (!_fired) {
          _cancel();
        }
      },
      onPointerCancel: (_) => _cancel(),
      child: widget.child,
    );
  }
}
