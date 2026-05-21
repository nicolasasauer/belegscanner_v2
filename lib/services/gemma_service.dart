import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:archive/archive_io.dart';

// ---------------------------------------------------------------------------
// SharedPreferences-Schlüssel
// ---------------------------------------------------------------------------

const String kGemmaEnabledKey = 'gemma_ai_enabled';
const String kGemmaModelPathKey = 'gemma_model_path';
const String kGemmaTemperatureKey = 'gemma_temperature';

// ---------------------------------------------------------------------------
// GemmaService
// ---------------------------------------------------------------------------

/// Singleton-Service für die Verwaltung des lokalen Gemma-Modells.
///
/// Kapselt Initialisierung, Inferenz und Persistenz der Modellkonfiguration.
/// Das Modell wird lazy geladen: erst beim ersten Aufruf von [ensureReady]
/// (oder [categorizeItems]) wird es tatsächlich in den Speicher geladen.
///
/// **Privacy-first**: Alle Inferenzen laufen vollständig lokal auf dem Gerät.
/// Es findet kein Netzwerk-Traffic statt.
///
/// **Nutzung:**
/// ```dart
/// final gemma = GemmaService.instance;
/// await gemma.loadSettings();
///
/// if (gemma.isEnabled) {
///   await gemma.ensureReady();
///   final cats = await gemma.categorizeItems(items, availableCategories);
/// }
/// ```
class GemmaService {
  GemmaService._();

  /// Singleton-Instanz.
  static final GemmaService instance = GemmaService._();

  // ── Zustand ──────────────────────────────────────────────────────────────

  /// Ob KI-Kategorisierung in den Einstellungen aktiviert ist.
  bool isEnabled = false;

  /// Pfad zur Gemma-Modelldatei (.task-Format von MediaPipe).
  String? modelPath;

  /// Inferenz-Temperatur (0.0–1.0). Niedrig = deterministischer Output.
  double temperature = 0.1;

  /// Ob das Modell gerade geladen und bereit für Inferenz ist.
  bool get isReady => _isInitialized;

  /// Kurze Status-Beschreibung für die UI.
  String get statusMessage => _statusMessage;

  bool _isInitialized = false;
  String _statusMessage = 'Nicht initialisiert';

  // ── Einstellungen ─────────────────────────────────────────────────────────

