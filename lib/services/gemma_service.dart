//import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// SharedPreferences-Schlüssel
// ---------------------------------------------------------------------------

const String kGemmaEnabledKey = 'gemma_ai_enabled';
const String kGemmaModelIdKey = 'gemma_model_id';
const String kGemmaTemperatureKey = 'gemma_temperature';
const String kHuggingFaceTokenKey = 'huggingface_token';

// ---------------------------------------------------------------------------
// Modell-Definitionen
// ---------------------------------------------------------------------------

/// Beschreibt ein verfügbares On-Device-Modell.
class ModelDefinition {
  final String id;
  final String name;
  final String description;
  final String sizeLabel;
  final int sizeMb;
  final String url;
  final ModelType modelType;
  final ModelFileType fileType;
  final String recommendedRam;
  final bool requiresHfToken;

  const ModelDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.sizeLabel,
    required this.sizeMb,
    required this.url,
    required this.modelType,
    this.fileType = ModelFileType.litertlm,
    required this.recommendedRam,
    this.requiresHfToken = true,
  });
}

/// Alle verfügbaren Modelle, aufsteigend nach Größe sortiert.
///
/// URLs zeigen auf litert-community auf Hugging Face.
/// Alle Modelle sind gated → HuggingFace-Token erforderlich.
const List<ModelDefinition> kAvailableModels = [
  ModelDefinition(
    id: 'gemma3-270m',
    name: 'Gemma 3 270M',
    description: 'Ultra-kompakt · Sehr schnell · Geringer RAM-Bedarf · '
        'Ideal für einfache Kategorisierung',
    sizeLabel: '~300 MB',
    sizeMb: 300,
    url: 'https://huggingface.co/litert-community/gemma-3-270m-it'
        '/resolve/main/gemma3-270m-it-q8.litertlm',
    modelType: ModelType.gemmaIt,
    recommendedRam: '2 GB+',
  ),
  ModelDefinition(
    id: 'gemma3-1b',
    name: 'Gemma 3 1B',
    description: 'Kompakt · Gutes Gleichgewicht aus Geschwindigkeit und '
        'Qualität',
    sizeLabel: '~700 MB',
    sizeMb: 700,
    url: 'https://huggingface.co/litert-community/Gemma3-1B-IT'
        '/resolve/main/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm',
    modelType: ModelType.gemmaIt,
    recommendedRam: '3 GB+',
  ),
  ModelDefinition(
    id: 'gemma4-e2b',
    name: 'Gemma 4 E2B',
    description: 'Neueste Generation · Beste Qualität bei moderater Größe · '
        'Empfohlen für die meisten Geräte',
    sizeLabel: '~2 GB',
    sizeMb: 2000,
    url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm'
        '/resolve/main/gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemma4,
    recommendedRam: '4 GB+',
  ),
  ModelDefinition(
    id: 'gemma4-e4b',
    name: 'Gemma 4 E4B',
    description: 'Maximale Qualität · Für leistungsstarke Geräte · '
        'Hoher RAM-Bedarf',
    sizeLabel: '~3.7 GB',
    sizeMb: 3700,
    url: 'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm'
        '/resolve/main/gemma-4-E4B-it.litertlm',
    modelType: ModelType.gemma4,
    recommendedRam: '6 GB+',
  ),
];

// ---------------------------------------------------------------------------
// GemmaService
// ---------------------------------------------------------------------------

/// Singleton-Service für die Verwaltung des lokalen Gemma-Modells.
///
/// Nutzt flutter_gemma's eingebautes Netzwerk-Download-System.
/// Alle Inferenzen laufen vollständig lokal – kein Cloud-Traffic.
class GemmaService {
  GemmaService._();
  static final GemmaService instance = GemmaService._();

  // ── Zustand ───────────────────────────────────────────────────────────────

  bool isEnabled = false;
  String? installedModelId;
  double temperature = 0.1;
  String? huggingFaceToken;

  bool get isReady => _isInitialized;
  String get statusMessage => _statusMessage;

  ModelDefinition? get installedModel => installedModelId == null
      ? null
      : kAvailableModels.where((m) => m.id == installedModelId).firstOrNull;

  bool _isInitialized = false;
  String _statusMessage = 'Nicht initialisiert';
  InferenceModel? _model;

