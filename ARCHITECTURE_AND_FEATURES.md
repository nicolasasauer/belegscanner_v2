# Architektur-Analyse & Feature-Vorschläge

Kurzfassung
- Ich habe die wichtigsten Services und Datenmodelle in `lib/services/` und `lib/models/` durchgesehen.
- Die App hat bereits robuste OCR-/Parsing‑Pipelines, lokale KI-Integration (`GemmaService`) und persistente Speicherung (`DatabaseService`).
- Fehlende / empfehlenswerte Funktionen: nutzerfreundlicher Modell-Download, Volltext-/semantische Suche, FTS-Index in der DB, Modell‑Integritätsprüfung, verbesserte UI‑Flows.

Bestehende Kernkomponenten (kurz)
- `OcrService` — Bildaufnahme, ML Kit Texterkennung, Parsing-Dispatch in Background-Isolate (`parseOcrText`).
- `ProcessorService` — Warteschlange, Duplikaterkennung (SHA-256), Persistenz, Post-Processing, KI-Kategorisierung (`AiCategorizationService`).
- `GemmaService` — Lifecycle: Einstellungen, Installieren (kopieren), Laden, Inferenz `categorizeItems(...)`. Kein Built-in-Download.
- `AiCategorizationService` — High-level-Fallback-Logik: ruft `GemmaService` und vereint KI-/Keyword-Kategorien.
- `DatabaseService` — SQLite-CRUD, Produkt-Mappings, Vendor-Profiles, Aggregation; derzeit keine FTS/Fulltext-Indexe.
- `ExportService` — CSV/JSON Export, Bild-Sharing, Knowledge Import/Export.

Probleme / Chancen
1) Modell-Download UX
  - Aktuell: Nutzer muss `.task` manuell aufs Gerät kopieren und dann per FilePicker auswählen (`ModelSetupPage`).
  - Problem: technisch anspruchsvoll (ADB, USB, Cloud), große Dateien (>100s MB–GB), fehlender Fortschritt/Integritätscheck.
2) Volltextsuche & semantische Suche
  - Aktuell: Keine DB-Fulltext-Indexe; Suche wäre ineffizient mit LIKE über große Texte.
  - Idee: FTS5-Index für `rawText`, `items` und `storeName` + optional semantische Tagging mit Gemma.
3) Gemma als Such-Feature
  - Idee: Gemma verwenden, um pro-Receipt Schlüsselwörter/Tags oder kurze Embeddings zu extrahieren und in DB zu speichern; ermöglicht semantische Suche ohne externen Dienst.
4) Zuverlässigkeit / Integrität
  - Empfehlung: Download-Checksumme (SHA-256) prüfen; optional Modellversion anzeigen.
5) Nutzerfreundlichkeit
  - WLAN-only Download-Option, Erklärende UI (Größe, Speicherbedarf, RAM), ein-Klick-Download, Fortschritt, Retry, Abbruch.

Konkrete Implementierungsvorschläge

A) Ein-Klick Modell-Download & Installation

High-Level:
- UI: In `ModelSetupPage` einen Button `Download & installieren` hinzufügen.
- Service: `GemmaService` um `downloadAndInstallModel(String url, {void Function(double progress)? onProgress})` erweitern.
- Ablauf: Datei streamen → temporäre Datei schreiben (mit Fortschritt) → optional Prüfsumme prüfen → `installAndLoadModel(tempPath)` aufrufen → temporäre Datei löschen.

Beispiel-Implementierung (vereinfacht) für `GemmaService`:

```dart
// in GemmaService
Future<String?> downloadAndInstallModel(
  String url, {
  void Function(double progress)? onProgress,
}) async {
  try {
    final httpClient = HttpClient();
    final req = await httpClient.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');

    final tmpDir = await getTemporaryDirectory();
    final tmpPath = p.join(tmpDir.path, 'gemma_download.tmp');
    final file = File(tmpPath);
    final sink = file.openWrite();

    final contentLength = res.contentLength;
    var received = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      received += chunk.length;
      if (contentLength > 0 && onProgress != null) {
        onProgress(received / contentLength);
      }
    }
    await sink.close();

    // Optional: prüfe SHA256 wenn bekannt
    // final checksumOk = await _verifyChecksum(tmpPath, expectedSha256);

    final installed = await installAndLoadModel(tmpPath);
    // tmp-Datei kann gelöscht werden
    try { await file.delete(); } catch (_) {}
    return installed;
  } catch (e) {
    debugPrint('[GemmaService] Download-Fehler: $e');
    _statusMessage = 'Download fehlgeschlagen: $e';
    return null;
  }
}
```

UI-Integration (`ModelSetupPage`):
- Button hinzufügen, auf Tap: Setze `_isLoading` und rufe `GemmaService.instance.downloadAndInstallModel(url, onProgress: (p){setState(()=>_loadingProgress=p);})` auf.
- Zeige Fortschrittsbalken und geschätzte verbleibende Zeit/Größe.
- Optionen: Download über Mobilfunk erlauben, nur WLAN, Auswahl der Modellgröße (2B vs 3B).

B) Volltextsuche mit SQLite FTS5

Ziel: Schnelle Volltextsuche über OCR-Rohtext (`rawText`), Artikel-Texte (`items`) und `storeName`.

Schema/Migration:
- Neue virtuelle Tabelle mit FTS5, z. B. `receipts_fts(rowid, rawText, itemsText, storeName)`.
- Bei Insert/Update/Delete die FTS-Tabelle synchronisieren (Trigger oder manuell aus `DatabaseService`).

