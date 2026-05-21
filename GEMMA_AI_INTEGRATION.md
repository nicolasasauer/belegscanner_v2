# Lokale KI-Integration – Technische Dokumentation

## Übersicht

Diese Erweiterung integriert ein lokales **Gemma 2B/3B**-Sprachmodell in den
bestehenden Belegscanner-Workflow. Die KI läuft **vollständig auf dem Gerät**
ohne Cloud-Anbindung und verfeinert die keyword-basierte Artikel-Kategorisierung
durch echtes Sprachverständnis.

```
Kamera
  ↓
ML Kit OCR                    (unverändert)
  ↓
bestehender Receipt Parser    (unverändert)
  ↓
strukturierte Produktliste    (unverändert)
  ↓
Keyword-Kategorisierung       (unverändert – Fallback)
  ↓
lokales Gemma-Modell          ← NEU (Schritt 6.5 in ProcessorService)
  ↓
JSON-Kategorisierung
  ↓
Merge: KI + Keyword           (KI bevorzugt, außer bei "Sonstiges")
  ↓
SQLite Speicherung            (unverändert)
```

---

## Neue Dateien

| Datei | Zweck |
|-------|-------|
| `lib/services/gemma_service.dart` | Singleton für Modell-Lifecycle und Inferenz |
| `lib/services/ai_categorization_service.dart` | Glue-Layer: Prompt-Building, Fallback-Logik |
| `lib/pages/model_setup_page.dart` | UI: Modell-Installation, Test, Einstellungen |
| `lib/widgets/ai_status_badge.dart` | AppBar-Badge mit KI-Zustand |

## Geänderte Dateien

| Datei | Änderung |
|-------|----------|
| `lib/services/processor_service.dart` | Schritt 6.5 eingefügt (KI-Kategorisierung) |
| `pubspec.yaml` | `flutter_gemma: ^0.4.0` hinzugefügt |
| `android/app/build.gradle` | `minSdk 21`, NDK `25.1.8937393`, optional `abiFilters` |
| `android/app/proguard-rules.pro` | MediaPipe/flutter_gemma keep-rules |

---

## Setup: Entwicklungsumgebung

### 1. NDK installieren

```bash
# Android Studio → SDK Manager → SDK Tools → NDK (Side by side)
# Version: 25.1.8937393
# Oder via sdkmanager:
sdkmanager "ndk;25.1.8937393"
```

### 2. Dependencies installieren

```bash
flutter pub get
```

### 3. Modell beschaffen

Das Modell ist **nicht im Repository enthalten** (zu groß, ~1,5 GB).

**Option A – Kaggle (empfohlen):**
```
https://www.kaggle.com/models/google/gemma/
→ "gemma-2b-it-gpu-int4.task" oder "gemma-2b-it-cpu-int8.task"
```

**Option B – Hugging Face:**
```
https://huggingface.co/google/gemma-2b-it
→ Datei im MediaPipe-Format (.task) herunterladen
```

**Modell auf Gerät übertragen:**
```bash
# ADB push in den Download-Ordner
adb push gemma-2b-it-gpu-int4.task /sdcard/Download/

# Dann in der App: KI-Einrichtung → Modelldatei auswählen
```

---

## Architektur-Details

### GemmaService (Singleton)

```dart
// Einmalige Initialisierung (in ProcessorService.loadSettings())
await GemmaService.instance.loadSettings();

// Modell vorladen (optional, passiert sonst beim ersten Scan)
await GemmaService.instance.ensureReady();

// Kategorisierung
final cats = await GemmaService.instance.categorizeItems(
  ['Vollmilch 1L', 'Red Bull 250ml'],
  ['Lebensmittel', 'Getränke', 'Drogerie', 'Pfand', 'Sonstiges'],
);
```

### Prompt-Design

Das Modell erhält einen kurzen Few-Shot-Prompt mit:
1. Kategorienliste (aus `CategoryService.availableCategories`)
2. Einem Beispiel (2 Artikel → JSON-Array)
3. Den zu kategorisierenden Artikeln

