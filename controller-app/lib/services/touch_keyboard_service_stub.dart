import 'package:flutter/widgets.dart';

class TouchKeyboardService {
  TouchKeyboardService._();

  factory TouchKeyboardService.fromEnvironment() {
    return TouchKeyboardService._();
  }

  final ValueNotifier<bool> hasEditableFocus = ValueNotifier<bool>(false);

  void start() {}

  Future<void> closeInput() async {
    hasEditableFocus.value = false;
  }

  Future<void> dispose() async {
    hasEditableFocus.dispose();
  }
}
