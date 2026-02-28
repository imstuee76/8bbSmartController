import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/device_models.dart';
import '../services/api_service.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  String? _error;
  List<SmartDevice> _devices = [];
  List<Map<String, dynamic>> _scanResults = [];
  final TextEditingController _subnetCtl = TextEditingController();
  String _statusOutput = '';

  String _friendlyError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('connection refused') || lower.contains('socketexception')) {
      return 'Backend unreachable at ${widget.api.baseUrl}.\n'
          'Set the Windows flasher URL in Config > Controller / API.';
    }
    return text;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
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
    try {
      final results = await widget.api.scanNetwork(subnetHint: _subnetCtl.text.trim());
      setState(() {
        _scanResults = results;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = _friendlyError(e);
        _statusOutput = _error!;
      });
    }
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
    try {
      final status = await widget.api.getDeviceStatus(device.id);
      setState(() {
        _statusOutput = const JsonEncoder.withIndent('  ').convert(status);
      });
    } catch (e) {
      setState(() {
        _statusOutput = e.toString();
      });
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
                    child: Row(
                      children: [
                        FilledButton(onPressed: () => _openCreateDialog(), child: const Text('Add Device')),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _refresh, child: const Text('Refresh')),
                        const Spacer(),
                        SizedBox(
                          width: 220,
                          child: TextField(
                            controller: _subnetCtl,
                            decoration: const InputDecoration(labelText: 'Subnet hint'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(onPressed: _scan, child: const Text('Scan LAN')),
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
                            : ListView.builder(
                            itemCount: _devices.length,
                            itemBuilder: (context, index) {
                              final d = _devices[index];
                              final provider = _providerOf(d);
                              final source = _sourceOf(d);
                              final mode = _modeOf(d);
                              final isEspFirmware = provider == 'esp_firmware';
                              return ExpansionTile(
                                title: Text('${d.name} (${d.type})'),
                                subtitle: Text(
                                  '${d.host ?? d.mac ?? 'No host yet'}\nSource: $source  Mode: $mode',
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                                    child: Wrap(
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
                                                .showSnackBar(const SnackBar(content: Text('Added to Main tiles')));
                                          },
                                          child: const Text('Add to Main'),
                                        ),
                                        OutlinedButton(onPressed: () => _runStatus(d), child: const Text('Status')),
                                        OutlinedButton(
                                          onPressed: () async {
                                            if (_isCloudMode(d)) {
                                              final ok = await _confirmCloudUse('Controlling this device', d);
                                              if (!ok) return;
                                            }
                                            await _runControlDialog(d);
                                          },
                                          child: const Text('Control'),
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
                                  )
                                ],
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
                        ..._scanResults.map(
                          (item) => ListTile(
                            dense: true,
                            title: Text(item['ip']?.toString() ?? ''),
                            subtitle: Text('${item['hostname'] ?? ''} ${item['mac'] ?? ''}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: () => _openCreateDialog(presetHost: item['ip']?.toString() ?? ''),
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