```
Du bist ein Kassenbon-Kategorisierer. Antworte NUR mit einem JSON-Array.

Kategorien: Lebensmittel, Getränke, Drogerie, Pfand, Sonstiges

Beispiel:
Artikel:
1. Vollmilch 1L
2. Red Bull 250ml
3. Colgate Zahnpasta
Antwort: ["Lebensmittel","Getränke","Drogerie"]

Artikel:
1. ...
2. ...
Antwort:
```

**Design-Entscheidungen:**
- `topK=1` (greedy decoding): Deterministisch, verhindert JSON-Syntaxfehler
- `temperature=0.1`: Niedrig für konsistente Kategorisierung
- `maxTokens=512`: Ausreichend für Listen bis ~50 Artikel
- Few-Shot mit 1 Beispiel: Gut für 2B-Modelle, hält Prompt-Länge klein

### Merge-Logik

```
KI = "Sonstiges" && Keyword ≠ "Sonstiges" → Keyword bevorzugen
KI ≠ "Sonstiges"                           → KI bevorzugen
KI nicht verfügbar / Fehler               → Keyword beibehalten (Fallback)
```

---

## Fallback-Verhalten

Die KI-Integration ist **vollständig optional**. Bei:

- Deaktivierter KI → Keyword-Kategorien unverändert
- Fehlendem Modell → Keyword-Kategorien unverändert
- Inferenz-Fehler → Keyword-Kategorien unverändert (+ Session-Neustart)
- Ungültigem JSON → `null` return, Fallback auf Keyword-Kategorien
- Verkürzter Antwortliste → fehlende Einträge mit 'Sonstiges' aufgefüllt

**Kein Breaking Change**: Bestehende Belege und Kategorien bleiben unverändert.

---

## Performance

| Szenario | Erwartete Latenz |
|----------|-----------------|
| Gemma 2B-IT INT4 auf GPU (Flagship) | 2–5 s pro Scan |
| Gemma 2B-IT INT8 auf CPU (Mittelklasse) | 10–30 s pro Scan |
| KI deaktiviert / Fallback | 0 ms (keine Änderung) |

**Hinweis:** Da die Verarbeitung ohnehin asynchron im Hintergrund läuft
(ProcessorService mit Queue), ist die zusätzliche Latenz für den Nutzer
kaum spürbar. Der Fortschrittsbalken wurde auf 4 Schritte (20/40/60/75/100 %)
angepasst.

---

## Geräteanforderungen

| Anforderung | Wert |
|-------------|------|
| Android API | ≥ 21 (Android 5.0) / empfohlen ≥ 24 für Gemma-Performance |
| RAM | ≥ 3 GB empfohlen (Modell + OS + App) |
| Speicherplatz | ≥ 2 GB für Modell (1,5 GB .task + 300 MB Arbeitsspeicher) |
| ABI | arm64-v8a (64-Bit ARM) |
| NDK | 25.1.8937393 |

---

## Hinzufügen von Kategorien

Die KI lernt automatisch alle Kategorien aus `CategoryService.availableCategories`.
Wenn du neue Kategorien hinzufügst:

1. `lib/services/category_service.dart` → `availableCategories` Liste erweitern
2. `getCategoryColor()` und `getCategoryTextColor()` entsprechend erweitern
3. Kein Retraining nötig – Gemma versteht neue Kategorien aus dem Prompt

---

## Bekannte Einschränkungen

1. **Kein iOS-Support (noch):** `flutter_gemma` unterstützt iOS via CoreML,
   aber der Fokus dieser PR liegt auf Android. iOS-Support kann später ergänzt
   werden.

2. **Kein Emulator-Support:** Das GPU-Delegate von MediaPipe läuft nicht im
   Android-Emulator. Für Tests mit der KI ist ein physisches Gerät notwendig.
   Die App kompiliert und läuft im Emulator, aber mit deaktivierter KI.

3. **Modell muss manuell übertragen werden:** Google erlaubt keine automatischen
   Gemma-Downloads aus Apps ohne Authentifizierung. Der manuelle Import-Schritt
   ist bewusst gewählt (Privacy-first).

4. **Modell-Dateigröße:** Die .task-Datei (1,0–1,5 GB) wird ins App-Verzeichnis
   kopiert. Bei wenig Gerätespeicher kann der Import fehlschlagen.
