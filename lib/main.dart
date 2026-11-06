import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'notification_service.dart';
import 'repository.dart';
import 'screens/absences_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'tray_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de_DE');
  final repo = Repository();
  final data = await repo.load();
  await NotificationService.instance.init();
  await NotificationService.instance.update(data);
  await TrayService.ensureInitialized();
  final state = AppState(repo, data)..sync.start();
  // Desktop: Steuerung über den Infobereich (Tray)
  await TrayService.instance.attach(state);
  runApp(
    ChangeNotifierProvider.value(
      value: state,
      child: const AnTaTimeApp(),
    ),
  );
}

class AnTaTimeApp extends StatelessWidget {
  const AnTaTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF00796B);
    return MaterialApp(
      title: 'AnTaTime',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      locale: const Locale('de', 'DE'),
      supportedLocales: const [Locale('de', 'DE')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _pages = [
    TodayScreen(),
    HistoryScreen(),
    AbsencesScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.timer_outlined), label: 'Heute'),
          NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Verlauf'),
          NavigationDestination(
              icon: Icon(Icons.beach_access_outlined), label: 'Abwesend'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Einstellungen'),
        ],
      ),
    );
  }
}
