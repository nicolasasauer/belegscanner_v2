import 'dart:io';

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/receipt.dart';
import 'database_service.dart';

// ---------------------------------------------------------------------------
// Top-level Parsing-Funktionen (erforderlich für compute-Isolate)
// ---------------------------------------------------------------------------

/// Fallback-Name für Artikel, bei denen kein Name aus dem OCR-Text
/// ermittelt werden kann (Preis-Anker-Logik).
const String kUnknownItemName = 'Unbekannter Artikel';

// ---------------------------------------------------------------------------
// Normalisierung und Kategorisierung
// ---------------------------------------------------------------------------

/// Normalisiert einen Artikelnamen:
///   - Überflüssige Leerzeichen werden entfernt.
///   - Der Name wird in „Title Case" umgewandelt (erster Buchstabe jedes
///     Wortes groß, Rest klein).
///   - Bekannte OCR-Fehler werden korrigiert: eine führende `0` (Ziffer) in
///     einem Wort, dessen Rest Buchstaben enthält, wird durch `O` (Buchstabe)
///     ersetzt (z. B. „0lio" → „Olio").
///
/// Beispiele:
/// - "  RED   BULL  " → "Red Bull"
/// - "dmBio Tofu Rosso 200g" → "Dmbio Tofu Rosso 200g"
/// - "VOLLKORNBROT 750G" → "Vollkornbrot 750g"
/// - "0lio Naturale" → "Olio Naturale"
@visibleForTesting
String normalizeName(String name) {
  final trimmed = name.trim().replaceAll(_whitespaceRunRegex, ' ');
  return trimmed.split(' ').map((word) {
    if (word.isEmpty) return word;
    // OCR-Fehlerkorrektur: führende '0' (Ziffer) → 'O' (Buchstabe),
    // wenn der restliche Teil des Wortes Buchstaben enthält.
    var corrected = word;
    if (corrected.startsWith('0') &&
        corrected.length > 1 &&
        _lettersRegex.hasMatch(corrected.substring(1))) {
      corrected = 'O${corrected.substring(1)}';
    }
    return corrected[0].toUpperCase() + corrected.substring(1).toLowerCase();
  }).join(' ');
}

/// Hilfs-Regex: prüft, ob ein String mindestens einen Buchstaben enthält
/// (für die OCR-Fehlerkorrektur in [normalizeName]).
final RegExp _lettersRegex = RegExp(r'[A-Za-zÄÖÜäöüß]');

/// Hilfs-Regex: erkennt aufeinanderfolgende Leerzeichen (für [normalizeName]).
final RegExp _whitespaceRunRegex = RegExp(r'\s+');

/// Schlüsselwort-zu-Kategorie-Zuordnung für die automatische Kategorisierung.
///
/// Der Vergleich ist nicht case-sensitiv. Wenn ein Artikelname eines dieser
/// Schlüsselwörter enthält, wird die entsprechende Kategorie gesetzt.
const Map<String, String> categoryMap = {
  'Bio': 'Lebensmittel',
  'Tofu': 'Lebensmittel',
  'Milch': 'Lebensmittel',
  'Brot': 'Lebensmittel',
  'Obst': 'Lebensmittel',
  'Gemüse': 'Lebensmittel',
  'Fruchtaufstr': 'Lebensmittel',
  'Shampoo': 'Drogerie',
  'Zahnpasta': 'Drogerie',
  'Duschgel': 'Drogerie',
  'Balea': 'Drogerie',
  'Hygiene': 'Drogerie',
  'Seife': 'Drogerie',
  'Pfand': 'Pfand',
  'Leergut': 'Pfand',
  'Red Bull': 'Getränke',
  'Cola': 'Getränke',
  'Wasser': 'Getränke',
  'Saft': 'Getränke',
  'Wein': 'Getränke',
  'Bier': 'Getränke',
};

/// Ermittelt die Kategorie eines Artikelnamens anhand von [categoryMap].
///
/// Gibt „Sonstiges" zurück, wenn kein Schlüsselwort übereinstimmt.
///
/// Beispiele:
/// - "Dmbio Tofu Rosso 200g" → "Lebensmittel"
/// - "Pfand 0,25" → "Pfand"
/// - "Red Bull" → "Getränke"
/// - "Kugelschreiber" → "Sonstiges"
@visibleForTesting
String categorizeItem(String name) {
  final lowerName = name.toLowerCase();
  for (final entry in categoryMap.entries) {
    if (lowerName.contains(entry.key.toLowerCase())) {
      return entry.value;
    }
  }
  return 'Sonstiges';
}

/// Ermittelt die Kategorie eines Artikelnamens anhand einer dynamisch
/// geladenen Liste von Kategorie-Daten aus der Datenbank.
///
/// Jeder Eintrag in [categoryData] ist eine Map mit den Schlüsseln
/// `name` (String) und `keywords` (String, kommagetrennt).
///
/// Fällt auf „Sonstiges" zurück, wenn keine Übereinstimmung gefunden wird.
/// Ist [categoryData] leer, wird auf [categorizeItem] zurückgegriffen.
String _smartCategorize(
    String name, List<Map<String, dynamic>> categoryData) {
  if (categoryData.isEmpty) {
    return categorizeItem(name);
  }
  final lowerName = name.toLowerCase();
  for (final catMap in categoryData) {
    final kwString = catMap['keywords'] as String;
    for (final kw in kwString.split(',')) {
      final trimmed = kw.trim().toLowerCase();
      if (trimmed.isNotEmpty && lowerName.contains(trimmed)) {
        return catMap['name'] as String;
      }
    }
  }
  return 'Sonstiges';
}

/// Compiled Regex: Preis am Ende einer OCR-Einzelposten-Zeile.
///
/// Erkennt z. B. "BROT 750G  2,99", "MILCH 1L 1,49 A" oder
/// "dmBio Tofu Rosso 200g 1,65 2" (Tax-Code am Ende ist Buchstabe oder Ziffer).
/// Das führende `\s+` stellt sicher, dass der Preis durch mindestens ein
/// Leerzeichen vom Artikelnamen getrennt ist.
///
/// Der optionale Tax-Code (`[A-Za-z0-9]`) muss durch ein Leerzeichen vom Preis
/// getrennt sein (z. B. "1,49 A", "1,65 2"). Direkt angehängte Einheiten wie
/// "0,33L" (Volumenangabe ohne Leerzeichen) werden damit NICHT als Preis erkannt.
final RegExp lineItemPriceRegex =
    RegExp(r'\s+(\d{1,4}[.,]\d{2})(?:\s+[A-Za-z0-9])?\s*$');

/// Parst eine OCR-Zeile in einen Artikelnamen und einen optionalen Preis.
///
/// Gibt einen Named-Record `(name, price)` zurück. Wenn kein Preis erkannt
/// wird, enthält [name] die ursprüngliche [line] und [price] ist `null`.
///
/// Dynamische Bereinigung: Einzelne Großbuchstaben am Ende des extrahierten
/// Namens (Steuerklassen-Kennzeichen wie "A", "B", "C"), die durch ein
/// Leerzeichen vom eigentlichen Namen getrennt sind, werden automatisch
/// entfernt (z. B. "BROT A" → "BROT").
///
/// Beispiele:
/// - "dmBio Tofu Rosso 200g 1,65 2" → name: "dmBio Tofu Rosso 200g", price: 1.65
/// - "Brot 750g  2,49" → name: "Brot 750g", price: 2.49
/// - "Apfelstrudel A 2,50" → name: "Apfelstrudel", price: 2.50
/// - "1,65" → name: "1,65", price: null
@visibleForTesting
({String name, double? price}) parseLineItem(String line) {
  final match = lineItemPriceRegex.firstMatch(line);
  if (match == null) return (name: line, price: null);
  final price = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  var name = line.substring(0, match.start).trim();
  // Dynamische Bereinigung: Steuerklassen-Buchstaben (A, B, C …) am Ende
  // des Artikelnamens entfernen – erkennbar als einzelner Großbuchstabe
  // nach einem Leerzeichen (z. B. "ARTIKEL A" → "ARTIKEL").
  name = name.replaceAll(RegExp(r'\s+[A-Z]$'), '');
  return (name: name, price: price);
}

