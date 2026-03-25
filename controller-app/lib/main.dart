import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_version.dart';
import 'screens/config_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/main_screen.dart';
import 'services/api_service.dart';
import 'services/local_store.dart';
import 'services/session_logger.dart';
import 'services/touch_keyboard_service.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await SessionLogger.instance.init(appVersion: controllerDisplayVersion);
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        unawaited(
          SessionLogger.instance.logError(
            'flutter_error',
            details.exception,
            stackTrace: details.stack,
            payload: <String, dynamic>{'library': details.library ?? ''},
          ),
        );
      };
      runApp(const SmartControllerBootstrap());
    },
    (Object error, StackTrace stackTrace) {
      unawaited(SessionLogger.instance.logError('uncaught_zone_error', error, stackTrace: stackTrace));
    },
  );
}

class SmartControllerBootstrap extends StatefulWidget {
  const SmartControllerBootstrap({super.key});

  @override
  State<SmartControllerBootstrap> createState() => _SmartControllerBootstrapState();
}

class _SmartControllerBootstrapState extends State<SmartControllerBootstrap> {
  final LocalStore _store = LocalStore();
  ApiService? _api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait<dynamic>([
      _store.loadServerUrl(),
      _store.loadAuthToken(),
    ]);
    final url = (results[0] ?? '').toString();
    final token = (results[1] ?? '').toString();
    setState(() {
      final api = ApiService(url);
      api.authToken = token;
      _api = api;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_api == null) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }

    return MaterialApp(
      title: '8bb Smart Controller',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        },
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7285), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF4F7F8),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity.standard,
        useMaterial3: true,
      ),
      home: HomeShell(api: _api!, store: _store),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.api, required this.store});

  final ApiService api;
  final LocalStore store;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final TouchKeyboardService _touchKeyboard;
  final GlobalKey<MainScreenState> _mainScreenKey = GlobalKey<MainScreenState>();

  void _setIndex(int index) {
    if (_index == index) {
      if (index == 0) {
        unawaited(_mainScreenKey.currentState?.refreshTiles() ?? Future<void>.value());
      }
      return;
    }
    setState(() {
      _index = index;
    });
    if (index == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_mainScreenKey.currentState?.refreshTiles() ?? Future<void>.value());
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _touchKeyboard = TouchKeyboardService.fromEnvironment();
    _touchKeyboard.start();
    unawaited(_initTouchKeyboard());
  }

  Future<void> _initTouchKeyboard() async {
    final enabled = await widget.store.loadTouchKeyboardEnabled();
    await _touchKeyboard.setEnabled(enabled);
  }

  bool _editableFocusShouldCloseOnEnter() {
    final node = FocusManager.instance.primaryFocus;
    final context = node?.context;
    if (context == null) return false;
    final editable = context.widget is EditableText
        ? context.widget as EditableText
        : context.findAncestorWidgetOfExactType<EditableText>();
    if (editable == null || editable.readOnly) return false;
    return (editable.maxLines ?? 1) <= 1;
  }

  Future<void> _handleTouchKeyboardChanged(bool enabled) async {
    await widget.store.saveTouchKeyboardEnabled(enabled);
    await _touchKeyboard.setEnabled(enabled);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    unawaited(SessionLogger.instance.logActivity('session_ended'));
    unawaited(_touchKeyboard.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = [
      MainScreen(key: _mainScreenKey, api: widget.api),
      DevicesScreen(api: widget.api, store: widget.store),
      ConfigScreen(
        api: widget.api,
        store: widget.store,
        onServerUrlChanged: (url) {
          setState(() {
            widget.api.baseUrl = url;
          });
        },
        onTouchKeyboardChanged: (enabled) {
          unawaited(_handleTouchKeyboardChanged(enabled));
        },
      ),
    ];

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): const _CloseKeyboardIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): const _CloseKeyboardIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseKeyboardIntent: CallbackAction<_CloseKeyboardIntent>(
            onInvoke: (intent) {
              if (_editableFocusShouldCloseOnEnter()) {
                unawaited(_touchKeyboard.closeInput());
              }
              return null;
            },
          ),
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (_) {
            final navigator = Navigator.of(context, rootNavigator: true);
            if (navigator.canPop()) {
              return;
            }
            if (_touchKeyboard.hasEditableFocus.value) {
              unawaited(_touchKeyboard.closeInput());
            }
          },
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 68,
              titleSpacing: 12,
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '8bb Smart Controller',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TabButton(title: 'Main', selected: _index == 0, onTap: () => _setIndex(0)),
                  _TabButton(title: 'Devices', selected: _index == 1, onTap: () => _setIndex(1)),
                  _TabButton(title: 'Config', selected: _index == 2, onTap: () => _setIndex(2)),
                  if (_index == 0) ...[
                    const SizedBox(width: 8),
                    _HeaderActionButton(
                      title: 'Groups',
                      icon: Icons.layers,
                      onTap: () {
                        _mainScreenKey.currentState?.openCreateGroupDialog();
                      },
                    ),
                    const SizedBox(width: 8),
                    _HeaderActionButton(
                      title: 'Automation',
                      icon: Icons.schedule,
                      onTap: () {
                        _mainScreenKey.currentState?.openAutomationDialog();
                      },
                    ),
                  ],
                  const SizedBox(width: 10),
                  const Text('v$controllerDisplayVersion', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            body: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFF4F7F8), Color(0xFFE8F2F4)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: tabs[_index],
            ),
            floatingActionButton: ValueListenableBuilder<bool>(
              valueListenable: _touchKeyboard.hasEditableFocus,
              builder: (context, editing, _) {
                if (!editing) return const SizedBox.shrink();
                return FloatingActionButton.extended(
                  heroTag: 'go-input-close',
                  onPressed: () => unawaited(_touchKeyboard.closeInput()),
                  label: const Text('GO', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  icon: const Icon(Icons.keyboard_hide, size: 24),
                );
              },
            ),
            floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          ),
        ),
      ),
    );
  }
}

class _CloseKeyboardIntent extends Intent {
  const _CloseKeyboardIntent();
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.title, required this.selected, required this.onTap});

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: FilledButton.tonal(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: selected ? const Color(0xFF0B7285) : const Color(0xFFDCEBED),
          foregroundColor: selected ? Colors.white : const Color(0xFF0F3A40),
          minimumSize: const Size(104, 46),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
        child: Text(title),
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  const _HeaderActionButton({required this.title, required this.icon, required this.onTap});

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFFDCEBED),
        foregroundColor: const Color(0xFF0F3A40),
        minimumSize: const Size(118, 46),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      icon: Icon(icon, size: 18),
      label: Text(title),
    );
  }
}
