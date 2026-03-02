import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

class TouchKeyboardService {
  TouchKeyboardService._({
    required this.enabled,
    required this.command,
    required this.args,
  });

  factory TouchKeyboardService.fromEnvironment() {
    final env = Platform.environment;
    final enabled = _isEnabled(env['SMART_CONTROLLER_TOUCH_KEYBOARD_ENABLED'] ?? '1');
    final rawCmd = (env['SMART_CONTROLLER_TOUCH_KEYBOARD_CMD'] ?? 'onboard').trim();
    final parsed = _splitCommand(rawCmd);
    final cmd = parsed.isEmpty ? 'onboard' : parsed.first;
    final args = parsed.length > 1 ? parsed.sublist(1) : <String>[];
    return TouchKeyboardService._(
      enabled: enabled,
      command: cmd,
      args: args,
    );
  }

  final bool enabled;
  final String command;
  final List<String> args;

  Timer? _focusPoll;
  Process? _keyboardProcess;
  bool _lastNeedsKeyboard = false;
  bool _active = false;

  static bool _isEnabled(String value) {
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'on';
  }

  static List<String> _splitCommand(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return <String>[];
    return trimmed.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList(growable: false);
  }

  void start() {
    if (_active || !enabled || !Platform.isLinux) return;
    _active = true;
    _focusPoll = Timer.periodic(const Duration(milliseconds: 220), (_) {
      unawaited(_sync());
    });
  }

  Future<void> _sync() async {
    if (!_active) return;
    final needsKeyboard = _focusedWidgetNeedsKeyboard();
    if (needsKeyboard == _lastNeedsKeyboard) return;
    _lastNeedsKeyboard = needsKeyboard;
    if (needsKeyboard) {
      await _show();
    } else {
      await _hide();
    }
  }

  bool _focusedWidgetNeedsKeyboard() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;
    final context = node.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Future<void> _show() async {
    if (_keyboardProcess != null) return;
    if (command == 'onboard') {
      await _configureOnboardForTablet();
    }
    try {
      final proc = await Process.start(command, args, runInShell: true);
      _keyboardProcess = proc;
      unawaited(
        proc.exitCode.then((_) {
          if (identical(_keyboardProcess, proc)) {
            _keyboardProcess = null;
          }
        }),
      );
    } catch (_) {}
  }

  Future<void> _hide() async {
    final proc = _keyboardProcess;
    if (proc == null) return;
    _keyboardProcess = null;
    try {
      proc.kill(ProcessSignal.sigterm);
      await proc.exitCode.timeout(const Duration(milliseconds: 900));
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  Future<void> _configureOnboardForTablet() async {
    // Best effort; ignored when schema/keys are unavailable.
    final commands = <List<String>>[
      <String>['set', 'org.onboard.window', 'docking-enabled', 'false'],
      <String>['set', 'org.onboard.window', 'force-to-top', 'false'],
      <String>['set', 'org.onboard.window', 'window-decoration', 'true'],
    ];
    for (final args in commands) {
      try {
        await Process.run('gsettings', args, runInShell: true);
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _active = false;
    _focusPoll?.cancel();
    _focusPoll = null;
    _lastNeedsKeyboard = false;
    await _hide();
  }
}
