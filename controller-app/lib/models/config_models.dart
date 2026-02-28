class DisplayConfig {
  String resolution;
  String orientation;
  double scale;

  DisplayConfig({
    required this.resolution,
    required this.orientation,
    required this.scale,
  });

  factory DisplayConfig.fromJson(Map<String, dynamic> json) {
    return DisplayConfig(
      resolution: (json['resolution'] ?? '1920x1080').toString(),
      orientation: (json['orientation'] ?? 'landscape').toString(),
      scale: (json['scale'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'resolution': resolution,
        'orientation': orientation,
        'scale': scale,
      };
}

class IntegrationsConfig {
  Map<String, dynamic> spotify;
  Map<String, dynamic> weather;
  Map<String, dynamic> tuya;
  Map<String, dynamic> scan;
  Map<String, dynamic> moes;
  Map<String, dynamic> ota;

  IntegrationsConfig({
    required this.spotify,
    required this.weather,
    required this.tuya,
    required this.scan,
    required this.moes,
    required this.ota,
  });

  factory IntegrationsConfig.fromJson(Map<String, dynamic> json) {
    return IntegrationsConfig(
      spotify: Map<String, dynamic>.from(json['spotify'] as Map? ?? {}),
      weather: Map<String, dynamic>.from(json['weather'] as Map? ?? {}),
      tuya: Map<String, dynamic>.from(json['tuya'] as Map? ?? {}),
      scan: Map<String, dynamic>.from(json['scan'] as Map? ?? {}),
      moes: Map<String, dynamic>.from(json['moes'] as Map? ?? {}),
      ota: Map<String, dynamic>.from(json['ota'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'spotify': spotify,
        'weather': weather,
        'tuya': tuya,
        'scan': scan,
        'moes': moes,
        'ota': ota,
      };
}