  // ── Einstellungen ─────────────────────────────────────────────────────────

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    isEnabled = prefs.getBool(kGemmaEnabledKey) ?? false;
    installedModelId = prefs.getString(kGemmaModelIdKey);
    temperature = prefs.getDouble(kGemmaTemperatureKey) ?? 0.1;
    huggingFaceToken = prefs.getString(kHuggingFaceTokenKey);
    debugPrint('[GemmaService] Einstellungen geladen: '
        'enabled=$isEnabled, modelId=$installedModelId');
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kGemmaEnabledKey, isEnabled);
    await prefs.setDouble(kGemmaTemperatureKey, temperature);
    if (installedModelId != null) {
      await prefs.setString(kGemmaModelIdKey, installedModelId!);
    } else {
      await prefs.remove(kGemmaModelIdKey);
    }
    if (huggingFaceToken != null && huggingFaceToken!.isNotEmpty) {
      await prefs.setString(kHuggingFaceTokenKey, huggingFaceToken!);
    } else {
      await prefs.remove(kHuggingFaceTokenKey);
    }
  }

  // ── Modell-Download & Installation ───────────────────────────────────────

  /// Lädt ein Modell aus dem Netzwerk herunter und installiert es.
  ///
  /// [onProgress] erhält Werte 0–100.
  /// Gibt [true] zurück, wenn Installation und Laden erfolgreich waren.
  Future<bool> downloadAndInstall(
    ModelDefinition model, {
    void Function(int progress)? onProgress,
  }) async {
    try {
      _statusMessage = 'Download wird gestartet…';
      debugPrint('[GemmaService] Starte Download: ${model.name} (${model.url})');

      await unloadModel();

      await FlutterGemma.installModel(
        modelType: model.modelType,
        fileType: model.fileType,
      )
          .fromNetwork(
            model.url,
            token: huggingFaceToken,
          )
          .withProgress((p) {
            debugPrint('[GemmaService] Download: $p%');
            onProgress?.call(p);
          })
          .install();

      debugPrint('[GemmaService] Download abgeschlossen, lade Modell…');
      _statusMessage = 'Modell wird geladen…';

      final ok = await _loadModel(model);
      if (ok) {
        installedModelId = model.id;
        await saveSettings();
        debugPrint('[GemmaService] Modell installiert und bereit: ${model.id}');
      }
      return ok;
    } catch (e, st) {
      final msg = 'Download/Installation fehlgeschlagen: $e';
      debugPrint('[GemmaService] FEHLER: $msg\n$st');
      _statusMessage = msg;
      return false;
    }
  }

  // ── Modell-Lifecycle ──────────────────────────────────────────────────────

  /// Stellt sicher, dass das Modell geladen ist (lazy load).
  Future<bool> ensureReady() async {
    if (_isInitialized) return true;
    if (!isEnabled) {
      _statusMessage = 'KI deaktiviert';
      return false;
    }
    final model = installedModel;
    if (model == null) {
      _statusMessage = 'Kein Modell installiert';
      return false;
    }
    return _loadModel(model);
  }

  Future<bool> _loadModel(ModelDefinition model) async {
    try {
      _statusMessage = 'Modell wird geladen…';
      debugPrint('[GemmaService] Lade Modell: ${model.id} '
          '(ModelType=${model.modelType})');

      await unloadModel();

      _model = await FlutterGemma.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
        supportAudio: false,
      );

      _isInitialized = true;
      _statusMessage = 'Modell bereit ✓ (${model.name})';
      debugPrint('[GemmaService] Modell bereit.');
      return true;
    } catch (e, st) {
      final msg = 'Ladefehler: $e';
      debugPrint('[GemmaService] FEHLER beim Laden: $msg\n$st');
      _statusMessage = msg;
      _isInitialized = false;
      return false;
    }
  }

  Future<void> unloadModel() async {
    if (_model != null) {
      try {
        await _model!.close();
        debugPrint('[GemmaService] Modell entladen.');
      } catch (e) {
        debugPrint('[GemmaService] Fehler beim Entladen: $e');
      } finally {
        _model = null;
      }
    }
    _isInitialized = false;
    _statusMessage = 'Modell entladen';
  }

  Future<void> removeModel() async {
    await unloadModel();
    installedModelId = null;
    isEnabled = false;
    await saveSettings();
    _statusMessage = 'Kein Modell installiert';
    debugPrint('[GemmaService] Modell entfernt.');
  }

  // ── Inferenz ──────────────────────────────────────────────────────────────

  /// Kategorisiert Artikel mit dem lokalen Modell.
  ///
  /// Gibt [null] zurück bei Fehler → Aufrufer fällt auf Keyword-Kategorisierung zurück.
  Future<List<String>?> categorizeItems(
    List<String> items,
    List<String> availableCategories,
  ) async {
    if (items.isEmpty) return [];

    final ready = await ensureReady();
    if (!ready) {
      debugPrint('[GemmaService] Modell nicht bereit → Fallback auf Keywords');
      return null;
    }

    final prompt = _buildPrompt(items, availableCategories);
    debugPrint('[GemmaService] Sende Prompt (${prompt.length} Zeichen)…');

    try {
      final model = _model!;
      final session = await model.createSession(
        temperature: temperature,
        randomSeed: 1,
        topK: 1,
        topP: 0.7,
      );
      await session.addQueryChunk(Message(text: prompt, isUser: true));
      final response = await session.getResponse();
      await session.close();
      debugPrint('[GemmaService] Antwort erhalten: $response');
      return _parseResponse(response, items.length, availableCategories);
    } catch (e, st) {
      debugPrint('[GemmaService] Inferenz-Fehler: $e\n$st');
      _statusMessage = 'Inferenz fehlgeschlagen: $e';
      await unloadModel();
      return null;
    }
  }

  String _buildPrompt(List<String> items, List<String> categories) {
    final catList = categories.join(', ');
    final itemLines = items
        .asMap()
        .entries
        .map((e) => '${e.key + 1}. ${e.value}')
        .join('\n');
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

  List<String>? _parseResponse(
    String response,
    int expectedCount,
    List<String> validCategories,
  ) {
    final jsonMatch = RegExp(r'\[.*?\]', dotAll: true).firstMatch(response);
    if (jsonMatch == null) {
      debugPrint('[GemmaService] Kein JSON-Array in Antwort: $response');
      return null;
    }
    try {
      final raw = jsonMatch.group(0)!;
      final cleaned = raw
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ''))
          .toList();
      final result = <String>[];
      for (int i = 0; i < expectedCount; i++) {
        if (i < cleaned.length) {
          final candidate = cleaned[i];
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
