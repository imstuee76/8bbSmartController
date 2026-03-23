class GroupMemberConfig {
  String deviceId;
  String channel;
  String label;
  String deviceName;
  String channelName;
  String kind;
  Map<String, dynamic> commandPayload;

  GroupMemberConfig({
    required this.deviceId,
    required this.channel,
    required this.label,
    required this.deviceName,
    required this.channelName,
    required this.kind,
    required this.commandPayload,
  });

  factory GroupMemberConfig.fromJson(Map<String, dynamic> json) {
    return GroupMemberConfig(
      deviceId: (json['device_id'] ?? '').toString(),
      channel: (json['channel'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      deviceName: (json['device_name'] ?? '').toString(),
      channelName: (json['channel_name'] ?? '').toString(),
      kind: (json['kind'] ?? '').toString(),
      commandPayload: (json['command_payload'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'channel': channel,
        'label': label,
        'device_name': deviceName,
        'channel_name': channelName,
        'kind': kind,
        'command_payload': commandPayload,
      };
}

class GroupConfig {
  String id;
  String name;
  String color;
  String kind;
  List<GroupMemberConfig> members;

  GroupConfig({
    required this.id,
    required this.name,
    required this.color,
    this.kind = 'mixed',
    this.members = const <GroupMemberConfig>[],
  });

  factory GroupConfig.fromJson(Map<String, dynamic> json) {
    return GroupConfig(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      color: (json['color'] ?? '#4CAF50').toString(),
      kind: (json['kind'] ?? 'mixed').toString(),
      members: (json['members'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(GroupMemberConfig.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'color': color,
        'kind': kind,
        'members': members.map((member) => member.toJson()).toList(growable: false),
      };
}

class DisplayConfig {
  String resolution;
  String orientation;
  double scale;
  List<GroupConfig> groups;

  DisplayConfig({
    required this.resolution,
    required this.orientation,
    required this.scale,
    required this.groups,
  });

  factory DisplayConfig.fromJson(Map<String, dynamic> json) {
    return DisplayConfig(
      resolution: (json['resolution'] ?? '1920x1080').toString(),
      orientation: (json['orientation'] ?? 'landscape').toString(),
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
      groups: (json['groups'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(GroupConfig.fromJson)
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'resolution': resolution,
        'orientation': orientation,
        'scale': scale,
        'groups': groups.map((group) => group.toJson()).toList(growable: false),
      };
}

class IntegrationsConfig {
  Map<String, dynamic> spotify;
  Map<String, dynamic> weather;
  Map<String, dynamic> tuya;
  Map<String, dynamic> scan;
  Map<String, dynamic> moes;
  Map<String, dynamic> ota;
  Map<String, dynamic> icons;

  IntegrationsConfig({
    required this.spotify,
    required this.weather,
    required this.tuya,
    required this.scan,
    required this.moes,
    required this.ota,
    required this.icons,
  });

  factory IntegrationsConfig.fromJson(Map<String, dynamic> json) {
    return IntegrationsConfig(
      spotify: Map<String, dynamic>.from(json['spotify'] as Map? ?? {}),
      weather: Map<String, dynamic>.from(json['weather'] as Map? ?? {}),
      tuya: Map<String, dynamic>.from(json['tuya'] as Map? ?? {}),
      scan: Map<String, dynamic>.from(json['scan'] as Map? ?? {}),
      moes: Map<String, dynamic>.from(json['moes'] as Map? ?? {}),
      ota: Map<String, dynamic>.from(json['ota'] as Map? ?? {}),
      icons: Map<String, dynamic>.from(json['icons'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'spotify': spotify,
        'weather': weather,
        'tuya': tuya,
        'scan': scan,
        'moes': moes,
        'ota': ota,
        'icons': icons,
      };
}