/// Extrahiert den Gesamtbetrag aus dem OCR-Text.
///
/// Sucht bevorzugt nach "SUMME" oder "TOTAL" (direkt daneben oder darunter),
/// dann nach anderen deutschen Schlüsselwörtern wie "Gesamtbetrag",
/// "Zahlbetrag", "Bar", und zuletzt nach EUR/€-Zeilen.
/// Unterstützt Punkt und Komma als Dezimaltrenner (z. B. 14,95 und 14.95).
@visibleForTesting
double parseAmountImpl(String text) {
  final pricePattern = RegExp(r'(\d{1,6}[.,]\d{2})');

  // Priorität 1: SUMME oder TOTAL – zeilenweise suchen, damit
  // Terminal-Daten (EUR 23,03) mit niedrigerer Priorität behandelt werden.
  final lines = text.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (RegExp(r'\b(?:SUMME|TOTAL)\b(?!-)', caseSensitive: false).hasMatch(line)) {
      // Preis direkt auf derselben Zeile
      final sameLine = pricePattern.firstMatch(line);
      if (sameLine != null) {
        final value =
            double.tryParse(sameLine.group(1)!.replaceAll(',', '.'));
        if (value != null && value > 0) return value;
      }
      // Preis auf der nächsten Zeile
      if (i + 1 < lines.length) {
        final nextLine = pricePattern.firstMatch(lines[i + 1].trim());
        if (nextLine != null) {
          final value =
              double.tryParse(nextLine.group(1)!.replaceAll(',', '.'));
          if (value != null && value > 0) return value;
        }
      }
    }
  }

  // Priorität 2: Weitere Gesamtbetrag-Schlüsselwörter (ohne EUR/€,
  // da diese auch in Terminal-Daten vorkommen).
  final RegExp amountKeywordRegex = RegExp(
    r'(?:gesamtbetrag|zahlbetrag|gesamt|betrag|amount|\bbar\b)\D*'
    r'(\d{1,6}[.,]\d{2})',
    caseSensitive: false,
  );
  final match2 = amountKeywordRegex.firstMatch(text);
  if (match2 != null) {
    final value =
        double.tryParse(match2.group(1)!.replaceAll(',', '.'));
    if (value != null && value > 0) return value;
  }

  // Priorität 3: EUR / €-Zeilen (niedrigere Priorität, da auch in
  // Terminal-Daten vorhanden sein können).
  final RegExp euroRegex = RegExp(
    r'(?:€|eur)\D*(\d{1,6}[.,]\d{2})',
    caseSensitive: false,
  );
  final match3 = euroRegex.firstMatch(text);
  if (match3 != null) {
    final value =
        double.tryParse(match3.group(1)!.replaceAll(',', '.'));
    if (value != null && value > 0) return value;
  }

  // Fallback: größten Betrag im Text suchen.
  //
  // Der Negative Lookahead `(?![.,\d%])` verhindert, dass Datumsbestandteile
  // (z. B. „23.03" aus „23.03.2026") und Prozentwerte (z. B. „20,00" aus
  // „20,00%") fälschlich als Preise gezählt werden: Auf eine gültige
  // Preis-Zahl darf keine weitere Ziffer, kein Komma, kein Punkt und kein
  // Prozentzeichen folgen.
  final RegExp fallbackPricePattern =
      RegExp(r'(\d{1,6}[.,]\d{2})(?![.,\d%])');
  double maxAmount = 0.0;
  for (final m in fallbackPricePattern.allMatches(text)) {
    final value = double.tryParse(m.group(1)!.replaceAll(',', '.')) ?? 0.0;
    if (value > maxAmount) {
      maxAmount = value;
    }
  }
  return maxAmount;
}

/// Formatiert einen Geldbetrag als String mit Komma als Dezimaltrenner
/// (z. B. 2.25 → "2,25"). Wird von [parseItemsHeuristic] verwendet.
String _formatPriceComma(double price) =>
    price.toStringAsFixed(2).replaceAll('.', ',');

