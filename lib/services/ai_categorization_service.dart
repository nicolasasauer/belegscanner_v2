import 'package:flutter/foundation.dart';

import 'gemma_service.dart';

// ---------------------------------------------------------------------------
// AiCategorizationService
// ---------------------------------------------------------------------------

/// High-Level-Service für die KI-gestützte Artikel-Kategorisierung.
///
/// Stellt die Verbindung zwischen dem [ProcessorService] und dem
/// [GemmaService] her. Enthält die gesamte Fehlerbehandlungs- und
/// Fallback-Logik, sodass [ProcessorService] keine Abhängigkeit auf
/// [GemmaService] kennen muss.
///
/// **Nutzungsmuster in [ProcessorService]:**
/// ```dart
/// final aiService = AiCategorizationService();
/// final result = await aiService.categorize(
///   items: parsedItems,
///   existingCategories: keywordCategories,
///   availableCategories: CategoryService.availableCategories,
/// );
/// // result ist immer eine vollständige, gleich lange Liste – egal ob
/// // KI verfügbar ist oder nicht.
/// ```
class AiCategorizationService {
  const AiCategorizationService();

  /// Kategorisiert [items] mit dem lokalen Gemma-Modell.
  ///
  /// **Fallback-Verhalten:**
  /// 1. KI nicht aktiviert oder Modell nicht bereit → gibt [existingCategories]
  ///    unverändert zurück.
  /// 2. Inferenz schlägt fehl oder liefert ungültige Antwort → gibt
  ///    [existingCategories] zurück (keine Exception).
  /// 3. KI liefert kürzere Liste als [items] → fehlende Einträge werden
  ///    aus [existingCategories] oder 'Sonstiges' ergänzt.
  ///
  /// Die zurückgegebene Liste hat immer genau die gleiche Länge wie [items].
  Future<List<String>> categorize({
    required List<String> items,
    required List<String> existingCategories,
    required List<String> availableCategories,
  }) async {
    if (items.isEmpty) return [];

    final gemma = GemmaService.instance;

    // Schnell-Pfad: KI nicht aktiviert
    if (!gemma.isEnabled) {
      debugPrint('[AiCategorizationService] KI deaktiviert – Keyword-Kategorien beibehalten.');
      return _ensureLength(existingCategories, items.length);
    }

    // Nur die reinen Artikelnamen extrahieren (Format: "Name  Preis")
    final itemNames = items.map(_extractItemName).toList();

    try {
      final aiCategories = await gemma.categorizeItems(
        itemNames,
        availableCategories,
      );

      if (aiCategories == null) {
        // Modell nicht bereit oder Inferenz fehlgeschlagen
        debugPrint('[AiCategorizationService] Fallback auf Keyword-Kategorien.');
        return _ensureLength(existingCategories, items.length);
      }

      // KI-Kategorien mit Keyword-Kategorien zusammenführen:
      // KI-Ergebnis hat Vorrang, außer es ist 'Sonstiges' und das
      // Keyword-System hat etwas Spezifischeres gefunden.
      final merged = List<String>.generate(items.length, (i) {
        final aiCat = i < aiCategories.length ? aiCategories[i] : 'Sonstiges';
        final kwCat = i < existingCategories.length
            ? existingCategories[i]
            : 'Sonstiges';

        if (aiCat == 'Sonstiges' && kwCat != 'Sonstiges') {
          // Keyword weiß mehr als die KI → Keyword bevorzugen
          debugPrint('[AiCategorizationService] Item "${ itemNames[i]}": '
              'KI=Sonstiges, Keyword=$kwCat → Keyword gewählt');
          return kwCat;
        }
        return aiCat;
      });

      debugPrint('[AiCategorizationService] KI-Kategorisierung erfolgreich: $merged');
      return merged;
    } catch (e, st) {
      debugPrint('[AiCategorizationService] Unerwarteter Fehler: $e\n$st');
      return _ensureLength(existingCategories, items.length);
    }
  }

  /// Extrahiert den Artikelnamen aus dem kombinierten Format "Name  Preis".
  ///
  /// Beispiele:
  /// - "Vollmilch 1L  1,29" → "Vollmilch 1L"
  /// - "Red Bull 250ml  1,99" → "Red Bull 250ml"
  /// - "Pfand  0,25" → "Pfand"
  String _extractItemName(String item) {
    // Das Format aus ocr_service.dart ist "Name  Preis" (doppeltes Leerzeichen)
    final parts = item.split('  ');
    return parts.isNotEmpty ? parts.first.trim() : item.trim();
  }

  /// Stellt sicher, dass [list] genau [length] Einträge hat.
  ///
  /// Fehlende Einträge werden mit 'Sonstiges' aufgefüllt.
  List<String> _ensureLength(List<String> list, int length) {
    if (list.length == length) return list;
    return List<String>.generate(
      length,
      (i) => i < list.length ? list[i] : 'Sonstiges',
    );
  }
}
