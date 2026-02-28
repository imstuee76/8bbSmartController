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
    final data = await dataDir();
    final dataEnv = File('${data.path}${Platform.pathSeparator}.env');
    if (await dataEnv.exists()) {
      return dataEnv;
    }
    final localEnv = File('${Directory.current.path}${Platform.pathSeparator}.env');
    if (await localEnv.exists()) {
      return localEnv;
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