/// Heuristische Artikel-Erkennung für OCR-Texte, bei denen Namen und Preise
/// vollständig getrennt in unterschiedlichen Textbereichen erscheinen
/// (z. B. OCR hat alle Namen gesammelt und alle Preise an anderer Stelle).
///
/// Diese Funktion wird von [parseItemsImpl] als Fallback aufgerufen, wenn
/// die primäre Look-Ahead-Logik keine Artikel gefunden hat.
///
/// [preferredStrategy] steuert, welche Sub-Strategie bevorzugt wird:
/// - `'auto'` (Standard): Tax-Code zuerst, dann Standard-Heuristik.
/// - `'tax_code'`: Nur Tax-Code-Strategie (SPAR-Kassenbons).
/// - `'standard'`: Nur Standard-Heuristik (dm-Kassenbons u. a.).
///
/// Algorithmus (Two-List-Pairing):
///   1. Jede Zeile wird durch einen aggressiven Junk-Filter geleitet
///      (ATU, EFSTA, Buchung, Contactless, GmbH, Payback, Hash-Codes, …).
///   2. **Tax-Code-Strategie** (für SPAR/österreichische Kassenbons):
///      - Preiszeilen mit Steuerklassen-Suffix (z. B. „1,59 A", „0,25 E") werden
///        separat in [taxCodePrices] gesammelt.
///      - Die Sammlung stoppt sobald die Summe der Tax-Code-Preise den
///        Gesamtbetrag des Belegs erreicht (verhindert Aufnahme von Subtotals
///        aus dem „Incl."-Abschnitt am Ende des Belegs).
///      - Sind Tax-Code-Preise vorhanden, werden die ersten N Namen aus
///        [tempNames] mit diesen Preisen gepaart (N = Anzahl Tax-Code-Preise).
///   3. **Standard-Strategie** (Fallback, z. B. für dm-Kassenbons):
///      - Alle Preis-Only-Zeilen werden in [tempPrices] gesammelt; Duplikate,
///        negative Beträge und MwSt-Beträge werden ignoriert.
///      - Match-Maker: letzte N Preise für N Namen (Summen/Terminalbeträge
///        stehen oft früh in der Liste).
@visibleForTesting
List<String> parseItemsHeuristic(String text,
    {String preferredStrategy = 'auto'}) {
  // ─── Aggressiver Junk-Filter ─────────────────────────────────────────────
  // Enthält alle bekannten Nicht-Artikel-Schlüsselwörter aus dm- und
  // SPAR-Kassenbons.
  // Hinweis: „öffnungszeiten" enthält das deutsche Sonderzeichen „ö", das
  // kein ASCII-\w-Zeichen ist; \b würde hier nicht korrekt greifen, daher
  // wird dieses Wort ohne Wortgrenzen als Substring-Muster eingesetzt.
  final junkLinePattern = RegExp(
    r'\bATU\b'                      // österreichische Steuernummer
    r'|\bEFSTA\b'                   // EFSTA-Finanzamt-Hash
    r'|\bBuchung\b'                 // Buchungs-/Zahlungszeile
    r'|\b[Cc]ontactless\b'          // kontaktloses Zahlen
    r'|\bZahlung\b|\bZahl\b'        // Zahlungszeile (inkl. OCR-Split "Zahl ung")
    r'|\bPayback\b|\bPAYBACK\b'     // Treuepunkte
    r'|\bVisa\b|\bMastercard\b'     // Zahlungsarten
    r'|\bGmbH\b'                    // Firmenbezeichnung
    r'|\bMarktgraben\b'             // dm-spezifische Adresszeile
    r'|\bInnsbruck\b'               // Ortsname
    r'|\bDanke\b'                   // Grußformel
    r'|\bEinkauf\b'                 // Kassentext (z. B. "Für diesen Einkauf")
    r'|\bMensch\b'                  // dm-Slogan "Hier bin ich Mensch"
    r'|öffnungszeiten'              // Öffnungszeiten-Hinweis
    r'|\bNettobetr\b'               // Netto-Betrag-Zeile
    r'|\bMWSt\b|\bMwSt\b|\bMHST\b' // Steuersatz-Labels
    r'|\bPunkte\b'                  // Payback-Punkte
    r'|\bDebit\b|\bCredit\b'        // Zahlungsart
    r'|\bEFT\b'                     // Electronic Funds Transfer
    r'|\bkauf\b'                    // dm-Slogan-Wort ("Hier kauf ich ein")
    r'|\bVerarbeitung\b'            // Terminal-Meldung "Verarbeitung OK"
    r'|\bKundenbeleg\b'             // Beleg-Bezeichnung
    r'|\bRabattmarkerl\b'           // SPAR-Rabattmarkerl-Hinweis
    r'|\bGutschein\b|\bGUTSCHEIN\b' // Rabatt-Gutschein
    r'|#',                          // Hash-Codes (z. B. #31514283*…)
    caseSensitive: false,
  );

  // Mengenberechnungs-Muster (z. B. "2 X 1,19", "4x1,59"): Diese Zeilen
  // sind keine Produktnamen und keine eigenständigen Preise.
  final qtyCalcPattern = RegExp(r'^\d+\s*[xX]\s*\d{1,4}[.,]\d{2}');

  // Preis-Only-Muster: Tax-Code muss durch Leerzeichen getrennt sein.
  final priceOnlyPattern =
      RegExp(r'^\d{1,4}[.,]\d{2}(?:\s+[A-Za-z0-9])?\s*$');

  // Tax-Code-Preis-Muster: Preis + PFLICHT-Leerzeichen + einzelner Großbuchstabe
  // (z. B. "1,59 A", "0,25 E", "1,39 B"). Kennzeichnet Artikel-Einzel­preise
  // auf österreichischen Kassenbons.
  final taxCodePricePattern =
      RegExp(r'^\d{1,4}[.,]\d{2}\s+[A-Z]\s*$');

  // Standalone-MwSt-Label: Preis auf der Folgezeile ist ein Steuerbetrag
  final mwstLabelPattern = RegExp(
    r'^\s*(?:MWSt|MwSt|MHST)\s*$',
    caseSensitive: false,
  );

  // Kurze Einzelzahl (1–2 Ziffern ohne Buchstaben, z. B. "2", "19")
  final pureShortNumberPattern = RegExp(r'^\d{1,2}$');

  final allLines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // ─── Gesamtbetrag für Tax-Code-Preisvalidierung ──────────────────────────
  // Wird genutzt, um bei SPAR-Kassenbons die Sammlung von Tax-Code-Preisen
  // zu stoppen, sobald ihre Summe den Gesamtbetrag erreicht.
  final receiptTotal = parseAmountImpl(text);

  final tempNames = <String>[];
  final tempPrices = <double>[];
  final seenPrices = <double>{};

  // Tax-Code-Preise (SPAR-Strategie): In Erscheinungsreihenfolge, ohne Dedup.
  final taxCodePrices = <double>[];
  double taxCodeSum = 0.0;

  for (int idx = 0; idx < allLines.length; idx++) {
    final line = allLines[idx];
    final prevLine = idx > 0 ? allLines[idx - 1] : '';

    // Junk-Filter: Zeile enthält bekannte Nicht-Artikel-Schlüsselwörter
    if (junkLinePattern.hasMatch(line)) continue;

    // Prozentsatz-Zeilen (z. B. "2=10,00%")
    if (line.contains('%')) continue;

    // Negative Beträge (z. B. "-3,90")
    if (line.startsWith('-')) continue;

    // Zeilen mit Doppelpunkt: Terminal-IDs, Labels (z. B. "Trm-Id:",
    // "Betrag EUR:", "SUMME:", "Acq-Id:", "(Basis: 10,51)")
    if (line.contains(':')) continue;

    // Zeilen, die mit einem Datum beginnen (z. B. "21.03.2026 13:45 …")
    if (RegExp(r'^\d{1,2}\.\d{1,2}\.').hasMatch(line)) continue;

    // Kartenummer-artige Zeichenketten (z. B. "1/1/1227**", "XXX9471")
    if (RegExp(r'\*{3,}|[Xx]{3,}|\d{10,}').hasMatch(line)) continue;

    // Kurze Einzelzahlen ("2", "19")
    if (pureShortNumberPattern.hasMatch(line)) continue;

    // Allein stehende Schlüsselwörter ohne Produktbezug
    if (RegExp(r'^(?:SUMME|TOTAL|GESAMT|EUR|€|excl|incl)\.?$',
            caseSensitive: false)
        .hasMatch(line)) continue;

    // Mengenberechnungs-Zeilen (z. B. "2 X 1,19") überspringen
    if (qtyCalcPattern.hasMatch(line)) continue;

    // Zeilen, die mit einer öffnenden Klammer beginnen (z. B. "(Basis: …)")
    if (line.startsWith('(')) continue;

    // Tax-Code-Preis-Zeile: Preis + Steuerklassen-Buchstabe (z. B. "1,59 A")
    // Wird parallel zu den normalen Preisen gesammelt (SPAR-Strategie).
    if (taxCodePricePattern.hasMatch(line)) {
      // Nur sammeln, bis die Summe den Gesamtbetrag erreicht hat
      if (receiptTotal <= 0 || taxCodeSum < receiptTotal - 0.005) {
        final rawPrice = line.split(RegExp(r'\s+'))[0].replaceAll(',', '.');
        final price = double.tryParse(rawPrice);
        if (price != null && price > 0) {
          taxCodePrices.add(price);
          taxCodeSum += price;
        }
      }
      // Tax-Code-Zeilen auch als normale Preis-Only-Zeilen behandeln
      // (für Standard-Fallback-Strategie)
    }

    // Preis-Zeile: Betrag in tempPrices aufnehmen
    if (priceOnlyPattern.hasMatch(line)) {
      // Steuerbeträge überspringen: Preis direkt nach einem MwSt-Label
      if (mwstLabelPattern.hasMatch(prevLine)) continue;

      final rawPrice = line.split(RegExp(r'\s+'))[0].replaceAll(',', '.');
      final price = double.tryParse(rawPrice);
      if (price != null && price > 0 && !seenPrices.contains(price)) {
        seenPrices.add(price);
        tempPrices.add(price);
      }
      continue;
    }

    // Produktzeile: muss mindestens einen Buchstaben enthalten
    if (!RegExp(r'[A-Za-zÄÖÜäöüß]').hasMatch(line)) continue;

    // Reine Codes/Kürzel ohne Leerzeichen (z. B. "XXX9471", "O503") filtern
    if (RegExp(r'^[A-Z0-9]{4,12}$').hasMatch(line)) continue;

    // Reine Zeitangaben (z. B. "13:46:00") filtern – werden bereits durch
    // den Doppelpunkt-Filter oben abgefangen, hier als Sicherheitsnetz.
    if (RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$').hasMatch(line)) continue;

    tempNames.add(line);
  }

  debugPrint(
      '[OCR-Heuristic] tempNames=$tempNames, tempPrices=$tempPrices, '
      'taxCodePrices=$taxCodePrices');

  if (tempNames.isEmpty) return [];

  // ─── Match-Maker: Namen und Preise zusammenführen ────────────────────────
  final result = <String>[];

  // ─── Strategie 1: Tax-Code-Preise (SPAR-Kassenbons) ─────────────────────
  // Wenn Tax-Code-Preise gefunden wurden UND ihre Anzahl ≤ Namen-Anzahl,
  // werden die ersten N Namen mit diesen Preisen gepaart.
  // Wird übersprungen, wenn preferredStrategy == 'standard'.
  if (preferredStrategy != 'standard' &&
      taxCodePrices.isNotEmpty &&
      taxCodePrices.length <= tempNames.length) {
    final n = taxCodePrices.length;
    for (int i = 0; i < n; i++) {
      result.add('${tempNames[i]}  ${_formatPriceComma(taxCodePrices[i])}');
    }
    for (final r in result) {
      final (:name, :price) = parseLineItem(r);
      debugPrint(
          '[OCR-Heuristic/TaxCode] Matched: Name=$name, Price=${price ?? "–"}');
    }
    return result;
  }

  // ─── Strategie 2: Standard-Heuristik (dm-Kassenbons) ────────────────────
  // Wird übersprungen, wenn preferredStrategy == 'tax_code' UND Tax-Code-
  // Preise gefunden wurden (d.h. Strategie 1 wurde versucht, lieferte aber
  // kein Ergebnis, weil taxCodePrices.length > tempNames.length).
  // Wenn jedoch gar keine Tax-Code-Preise gefunden wurden, ist der Bon
  // möglicherweise ein anderes Format – Fallback auf Standard-Heuristik.
  if (preferredStrategy == 'tax_code' && taxCodePrices.isNotEmpty) return [];
  if (tempPrices.isEmpty) return [];

  if (tempNames.length == tempPrices.length) {
    // Perfekte Übereinstimmung: paarweise in Reihenfolge des Erscheinens
    for (int i = 0; i < tempNames.length; i++) {
      result.add('${tempNames[i]}  ${_formatPriceComma(tempPrices[i])}');
    }
  } else if (tempPrices.length > tempNames.length) {
    // Mehr Preise als Namen: letzte N Preise nehmen
    // (Summen/Terminalbeträge erscheinen typischerweise früh in der Liste,
    // die Artikel-Preise am Ende)
    final n = tempNames.length;
    final pricesSlice = tempPrices.sublist(tempPrices.length - n);
    for (int i = 0; i < n; i++) {
      result.add('${tempNames[i]}  ${_formatPriceComma(pricesSlice[i])}');
    }
  } else {
    // Mehr Namen als Preise: so viele Paare wie möglich bilden
    for (int i = 0; i < tempPrices.length; i++) {
      result.add('${tempNames[i]}  ${_formatPriceComma(tempPrices[i])}');
    }
  }

  for (final r in result) {
    final (:name, :price) = parseLineItem(r);
    debugPrint('[OCR-Heuristic] Matched: Name=$name, Price=${price ?? "–"}');
  }

  return result;
}

/// Zerlegt den OCR-Text in Einzelzeilen und extrahiert Artikel per
/// Look-Ahead-Logik.
///
/// Algorithmus (ladenunabhängig / generisch):
///   1. Vorbereitung: Leere Zeilen und Strich-Trennlinien werden entfernt.
///   2. Header-Cut: Alle Zeilen vor dem ersten Datum (TT.MM.JJJJ) oder der
///      ersten Uhrzeit (HH:MM) werden übersprungen. Ist kein Anker vorhanden,
///      werden alle Zeilen verarbeitet. Zusätzlich werden typische
///      Header-Zeilen (z. B. mit „GmbH", „UID-Nr", Telefonnummern) ignoriert.
///   3. Footer-Cut: Sobald SUMME, TOTAL, GESAMT oder ZAHLBETRAG erscheint,
///      wird die Artikel-Suche beendet. Terminal-Daten, Payback und
///      Grußformeln dahinter werden vollständig ignoriert.
///   4. Müll-Muster: Herausgefiltert werden Zeilen mit mehr als 15
///      aufeinanderfolgenden Ziffern (Terminal-IDs/IBANs), Zeilen aus
///      ausschließlich Sonderzeichen (z. B. "------") sowie Zeilen mit
///      URLs oder E-Mail-Adressen.
///   5. OCR-Junk-Präfixe am Zeilenanfang (z. B. "CnBio", "unBio") werden
///      gestripped, sodass der Artikelname erhalten bleibt.
///   6. Look-Ahead-Erkennung (Artikel-Paar-Logik):
///      - Zeilen mit Text + Preis am Ende → direkt als Artikel übernommen.
///      - Reine Text-Zeilen gefolgt von einer Mengenberechnung
///        (z. B. "4 X 1,59") und dann einer Preis-Zeile →
///        zusammengeführt (Multi-Line-Artikel).
///      - Reine Text-Zeilen gefolgt von einer Preis-Zeile (Look-Ahead) →
///        zusammengeführt; aus der Preis-Zeile wird nur die erste Zahl
///        extrahiert (z. B. „2,25 2" → Preis 2,25).
///      - Standalone-Preis-Zeilen ohne vorherigen Namenstext erhalten den
///        Fallback-Namen „Unbekannter Artikel".
///      - Mengenberechnungs-Zeilen (z. B. "4 X 1,59") und reine
///        Zahlen ohne Dezimaltrenner werden ignoriert.
///   7. Heuristik-Fallback: Wenn Schritt 6 keine Artikel liefert (z. B.
///      weil der OCR-Text Namen und Preise vollständig getrennt darstellt),
///      wird [parseItemsHeuristic] als Fallback aufgerufen.
///
/// Jeder erkannte Treffer wird per [debugPrint] mit
/// `[OCR-Match] Found: Name=… Price=…` protokolliert.
@visibleForTesting
List<String> parseItemsImpl(String text,
    {String preferredStrategy = 'auto'}) {
  // ─── 1. Strukturelle Muster (Anker) ──────────────────────────────────────

  // Header-Cut: Datum (TT.MM.JJJJ) oder Uhrzeit (HH:MM) markiert das Ende
  // des Bon-Headers. Alle Zeilen davor werden übersprungen.
  final RegExp headerCutPattern = RegExp(
    r'\b\d{1,2}\.\d{1,2}\.\d{2,4}\b|\b\d{1,2}:\d{2}\b',
  );

  // Sperrliste für Header-Zeilen: Typische Bestandteile des Bon-Headers,
  // die als Artikel ignoriert werden sollen (GmbH, UID-Nr., Straßenangaben,
  // Telefonnummern). Diese Muster werden nur auf Header-Zeilen (vor dem
  // Date-Anchor) angewendet; innerhalb der Artikelsektion bleiben sie
  // unberührt.
  // Hinweis: „Marktgraben" ist eine typische Adresszeile im dm-Bon-Header
  // und wird daher explizit in die Sperrliste aufgenommen.
  final RegExp headerBlocklistPattern = RegExp(
    r'\bGmbH\b|UID-Nr|Marktgraben|\bTel\.?\s*\d|\b\d{3,}\s*[-/]\s*\d{3,}\b',
    caseSensitive: false,
  );

  // Footer-Cut: Diese Schlüsselwörter markieren das Ende der Artikel-Sektion.
  // Alles ab dieser Zeile (Terminal-Daten, Payback, Grußformeln) wird ignoriert.
  final RegExp footerPattern = RegExp(
    r'\b(?:SUMME|TOTAL|GESAMT|ZAHLBETRAG)\b',
    caseSensitive: false,
  );

  // ─── 2. Müll-Muster ──────────────────────────────────────────────────────

  // Mehr als 15 aufeinanderfolgende Ziffern (Terminal-IDs, IBANs)
  final RegExp manyDigitsPattern = RegExp(r'\d{15,}');

  // Nur Sonderzeichen (Trennlinien wie "------", "====="):
  // Zeilen ohne einen einzigen Buchstaben oder eine einzige Ziffer.
  final RegExp specialCharsOnlyPattern = RegExp(r'^[^A-Za-z0-9äöüÄÖÜß]+$');

  // URLs oder E-Mail-Adressen.
  // Das TLD-Muster [A-Za-z][A-Za-z0-9-]*\.(de|at|…) erfordert, dass der
  // Domain-Name mit einem Buchstaben beginnt, um Preismuster (z. B. "1,99")
  // nicht fälschlich zu treffen.
  final RegExp urlEmailPattern = RegExp(
    r'www\.|https?://|\S+@\S+|\b[A-Za-z][A-Za-z0-9-]*\.(de|at|com|org)\b',
    caseSensitive: false,
  );

  // ─── 3. OCR-Artefakt-Bereinigung ─────────────────────────────────────────
  // Bekannte OCR-Junk-Präfixe (z. B. 'CnBio', 'unBio', 'dnBio').
  final RegExp junkPrefixPattern = RegExp(r'^[A-Za-z]nBio\s+');

  // ─── 4. Artikel-Erkennungs-Muster ────────────────────────────────────────

  // Preis-Only: die ganze Zeile ist nur ein Preis (z. B. "1,65", "2,99 A").
  // Ein Tax-Code (Buchstabe oder Ziffer) muss durch ein Leerzeichen vom
  // Preis getrennt sein. "0,33L" (Volumen ohne Leerzeichen) wird damit NICHT
  // als Preis-Only-Zeile erkannt.
  final RegExp priceOnlyPattern = RegExp(
    r'^\d{1,4}[.,]\d{2}(?:\s+[A-Za-z0-9])?\s*$',
  );

  // Vollständiges Artikel-Muster: Text + Preis am Ende.
  // Lookahead stellt sicher, dass mindestens ein Buchstabe im Namensteil
  // enthalten ist, um reine Zahlenzeilen auszuschließen.
  // Der Tax-Code muss durch ein Leerzeichen vom Preis getrennt sein.
  final RegExp itemWithPricePattern = RegExp(
    r'(?=.*[A-Za-zÄÖÜäöüß]).+\s+\d{1,4}[.,]\d{2}(?:\s+[A-Za-z0-9])?\s*$',
  );

  // Mengenberechnungs-Muster: z. B. "4 X 1,59" oder "2x0,99"
  // Nur im Kontext von Multi-Line-Artikeln ausgewertet.
  final RegExp qtyCalcPattern = RegExp(
    r'^\d+\s*[xX]\s*\d{1,4}[.,]\d{2}',
  );

  // ─── Schritt 1: Zeilen aufteilen ─────────────────────────────────────────
  final allLines = text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // ─── Schritt 2: Header-Cut ───────────────────────────────────────────────
  // Überspringe alle Zeilen vor dem ersten Datum / der ersten Uhrzeit.
  // Wenn kein Anker gefunden wird, beginne von vorne (kein Header-Cut).
  // Zeilen vor dem Anker, die auf die Sperrliste passen (GmbH, UID-Nr,
  // Marktgraben, Telefonnummern), werden ebenfalls explizit ignoriert.
  int startIndex = 0;
  int headerAnchorIndex = -1;
  for (int i = 0; i < allLines.length; i++) {
    if (headerCutPattern.hasMatch(allLines[i])) {
      headerAnchorIndex = i;
      startIndex = i;
      break;
    }
  }
  // Sperrliste: Wenn kein Datum-Anker gefunden wurde, überspringe
  // führende Zeilen, die Header-Begriffe wie „GmbH", „UID-Nr", „Marktgraben"
  // oder Telefonnummern enthalten.
  if (headerAnchorIndex == -1) {
    while (startIndex < allLines.length &&
        headerBlocklistPattern.hasMatch(allLines[startIndex])) {
      startIndex++;
    }
  }

  // ─── Schritt 3: Footer-Cut ───────────────────────────────────────────────
  // Beende die Artikel-Suche sobald SUMME / TOTAL / GESAMT / ZAHLBETRAG
  // erscheint. Alles danach wird vollständig ignoriert.
  int endIndex = allLines.length;
  for (int i = startIndex; i < allLines.length; i++) {
    if (footerPattern.hasMatch(allLines[i])) {
      endIndex = i;
      break;
    }
  }

  // ─── Schritt 4: Müll filtern, OCR-Artefakte bereinigen ───────────────────
  final lines = allLines
      .sublist(startIndex, endIndex)
      .where((l) => !manyDigitsPattern.hasMatch(l))
      .where((l) => !specialCharsOnlyPattern.hasMatch(l))
      .where((l) => !urlEmailPattern.hasMatch(l))
      .map((l) => l.replaceFirst(junkPrefixPattern, '').trim())
      .where((l) => l.isNotEmpty)
      .toList();

  // ─── Schritt 5: Artikel per Look-Ahead-Logik erkennen ───────────────────
  final result = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    // Mengenberechnungs-Zeile (z. B. "4 X 1,59") ohne vorherigen
    // Artikel-Kontext → überspringen, damit "4 X" nicht als Name landet.
    if (qtyCalcPattern.hasMatch(line)) {
      i++;
      continue;
    }

    // Vollständiger Artikel: Name + Preis auf derselben Zeile
    if (itemWithPricePattern.hasMatch(line)) {
      result.add(line);
      final (:name, :price) = parseLineItem(line);
      debugPrint('[OCR-Match] Found: Name=$name, Price=${price ?? "–"}');
      i++;
      continue;
    }

    // Look-Ahead: Reine Text-Zeile mit Preis auf einer der Folgezeilen.
    // Bedingung: die aktuelle Zeile muss mindestens einen Buchstaben enthalten,
    // damit reine Zahlenzeilen (z. B. MwSt-Prozentsätze) nicht als Namen
    // behandelt werden.
    final bool nameHasLetter = RegExp(r'[A-Za-zÄÖÜäöüß]').hasMatch(line);
    if (nameHasLetter) {
      // Fall A: Name | Mengenberechnung (z. B. "4 X 1,59") | Gesamtpreis
      //         → Multi-Line-Artikel: Name mit Gesamtpreis zusammenführen.
      if (i + 2 < lines.length &&
          qtyCalcPattern.hasMatch(lines[i + 1]) &&
          priceOnlyPattern.hasMatch(lines[i + 2])) {
        final merged = '$line  ${lines[i + 2].trim()}';
        result.add(merged);
        final (:name, :price) = parseLineItem(merged);
        debugPrint(
            '[OCR-Match] Found (multi-line): Name=$name, Price=${price ?? "–"}');
        i += 3;
        continue;
      }

      // Fall B (Look-Ahead): Name | Preis-Zeile (beginnt mit X,XX).
      // Preis-Extraktion: Aus der Preis-Zeile wird nur die erste Zahl
      // verwendet (z. B. aus „2,25 2" wird Preis 2,25).
      if (i + 1 < lines.length &&
          priceOnlyPattern.hasMatch(lines[i + 1])) {
        final merged = '$line  ${lines[i + 1].trim()}';
        result.add(merged);
        final (:name, :price) = parseLineItem(merged);
        debugPrint('[OCR-Match] Found: Name=$name, Price=${price ?? "–"}');
        i += 2;
        continue;
      }
    }

    // Standalone-Preis-Zeile (kein Namenstext in dieser Iteration):
    // Preis-First-Logik: Preis wird als Artikel mit Fallback-Name gewertet.
    if (priceOnlyPattern.hasMatch(line)) {
      final merged = '$kUnknownItemName  ${line.trim()}';
      result.add(merged);
      final (:name, :price) = parseLineItem(merged);
      debugPrint('[OCR-Match] Found (fallback): Name=$name, Price=${price ?? "–"}');
      i++;
      continue;
    }

    // Text-Zeile ohne zugehörigen Preis → ignorieren
    i++;
  }

  // ─── Schritt 6: Heuristik-Fallback für scrambled Receipts ────────────────
  // Wenn die primäre Look-Ahead-Logik keine Artikel gefunden hat (z. B. weil
  // der OCR-Text Namen und Preise vollständig getrennt darstellt und SUMME
  // sehr früh im Text erscheint), greift die Heuristik-Queue-Logik.
  if (result.isEmpty) {
    return parseItemsHeuristic(text, preferredStrategy: preferredStrategy);
  }

  return result;
}



