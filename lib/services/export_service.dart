import 'dart:io';

import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';

import '../models/category.dart';
import '../models/receipt.dart';
import 'database_service.dart';
import 'ocr_service.dart';

/// Stellt statische Hilfsmethoden für den Export und das Teilen von
/// Belegen bereit (Belegbild-Sharing, Galerie-Speicherung, CSV-Export).
class ExportService {
  // Nur statische Methoden – keine Instanz nötig.
  ExportService._();

  // ---------------------------------------------------------------------------
  // Dateinamen
  // ---------------------------------------------------------------------------

  /// Generiert einen sprechenden Dateinamen für den Export des Belegbilds.
  ///
  /// Format: `YYYY-MM-DD_Händler_Betrag.jpg`
  /// Beispiel: `2026-03-23_Spar_10.76.jpg`
  ///
  /// Verbotene Zeichen (`/ \ : * ? " < > |`) und Leerzeichen werden aus dem
  /// Händlernamen entfernt; Dezimalkomma wird durch Punkt ersetzt.
  static String getExportFileName(Receipt receipt) {
    final dateStr = DateFormat('yyyy-MM-dd').format(receipt.date);
    final rawMerchant = receipt.items.isNotEmpty
        ? parseLineItem(receipt.items.first).name
        : 'Unbekannt';
    final sanitizedMerchant =
        rawMerchant.replaceAll(RegExp(r'[ /\\:*?"<>|]'), '');
    final merchant =
        sanitizedMerchant.isNotEmpty ? sanitizedMerchant : 'Unbekannt';
    final totalStr =
        receipt.totalAmount.toStringAsFixed(2).replaceAll(',', '.');
    return '${dateStr}_${merchant}_$totalStr.jpg';
  }

  // ---------------------------------------------------------------------------
  // Belegbild-Export
  // ---------------------------------------------------------------------------

  /// Erstellt eine temporäre Kopie des Belegbilds mit dem Smart-Dateinamen
  /// und öffnet das native Share-Sheet.
  ///
  /// Wirft eine Exception, wenn etwas schiefläuft (kein imagePath, I/O-Fehler).
  static Future<void> shareImage(Receipt receipt) async {
    final imagePath = receipt.imagePath;
    if (imagePath == null) return;

    final fileName = getExportFileName(receipt);
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, fileName);
    await File(imagePath).copy(tempPath);

    await Share.shareXFiles([XFile(tempPath)]);

