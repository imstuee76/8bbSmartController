class DeviceChannel {
  final String channelKey;
  final String channelName;
  final String channelKind;
  final Map<String, dynamic> payload;

  DeviceChannel({
    required this.channelKey,
    required this.channelName,
    required this.channelKind,
    required this.payload,
  });

  factory DeviceChannel.fromJson(Map<String, dynamic> json) {
    return DeviceChannel(
      channelKey: (json['channel_key'] ?? '').toString(),
      channelName: (json['channel_name'] ?? '').toString(),
      channelKind: (json['channel_kind'] ?? '').toString(),
      payload: (json['payload'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
        'channel_key': channelKey,
        'channel_name': channelName,
        'channel_kind': channelKind,
        'payload': payload,
      };
}

class SmartDevice {
  final String id;
  final String name;
  final String type;
  final String? host;
  final String? mac;
  final String ipMode;
  final String? staticIp;
  final String? gateway;
  final String? subnetMask;
  final Map<String, dynamic> metadata;
  final List<DeviceChannel> channels;

  SmartDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.mac,
    required this.ipMode,
    required this.staticIp,
    required this.gateway,
    required this.subnetMask,
    required this.metadata,
    required this.channels,
  });

  factory SmartDevice.fromJson(Map<String, dynamic> json) {
    final channelList = (json['channels'] as List<dynamic>? ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(DeviceChannel.fromJson)
        .toList();

    return SmartDevice(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      host: json['host']?.toString(),
      mac: json['mac']?.toString(),
      ipMode: (json['ip_mode'] ?? 'dhcp').toString(),
      staticIp: json['static_ip']?.toString(),
      gateway: json['gateway']?.toString(),
      subnetMask: json['subnet_mask']?.toString(),
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      channels: channelList,
    );
  }
}

class MainTile {
  final String id;
  final String tileType;
  final String? refId;
  final String label;
  final Map<String, dynamic> payload;

  MainTile({
    required this.id,
    required this.tileType,
    required this.refId,
    required this.label,
    required this.payload,
  });

  factory MainTile.fromJson(Map<String, dynamic> json) {
    return MainTile(
      id: (json['id'] ?? '').toString(),
      tileType: (json['tile_type'] ?? '').toString(),
      refId: json['ref_id']?.toString(),
      label: (json['label'] ?? '').toString(),
      payload: (json['payload'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
  }
}