/// Versucht, ein Druckdatum im Format DD.MM.YYYY aus dem OCR-Text zu extrahieren.
///
/// Gibt `null` zurück, wenn kein valides Datum gefunden wird.
String? detectDate(String text) {
  final datePattern = RegExp(r'\b(\d{1,2})\.(\d{1,2})\.(\d{2,4})\b');
  for (final match in datePattern.allMatches(text)) {
    try {
      final day = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      var year = int.parse(match.group(3)!);
      if (year < 100) year += 2000;
      if (day > 0 && day <= 31 && month > 0 && month <= 12 && year >= 2000 && year <= 2100) {
        return DateTime(year, month, day).toIso8601String();
      }
    } catch (_) {}
  }
  return null;
}

/// Versucht, einen Händler-/Geschäftsnamen aus dem OCR-Text zu extrahieren.
/// Sucht nach typischen österreichischen/deutschen Handelsketten.
String? detectMerchant(String text) {
  final lowerText = text.toLowerCase();
  final knownMerchants = [
    'billa', 'billa plus', 'spar', 'eurospar', 'interspar', 'hofer', 
    'lidl', 'penny', 'dm', 'bipa', 'mueller', 'müller', 'rewe', 
    'zielpunkt', 'merkur'
  ];

  // Merchants that must keep their exact canonical casing.
  const canonicalNames = {
    'dm': 'dm',
    'mueller': 'Müller',
    'müller': 'Müller',
  };

  for (final merchant in knownMerchants) {
    if (lowerText.contains(merchant)) {
      if (canonicalNames.containsKey(merchant)) {
        return canonicalNames[merchant];
      }
      // Default: title-case each word.
      return merchant
          .split(' ')
          .map((w) => w[0].toUpperCase() + w.substring(1))
          .join(' ');
    }
  }

  return null;
}

