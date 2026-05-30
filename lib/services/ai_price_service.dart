import 'package:flutter/foundation.dart';

import 'gemma_service.dart';

// ---------------------------------------------------------------------------
// AiPriceResult
// ---------------------------------------------------------------------------

class AiPriceResult {
  /// KI-extrahierter Gesamtbetrag; null wenn nicht extrahiert.
  final double? total;

  /// Angereicherte Items im Format "Name  Preis" (Komma als Dezimaltrenner).
  /// Gleiche Länge wie die übergebene items-Liste.
  final List<String> items;

  const AiPriceResult({this.total, required this.items});
}

// ---------------------------------------------------------------------------
// AiPriceService
// ---------------------------------------------------------------------------

/// Ergänzt fehlende Preise und den Gesamtbetrag mit dem lokalen Gemma-Modell.
///
/// Wird nur aufgerufen, wenn:
/// - Artikel ohne Preis vorhanden sind, ODER
/// - der Gesamtbetrag fehlt (< 0,01 €)
///
/// Gibt null zurück wenn KI nicht verfügbar oder keine Anreicherung nötig.
class AiPriceService {
  const AiPriceService();

  Future<AiPriceResult?> enrichPrices({
    required String rawText,
    required List<String> currentItems,
    required double currentTotal,
  }) async {
    if (currentItems.isEmpty || rawText.isEmpty) return null;

    final gemma = GemmaService.instance;
    if (!gemma.isEnabled) return null;

    final missingCount = currentItems.where((i) => !i.contains('  ')).length;
    final noTotal = currentTotal < 0.01;

    if (missingCount == 0 && !noTotal) {
      debugPrint('[AiPriceService] Alle Preise vorhanden, keine Anreicherung nötig.');
      return null;
    }

    debugPrint('[AiPriceService] Starte Preisextraktion '
        '(fehlende Preise: $missingCount, Gesamtbetrag fehlt: $noTotal)');

    final itemNames = currentItems.map(_nameOnly).toList();
    final result = await gemma.extractPricesFromOcr(rawText, itemNames);
    if (result == null) return null;

    final enrichedItems = <String>[];
    for (int i = 0; i < currentItems.length; i++) {
      final original = currentItems[i];
      if (original.contains('  ')) {
        enrichedItems.add(original);
      } else {
        final aiPrice = i < result.prices.length ? result.prices[i] : null;
        if (aiPrice != null && aiPrice > 0 && aiPrice < 10000) {
          final name = original.trim();
          final priceStr = aiPrice.toStringAsFixed(2).replaceAll('.', ',');
          enrichedItems.add('$name  $priceStr');
          debugPrint('[AiPriceService] Preis ergänzt: "$name" → $priceStr');
        } else {
          enrichedItems.add(original);
        }
      }
    }

    final finalTotal = noTotal ? result.total : null;
    debugPrint('[AiPriceService] Anreicherung abgeschlossen: '
        'total=${finalTotal ?? "unverändert"}, '
        '${enrichedItems.where((i) => i.contains("  ")).length}/${enrichedItems.length} Artikel mit Preis');

    return AiPriceResult(total: finalTotal, items: enrichedItems);
  }

  String _nameOnly(String item) {
    final parts = item.split('  ');
    return parts.first.trim();
  }
}
