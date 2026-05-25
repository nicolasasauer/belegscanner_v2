import 'package:flutter/foundation.dart';

import 'gemma_service.dart';

// ---------------------------------------------------------------------------
// CategorizationResult
// ---------------------------------------------------------------------------

class CategorizationResult {
  final List<String> categories;

  /// Anzahl der Artikel, bei denen die KI die Keyword-Kategorie geändert hat.
  final int aiChangedCount;

  const CategorizationResult(this.categories, this.aiChangedCount);
}

// ---------------------------------------------------------------------------
// AiCategorizationService
// ---------------------------------------------------------------------------

/// High-Level-Service für die KI-gestützte Artikel-Kategorisierung.
///
/// Stellt die Verbindung zwischen dem [ProcessorService] und dem
/// [GemmaService] her. Enthält die gesamte Fehlerbehandlungs- und
/// Fallback-Logik, sodass [ProcessorService] keine Abhängigkeit auf
/// [GemmaService] kennen muss.
class AiCategorizationService {
  const AiCategorizationService();

  /// Kategorisiert [items] mit dem lokalen Gemma-Modell.
  ///
  /// Gibt immer eine vollständige [CategorizationResult] zurück – auch wenn
  /// die KI nicht verfügbar ist (dann aiChangedCount = 0).
  Future<CategorizationResult> categorize({
    required List<String> items,
    required List<String> existingCategories,
    required List<String> availableCategories,
  }) async {
    if (items.isEmpty) return const CategorizationResult([], 0);

    final gemma = GemmaService.instance;

    if (!gemma.isEnabled) {
      debugPrint('[AiCategorizationService] KI deaktiviert – Keyword-Kategorien beibehalten.');
      return CategorizationResult(_ensureLength(existingCategories, items.length), 0);
    }

    final itemNames = items.map(_extractItemName).toList();

    try {
      final aiCategories = await gemma.categorizeItems(
        itemNames,
        availableCategories,
      );

      if (aiCategories == null) {
        debugPrint('[AiCategorizationService] Fallback auf Keyword-Kategorien.');
        return CategorizationResult(_ensureLength(existingCategories, items.length), 0);
      }

      int changedCount = 0;
      final merged = List<String>.generate(items.length, (i) {
        final aiCat = i < aiCategories.length ? aiCategories[i] : 'Sonstiges';
        final kwCat = i < existingCategories.length ? existingCategories[i] : 'Sonstiges';

        if (aiCat == 'Sonstiges' && kwCat != 'Sonstiges') {
          debugPrint('[AiCategorizationService] Item "${itemNames[i]}": '
              'KI=Sonstiges, Keyword=$kwCat → Keyword gewählt');
          return kwCat;
        }

        if (aiCat != kwCat) changedCount++;
        return aiCat;
      });

      debugPrint('[AiCategorizationService] KI-Kategorisierung erfolgreich: $merged ($changedCount Änderungen)');
      return CategorizationResult(merged, changedCount);
    } catch (e, st) {
      debugPrint('[AiCategorizationService] Unerwarteter Fehler: $e\n$st');
      return CategorizationResult(_ensureLength(existingCategories, items.length), 0);
    }
  }

  String _extractItemName(String item) {
    final parts = item.split('  ');
    return parts.isNotEmpty ? parts.first.trim() : item.trim();
  }

  List<String> _ensureLength(List<String> list, int length) {
    if (list.length == length) return list;
    return List<String>.generate(
      length,
      (i) => i < list.length ? list[i] : 'Sonstiges',
    );
  }
}
