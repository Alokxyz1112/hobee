import 'dart:async';
import 'package:flutter/material.dart';
import 'crash_log.dart';
import 'glass.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'player.dart';
import 'archive.dart';
import 'public_sources.dart';
import 'auth.dart';
import 'filters.dart';
import 'deep_search.dart';
import 'nav.dart';
import 'nav_bar.dart';
import 'posts_view.dart';
import 'search.dart';
import 'source_bar.dart';
import 'settings.dart';
import 'sub_search.dart';
import 'sub_users.dart';
import 'viewed.dart';

const accent = Color(0xFFE53935);
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

void main() {
  runZonedGuarded(_main, (e, s) => CrashLog.record(e, s));
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _safe('crashlog', CrashLog.init);
  final sp = await SharedPreferences.getInstance();
  // If the last launch died before the first frame settled, start in safe mode: drop saved search state.
  if (sp.getBool('booting') ?? false) {
    CrashLog.record('Previous launch did not finish; search state reset (safe mode)', null, 'boot');
    await _safe('reset', () async {
      for (final k in sp.getKeys().toList()) {
        if (k.startsWith('filters.') || k == 'mediaFilter') await sp.remove(k);
      }
    });
  }
  await sp.setBool('booting', true);
  themeMode.value = ThemeMode.values[(sp.getInt('theme') ?? 0).clamp(0, ThemeMode.values.length - 1)];
  await _safe('filters', loadFilterPrefs);
  await _safe('archive', ArchiveConfig.load);
  await _safe('redlib', RedlibConfig.load);
  await _safe('recents', Recents.load);
  await _safe('deepHistory', () async => DeepHistory.load());
  await _safe('subHistory', SubHistory.load);
  await _safe('subNav', () async => initSubNav());
  await _safe('viewed', Viewed.load);
  // Older builds saved suggestion filter choices; they are gone now, so drop the key.
  await _safe('suggest', () async => sp.remove('suggestPrefs'));
  await _safe('video', VideoPrefs.load);
  await _safe('auth', Auth.i.init);
  // Thumbs are decoded at display size (cacheWidth), so 160 MB holds plenty without OOM pressure on big lists.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 160 << 20
    ..maximumSize = 1000;
  runApp(const HobeeApp());
  // Startup counts as finished once the app has been up for a few seconds.
  Timer(const Duration(seconds: 6), () => sp.setBool('booting', false));
}

/// One failing restore must never stop the app from opening.
Future<void> _safe(String what, Future<void> Function() f) async {
  try {
    await f();
  } catch (e, s) {
    CrashLog.record('startup $what: $e', s, 'boot');
  }
}

ThemeData _theme(Brightness b) => ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: b == Brightness.dark ? const Color(0xFF161214) : const Color(0xFFFFF6F5),
      colorScheme: ColorScheme.fromSeed(seedColor: accent, primary: accent, brightness: b),
      appBarTheme: const AppBarTheme(centerTitle: false, backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, scrolledUnderElevation: 0, elevation: 0),
      dialogTheme: DialogThemeData(
        backgroundColor: (b == Brightness.dark ? const Color(0xFF1A1A1A) : Colors.white).withValues(alpha: 0.88),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: BorderSide(color: Colors.white.withValues(alpha: b == Brightness.dark ? 0.14 : 0.8))),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: (b == Brightness.dark ? Colors.white : Colors.white).withValues(alpha: b == Brightness.dark ? 0.08 : 0.55),
        selectedColor: accent.withValues(alpha: 0.18),
        side: BorderSide(color: (b == Brightness.dark ? Colors.white : Colors.black).withValues(alpha: 0.12)),
        shape: const StadiumBorder(),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: b == Brightness.dark ? 0.06 : 0.5)),
      )),
    );

class HobeeApp extends StatelessWidget {
  const HobeeApp({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: themeMode,
        builder: (_, m, _) => MaterialApp(
          title: 'Hobee',
          scaffoldMessengerKey: messengerKey,
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: m,
          home: const Home(),
        ),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String homeSrc = currentSource.value;

  @override
  void initState() {
    super.initState();
    Auth.i.addListener(_r);
    mainTab.addListener(_tab);
    deepSource.addListener(_syncDeep);
  }

  void _r() => mounted ? setState(() {}) : null;

  void _tab() {
    final t = mainTab.value;
    if (t == tab) return;
    if (tab == 0) homeSrc = currentSource.value;
    setState(() => tab = t);
    // Apply the new tab's source after the old tab has gone inactive.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tab == 0) currentSource.value = homeSrc;
      if (tab == 1 && deepSource.value != null) currentSource.value = deepSource.value!;
    });
  }

  void _syncDeep() {
    if (tab == 1 && deepSource.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => currentSource.value = deepSource.value!);
    }
  }

  @override
  void dispose() {
    Auth.i.removeListener(_r);
    mainTab.removeListener(_tab);
    deepSource.removeListener(_syncDeep);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: pageBackground(context),
      child: Scaffold(
        extendBody: true,
        backgroundColor: Colors.transparent,
        body: IndexedStack(index: tab, children: [
          Auth.i.loggedIn ? const PostsView() : const LoginPrompt(),
          const DeepSearchScreen(),
          const SearchScreen(),
          const SettingsScreen(),
        ]),
        bottomNavigationBar: HobeeNavBar(selected: tab, accent: accent, onSelect: (i) => mainTab.value = i),
      ),
    );
  }
}

class LoginPrompt extends StatelessWidget {
  const LoginPrompt({super.key});
  @override
  Widget build(BuildContext context) => SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/icon/logo.png', width: 88, height: 88),
              const SizedBox(height: 12),
              Text('Hobee', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Your Reddit media, ad-free.', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(onPressed: () => startLogin(context), icon: const Icon(Icons.login), label: const Text('Log in with Reddit')),
              if (Auth.i.lastError != null) ...[
                const SizedBox(height: 16),
                Text(Auth.i.lastError!, style: const TextStyle(color: accent), textAlign: TextAlign.center),
              ],
            ]),
          ),
        ),
      );
}
