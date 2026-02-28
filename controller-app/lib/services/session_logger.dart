import 'dart:convert';
import 'dart:io';

import 'data_paths.dart';

class SessionLogger {
  SessionLogger._();

  static final SessionLogger instance = SessionLogger._();
  bool _ready = false;
  String _sessionId = '';
  late File _activityFile;
  late File _errorFile;
  Future<void> _writeQueue = Future<void>.value();

  Future<void> init({String appVersion = ''}) async {
    if (_ready) {
      return;
    }
    final data = await DataPaths.dataDir();
    final now = DateTime.now().toUtc();
    final day = _fmtDay(now);
    final stamp = _fmtStamp(now);
    _sessionId = 'controller-$stamp-${pid}';
    final sessionDir = Directory(
      '${data.path}${Platform.pathSeparator}logs${Platform.pathSeparator}controller${Platform.pathSeparator}sessions${Platform.pathSeparator}$_sessionId',
    );
    await sessionDir.create(recursive: true);
    _activityFile = File('${sessionDir.path}${Platform.pathSeparator}activity-$day.jsonl');
    _errorFile = File('${sessionDir.path}${Platform.pathSeparator}errors-$day.jsonl');
    _ready = true;
    await logActivity('session_started', <String, dynamic>{
      'session_id': _sessionId,
      'pid': pid,
      'app_version': appVersion,
      'platform': Platform.operatingSystem,
      'cwd': Directory.current.path,
    });
  }

  String get sessionId => _sessionId;

  Future<void> logActivity(String event, [Map<String, dynamic>? payload]) async {
    if (!_ready) {
      await init();
    }
    final row = <String, dynamic>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'payload': payload ?? <String, dynamic>{},
    };
    await _append(_activityFile, row);
  }

  Future<void> logError(
    String event,
    Object error, {
    StackTrace? stackTrace,
    Map<String, dynamic>? payload,
  }) async {
    if (!_ready) {
      await init();
    }
    final row = <String, dynamic>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'error': error.toString(),
      'stack_trace': stackTrace?.toString() ?? '',
      'payload': payload ?? <String, dynamic>{},
    };
    await _append(_errorFile, row);
    await _append(_activityFile, row);
  }

  Future<void> _append(File file, Map<String, dynamic> row) async {
    final line = '${jsonEncode(row)}\n';
    _writeQueue = _writeQueue
        .catchError((_) {})
        .then((_) async {
          await file.parent.create(recursive: true);
          await file.writeAsString(line, mode: FileMode.append, flush: true);
        });
    await _writeQueue;
  }

  String _fmtDay(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  String _fmtStamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '${y}${m}${d}T${hh}${mm}${ss}Z';
  }
}
