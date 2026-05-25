import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/receipt.dart';
import 'ai_categorization_service.dart';  // NEU
import 'category_service.dart';           // NEU
import 'database_service.dart';
import 'gemma_service.dart';              // NEU
import 'ocr_service.dart';

// ---------------------------------------------------------------------------
// Shared-Preferences-Schlüssel
// ---------------------------------------------------------------------------

/// Schlüssel für die maximale Anzahl gleichzeitiger Verarbeitungsjobs.
const String kMaxConcurrentTasksKey = 'max_concurrent_tasks';

/// Standard-Wert für [kMaxConcurrentTasksKey].
const int kDefaultMaxConcurrentTasks = 2;

// ---------------------------------------------------------------------------
// ProcessorService
// ---------------------------------------------------------------------------

/// Verwaltet eine Warteschlange von OCR-Verarbeitungsaufgaben.
///
/// Verarbeitet Belege parallel bis zu [maxConcurrent] gleichzeitig.
/// Neue Aufgaben werden sofort in die Warteschlange aufgenommen; sobald ein
/// Slot frei wird, startet der nächste Job automatisch.
///
/// **Duplikatserkennung:** Vor dem Start jedes Jobs wird ein SHA-256-Hash
/// der Bilddatei berechnet (in einem Background-Isolate via [compute]).
/// Existiert bereits ein Beleg mit demselben Hash, wird der Job übersprungen
/// und der Zähler [skippedDuplicates] erhöht.
///
/// **KI-Kategorisierung:** Nach dem Receipt-Parsing wird optional eine
/// lokale Gemma-Inferenz durchgeführt, die die keyword-basierten Kategorien
/// verfeinert. Schlägt die KI fehl, bleiben die Keyword-Kategorien erhalten
/// (kein Breaking Change gegenüber v1).
///
/// Benachrichtigungen über Statusänderungen werden über [onReceiptUpdated]
/// weitergeleitet.
class ProcessorService {
  ProcessorService({
    required DatabaseService databaseService,
    this.maxConcurrent = kDefaultMaxConcurrentTasks,
  })  : _databaseService = databaseService,
        _aiService = const AiCategorizationService(); // NEU

  final DatabaseService _databaseService;
  final AiCategorizationService _aiService; // NEU

  /// Maximale Anzahl gleichzeitig laufender Verarbeitungsjobs.
  int maxConcurrent;

  /// Callback, der aufgerufen wird, wenn ein Beleg aktualisiert wurde.
  ValueChanged<Receipt>? onReceiptUpdated;

  /// Anzahl der übersprungenen Duplikate seit dem letzten Batch-Start.
  int skippedDuplicates = 0;

  /// Anzahl der Artikel, die die KI im aktuellen Batch kategorisiert hat.
  int totalAiCategorizedCount = 0;

  final Queue<_ProcessorTask> _queue = Queue();
  int _activeJobs = 0;
  final _uuid = const Uuid();

  // ---------------------------------------------------------------------------
  // Öffentliche API
  // ---------------------------------------------------------------------------

  /// Liest [maxConcurrent] aus den [SharedPreferences] und aktualisiert den Wert.
  /// Lädt außerdem die GemmaService-Einstellungen.
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    maxConcurrent =
        prefs.getInt(kMaxConcurrentTasksKey) ?? kDefaultMaxConcurrentTasks;

