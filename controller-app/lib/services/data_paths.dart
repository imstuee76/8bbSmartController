import 'dart:io';

class DataPaths {
  static Future<Directory> dataDir() async {
    final env = Platform.environment;
    final configured = (env['SMART_CONTROLLER_DATA_DIR'] ?? '').trim();
    final fallback = Platform.isLinux
        ? '/home/arcade/8bbController/data'
        : '${Directory.current.path}${Platform.pathSeparator}data';
    final dir = Directory(configured.isEmpty ? fallback : configured);
    await dir.create(recursive: true);
    await Directory('${dir.path}${Platform.pathSeparator}logs').create(recursive: true);
    return dir;
  }

  static Future<File?> resolveEnvFile() async {
    final env = Platform.environment;
    final configuredEnvFile = (env['SMART_CONTROLLER_ENV_FILE'] ?? '').trim();
    if (configuredEnvFile.isNotEmpty) {
      final configured = File(configuredEnvFile);
      if (await configured.exists()) {
        return configured;
      }
    }

    final data = await dataDir();
    final appRoot = (env['SMART_CONTROLLER_APP_ROOT'] ?? '').trim();
    final current = Directory.current.path;
    final parent = Directory.current.parent.path;
    final grandParent = Directory.current.parent.parent.path;

    final candidates = <String>[
      '${data.path}${Platform.pathSeparator}.env',
      if (appRoot.isNotEmpty) '$appRoot${Platform.pathSeparator}.env',
      '$current${Platform.pathSeparator}.env',
      '$parent${Platform.pathSeparator}.env',
      '$grandParent${Platform.pathSeparator}.env',
    ];

    final seen = <String>{};
    for (final path in candidates) {
      final normalized = path.trim();
      if (normalized.isEmpty || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      final file = File(normalized);
      if (await file.exists()) {
        return file;
      }
    }

    return null;
  }

  static Future<Map<String, String>> loadEnvMap() async {
    final file = await resolveEnvFile();
    if (file == null) {
      return <String, String>{};
    }
    final content = await file.readAsString();
    final out = <String, String>{};
    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final eq = line.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final key = line.substring(0, eq).trim();
      String value = line.substring(eq + 1).trim();
      if (value.length >= 2) {
        final first = value[0];
        final last = value[value.length - 1];
        if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
          value = value.substring(1, value.length - 1);
        }
      }
      if (key.isNotEmpty) {
        out[key] = value;
      }
    }
    return out;
  }
}