/// Maximale Y-Abstand (in Pixeln) zwischen dem vertikalen Mittelpunkt eines
/// Artikelnamens und eines Preises, damit sie als "auf gleicher Zeile liegend"
/// gelten.
///
/// **Begründung für 20 px:**
/// Bei einem typischen Belegfoto (ca. 1080 × 1920 px) ist eine gedruckte Zeile
/// auf dem physischen Bon etwa 8–12 Pixel hoch. OCR-Ungenauigkeiten und
/// leichte Bildschiefstellungen verschieben den ermittelten `centerY`-Wert um
/// ±3–8 Pixel. Ein Korridor von 20 Pixeln deckt zuverlässig dieselbe Zeile ab
/// (Δ < 10 px typisch), ohne auf die nächste Bon-Zeile überzuspringen
/// (Zeilenabstand > 20 px bei gängigen Kassenbons).
///
/// Hinweis: Bei sehr hochauflösenden Scans oder stark verzerrten Bildern kann
/// ein größerer Wert sinnvoll sein. Eine künftige Konfigurationsmöglichkeit ist
/// explizit vorgesehen.
///
/// Wird in [parseSpatialItems] für die Korridor-Zuordnung verwendet.
const double kSpatialYCorridor = 20.0;

/// Versucht, Artikelnamen und Preise anhand ihrer Bounding-Box-Koordinaten
/// (Y-Achsen-Korridor) zuzuordnen.
///
/// Diese Funktion ist für den Einsatz in einem Background-Isolate konzipiert:
/// Sie erwartet ausschließlich plain-Dart-Daten (keine UI-Objekte).
///
/// [spatialLines] ist eine Liste von Maps mit den Schlüsseln:
///   - `'text'` (String): Textinhalt der Zeile
///   - `'top'` (double): oberer Rand der Bounding Box in Pixeln
///   - `'bottom'` (double): unterer Rand der Bounding Box in Pixeln
///   - `'left'` (double): linker Rand
///   - `'right'` (double): rechter Rand
///   - `'centerY'` (double): vertikaler Mittelpunkt `(top + bottom) / 2`
///   - `'centerX'` (double): horizontaler Mittelpunkt `(left + right) / 2`
///
/// Algorithmus (Zwei-Spalten-Modell):
///   1. Alle Zeilen werden in Name-Kandidaten und Preis-Kandidaten aufgeteilt.
///   2. Für jeden Artikel-Kandidaten wird ein passender Preis gesucht, dessen
///      `centerY` maximal [kSpatialYCorridor] Pixel abweicht.
///   3. Sind alle Preise auf der rechten Seite (rechte Spalte) und alle
///      Namen auf der linken, wird zusätzlich eine spaltenbasierte Paarung
///      nach Erscheinungsreihenfolge versucht.
///
/// Gibt eine leere Liste zurück, wenn keine sinnvollen Paare gefunden werden.
@visibleForTesting
List<String> parseSpatialItems(List<Map<String, dynamic>> spatialLines) {
  if (spatialLines.isEmpty) return [];

  final priceRegex = RegExp(r'^\d{1,4}[.,]\d{2}(?:\s+[A-Za-z0-9])?\s*$');
  final nameRequiresLetterRegex = RegExp(r'[A-Za-zÄÖÜäöüß]');
  final junkPattern = RegExp(
    r'\bATU\b|\bEFSTA\b|\bGmbH\b|\bSUMME\b|\bTOTAL\b|\bGESAMT\b'
    r'|\bZAHLBETRAG\b|\bPayback\b|\bMWSt\b|\bMwSt\b|\bUID-Nr\b'
    r'|\bBuchung\b|\bContactless\b|\bVisa\b|\bMastercard\b',
    caseSensitive: false,
  );

  // Trenne alle räumlichen Zeilen in Namen- und Preis-Kandidaten.
  final nameCandidates = <Map<String, dynamic>>[];
  final priceCandidates = <Map<String, dynamic>>[];

  for (final line in spatialLines) {
    final text = (line['text'] as String).trim();
    if (text.isEmpty) continue;
    if (junkPattern.hasMatch(text)) continue;
    if (text.contains('%')) continue;
    if (text.startsWith('-')) continue;
    if (text.contains(':') && !priceRegex.hasMatch(text)) continue;

    if (priceRegex.hasMatch(text)) {
      priceCandidates.add(line);
    } else if (nameRequiresLetterRegex.hasMatch(text)) {
      nameCandidates.add(line);
    }
  }

  if (nameCandidates.isEmpty || priceCandidates.isEmpty) return [];

  // Korridor-Zuordnung: für jeden Namen den Preis mit geringstem Y-Abstand
  // suchen (innerhalb des erlaubten Korridors).
  final result = <String>[];
  final usedPriceIndices = <int>{};

  for (final nameEntry in nameCandidates) {
    final nameCenterY = nameEntry['centerY'] as double;
    int bestIdx = -1;
    double bestDelta = double.infinity;

    for (int j = 0; j < priceCandidates.length; j++) {
      if (usedPriceIndices.contains(j)) continue;
      final priceCenterY = priceCandidates[j]['centerY'] as double;
      final delta = (nameCenterY - priceCenterY).abs();
      if (delta < kSpatialYCorridor && delta < bestDelta) {
        bestDelta = delta;
        bestIdx = j;
      }
    }

    if (bestIdx >= 0) {
      usedPriceIndices.add(bestIdx);
      final nameText = (nameEntry['text'] as String).trim();
      final priceText = (priceCandidates[bestIdx]['text'] as String).trim();
      // Steuerklassen-Buchstaben am Ende des Namens entfernen (z. B. "BROT A")
      final cleanName = nameText.replaceAll(RegExp(r'\s+[A-Z]$'), '');
      result.add('$cleanName  $priceText');
      debugPrint(
          '[Spatial-Match] Name="$cleanName" ↔ Preis="$priceText" '
          '(ΔY=${bestDelta.toStringAsFixed(1)}px)');
    }
  }

  // Spaltenbasierter Fallback: Wenn die Korridor-Zuordnung erfolgreich war,
  // zurückgeben. Ansonsten versuchen, Namen und Preise nach Index zu paaren,
  // falls sie geometrisch in zwei Spalten getrennt sind.
  if (result.isNotEmpty) return result;

  // Keine Korridor-Paare gefunden – spaltenbasierte Paarung nach Index.
  final n = nameCandidates.length < priceCandidates.length
      ? nameCandidates.length
      : priceCandidates.length;
  for (int i = 0; i < n; i++) {
    final nameText =
        (nameCandidates[i]['text'] as String).trim()
            .replaceAll(RegExp(r'\s+[A-Z]$'), '');
    final priceText = (priceCandidates[i]['text'] as String).trim();
    result.add('$nameText  $priceText');
    debugPrint('[Spatial-Fallback] Name="$nameText" ↔ Preis="$priceText"');
  }

  return result;
}