    // NEU: Gemma-Einstellungen laden
    await GemmaService.instance.loadSettings();
  }

  /// Speichert [maxConcurrent] in den [SharedPreferences].
  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kMaxConcurrentTasksKey, maxConcurrent);
  }

  /// Fügt einen neuen Verarbeitungsjob für [receipt] in die Warteschlange ein.
  void enqueue(Receipt receipt) {
    _queue.add(_ProcessorTask(receipt: receipt));
    _tryStartNext();
  }

  /// Markiert alle `'processing'`-Belege als `'failed'`.
  Future<void> markInterruptedAsFailed() async {
    final interrupted = await _databaseService.getProcessingReceipts();
    for (final receipt in interrupted) {
      final updated = receipt.copyWith(status: 'failed', progress: 0.0);
      await _databaseService.updateReceipt(updated);
      onReceiptUpdated?.call(updated);
    }
  }

  // ---------------------------------------------------------------------------
  // Interne Verarbeitungslogik
  // ---------------------------------------------------------------------------

  void _tryStartNext() {
    while (_activeJobs < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _activeJobs++;
      _processTask(task).then((_) {
        _activeJobs--;
        _tryStartNext();
      });
    }
  }

  Future<void> _processTask(_ProcessorTask task) async {
    final receipt = task.receipt;
    final tempPath = receipt.imagePath;

    if (tempPath == null || !File(tempPath).existsSync()) {
      final failed = receipt.copyWith(status: 'failed', progress: 0.0);
      await _databaseService.updateReceipt(failed);
      onReceiptUpdated?.call(failed);
      return;
    }

    try {
      // ── Schritt 1: SHA-256-Hash im Background-Isolate berechnen ──────────
      final hash = await compute(computeFileHash, tempPath);

      if (hash != null) {
        // ── Schritt 2: Duplikatsprüfung in der Datenbank ──────────────────
        final existingId =
            await _databaseService.findReceiptIdByFileHash(hash);
        if (existingId != null && existingId != receipt.id) {
          debugPrint(
              '[ProcessorService] Duplikat erkannt (hash=$hash, '
              'existingId=$existingId) – überspringe ${receipt.id}');
          await _databaseService.deleteReceipt(receipt.id);
          skippedDuplicates++;
          onReceiptUpdated?.call(receipt.copyWith(status: 'duplicate'));
          return;
        }
      }

      // ── Schritt 3: Fortschritt aktualisieren (20 %) ───────────────────────
      await _updateProgress(receipt, 0.20);

      // ── Schritt 4: OCR auf dem Haupt-Isolate ─────────────────────────────
      final inputImage = InputImage.fromFilePath(tempPath);
      final textRecognizer =
          TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText;
      try {
        recognizedText = await textRecognizer.processImage(inputImage);
      } finally {
        await textRecognizer.close();
      }

      final fullText = recognizedText.text;

      // ── Schritt 5: Bild permanent speichern (40 %) ───────────────────────
      await _updateProgress(receipt, 0.40);
      final permanentPath = await _persistImage(tempPath);

      // ── Schritt 6: Kategorien + Mappings laden + Parsing (60 %) ──────────
      await _updateProgress(receipt, 0.60);

      List<Map<String, dynamic>> categoryData = [];
      List<Map<String, dynamic>> productMappings = [];
      try {
        final cats = await _databaseService.getCategories();
        categoryData = cats.map((c) => c.toMap()).toList();
      } catch (e) {
        debugPrint(
            '[ProcessorService] Kategorien konnten nicht geladen werden: $e');
      }
      try {
        productMappings = await _databaseService.getProductMappings();
      } catch (e) {
        debugPrint(
            '[ProcessorService] Produkt-Mappings konnten nicht geladen werden: $e');
      }

      // Händler-Profil laden
      Map<String, dynamic>? vendorProfile;
      final preliminaryVendor = detectMerchant(fullText);
      if (preliminaryVendor != null) {
        debugPrint('[ProcessorService] Händler erkannt: $preliminaryVendor');
        try {
          vendorProfile =
              await _databaseService.getVendorProfile(preliminaryVendor);
        } catch (e) {
          debugPrint(
              '[ProcessorService] Vendor-Profil für "$preliminaryVendor" '
              'konnte nicht geladen werden: $e');
        }
      }

      // Räumliche Zeilendaten extrahieren
      final spatialLines = <Map<String, dynamic>>[];
      for (final block in recognizedText.blocks) {
        for (final line in block.lines) {
          final rect = line.boundingBox;
          spatialLines.add({
            'text': line.text,
            'top': rect.top.toDouble(),
            'bottom': rect.bottom.toDouble(),
            'left': rect.left.toDouble(),
            'right': rect.right.toDouble(),
            'centerY': ((rect.top + rect.bottom) / 2.0),
            'centerX': ((rect.left + rect.right) / 2.0),
          });
        }
      }

      // Text-Parsing im Background-Isolate (unverändert gegenüber v1)
      final result = await compute(parseOcrText, {
        'text': fullText,
        'categoryData': categoryData,
        'productMappings': productMappings,
        'spatialLines': spatialLines,
        if (vendorProfile != null) 'vendorProfile': vendorProfile,
      });

      final parsedItems = List<String>.from(result['items'] as List);
      final keywordCategories = List<String>.from(result['categories'] as List);

      // ── Schritt 6.5: KI-Kategorisierung (75 %) ───────────────────────────
      await _updateProgress(receipt, 0.75);

      final aiResult = await _aiService.categorize(
        items: parsedItems,
        existingCategories: keywordCategories,
        availableCategories: CategoryService.availableCategories,
      );

      totalAiCategorizedCount += aiResult.aiChangedCount;
      debugPrint('[ProcessorService] Finale Kategorien: ${aiResult.categories} '
          '(${aiResult.aiChangedCount} KI-Änderungen)');

      // ── Schritt 6.6: KI-Händlernamen-Extraktion (falls leer) ─────────────
      String? storeName = result['storeName'] as String?;
      if ((storeName == null || storeName.trim().length < 3) &&
          fullText.isNotEmpty &&
          GemmaService.instance.isEnabled) {
        final aiStoreName = await GemmaService.instance.extractStoreName(fullText);
        if (aiStoreName != null) {
          debugPrint('[ProcessorService] KI-Händlername: "$aiStoreName"');
          storeName = aiStoreName;
        }
      }

      // ── Schritt 7: Abgeschlossenen Beleg speichern (100 %) ───────────────
      final dateStr = result['date'] as String?;
      final parsedDate = dateStr != null ? DateTime.tryParse(dateStr) : null;

      final completed = receipt.copyWith(
        date: parsedDate ?? receipt.date,
        totalAmount: result['amount'] as double,
        items: parsedItems,
        categories: aiResult.categories,
        imagePath: permanentPath ?? tempPath,
        storeName: storeName,
        spatialData: result['spatialData'] as String?,
        rawText: fullText.isEmpty ? null : fullText,
        status: 'completed',
        progress: 1.0,
        fileHash: hash,
        aiCategorizedCount: aiResult.aiChangedCount > 0 ? aiResult.aiChangedCount : null,
      );

      await _databaseService.updateReceipt(completed);
      onReceiptUpdated?.call(completed);

      // ── Schritt 8: Vendor-Profil aktualisieren ────────────────────────────
      final detectedVendor = result['storeName'] as String?;
      final usedStrategy = result['usedStrategy'] as String?;
      if (detectedVendor != null &&
          parsedItems.isNotEmpty &&
          usedStrategy != null) {
        try {
          await _databaseService.upsertVendorProfile(
            detectedVendor,
            preferredStrategy: usedStrategy,
            incrementSuccess: true,
          );
        } catch (e) {
          debugPrint(
              '[ProcessorService] Vendor-Profil konnte nicht gespeichert werden: $e');
        }
      }
    } catch (e, st) {
      debugPrint('[ProcessorService] Fehler bei der Verarbeitung: $e\n$st');
      final failed = receipt.copyWith(status: 'failed', progress: 0.0);
      await _databaseService.updateReceipt(failed);
      onReceiptUpdated?.call(failed);
    }
  }

  Future<void> _updateProgress(Receipt receipt, double progress) async {
    final updated = receipt.copyWith(status: 'processing', progress: progress);
    await _databaseService.updateReceipt(updated);
    onReceiptUpdated?.call(updated);
  }

  Future<String?> _persistImage(String tempPath) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(docsDir.path, 'receipt_images'));
      if (!imagesDir.existsSync()) {
        await imagesDir.create(recursive: true);
      }
      if (tempPath.startsWith(docsDir.path)) {
        return tempPath;
      }
      final fileName = '${_uuid.v4()}${p.extension(tempPath)}';
      final permanentFile = File(p.join(imagesDir.path, fileName));
      await File(tempPath).copy(permanentFile.path);
      return permanentFile.path;
    } catch (e) {
      debugPrint(
          '[ProcessorService] Bild konnte nicht persistiert werden: $e');
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Interne Hilfsklassen
// ---------------------------------------------------------------------------

class _ProcessorTask {
  _ProcessorTask({required this.receipt});
  final Receipt receipt;
}
