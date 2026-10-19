import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/system/shell_environment.dart';
import 'state/forms.dart';
import 'state/providers.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = await loadShellEnvironment();
  final settings = PreferencesSettingsStore(
    await SharedPreferences.getInstance(),
  );
  migrateSettings(settings);

  runApp(
    ProviderScope(
      // A failed provider (a tool that crashed) shows its error; retrying it
      // on its own would run the tool again behind the user's back.
      retry: (_, _) => null,
      overrides: [
        environmentProvider.overrideWithValue(environment),
        settingsStoreProvider.overrideWithValue(settings),
      ],
      child: const ApkForgeApp(),
    ),
  );
}

class ApkForgeApp extends StatelessWidget {
  const ApkForgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APK Forge',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