/// Top-level-Funktion für [compute]: Parst OCR-Text und gibt Betrag,
/// normalisierte Artikel-Liste und Kategorien zurück.
///
/// Erwartet eine Map mit den Schlüsseln:
/// - `'text'`: der zu parsende OCR-Rohtext (String)
/// - `'categoryData'`: Liste von Kategorie-Maps aus der Datenbank
///   (jede Map hat `name` und `keywords`). Kann leer sein – dann greift der
///   statische [categoryMap]-Fallback.
/// - `'productMappings'` *(optional)*: Liste von Maps aus der Tabelle
///   `product_mappings` (Schlüssel: `raw_ocr_name`, `corrected_name`,
///   `category_id`). Wenn ein normalisierter Artikelname mit einem
///   `raw_ocr_name` übereinstimmt, wird er automatisch durch
///   `corrected_name` ersetzt und die gespeicherte Kategorie zugewiesen.
/// - `'spatialLines'` *(optional)*: Liste räumlicher Zeilendaten aus ML Kit
///   (Schlüssel: `text`, `top`, `bottom`, `left`, `right`, `centerY`,
///   `centerX`). Wenn angegeben, wird [parseSpatialItems] als primäre
///   Matching-Strategie bevorzugt (Y-Achsen-Korridor-Logik).
/// - `'vendorProfile'` *(optional)*: Map mit dem Händler-Profil aus der
///   Datenbank (Schlüssel: `preferred_strategy`). Wenn vorhanden, wird die
///   bevorzugte Parsing-Strategie des Händlers verwendet.
///
/// Gibt zusätzlich `'usedStrategy'` zurück: die tatsächlich verwendete
/// Parsing-Strategie (`'spatial'`, `'tax_code'` oder `'standard'`).
///
/// Nach dem Extrahieren der Artikel werden [normalizeName] und
/// [_smartCategorize] auf jeden Artikel angewendet, sodass die
/// zurückgegebenen Items bereits normalisierte Namen tragen und die
/// Kategorien-Liste parallel befüllt ist.
///
/// Diese Funktion ist öffentlich, damit sie auch aus dem [ProcessorService]
/// heraus in einem Background-Isolate via [compute] aufgerufen werden kann.
Map<String, dynamic> parseOcrText(Map<String, dynamic> params) {
  final text = params['text'] as String;
  final rawCategoryData = params['categoryData'] as List<dynamic>? ?? [];
  final categoryData = rawCategoryData.cast<Map<String, dynamic>>();

  // Produkt-Mappings für den semantischen Lern-Loop laden.
  final rawMappings = params['productMappings'] as List<dynamic>? ?? [];
  final productMappings = rawMappings.cast<Map<String, dynamic>>();

  // Räumliche Zeilendaten für Y-Achsen-Korridor-Matching.
  final rawSpatialLines = params['spatialLines'] as List<dynamic>? ?? [];
  final spatialLines = rawSpatialLines.cast<Map<String, dynamic>>();

  // Händler-Profil für die bevorzugte Parsing-Strategie.
  final vendorProfile =
      params['vendorProfile'] as Map<String, dynamic>?;
  final preferredStrategy =
      (vendorProfile?['preferred_strategy'] as String?) ?? 'auto';

  // Primäre Strategie: Spatial-Matching, wenn Bounding-Box-Daten vorhanden.
  List<String> rawItems;
  String? usedStrategy;
  if (spatialLines.isNotEmpty) {
    rawItems = parseSpatialItems(spatialLines);
    if (rawItems.isEmpty) {
      // Kein räumliches Ergebnis → klassische Text-Parsing-Logik.
      rawItems = parseItemsImpl(text, preferredStrategy: preferredStrategy);
      usedStrategy = _inferHeuristicStrategy(text, rawItems);
    } else {
      usedStrategy = 'spatial';
    }
  } else {
    rawItems = parseItemsImpl(text, preferredStrategy: preferredStrategy);
    usedStrategy = _inferHeuristicStrategy(text, rawItems);
  }

  final normalizedItems = <String>[];
  final categories = <String>[];

  for (final item in rawItems) {
    final (:name, :price) = parseLineItem(item);
    final normalizedName = normalizeName(name);

    // ── Semantischer Lern-Loop: Produkt-Mapping prüfen ──────────────────
    // Wenn der normalisierte Name einem gespeicherten raw_ocr_name entspricht,
    // wird er durch den corrected_name ersetzt und die hinterlegte Kategorie
    // (sofern vorhanden) direkt zugewiesen.
    String finalName = normalizedName;
    String? mappedCategory;
    for (final mapping in productMappings) {
      final rawOcr = mapping['raw_ocr_name'] as String? ?? '';
      if (rawOcr.toLowerCase() == normalizedName.toLowerCase()) {
        finalName = mapping['corrected_name'] as String? ?? normalizedName;
        final catId = mapping['category_id'];
        if (catId != null) {
          // Kategoriename via category_id aus categoryData suchen.
          for (final cat in categoryData) {
            if (cat['id'] == catId) {
              mappedCategory = cat['name'] as String?;
              break;
            }
          }
        }
        debugPrint(
            '[OCR-Learning] "$normalizedName" → "$finalName" '
            '(Kategorie: ${mappedCategory ?? "—"})');
        break;
      }
    }

    categories.add(
      mappedCategory ?? _smartCategorize(finalName, categoryData),
    );

    if (price != null) {
      normalizedItems.add('$finalName  ${_formatPriceComma(price)}');
    } else {
      normalizedItems.add(finalName);
    }
  }

  return {
    'amount': parseAmountImpl(text),
    'items': normalizedItems,
    'categories': categories,
    'storeName': detectMerchant(text),
    'date': detectDate(text),
    'spatialData': jsonEncode(spatialLines),
    'usedStrategy': usedStrategy,
  };
}

