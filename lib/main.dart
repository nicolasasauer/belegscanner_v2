import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'pages/dashboard_page.dart';
import 'pages/home_page.dart';
import 'services/database_service.dart';

/// Einstiegspunkt der Bong-Scanner-App.
void main() {
  // WidgetsFlutterBinding muss als allererste Zeile initialisiert werden,
  // bevor andere Plugins oder Platform-Channels genutzt werden.
  WidgetsFlutterBinding.ensureInitialized();

  try {
    runZonedGuarded(
      () async {
        try {
          // Lokalisierungsdaten für Deutsch initialisieren
          await initializeDateFormatting('de_DE');

          runApp(const BongScannerApp());
        } catch (e, stackTrace) {
          debugPrint('Startup-Fehler: $e\n$stackTrace');
          runApp(ErrorApp(error: e));
        }
      },
      (error, stackTrace) {
        debugPrint('Zone-Fehler: $error\n$stackTrace');
      },
    );
  } catch (e, stackTrace) {
    debugPrint('Kritischer Startup-Fehler: $e\n$stackTrace');
    runApp(ErrorApp(error: e));
  }
}

/// Fehler-Screen der beim Start-Absturz angezeigt wird, damit der Fehler lesbar ist.
class ErrorApp extends StatelessWidget {
  final Object error;

  const ErrorApp({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.red,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              error.toString(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// Root-Widget der App mit Material 3 Theme.
class BongScannerApp extends StatelessWidget {
  const BongScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bong-Scanner',
      debugShowCheckedModeBanner: false,
      // Material 3 aktivieren
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const AppShell(),
    );
  }
}

// =============================================================================
// App-Shell mit Tab-Navigation
// =============================================================================

/// Haupt-Shell der App mit [BottomNavigationBar] zum Wechsel zwischen
/// Belegliste und Dashboard.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  final DatabaseService _databaseService = DatabaseService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomePage(databaseService: _databaseService),
          DashboardPage(databaseService: _databaseService),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) =>
            setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Belegliste',
          ),
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'Dashboard',
          ),
        ],
      ),
    );
  }
}
