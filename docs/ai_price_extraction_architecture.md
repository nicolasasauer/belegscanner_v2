# KI-Preisextraktion – Architektur & Designentscheidungen

## Aktueller Stand (Schritt 6.7 im ProcessorService)

Der `AiPriceService` wird als Fallback aufgerufen, wenn die Regex-basierte
Preiserkennung unvollständig war (fehlende Einzelpreise oder Gesamtbetrag = 0).

Die KI bekommt:
- Den OCR-Rohtext (gekürzt auf 600 Zeichen)
- Die **bereits von der Regex extrahierten Artikelnamen** als Ankerpunkte

Ausgabe: `{"total": 12.95, "prices": [1.29, 2.39, 5.99]}`

---

## Warum bekommt die KI die Artikelnamen statt selbst zu extrahieren?

### Namen-Extraktion vs. Preis-Extraktion

| Task | Schwierigkeit | Aktuelle Methode |
|------|--------------|------------------|
| Artikelnamen erkennen | Mittel – links-bündiger Text, klare Muster | Regex (zuverlässig) |
| Preise zuordnen | Schwerer – Folgezeilen, mehrdeutige Beträge, fehlende Steuerkennzeichen | Regex + KI-Fallback |

### Vorteile der "Namen als Anker"-Strategie

- **Geringeres Halluzinationsrisiko:** Die KI muss nicht raten "was ist ein
  Artikelname?" – sie sucht nur den Preis für ein bekanntes Item.
- **Konsistenz:** Die Artikelnamen wurden bereits in Schritt 6.5 für die
  KI-Kategorisierung benutzt. Würde die KI die Namen neu erfinden, entsteht
  ein Naming-Konflikt mit den bereits gespeicherten Kategorien.
- **Schnellerer, fokussierter Prompt:** Kürzere Kontextlänge, klarere Aufgabe.

### Wann dieser Ansatz an Grenzen stößt

Wenn die Regex bereits **schlechte Namen** extrahiert hat (z. B. bei
ungewöhnlichen Bon-Layouts), können die Anker irreführend sein. In diesem
Fall wäre ein vollständiger AI-Extraction-Ansatz besser.

---

## Alternativer Ansatz: Vollständige KI-Extraktion aus Raw Text

Statt vorextrahierter Namen könnte die KI alles direkt aus dem OCR-Rohtext
holen:

```
Prompt: "Extrahiere alle Artikel mit Preisen und den Gesamtbetrag aus diesem Kassenbon."
Ausgabe: {"total": 12.95, "items": [{"name": "Vollmilch 1L", "price": 1.29}, ...]}
```

### Vorteile
- KI versteht mehrzeilige Artikelnamen und ungewöhnliche Bon-Formate
- Keine Abhängigkeit von der Regex-Qualität
- Kann Nicht-Artikel-Zeilen (Steuern, Zahlungsinfos) selbstständig filtern

### Nachteile / Herausforderungen
- **Architektur-Umbau nötig:** Müsste VOR der Kategorisierung (Schritt 6.5)
  laufen, damit die Namen konsistent sind
- **Höheres Halluzinationsrisiko** bei Preisen und Artikelnamen
- **Längerer Kontext** → langsamer, höhere Fehlerquote bei kleinen Modellen
- Reconciliation mit dem Vendor-Learning-System (Produkt-Mappings) nötig

### Empfehlung für Umsetzung (zukünftig)

Den Einstiegspunkt in den Pipeline **vor** Schritt 6.5 verschieben und einen
neuen Prompt-Typ entwickeln:

```
Schritt 5.5 (neu): KI-Strukturextraktion (nur wenn isEnabled)
  → Artikelnamen + Preise + Gesamtbetrag aus Raw Text
  → Ergebnis als "AI-Basis" für Schritt 6.5 und 6.7
  → Regex-Ergebnis als Fallback wenn KI leer
```

---

## OCR-Koordinaten (SpatialLines)

Jeder erkannte Textblock hat x/y-Koordinaten. Das Bon-Layout folgt
einem sehr klaren Muster:

```
│ Artikelname (x ≈ 40–200)    │  Preis (x ≈ 750–900, rechtsbündig) │
│ SUMME                        │  12,95                               │
```

### Warum LLMs mit Koordinaten schlecht umgehen

LLMs können nicht zuverlässig mit Pixel-Koordinaten rechnen. Ein Prompt wie
"Zeile bei x=820, y=340 ist der Preis für Zeile bei x=45, y=340" ist für
kleine Modelle (270M–1B) nicht robust.

### Wo Koordinaten bereits genutzt werden

Die OCR-Pipeline (Schritt 6) nutzt `spatialLines` bereits intern:
- Erkennung von Preisspalten per X-Position
- Zuordnung von mehrzeiligen Artikelnamen
- Vendor-spezifische Strategien (TaxCode vs. Standard)

### Sinnvoller Einsatz von Koordinaten (ohne LLM)

Koordinaten eignen sich für eine verbesserte **regelbasierte** Preis-Zuordnung:
- Items mit `centerX < 400` → Artikelname
- Items mit `centerX > 700` → Preiskandidat
- Paare per Y-Koordinate (gleiche Zeile oder nächste Zeile)

Dies wäre eine **Verbesserung am Regex-Layer** (Schritt 6), nicht am KI-Layer.

---

## Zusammenfassung: Was wann verbessern?

| Problem | Beste Lösung |
|---------|-------------|
| Einzelpreis fehlt, Name bekannt | KI mit Namen als Anker (aktuell) |
| Gesamtbetrag fehlt | KI aus Raw Text (aktuell) |
| Artikelname falsch erkannt | Koordinaten-basierte Regex verbessern |
| Gan unbekanntes Bon-Format | KI-Vollextraktion (zukünftiger Ansatz) |
| Preis auf falscher Zeile | Koordinaten-Pairing in Regex-Layer |
