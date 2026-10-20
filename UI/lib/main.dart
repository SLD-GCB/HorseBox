import 'dart:io';

import 'package:flutter/material.dart';
import 'package:horsebox_backend/horsebox_backend.dart';

import 'pages/shell.dart';
import 'platform/vpn_channel.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'utils/app_paths.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final dataDir = await _dataDir();
    final store = await LocalStore.open(dataDir);
    final state = AppState(store, dataDir);
    await state.init();
    runApp(HorseBoxApp(state: state));
  } catch (e) {
    runApp(_StartupError(message: '$e'));
  }
}

Future<String> _dataDir() async {
  if (Platform.isAndroid) {
    return VpnChannel().filesDir();
  }
  return resolveWindowsDataDir();
}

class HorseBoxApp extends StatelessWidget {
  const HorseBoxApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final mode = switch (state.settings.themeMode) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        };
        return MaterialApp(
          title: 'HorseBox',
          debugShowCheckedModeBanner: false,
          theme: HorseBoxTheme.build(brightness: Brightness.light),
          darkTheme: HorseBoxTheme.build(brightness: Brightness.dark),
          themeMode: mode,
          home: HomeShell(state: state),
        );
      },
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HorseBoxTheme.build(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 44,
                  color: Colors.redAccent,
                ),
                const SizedBox(height: 16),
                const Text(
                  '启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
