import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_downloader/flutter_downloader.dart';

// ---------------------------------------------------------------------------
// SharedPreferences-Schlüssel
// ---------------------------------------------------------------------------

const String kGemmaEnabledKey = 'gemma_ai_enabled';
const String kGemmaModelPathKey = 'gemma_model_path';
const String kGemmaModelNameKey = 'gemma_model_name';
const String kGemmaModelSourceKey = 'gemma_model_source';
const String kGemmaModelSha256Key = 'gemma_model_sha256';
const String kGemmaModelInstalledAtKey = 'gemma_model_installed_at';
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

  /// Optionaler, Anzeigenamen des installierten Modells.
  String? modelName;

  /// Optionaler Ursprung / Quelle des installierten Modells.
  String? modelSource;

  /// Optionaler SHA-256-Hash der installierten Modelldatei.
  String? modelSha256;

  /// Installationszeitpunkt des aktuellen Modells.
  DateTime? modelInstalledAt;

  /// Inferenz-Temperatur (0.0–1.0). Niedrig = deterministischer Output.
  double temperature = 0.1;

  /// Ob das Modell gerade geladen und bereit für Inferenz ist.
  bool get isReady => _isInitialized;

  /// Kurze Status-Beschreibung für die UI.
  String get statusMessage => _statusMessage;

  bool _isInitialized = false;
  String _statusMessage = 'Nicht initialisiert';
  InferenceModel? _model;

  // ── Einstellungen ─────────────────────────────────────────────────────────

  /// Liest alle gespeicherten Einstellungen aus den [SharedPreferences].
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool(kGemmaEnabledKey) ?? false;
    modelPath = prefs.getString(kGemmaModelPathKey);
    modelName = prefs.getString(kGemmaModelNameKey);
    modelSource = prefs.getString(kGemmaModelSourceKey);
    modelSha256 = prefs.getString(kGemmaModelSha256Key);
    final installedAtString = prefs.getString(kGemmaModelInstalledAtKey);
    modelInstalledAt = installedAtString != null ? DateTime.tryParse(installedAtString) : null;
    temperature = prefs.getDouble(kGemmaTemperatureKey) ?? 0.1;
    debugPrint('[GemmaService] Einstellungen geladen: '
        'enabled=$isEnabled, modelPath=$modelPath, modelName=$modelName');
  }

  /// Speichert alle aktuellen Einstellungen in [SharedPreferences].
  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGemmaEnabledKey, isEnabled);
    if (modelPath != null) {
      await prefs.setString(kGemmaModelPathKey, modelPath!);
      if (modelName != null) await prefs.setString(kGemmaModelNameKey, modelName!);
      if (modelSource != null) await prefs.setString(kGemmaModelSourceKey, modelSource!);
      if (modelSha256 != null) await prefs.setString(kGemmaModelSha256Key, modelSha256!);
      if (modelInstalledAt != null) {
        await prefs.setString(kGemmaModelInstalledAtKey, modelInstalledAt!.toIso8601String());
      }
    } else {
      await prefs.remove(kGemmaModelPathKey);
      await prefs.remove(kGemmaModelNameKey);
      await prefs.remove(kGemmaModelSourceKey);
      await prefs.remove(kGemmaModelSha256Key);
      await prefs.remove(kGemmaModelInstalledAtKey);
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
  Future<String?> installAndLoadModel(String sourcePath, {String? sourceLabel, String? sourceUrl}) async {
    try {
      _statusMessage = 'Modell wird installiert…';
      final oldModelPath = modelPath;
      final oldModelName = modelName;
      final oldModelSource = modelSource;
      final oldModelSha = modelSha256;
      final oldModelInstalledAt = modelInstalledAt;
      final docsDir = await getApplicationDocumentsDirectory();
      final destPath = p.join(docsDir.path, 'model.bin');
      final backupPath = p.join(docsDir.path, 'model.bin.bak');
      final hadExistingModel = File(destPath).existsSync();

      await unloadModel();
      if (hadExistingModel) {
        try {
          await File(destPath).copy(backupPath);
        } catch (e) {
          debugPrint('[GemmaService] Backup des alten Modells fehlgeschlagen: $e');
        }
      }

      final permanentPath = await _copyModelToAppDir(sourcePath);
      if (permanentPath == null) {
        if (hadExistingModel && File(backupPath).existsSync()) {
          await _restoreBackup(backupPath, destPath);
        }
        return null;
      }

      modelPath = permanentPath;
      modelName = sourceLabel ?? p.basename(sourcePath);
      modelSource = sourceUrl ?? sourcePath;
      modelSha256 = await _computeFileSha256(permanentPath);
      modelInstalledAt = DateTime.now();
      await saveSettings();

      final ok = await _loadModel(permanentPath);
      if (!ok) {
        debugPrint('[GemmaService] Neues Modell konnte nicht geladen werden, altes Modell wird wiederhergestellt.');
        if (hadExistingModel && File(backupPath).existsSync()) {
          await _restoreBackup(backupPath, destPath);
          modelPath = oldModelPath;
          modelName = oldModelName;
          modelSource = oldModelSource;
          modelSha256 = oldModelSha;
          modelInstalledAt = oldModelInstalledAt;
          await saveSettings();
          await _loadModel(destPath);
        } else {
          await removeModel();
        }
        return null;
      }

      if (hadExistingModel && File(backupPath).existsSync()) {
        try {
          await File(backupPath).delete();
        } catch (_) {}
      }
      return permanentPath;
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
      final installed = await installAndLoadModel(
        candidate,
        sourceLabel: p.basename(uri.path),
        sourceUrl: url,
      );
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

  /// Versucht einen Hintergrund-Download via `flutter_downloader` und
  /// verwendet bei Nichterreichbarkeit das normale HTTP-Streaming als Fallback.
  Future<String?> downloadAndInstallModelBackground(
    String url, {
    void Function(double progress)? onProgress,
    String? expectedSha256,
  }) async {
    try {
      _statusMessage = 'Starte Hintergrund-Download…';
      final tmpDir = await getTemporaryDirectory();
      final savedDir = tmpDir.path;

      final taskId = await FlutterDownloader.enqueue(
        url: url,
        savedDir: savedDir,
        showNotification: true,
        openFileFromNotification: false,
      );

      // Poll den Task-Status bis zum Abschluss
      while (true) {
        final tasks = await FlutterDownloader.loadTasksWithRawQuery(query: 'task_id="$taskId"');
        if (tasks == null || tasks.isEmpty) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        final t = tasks.first;
        if (t.status == DownloadTaskStatus.complete) {
          final filePath = p.join(savedDir, t.filename ?? p.basename(Uri.parse(url).path));
          if (onProgress != null) try { onProgress(1.0); } catch (_) {}
          final candidate = await _tryExtractAndFindModel(filePath);
          if (candidate == null) return null;
          final installed = await installAndLoadModel(
            candidate,
            sourceLabel: p.basename(Uri.parse(url).path),
            sourceUrl: url,
          );
          return installed;
        } else if (t.status == DownloadTaskStatus.failed) {
          _statusMessage = 'Hintergrund-Download fehlgeschlagen';
          return null;
        } else {
          if (onProgress != null) try { onProgress((t.progress ?? 0) / 100.0); } catch (_) {}
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    } catch (e) {
      debugPrint('[GemmaService] Hintergrund-Download fehlgeschlagen, versuche Fallback: $e');
      // Fallback auf den einfachen HTTP-Downloader
      return downloadAndInstallModel(url, onProgress: onProgress, expectedSha256: expectedSha256);
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
    if (_model != null) {
      try {
        await _model!.close();
      } catch (e) {
        debugPrint('[GemmaService] Fehler beim Schließen: $e');
      } finally {
        _model = null;
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
      final model = _model!;
      final session = await model.createSession(
        temperature: temperature,
        randomSeed: 1,
        topK: 1,
        topP: 0.7,
      );
      final response = await session.getResponse();
      await session.close();
      debugPrint('[GemmaService] Antwort: $response');
      return _parseResponse(response, items.length, availableCategories);
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

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromFile(expectedPath)
          .install();

      _model = await FlutterGemma.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
        supportAudio: false,
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
    final extension = p.extension(sourcePath).toLowerCase();
    final normalizedExtension = extension.isEmpty ? '.bin' : extension;
    final destPath = p.join(docsDir.path, 'model$normalizedExtension');
    final tempPath = p.join(docsDir.path, 'model$normalizedExtension.tmp');
      if (sourcePath == destPath) return destPath;

      final src = File(sourcePath);
      if (!src.existsSync()) {
        _statusMessage = 'Quelldatei nicht gefunden';
        return null;
      }

      final tempFile = File(tempPath);
      if (tempFile.existsSync()) {
        await tempFile.delete();
      }

      debugPrint('[GemmaService] Kopiere Modell temporär: $sourcePath → $tempPath');
      await src.copy(tempPath);

      final destFile = File(destPath);
      if (destFile.existsSync()) {
        await destFile.delete();
      }
      await tempFile.rename(destPath);
      return destPath;
    } catch (e) {
      debugPrint('[GemmaService] Kopierfehler: $e');
      _statusMessage = 'Kopierfehler: $e';
      return null;
    }
  }

  Future<String?> _computeFileSha256(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      return sha256.convert(bytes).toString();
    } catch (e) {
      debugPrint('[GemmaService] SHA256-Berechnung fehlgeschlagen: $e');
      return null;
    }
  }

  Future<void> _restoreBackup(String backupPath, String destPath) async {
    try {
      final backupFile = File(backupPath);
      final destFile = File(destPath);
      if (destFile.existsSync()) {
        await destFile.delete();
      }
      await backupFile.rename(destPath);
    } catch (e) {
      debugPrint('[GemmaService] Backup-Wiederherstellung fehlgeschlagen: $e');
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
