import 'package:flutter/foundation.dart';

import 'gemma_service.dart';

// ---------------------------------------------------------------------------
// AiExtractionResult
// ---------------------------------------------------------------------------

class AiExtractionResult {
  /// KI-extrahierter Gesamtbetrag (null wenn nicht erkannt).
  final double? total;

  /// Angereicherte Items im Format "Name  Preis" (Komma-Dezimal) oder "Name".
  final List<String> items;

  /// Nur Artikelnamen — für die anschließende KI-Kategorisierung.
  final List<String> itemNames;

  /// 1–2 Sätze was die KI gemacht hat (Anzahl Artikel, Gesamtbetrag, Runden).
  final String summary;

  /// Anzahl der durchgeführten KI-Runden (1 oder 2).
  final int rounds;

  const AiExtractionResult({
    this.total,
    required this.items,
    required this.itemNames,
    required this.summary,
    required this.rounds,
  });
}

// ---------------------------------------------------------------------------
// AiReceiptExtractionService
// ---------------------------------------------------------------------------

/// Extrahiert Artikelnamen, Preise und Gesamtbetrag aus OCR-Rohtext.
///
/// Runde 1: vollständige Extraktion aus dem Raw Text.
/// Runde 2 (optional): Korrekturhinweis wenn Summe nicht mit Gesamtbetrag
/// übereinstimmt (Toleranz: 0,05 €).
///
/// Gibt null zurück wenn KI deaktiviert, kein Text vorhanden oder alle
/// Runden fehlgeschlagen.
class AiReceiptExtractionService {
  const AiReceiptExtractionService();

  /// Summen-Toleranz in Euro (Kassenbons runden manchmal auf 0,01–0,05 €).
  static const double _tolerance = 0.05;

  Future<AiExtractionResult?> extractFromRawText({
    required String rawText,
    required double regexTotal,
  }) async {
    final gemma = GemmaService.instance;
    if (!gemma.isEnabled || rawText.isEmpty) return null;

    // ── Runde 1 ──────────────────────────────────────────────────────────────
    final r1 = await gemma.extractReceiptItems(rawText);
    if (r1 == null || r1.items.isEmpty) {
      debugPrint('[AiReceiptExtractionService] Runde 1 lieferte kein Ergebnis.');
      return null;
    }
    debugPrint('[AiReceiptExtractionService] Runde 1: '
        '${r1.items.length} Artikel, total=${r1.total}');

    final effectiveTotal = r1.total ?? (regexTotal > 0 ? regexTotal : null);
    final calc1 = _sumPrices(r1.items);

    // ── Validierung ───────────────────────────────────────────────────────────
    if (effectiveTotal != null &&
        effectiveTotal > 0 &&
        _allHavePrices(r1.items)) {
      final diff = (calc1 - effectiveTotal).abs();
      if (diff > _tolerance) {
        debugPrint('[AiReceiptExtractionService] Summen-Abweichung '
            '${diff.toStringAsFixed(2)}€ → Runde 2');

        // ── Runde 2 ────────────────────────────────────────────────────────
        final r2 = await gemma.extractReceiptItems(
          rawText,
          isRetry: true,
          previousCalculated: calc1,
          targetTotal: effectiveTotal,
        );

        if (r2 != null && r2.items.isNotEmpty) {
          final calc2 = _sumPrices(r2.items);
          final diff2 = (calc2 - effectiveTotal).abs();
          final corrected = diff2 <= _tolerance;
          debugPrint('[AiReceiptExtractionService] Runde 2: '
              '${r2.items.length} Artikel, diff=${diff2.toStringAsFixed(2)}€, '
              'korrigiert=$corrected');

          final finalTotal = r2.total ?? effectiveTotal;
          return AiExtractionResult(
            total: finalTotal,
            items: _toItemStrings(r2.items),
            itemNames: r2.items.map((i) => i.name).toList(),
            summary: _buildSummary(
              rounds: 2,
              count: r2.items.length,
              total: finalTotal,
              corrected: corrected,
              diff1: diff,
            ),
            rounds: 2,
          );
        }
        // Runde 2 schlug fehl → Runde-1-Ergebnis mit Hinweis verwenden
        return AiExtractionResult(
          total: effectiveTotal,
          items: _toItemStrings(r1.items),
          itemNames: r1.items.map((i) => i.name).toList(),
          summary: _buildSummary(
            rounds: 2,
            count: r1.items.length,
            total: effectiveTotal,
            corrected: false,
            diff1: diff,
          ),
          rounds: 2,
        );
      }
    }

    // ── Runde 1 ausreichend ───────────────────────────────────────────────────
    return AiExtractionResult(
      total: r1.total,
      items: _toItemStrings(r1.items),
      itemNames: r1.items.map((i) => i.name).toList(),
      summary: _buildSummary(
        rounds: 1,
        count: r1.items.length,
        total: effectiveTotal ?? 0,
        corrected: true,
      ),
      rounds: 1,
    );
  }

  // ── Hilfsmethoden ─────────────────────────────────────────────────────────

  double _sumPrices(List<({String name, double? price})> items) =>
      items.fold(0.0, (s, i) => s + (i.price ?? 0.0));

  bool _allHavePrices(List<({String name, double? price})> items) =>
      items.every((i) => i.price != null && i.price! > 0);

  List<String> _toItemStrings(List<({String name, double? price})> items) {
    return items.map((i) {
      if (i.price != null && i.price! > 0) {
        final priceStr = i.price!.toStringAsFixed(2).replaceAll('.', ',');
        return '${i.name}  $priceStr';
      }
      return i.name;
    }).toList();
  }

  String _buildSummary({
    required int rounds,
    required int count,
    required double total,
    required bool corrected,
    double? diff1,
  }) {
    final totalStr =
        total > 0 ? '${total.toStringAsFixed(2).replaceAll('.', ',')} €' : '?';
    final artikelStr = count == 1 ? '1 Artikel' : '$count Artikel';

    if (rounds == 1) {
      return 'KI erkannte $artikelStr, Gesamtbetrag $totalStr.';
    }

    final diffStr = diff1 != null
        ? ' (${diff1.toStringAsFixed(2).replaceAll('.', ',')} € Differenz)'
        : '';
    final resultStr = corrected ? 'Summe stimmt.' : 'Summe weicht weiterhin ab.';
    return 'KI brauchte 2 Runden$diffStr — $artikelStr erkannt, '
        'Gesamtbetrag $totalStr. $resultStr';
  }
}