    // Temporäre Datei nach dem Teilen aufräumen.
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();
  }

  /// Speichert das Belegbild mit dem Smart-Dateinamen in der Gerätegalerie.
  ///
  /// Gibt `true` zurück, wenn [ImageGallerySaver] Erfolg meldet, sonst
  /// `false`. Wirft eine Exception bei I/O- oder API-Fehlern.
  static Future<bool> saveImageToGallery(Receipt receipt) async {
    final imagePath = receipt.imagePath;
    if (imagePath == null) return false;

    final fileName = getExportFileName(receipt);
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, fileName);
    await File(imagePath).copy(tempPath);

    final result = await ImageGallerySaver.saveFile(tempPath);

    // Temporäre Datei nach dem Speichern aufräumen.
    final tempFile = File(tempPath);
    if (await tempFile.exists()) await tempFile.delete();

    return result is Map && result['isSuccess'] == true;
  }

  // ---------------------------------------------------------------------------
  // CSV-Export
  // ---------------------------------------------------------------------------

  /// Maskiert ein CSV-Feld gemäß RFC 4180.
  ///
  /// Enthält das Feld ein Semikolon oder Anführungszeichen, wird es in
  /// doppelte Anführungszeichen eingeschlossen.
  static String escapeCsvField(String value) {
    final cleaned = value.replaceAll('\n', ' ').replaceAll('\r', '');
    if (cleaned.contains(';') || cleaned.contains('"')) {
      return '"${cleaned.replaceAll('"', '""')}"';
    }
    return cleaned;
  }

  /// Baut den CSV-Inhalt für die übergebene Belegliste auf.
  ///
  /// Spalten: `Datum;Händler;Gesamtbetrag (EUR);Artikel`
  static String buildCsvContent(List<Receipt> receipts) {
    final buffer = StringBuffer();
    buffer.writeln('Datum;Händler;Gesamtbetrag (EUR);Artikel');

    final amountFormat = NumberFormat('#,##0.00', 'de_DE');
    final exportDateFormat = DateFormat('yyyy-MM-dd', 'de_DE');

    for (final receipt in receipts) {
      final date = exportDateFormat.format(receipt.date);
      final merchant = receipt.items.isNotEmpty
          ? escapeCsvField(receipt.items.first)
          : '';
      final amount = amountFormat.format(receipt.totalAmount);
      final items = receipt.items.length > 1
          ? escapeCsvField(receipt.items.sublist(1).join(' | '))
          : '';
      buffer.writeln('$date;$merchant;$amount;$items');
    }
    return buffer.toString();
  }

  /// Schreibt den CSV-Export in [cacheDir] und teilt ihn über das native
  /// Share-Sheet.
  static Future<void> shareCsv(
    List<Receipt> receipts,
    String cacheDir,
  ) async {
    final content = buildCsvContent(receipts);
    final file = File(p.join(cacheDir, 'belege_export.csv'));
    await file.writeAsString(content, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv')],
      subject: 'Bong-Scanner Export',
      text: 'Exportierte Belege aus der Bong-Scanner-App.',
    );
  }

  // ---------------------------------------------------------------------------
  // Knowledge Export/Import
  // ---------------------------------------------------------------------------

  /// Exportiert die gelernten Produkt-Mappings und benutzerdefinierten Kategorien
  /// als JSON und teilt die Datei via nativem Share-Sheet.
  static Future<void> exportKnowledge(DatabaseService dbService) async {
    final categories = await dbService.getCategories();
    final mappings = await dbService.getProductMappings();

    final data = {
      'categories': categories.map((c) => c.toMap()).toList(),
      'mappings': mappings,
    };

    final cacheDir = await getTemporaryDirectory();
    final file = File(p.join(cacheDir.path, 'belegscanner_knowledge.json'));
    await file.writeAsString(jsonEncode(data), flush: true);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'Bong-Scanner Knowledge Backup',
      text: 'Hier sind meine angelernten Bong-Scanner Erkennungs-Daten.',
    );
  }

  /// Importiert Knowledge-Daten aus einer JSON-Datei via FilePicker in die DB.
  /// 
  /// Gibt die Anzahl der importierten Mappings zurück, oder -1 bei Fehler.
  static Future<int> importKnowledge(DatabaseService dbService) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) {
        return 0; // Abgebrochen
      }

      final file = File(result.files.single.path!);
      final text = await file.readAsString();
      final data = jsonDecode(text) as Map<String, dynamic>;

      int mappingCount = 0;

      // Import categories (skip entries with names that already exist).
      if (data.containsKey('categories') &&
          data['categories'] is List<dynamic>) {
        final existingCats = await dbService.getCategories();
        final existingNames = existingCats.map((c) => c.name).toSet();

        final cats = data['categories'] as List<dynamic>;
        for (final c in cats) {
          if (c is! Map<String, dynamic>) continue;
          final name = c['name'] as String?;
          if (name != null && !existingNames.contains(name)) {
            await dbService.insertCategory(Category.fromMap(c));
          }
        }
      }

      if (data.containsKey('mappings') &&
          data['mappings'] is List<dynamic>) {
        final mappings = data['mappings'] as List<dynamic>;
        for (final m in mappings) {
          if (m is! Map<String, dynamic>) continue;
          final raw = m['raw_ocr_name'] as String?;
          final corrected = m['corrected_name'] as String?;
          if (raw != null && corrected != null) {
            await dbService.upsertProductMapping(raw, corrected, m['category_id'] as int?);
            mappingCount++;
          }
        }
      }

      return mappingCount;
    } catch (e) {
      return -1;
    }
  }
}
