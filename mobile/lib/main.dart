import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_state.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  app = await AppState.load();
  runApp(const MeshLokalApp());
}

/// Warna: netral gelap/terang + satu aksen amber. Merah hanya untuk SOS.
const kAccent = Color(0xFFE09A1A);
const kSos = Color(0xFFD93025);

ThemeData _theme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.neutral,
  ).copyWith(
    primary: dark ? kAccent : const Color(0xFF9A6400),
    onPrimary: dark ? const Color(0xFF1C1406) : Colors.white,
    error: kSos,
    surface: dark ? const Color(0xFF111113) : const Color(0xFFFAFAF8),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, scrolledUnderElevation: 0, centerTitle: false),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xFF18181B) : const Color(0xFFF1F0EC),
      indicatorColor: scheme.primary.withValues(alpha: 0.18),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF18181B) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: dark ? const Color(0xFF2A2A2F) : const Color(0xFFE4E2DC)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}

class MeshLokalApp extends StatelessWidget {
  const MeshLokalApp({super.key});

  @override
  Widget build(BuildContext context) => WithForegroundTask(
        child: MaterialApp(
          title: 'MeshLokal',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: ListenableBuilder(
            listenable: app,
            builder: (_, _) => app.hasIdentity ? const HomeScreen() : const OnboardingScreen(),
          ),
        ),
      );
}
