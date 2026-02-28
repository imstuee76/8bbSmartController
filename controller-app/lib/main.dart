import 'dart:async';

import 'package:flutter/material.dart';

import 'app_version.dart';
import 'screens/config_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/main_screen.dart';
import 'services/api_service.dart';
import 'services/local_store.dart';
import 'services/session_logger.dart';

Future<void> main() async {
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
  runZonedGuarded(
    () => runApp(const SmartControllerBootstrap()),
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
    final url = await _store.loadServerUrl();
    final token = await _store.loadAuthToken();
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7285), brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF4F7F8),
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

  @override
  Widget build(BuildContext context) {
    final tabs = [
      MainScreen(api: widget.api),
      DevicesScreen(api: widget.api),
      ConfigScreen(
        api: widget.api,
        store: widget.store,
        onServerUrlChanged: (url) {
          setState(() {
            widget.api.baseUrl = url;
          });
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: const [
            Text('8bb Smart Controller'),
            Spacer(),
            Text('v$controllerDisplayVersion', style: TextStyle(fontSize: 14)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Row(
            children: [
              _TabButton(title: 'Main', selected: _index == 0, onTap: () => setState(() => _index = 0)),
              _TabButton(title: 'Devices', selected: _index == 1, onTap: () => setState(() => _index = 1)),
              _TabButton(title: 'Config', selected: _index == 2, onTap: () => setState(() => _index = 2)),
            ],
          ),
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
    );
  }
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
          minimumSize: const Size(140, 40),
        ),
        child: Text(title),
      ),
    );
  }
}
