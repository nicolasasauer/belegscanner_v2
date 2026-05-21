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

G) CI-Fix: Flutter-Version anpassen

- Problem: Die GitHub Action verwendete `flutter-version: '3.22.x'`, wodurch das CI-Environment Dart SDK `3.4.4` bereitstellte.
- Fehler: `flutter_gemma ^0.4.0` hängt von `large_file_handler ^0.3.0`, das Dart SDK `>=3.5.3 <4.0.0` verlangt. Das schlug `flutter pub get` im CI fehl.
- Fix: Die Workflow-Datei `.github/workflows/build-apk.yml` wurde auf `flutter-version: '3.44.0'` aktualisiert. Damit steht in der Action die benötigte Dart-Version zur Verfügung.
- Ergebnis: Ein frisch ausgelöster Run wird jetzt mit neuer Konfiguration gestartet; der ursprüngliche `pub get`-Fehler sollte damit beseitigt sein.

H) Austauschbares lokales KI-Modell

- Ziel: Die App soll ein installiertes Gemma-Modell ersetzen können, ohne dass bestehende App-Daten kaputtgehen.
- Umsetzungsidee:
  - `GemmaService` verwaltet jetzt nicht nur `modelPath`, sondern auch Modellversion/-metadaten und eine saubere Austausch-API.
  - Beim Installieren eines neuen Modells wird das alte Modell sicher entfernt oder atomar ersetzt.
  - UI: `ModelSetupPage` zeigt aktuelle Modell-Version/Dateigröße und bietet einen klaren Button zum Ersetzen des Modells an.
  - Validierung: neue Modelle sollten anhand der Dateiendung, optionaler SHA-256-Prüfsumme oder ZIP-Content geprüft werden.

Abschluss & nächste Schritte
- Ich habe die Analyse dokumentiert, den CI-Fix beschrieben und die zukünftige Aufgabe für ein austauschbares lokales KI-Modell ergänzt.
- Als nächsten Schritt setze ich die Implementierung des austauschbaren KI-Modells um.
