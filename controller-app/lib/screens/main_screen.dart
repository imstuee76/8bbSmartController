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
        _error = e.toString();
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

  Future<void> _toggleDevice(String refId, {required bool cloudMode, required String label}) async {
    if (cloudMode) {
      final ok = await _confirmCloudWarning(label);
      if (!ok) return;
    }
    await widget.api.sendDeviceCommand(
      deviceId: refId,
      channel: 'relay1',
      state: 'toggle',
    );
    await _load();
  }

  Widget _buildTileCard(Map<String, dynamic> tile) {
    final tileType = (tile['tile_type'] ?? '').toString();
    final label = (tile['label'] ?? '').toString();
    final refId = (tile['ref_id'] ?? '').toString();
    final data = (tile['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
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
      final cloudMode = mode.toLowerCase().contains('cloud') || provider == 'tuya_cloud';
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Type: ${(data['type'] ?? data['device_type'] ?? '').toString()}'),
          Text('Source: $source'),
          Text('Mode: $mode'),
          if (cloudMode)
            const Text(
              'Warning: cloud dependent',
              style: TextStyle(color: Colors.orange),
            ),
          Text('State: ${(outputs['relay1'] ?? outputs['light'] ?? outputs['power'] ?? '--').toString()}'),
          const SizedBox(height: 8),
          if (refId.isNotEmpty)
            FilledButton.tonal(
              onPressed: () => _toggleDevice(refId, cloudMode: cloudMode, label: label),
              child: const Text('Toggle'),
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

    return Card(
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