Beispiel-Migration (SQL):

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS receipts_fts USING fts5(
  rawText, itemsText, storeName, content='', tokenize='unicode61'
);
-- Bei jeder Receipt-Insert/Update: INSERT INTO receipts_fts(rowid, rawText, itemsText, storeName) VALUES(?, ?, ?, ?)
```

Datenbank-API (in `DatabaseService`):

```dart
Future<List<Receipt>> searchReceiptsFullText(String query) async {
  final db = await database;
  final rows = await db.rawQuery(
    "SELECT r.* FROM $_tableName r JOIN receipts_fts f ON f.rowid = r.rowid WHERE receipts_fts MATCH ? ORDER BY rank DESC",
    [query],
  );
  return rows.map(Receipt.fromMap).toList();
}
```

Hinweis: SQFlite/Android muss FTS5 unterstützen — auf den meisten modernen Android-APIs ist das verfügbar. Testen!

C) Semantische Suche / Tags via Gemma

Variante 1 (kostengünstig): Während der Verarbeitung (`ProcessorService`) zusätzliches Feld `searchTags` generieren:
- Prompt an Gemma: "Extrahiere 6 kurze Schlagwörter aus diesem Belegtext, JSON-Array" → parse JSON → store tags in DB (neue Spalte `searchTags` als JSON).
- Suche: `WHERE json_extract(searchTags, '$') LIKE '%query%'` oder besser: normalize tags to lowercase and store in a separate `receipt_tags` table for fast lookup.

Variante 2 (fortgeschritten): Embeddings — falls Gemma/FlutterGemmaPlugin Embeddings unterstützt, generiere Embeddings und speichere lokal (Float32 arrays) in einer `vectors`-Tabelle; suche mit Annoy/FAISS-like libs (auf mobile kompliziert). Deshalb: eher Tags/keywords.

Kurzbeispiel für Keyword-Extraktion (GemmaService Erweiterung):

```dart
Future<List<String>?> extractKeywords(String text) async {
  if (!await ensureReady()) return null;
  final prompt = 'Extrahiere bis zu 6 kurze, kommagetrennte Keywords aus dem folgenden Belegtext als JSON-Array:\n\n$text\n\nAntwort:';
  final resp = await FlutterGemmaPlugin.instance.getResponse(prompt: prompt);
  // parse JSON-Array (ähnlich zu _parseResponse)
}
```

Datenmodell: `DatabaseService` erweitern
- Neue Spalte `searchTags TEXT` in `$_tableName` oder separate Tabelle `receipt_tags(receipt_id, tag)` für effiziente Suche.

D) UI: Suche & Ergebnisse

- Neue Sucheingabe (globaler Such-Button in AppBar) mit Autocomplete (letzte Tags, Merchants).
- Filter: Datum, Kategorie, Betragsspanne, Händler.
- Ergebnisliste: Highlight matched snippet (Kontext aus `rawText` oder `items`).
- Optional: „Ähnliche Belege“-Ansicht (matching tags).

F) Datenbank-Backups (neu implementiert)

- Ziel: Regelmäßige Backups der SQLite-Datenbank, Aufbewahrungsfrist (N Versionen), manuelles Erstellen und Wiederherstellen.
- Implementierung: `lib/services/backup_service.dart` erstellt Backups im App-Dokumenten-Ordner `backups/backup_<timestamp>.db`, bietet `performBackup()`, `listBackups()` und `restoreBackup(path)` sowie einfache Einstellungen (`enabled`, `frequency`, `time`, `maxVersions`).
- UI: In `ModelSetupPage` gibt es jetzt eine Sektion "Datenbank-Backup" mit: Schalter für automatische Backups, Frequenzauswahl (täglich/wöchentlich), Uhrzeit, Anzahl Versionen, "Jetzt Backup erstellen" und "Backup wiederherstellen"-Dialog.
- Einschränkungen: Backup-Trigger läuft aktuell nur beim App-Start (Aufruf von `BackupService.checkAndRunScheduledBackup()` in `main.dart`). Keine OS‑Level-Job-Scheduler integriert (z.B. WorkManager) — für zuverlässige zeitgesteuerte Backups auf Android/iOS sollte WorkManager/BackgroundFetch integriert werden.

E) Weitere kleine Verbesserungen
- Modellgröße & Speicherbedarf in `ModelSetupPage` anzeigen (schätze anhand remote metadata).
- Warnung bei wenig freiem Speicher vor Download/Install.
- Automatische Entpack-/Konvertier-Logik wenn Modelle als `.zip` geliefert werden.
- Hintergrund‑Downloads mit `flutter_downloader` für langlebige Downloads.
- Telemetrie/Logs (opt-in) für Modell-Install-Fehler, um Support zu erleichtern.

Abschluss & nächste Schritte
- Ich habe die Analyse dokumentiert und konkrete Implementierungsvorschläge (Download‑Flow, FTS, semantische Tags) aufgenommen.
- Wenn du möchtest, implementiere ich als nächstes entweder:
  1) die `GemmaService.downloadAndInstallModel(...)`-Methode + UI‑Button in `ModelSetupPage`, oder
  2) die FTS-Migration + `DatabaseService.searchReceiptsFullText(...)` API + einfache UI‑Suche.

Sag mir welche Teilaufgabe ich als nächstes umsetzen soll — ich kann den Code direkt anlegen und Tests / UI‑Screens hinzufügen.