/// Bestimmt heuristisch, welche Text-Parsing-Strategie für [items] verwendet
/// wurde, indem der Ursprungstext auf Tax-Code-Muster geprüft wird.
///
/// Gibt `'tax_code'` zurück, wenn Tax-Code-Preiszeilen im Text vorhanden sind
/// (typisch für SPAR-Kassenbons) und Artikel gefunden wurden.
/// Gibt `'standard'` zurück, wenn keine Tax-Codes vorhanden sind und Artikel
/// gefunden wurden. Gibt `null` zurück, wenn keine Artikel geparst wurden –
/// in diesem Fall wird kein Vendor-Profil aktualisiert.
String? _inferHeuristicStrategy(String text, List<String> items) {
  if (items.isEmpty) return null;
  final taxCodePattern = RegExp(
    r'^\d{1,4}[.,]\d{2}\s+[A-Z]\s*$',
    multiLine: true,
  );
  return taxCodePattern.hasMatch(text) ? 'tax_code' : 'standard';
}

// ---------------------------------------------------------------------------
// OcrService
// ---------------------------------------------------------------------------

/// Service-Klasse für OCR-Texterkennung und Beleg-Parsing.
///
/// Kapselt die gesamte Logik für:
///   - Bildaufnahme via Kamera
///   - Texterkennung mit Google ML Kit
///   - Parsing des erkannten Textes (Betrag, Artikel) im Background-Isolate
///
/// Der optionale [databaseService] wird genutzt, um die benutzerdefinierte
/// Kategorienliste für die automatische Artikelzuordnung zu laden.
/// Ist er nicht angegeben, greift der statische [categoryMap]-Fallback.
class OcrService {
  OcrService({DatabaseService? databaseService})
      : _databaseService = databaseService;

