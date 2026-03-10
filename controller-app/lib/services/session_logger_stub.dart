class SessionLogger {
  SessionLogger._();

  static final SessionLogger instance = SessionLogger._();
  String _sessionId = '';

  Future<void> init({String appVersion = ''}) async {
    if (_sessionId.isEmpty) {
      _sessionId = 'controller-stub-${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  String get sessionId => _sessionId;

  Future<void> logActivity(String event, [Map<String, dynamic>? payload]) async {}

  Future<void> logError(
    String event,
    Object error, {
    StackTrace? stackTrace,
    Map<String, dynamic>? payload,
  }) async {}
}
