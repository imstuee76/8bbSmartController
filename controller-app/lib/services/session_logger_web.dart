import 'dart:developer' as developer;
import 'dart:math';

class SessionLogger {
  SessionLogger._();

  static final SessionLogger instance = SessionLogger._();
  bool _ready = false;
  String _sessionId = '';

  Future<void> init({String appVersion = ''}) async {
    if (_ready) {
      return;
    }
    _sessionId = 'controller-web-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    _ready = true;
    await logActivity('session_started', <String, dynamic>{
      'session_id': _sessionId,
      'app_version': appVersion,
      'platform': 'web',
    });
  }

  String get sessionId => _sessionId;

  Future<void> logActivity(String event, [Map<String, dynamic>? payload]) async {
    if (!_ready) {
      await init();
    }
    developer.log(
      'activity',
      name: '8bb.controller',
      time: DateTime.now(),
      error: <String, dynamic>{
        'event': event,
        'payload': payload ?? <String, dynamic>{},
      },
    );
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
    developer.log(
      event,
      name: '8bb.controller.error',
      error: error,
      stackTrace: stackTrace,
      time: DateTime.now(),
    );
    if (payload != null && payload.isNotEmpty) {
      developer.log('error_payload', name: '8bb.controller.error', error: payload);
    }
  }
}