  final ImagePicker _picker = ImagePicker();
  final _uuid = const Uuid();
  final DatabaseService? _databaseService;

  /// Öffnet die Kamera, nimmt ein Bild auf und erkennt den Text per OCR.
  ///
  /// Gibt einen [Receipt] zurück oder `null`, wenn der Vorgang abgebrochen wurde.
  Future<Receipt?> scanReceipt() async {
    return _pickAndProcess(ImageSource.camera);
  }

  /// Öffnet die Galerie, wählt ein **einzelnes** Bild aus und verarbeitet es.
  ///
  /// Gibt einen [Receipt] zurück oder `null`, wenn der Vorgang abgebrochen wurde.
  Future<Receipt?> importFromGallery() async {
    return _pickAndProcess(ImageSource.gallery);
  }

  /// Öffnet die Galerie und ermöglicht die Auswahl **mehrerer** Bilder.
  ///
  /// Für jedes ausgewählte Bild wird sofort ein Platzhalter-[Receipt] mit
  /// `status: 'processing'` und dem temporären Bildpfad erstellt.
  /// Die eigentliche OCR-Verarbeitung übernimmt der [ProcessorService].
  ///
  /// Gibt eine leere Liste zurück, wenn der Vorgang abgebrochen wird.
  Future<List<Receipt>> pickMultipleImages() async {
    final List<XFile> imageFiles = await _picker.pickMultiImage(
      imageQuality: 90,
    );

    if (imageFiles.isEmpty) return [];

    final now = DateTime.now();
    return imageFiles
        .map(
          (f) => Receipt(
            id: _uuid.v4(),
            date: now,
            totalAmount: 0.0,
            items: const [],
            imagePath: f.path,
            status: 'processing',
            progress: 0.0,
          ),
        )
        .toList();
  }

  /// Gemeinsame Implementierung für Kamera- und Galerie-Import.
  Future<Receipt?> _pickAndProcess(ImageSource source) async {
    final XFile? imageFile = await _picker.pickImage(
      source: source,
      imageQuality: 90,
    );

    if (imageFile == null) {
      // Benutzer hat den Vorgang abgebrochen
      return null;
    }

    if (source == ImageSource.camera) {
      try {
        await ImageGallerySaver.saveFile(imageFile.path, name: 'BongScanner');
      } catch (e) {
        debugPrint('[OcrService] Fehler beim Speichern in der Galerie: $e');
      }
    }

    return _processImage(imageFile.path);
  }

  /// Verarbeitet ein Bild und erstellt einen [Receipt] aus dem erkannten Text.
  Future<Receipt> _processImage(String tempImagePath) async {
    // Text via Google ML Kit erkennen (muss auf dem Haupt-Isolate laufen,
    // da Platform Channels verwendet werden)
    final inputImage = InputImage.fromFilePath(tempImagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    final RecognizedText recognizedText;
    try {
      recognizedText = await textRecognizer.processImage(inputImage);
    } finally {
      // Ressourcen freigeben
      await textRecognizer.close();
    }

    final fullText = recognizedText.text;

    // ── Räumliche Zeilendaten extrahieren ────────────────────────────────────
    // Die Bounding-Box-Koordinaten aus ML Kit werden als plain-Dart-Maps
    // kodiert, damit sie sicher in einem Background-Isolate via `compute`
    // verarbeitet werden können.
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

    // ── Händler-Erkennung (Merchant Anchor) ──────────────────────────────────
    final detectedMerchant = detectMerchant(fullText);
    if (detectedMerchant != null) {
      debugPrint('[OcrService] Händler erkannt: $detectedMerchant');
    }

    // Bild permanent speichern: aus dem temporären Cache-Verzeichnis in das
    // app-private Dokumenten-Verzeichnis kopieren, damit es auch nach dem
    // App-Neustart noch vorhanden ist.
    final String? permanentImagePath = await _persistImage(tempImagePath);

    // Kategorien aus der Datenbank laden (für dynamische Zuordnung).
    // Schlägt das Laden fehl, greift der statische categoryMap-Fallback.
    List<Map<String, dynamic>> categoryData = [];
    List<Map<String, dynamic>> productMappings = [];
    Map<String, dynamic>? vendorProfile;
    final db = _databaseService;
    if (db != null) {
      try {
        final cats = await db.getCategories();
        categoryData = cats.map((c) => c.toMap()).toList();
      } catch (e) {
        debugPrint('[OcrService] Kategorien konnten nicht geladen werden: $e');
      }
      try {
        productMappings = await db.getProductMappings();
      } catch (e) {
        debugPrint(
            '[OcrService] Produkt-Mappings konnten nicht geladen werden: $e');
      }
      // Händler-Profil für die bevorzugte Parsing-Strategie laden.
      if (detectedMerchant != null) {
        try {
          vendorProfile = await db.getVendorProfile(detectedMerchant);
        } catch (e) {
          debugPrint(
              '[OcrService] Vendor-Profil konnte nicht geladen werden: $e');
        }
      }
    }

    // Parsing im Background-Isolate ausführen, damit der UI-Thread
    // (insbesondere der CircularProgressIndicator) nicht blockiert wird
    final result = await compute(parseOcrText, {
      'text': fullText,
      'categoryData': categoryData,
      'productMappings': productMappings,
      'spatialLines': spatialLines,
      if (vendorProfile != null) 'vendorProfile': vendorProfile,
    });

    // Vendor-Profil nach erfolgreichem Parsing aktualisieren.
    final parsedStoreName = result['storeName'] as String?;
    final parsedItems = result['items'] as List?;
    final usedStrategy = result['usedStrategy'] as String?;
    if (db != null &&
        parsedStoreName != null &&
        parsedItems != null &&
        parsedItems.isNotEmpty &&
        usedStrategy != null) {
      try {
        await db.upsertVendorProfile(
          parsedStoreName,
          preferredStrategy: usedStrategy,
          incrementSuccess: true,
        );
      } catch (e) {
        debugPrint(
            '[OcrService] Vendor-Profil konnte nicht gespeichert werden: $e');
      }
    }

    final dateStr = result['date'] as String?;
    final parsedDate = dateStr != null ? DateTime.tryParse(dateStr) : null;

    return Receipt(
      id: _uuid.v4(),
      date: parsedDate ?? DateTime.now(),
      totalAmount: result['amount'] as double,
      items: List<String>.from(result['items'] as List),
      categories: List<String>.from(result['categories'] as List),
      imagePath: permanentImagePath,
      storeName: parsedStoreName,
      spatialData: result['spatialData'] as String?,
      rawText: fullText.isEmpty ? null : fullText,
    );
  }

  /// Kopiert das Bild von [tempPath] in das permanente App-Dokumenten-
  /// Verzeichnis und gibt den neuen Pfad zurück.
  ///
  /// Gibt `null` zurück, wenn der Kopiervorgang fehlschlägt, sodass der
  /// Beleg ohne Bild gespeichert werden kann.
  Future<String?> _persistImage(String tempPath) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final imagesDir = Directory(p.join(docsDir.path, 'receipt_images'));
      if (!imagesDir.existsSync()) {
        await imagesDir.create(recursive: true);
      }
      // UUID als Dateiname, um Kollisionen zuverlässig zu vermeiden
      final fileName = '${_uuid.v4()}${p.extension(tempPath)}';
      final permanentFile = File(p.join(imagesDir.path, fileName));
      await File(tempPath).copy(permanentFile.path);
      return permanentFile.path;
    } catch (e, st) {
      // Fehler beim Kopieren: Beleg wird ohne Bild gespeichert
      debugPrint('[OcrService] Bild konnte nicht persistiert werden: $e\n$st');
      return null;
    }
  }

  /// Prüft, ob die Bilddatei noch auf dem Gerät vorhanden ist.
  bool imageExists(String imagePath) {
    return File(imagePath).existsSync();
  }
}