  /// Liest alle gespeicherten Einstellungen aus den [SharedPreferences].
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool(kGemmaEnabledKey) ?? false;
    modelPath = prefs.getString(kGemmaModelPathKey);
    temperature = prefs.getDouble(kGemmaTemperatureKey) ?? 0.1;
    debugPrint('[GemmaService] Einstellungen geladen: '
        'enabled=$isEnabled, modelPath=$modelPath');
  }

  /// Speichert alle aktuellen Einstellungen in [SharedPreferences].
  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGemmaEnabledKey, isEnabled);
    if (modelPath != null) {
      await prefs.setString(kGemmaModelPathKey, modelPath!);
    } else {
      await prefs.remove(kGemmaModelPathKey);
    }
    await prefs.setDouble(kGemmaTemperatureKey, temperature);
  }

  // ── Modell-Lifecycle ──────────────────────────────────────────────────────

  /// Stellt sicher, dass das Modell geladen ist.
  ///
  /// Gibt [true] zurück, wenn das Modell nach dem Aufruf bereit ist.
  /// Gibt [false] zurück bei Fehler oder wenn kein Modell konfiguriert ist.
  /// Idempotent: ein bereits geladenes Modell wird nicht neu geladen.
  Future<bool> ensureReady() async {
    if (_isInitialized) return true;
    if (!isEnabled) {
      _statusMessage = 'KI deaktiviert';
      return false;
    }
    final path = modelPath;
    if (path == null || !File(path).existsSync()) {
      _statusMessage = 'Kein Modell gefunden – bitte Modell einrichten';
      debugPrint('[GemmaService] Kein gültiger Modellpfad: $path');
      return false;
    }
    return _loadModel(path);
  }

  /// Registriert eine neue Modelldatei (kopiert sie ins App-Verzeichnis,
  /// wenn sie sich außerhalb davon befindet) und lädt das Modell.
  ///
  /// Gibt den permanenten Pfad zurück oder `null` bei Fehler.
  Future<String?> installAndLoadModel(String sourcePath) async {
    try {
      _statusMessage = 'Modell wird installiert…';
      final permanentPath = await _copyModelToAppDir(sourcePath);
      if (permanentPath == null) return null;

      modelPath = permanentPath;
      await saveSettings();

      final ok = await _loadModel(permanentPath);
      return ok ? permanentPath : null;
    } catch (e, st) {
      debugPrint('[GemmaService] Fehler beim Installieren: $e\n$st');
      _statusMessage = 'Fehler beim Installieren: $e';
      return null;
    }
  }

  /// Lädt eine Modelldatei von `url` herunter, speichert sie temporär und
  /// führt anschließend `installAndLoadModel` aus.
  ///
  /// `onProgress` erhält Werte 0.0–1.0 während des Downloads.
  /// Gibt den permanenten Installationspfad oder `null` bei Fehler zurück.
  Future<String?> downloadAndInstallModel(
    String url, {
    void Function(double progress)? onProgress,
    String? expectedSha256,
  }) async {
    try {
      _statusMessage = 'Modell wird heruntergeladen…';
      final uri = Uri.parse(url);
      final client = HttpClient();
      final req = await client.getUrl(uri);
      final res = await req.close();
      if (res.statusCode != 200) {
        _statusMessage = 'Download fehlgeschlagen: HTTP ${res.statusCode}';
        return null;
      }

      final tmpDir = await getTemporaryDirectory();
      final tmpPath = p.join(tmpDir.path, p.basename(uri.path));
      final tmpFile = File(tmpPath);
      final sink = tmpFile.openWrite();

      final contentLength = res.contentLength;
      var received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0 && onProgress != null) {
          try {
            onProgress(received / contentLength);
          } catch (_) {}
        }
      }
      await sink.close();

      // Optional: Prüfsumme prüfen, falls erwartet
      if (expectedSha256 != null) {
        try {
          final bytes = await tmpFile.readAsBytes();
          final hash = sha256.convert(bytes).toString();
          if (hash.toLowerCase() != expectedSha256.toLowerCase()) {
            _statusMessage = 'Checksumme stimmt nicht überein';
            await tmpFile.delete().catchError((_) {});
            return null;
          }
        } catch (e) {
          debugPrint('[GemmaService] Prüfsummen-Fehler: $e');
        }
      }

      // Wenn ZIP: extrahiere geeignete Modelldatei
      final candidate = await _tryExtractAndFindModel(tmpPath);
      if (candidate == null) {
        await tmpFile.delete().catchError((_) {});
        return null;
      }
      final installed = await installAndLoadModel(candidate);
      // Temporäre Datei entfernen (Installations-Kopie bleibt im App-Ordner)
      try {
        await tmpFile.delete();
      } catch (_) {}
      return installed;
    } catch (e, st) {
      debugPrint('[GemmaService] Download-Fehler: $e\n$st');
      _statusMessage = 'Download fehlgeschlagen: $e';
      return null;
    }
  }

  Future<String?> _tryExtractAndFindModel(String filePath) async {
    // Wenn ZIP, versuche .task/.bin darin zu finden und extrahieren
    final ext = p.extension(filePath).toLowerCase();
    if (ext == '.zip') {
      try {
        final bytes = await File(filePath).readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final docsDir = await getTemporaryDirectory();
        for (final file in archive) {
          if (file.isFile) {
            final name = file.name;
            final lower = name.toLowerCase();
            if (lower.endsWith('.task') || lower.endsWith('.bin') || lower.endsWith('.tflite')) {
              final outPath = p.join(docsDir.path, p.basename(name));
              final outFile = File(outPath);
              await outFile.writeAsBytes(file.content as List<int>);
              return outPath;
            }
          }
        }
        _statusMessage = 'Keine .task/.bin Datei im ZIP gefunden';
        return null;
      } catch (e, st) {
        debugPrint('[GemmaService] ZIP-Extraktion fehlgeschlagen: $e\n$st');
        _statusMessage = 'ZIP-Extraktion fehlgeschlagen';
        return null;
      }
    }
    return filePath;
  }

  /// Entlädt das Modell aus dem Speicher und setzt den Zustand zurück.
  Future<void> unloadModel() async {
    if (_isInitialized) {
      try {
        await FlutterGemmaPlugin.instance.close();
      } catch (e) {
        debugPrint('[GemmaService] Fehler beim Schließen: $e');
      }
    }
    _isInitialized = false;
    _statusMessage = 'Modell entladen';
    debugPrint('[GemmaService] Modell entladen.');
  }

  /// Löscht die installierte Modelldatei und setzt alle Einstellungen zurück.
  Future<void> removeModel() async {
    await unloadModel();
    if (modelPath != null) {
      try {
        final f = File(modelPath!);
        if (f.existsSync()) await f.delete();
      } catch (e) {
        debugPrint('[GemmaService] Modelldatei konnte nicht gelöscht werden: $e');
      }
    }
    modelPath = null;
    isEnabled = false;
    await saveSettings();
    _statusMessage = 'Kein Modell installiert';
  }

  // ── Inferenz ──────────────────────────────────────────────────────────────

  /// Kategorisiert eine Liste von Artikelnamen mittels des lokalen Modells.
  ///
  /// Gibt eine parallele Liste von Kategorienamen zurück. Schlägt die Inferenz
  /// fehl oder ist das Modell nicht bereit, gibt die Methode `null` zurück –
  /// der Aufrufer soll in diesem Fall auf Keyword-Kategorisierung zurückfallen.
  ///
  /// **Beispiel:**
  /// ```dart
  /// final cats = await gemma.categorizeItems(
  ///   ['Vollmilch 1L', 'Red Bull 250ml', 'Colgate Zahnpasta'],
  ///   ['Lebensmittel', 'Getränke', 'Drogerie', 'Pfand', 'Sonstiges'],
  /// );
  /// // → ['Lebensmittel', 'Getränke', 'Drogerie']
  /// ```
  Future<List<String>?> categorizeItems(
    List<String> items,
    List<String> availableCategories,
  ) async {
    if (items.isEmpty) return [];

    final ready = await ensureReady();
    if (!ready) return null;

    final prompt = _buildPrompt(items, availableCategories);
    debugPrint('[GemmaService] Prompt (${prompt.length} Zeichen) wird gesendet…');

    try {
      final response = await FlutterGemmaPlugin.instance.getResponse(prompt: prompt);
      debugPrint('[GemmaService] Antwort: $response');
      return _parseResponse(response ?? '', items.length, availableCategories);
    } catch (e, st) {
      debugPrint('[GemmaService] Inferenz-Fehler: $e\n$st');
      _statusMessage = 'Inferenz fehlgeschlagen: $e';
      await unloadModel();
      return null;
    }
  }

  // ── Private Hilfsmethoden ─────────────────────────────────────────────────

  Future<bool> _loadModel(String path) async {
    try {
      _statusMessage = 'Modell wird geladen…';
      debugPrint('[GemmaService] Lade Modell von: $path');

      await unloadModel();

      final docsDir = await getApplicationDocumentsDirectory();
      final expectedPath = p.join(docsDir.path, 'model.bin');
      if (path != expectedPath) {
        final src = File(path);
        if (!src.existsSync()) {
          throw Exception('Quelldatei nicht gefunden: $path');
        }
        await src.copy(expectedPath);
      }

      await FlutterGemmaPlugin.instance.init(
        maxTokens: 512,
        temperature: temperature,
        topK: 1,
        randomSeed: 1,
      );

      _isInitialized = true;
      _statusMessage = 'Modell bereit ✓';
      debugPrint('[GemmaService] Modell erfolgreich geladen.');
      return true;
    } catch (e, st) {
      debugPrint('[GemmaService] Fehler beim Laden: $e\n$st');
      _statusMessage = 'Ladefehler: $e';
      _isInitialized = false;
      return false;
    }
  }

  Future<String?> _copyModelToAppDir(String sourcePath) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final destPath = p.join(docsDir.path, 'model.bin');

      if (sourcePath == destPath) return destPath;

      final src = File(sourcePath);
      if (!src.existsSync()) {
        _statusMessage = 'Quelldatei nicht gefunden';
        return null;
      }

      debugPrint('[GemmaService] Kopiere Modell: $sourcePath → $destPath');
      await src.copy(destPath);
      return destPath;
    } catch (e) {
      debugPrint('[GemmaService] Kopierfehler: $e');
      _statusMessage = 'Kopierfehler: $e';
      return null;
    }
  }

  /// Erstellt den Inferenz-Prompt für die Kategorisierung.
  ///
  /// Sehr kurz und präzise gehalten, da Gemma 2B ein begrenztes Context-Window
  /// hat und kleine Modelle bei langen Prompts unzuverlässiger werden.
  String _buildPrompt(List<String> items, List<String> categories) {
    final catList = categories.join(', ');
    final itemLines = items
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value}')
        .join('\n');

    // Few-Shot-Prompt: 2 Beispiele geben dem Modell das Output-Format vor
    return '''Du bist ein Kassenbon-Kategorisierer. Antworte NUR mit einem JSON-Array.

Kategorien: $catList

Beispiel:
Artikel:
1. Vollmilch 1L
2. Red Bull 250ml
3. Colgate Zahnpasta
Antwort: ["Lebensmittel","Getränke","Drogerie"]

Artikel:
$itemLines
Antwort:''';
  }

  /// Parst die JSON-Antwort des Modells.
  ///
  /// Ist die Antwort kein valides JSON-Array oder hat die falsche Länge,
  /// wird versucht, so viele Kategorien wie möglich zu extrahieren. Fehlende
  /// Einträge werden mit 'Sonstiges' aufgefüllt.
  List<String>? _parseResponse(
    String response,
    int expectedCount,
    List<String> validCategories,
  ) {
    // JSON-Array aus der Antwort extrahieren (Modelle generieren manchmal
    // führende/nachfolgende Zeichen)
    final jsonMatch = RegExp(r'\[.*?\]', dotAll: true).firstMatch(response);
    if (jsonMatch == null) {
      debugPrint('[GemmaService] Kein JSON-Array in Antwort gefunden.');
      return null;
    }

    try {
      final raw = jsonMatch.group(0)!;
      // Einfaches Parsen ohne dart:convert-Import-Overhead via String-Split
      // (JSON-Array enthält nur Strings, daher sicher)
      final cleaned = raw
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
          .toList();

      // Jede extrahierte Kategorie gegen die valide Liste prüfen
      final result = <String>[];
      for (int i = 0; i < expectedCount; i++) {
        if (i < cleaned.length) {
          final candidate = cleaned[i];
          // Exakter Match (bevorzugt) oder case-insensitiver Fallback
          final matched = validCategories.firstWhere(
            (c) => c.toLowerCase() == candidate.toLowerCase(),
            orElse: () => 'Sonstiges',
          );
          result.add(matched);
        } else {
          result.add('Sonstiges');
        }
      }
      debugPrint('[GemmaService] Kategorien geparst: $result');
      return result;
    } catch (e) {
      debugPrint('[GemmaService] Parse-Fehler: $e');
      return null;
    }
  }
}
