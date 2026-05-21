# Bong-Scanner 📷

Eine Flutter-App für Android zum **Einscannen**, **Speichern**, **Durchsuchen** und **Exportieren** von Kassenbons – vollständig On-Device, ohne Cloud. Nutzt **Google ML Kit** für OCR und optionales **Gemma 2B/3B**-Modell zur intelligenten Kategorisierung.

---

## 🎯 Kernfeatures

### 📱 Belegverwaltung
- **📷 On-Device OCR** – Belege fotografieren, Text lokal mit Google ML Kit erkennen
- **🗄️ SQLite-Persistenz** – Alle Daten (Beleg-Metadaten, Bild-Pfade, OCR-Text) dauerhaft lokal gespeichert
- **🖼️ Bild-Verwaltung** – Original-Bild jedes Belegs im App-Verzeichnis; Thumbnail in Liste, Vollbild-Ansicht im Detail
- **✏️ Inline-Bearbeitung** – Beleg-Details, Artikelnamen, Preise direkt im Detail-BottomSheet bearbeiten
- **🗑️ Sicheres Löschen** – Wisch-Geste entfernt Datensatz UND Bilddatei vollständig

### 🧠 Intelligente Kategorisierung
- **💶 Automatische Betragserkennung** – 3-stufige Priorisierung (SUMME/TOTAL → Keywords → EUR-Muster)
- **🏷️ Artikel-Kategorien** – Jede Position kategori sierbar: Lebensmittel, Drogerie, Freizeit, Transport, Sonstiges
- **🤖 KI-Kategorisierung (Optional)** – Lokales **Gemma-Modell** verfeinert Kategorisierung mit echter Sprachverständnis
- **🧾 Verbesserte Artikelerkennung** – Header/Footer-Cut, Garbage-Filter, 3-Zeilen-Artikel-Zusammenführung
- **🔢 Auto-Summe** – Berechnet Gesamtbetrag aus Einzelpreisen mit Knopfdruck

### 🔍 Suche & Filter
- **🔍 Volltextsuche** – Nach Händlername, Betrag oder Stichwörtern in Artikeln suchen
- **🗂️ Datum-Filter** – Kombinierbare FilterChips für Tag, Monat, Jahr

### 📤 Daten-Export & Import
- **📤 CSV-Export** – Alle Belege exportieren und per Share-Sheet teilen
- **📥 Multi-Galerie-Import** – Mehrere Bonfotos parallel importieren (konfigurierbare Concurrency-Queue)
- **🔒 SHA-256 Duplikatschutz** – Identische Bilder vor OCR-Verarbeitung erkennen und überspringen

### ⚙️ Konfiguration
- **⚡ Concurrency-Queue** – Max. N OCR-Jobs parallel (einstellbar 1–5), weitere warten in Queue
- **🌙 Material 3 Theme** – Light/Dark-Mode mit dynamischer Indigo-Palette
- **🌍 Deutsches Locale** – Euro-Formatierung (`42,50 €`), deutsche Monatsnamen

---

## 🤖 KI-Integration (Gemma On-Device)

Eine optionale Erweiterung nutzt ein lokal auf dem Gerät laufendes **Gemma 2B/3B**-Sprachmodell zur intelligenten Kategorisierung von Bonartikeln.

### Workflow
```
Kamera → ML Kit OCR → Artikel-Parser → Keyword-Kategorisierung → 
  ↓ (Optional)
  Gemma-Modell (On-Device) → KI-Kategorisierung → Merge → SQLite
```

### Features
- ✅ **Vollständig On-Device** – Keine Cloud, keine Datenschutz-Bedenken
- ✅ **Fallback-Logik** – Keyword-Kategorisierung bei KI-Fehlern oder "Sonstiges"-Klassifizierung
- ✅ **Setup-UI** – In-App Modell-Installation, Test, Einstellungen unter `model_setup_page.dart`
- 🔁 **Modell austauschbar** – Sicherer Austausch mit Backup, Rollback und Metadaten für installierten Modellnamen / Quelle
- 🗄️ **Manuelles Datenbank-Backup** – In der App gibt es einen Button "Jetzt Backup erstellen" für sofortige Sicherungen und ein Backup-Management.
- ℹ️ **Modell-Download erforderlich** – ~1,5 GB (Kaggle/Hugging Face)

**Technische Details:** Siehe [GEMMA_AI_INTEGRATION.md](./GEMMA_AI_INTEGRATION.md)

---

## 🛠️ Technologie-Stack

| Layer | Technologie |
|-------|-------------|
| **Framework** | Flutter (Dart) – Material 3 |
| **OCR-Engine** | Google ML Kit Text Recognition (lokal) |
| **KI (Optional)** | Gemma 2B/3B via flutter_gemma (lokal, On-Device) |
| **Datenbank** | SQLite (sqflite) |
| **Persistenz** | App-Verzeichnis via path_provider |
| **Datei-Sharing** | share_plus |
| **Bildwahl** | image_picker |
| **Duplikat-Check** | SHA-256 (crypto package) |
| **Formatierung** | intl (Locale, Datum, Zahlen) |
| **IDs** | uuid |
| **Einstellungen** | shared_preferences |

---

## 📋 Projektstatus

✅ **Code-Qualität**: `flutter analyze` zeigt **0 Issues**
✅ **Abhängigkeiten**: Alle aktuell und kompatibel (Flutter 3.44.0)
⚠️ **APK-Build**: Benötigt Android SDK + NDK (25.1.8937393 für Gemma-Support)
📌 **KI-Modell**: Erforderlich für erweiterte Kategorisierung (~1,5 GB Download)

### Projektstruktur

```
lib/
├── main.dart                    # App Entry Point, Theme & Navigation
├── models/
│   ├── receipt.dart            # Kassenbon-Datenmodell
│   └── category.dart           # Kategorisierung-Enums
├── pages/
│   ├── home_page.dart          # Haupt-Dashboard mit FAB-Menü
│   ├── dashboard_page.dart     # Statistiken & Filter
│   ├── model_setup_page.dart   # KI-Modell Installation & Test
│   ├── ocr_debug_page.dart     # Interaktives OCR-Debug UI
│   └── category_management_page.dart
├── services/
│   ├── database_service.dart   # SQLite Operations
│   ├── ocr_service.dart        # Google ML Kit Integration
│   ├── processor_service.dart  # Beleg-Parsing & Kategorisierung
│   ├── gemma_service.dart      # Lokales KI-Modell (Gemma 2B/3B)
│   ├── ai_categorization_service.dart # KI-Glue-Layer
│   ├── category_service.dart   # Kategorie-Management
│   └── export_service.dart     # CSV & Sharing
└── widgets/
    ├── receipt_list_tile.dart
    ├── receipt_detail_view.dart
    ├── ai_status_badge.dart    # KI-Status-Anzeige
    └── ...
```

---

## ⚙️ Voraussetzungen

### Erforderlich
- **Flutter SDK** 3.40+ (getestet mit 3.44.0)
- **Dart** 3.20+ (im Flutter SDK enthalten)
- **Android SDK** API 34+
- **Android NDK** 25.1.8937393 (für Gemma ML Kit Support)
- **Java/JDK** 11+ (für Gradle)

### Optional
- **Gemma-Modell** (~1,5 GB) für KI-Kategorisierung
  - Download von [Kaggle](https://www.kaggle.com/models/google/gemma/) oder [Hugging Face](https://huggingface.co/google/gemma-2b-it)
  - `gemma-2b-it-gpu-int4.task` (GPU) oder `gemma-2b-it-cpu-int8.task` (CPU)

### Umgebungsvariablen

```bash
# Android SDK & NDK
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export NDK_HOME=$ANDROID_HOME/ndk/25.1.8937393
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$NDK_HOME/bin

# Flutter (falls nicht global installiert)
export PATH=$PATH:/path/to/flutter/bin
```

---

## Installation

### Schnellstart (Entwicklung)

```bash
# Repository klonen
git clone https://github.com/nicolasasauer/belegscanner_v2.git
cd belegscanner_v2

# Dependencies installieren
flutter pub get

# App ausführen (mit Emulator oder Gerät verbunden)
flutter run
```

### APK-Build

```bash
# Debug-APK
flutter build apk

# Release-APK (unverschlüsselt)
flutter build apk --release

# Release-APK (mit Signierung)
# Requires: android/key.properties mit Keystore-Daten
flutter build apk --release --split-debug-info
```

**Ausgabedatei:** `build/app/outputs/apk/release/app-release.apk`

### Signierter Release-Build (CI/CD)

Für automatisierte Builds via GitHub Actions können Secrets gesetzt werden:

```yaml
ANDROID_KEYSTORE_BASE64    # Base64 des .jks-Keystores
ANDROID_KEYSTORE_PASSWORD  # Keystore-Passwort
ANDROID_KEY_ALIAS         # Key-Alias im Store
ANDROID_KEY_PASSWORD      # Key-Passwort
```

**Lokal signieren:**
```bash
# Keystore erstellen (einmalig)
keytool -genkey -v -keystore android/my-release-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias my-key-alias

# android/key.properties konfigurieren
echo "storeFile=../my-release-key.jks" >> android/key.properties
echo "storePassword=YOUR_STORE_PASSWORD" >> android/key.properties
echo "keyAlias=my-key-alias" >> android/key.properties
echo "keyPassword=YOUR_KEY_PASSWORD" >> android/key.properties

# Dann regulär builden
flutter build apk --release
```

---

## 🤖 KI-Modell Einrichtung (Optional)

Falls gewünscht, kann das Gemma-Modell für intelligente Kategorisierung genutzt werden.

### Modell installieren

1. **Modell herunterladen** (Kaggle oder Hugging Face)
   - Format: `.task` (MediaPipe)
   - Empfohlen: `gemma-2b-it-gpu-int4.task`

2. **Auf Gerät übertragen** (via ADB)
   ```bash
   adb push gemma-2b-it-gpu-int4.task /sdcard/Download/
   ```

3. **In der App einrichten**
   - Home-Screen → FAB-Menü → **KI-Einrichtung**
   - Modelldatei aus Downloads auswählen
   - Test durchführen
   - Die App speichert den Pfad lokal

### Verwendung

Ist das Modell eingerichtet, wird es automatisch beim Bonscanning verwendet:
- Standard-Kategorisierung (Keyword-basiert) läuft zuerst
- KI verfeinert das Ergebnis, falls verfügbar
- Fallback auf Keyword-Kategorisierung bei Fehlern

**Technische Details:** Siehe [GEMMA_AI_INTEGRATION.md](./GEMMA_AI_INTEGRATION.md)

---

## Testen

```bash
# Flutter analyzer (Code-Qualität)
flutter analyze

# Unit- & Widget-Tests (Standard)
flutter test

# Coverage
flutter test --coverage
```

**Aktueller Status:**
```
$ flutter analyze
No issues found! (Laufzeit: 5.5s)
```

---

## 📦 CI/CD – GitHub Actions

Ein automatisierter Build-Workflow ist unter `.github/workflows/build-apk.yml` konfiguriert:

1. Flutter Dependencies installieren (`flutter pub get`)
2. Code-Qualität prüfen (`flutter analyze`)
3. Release-APK bauen (`flutter build apk --release`)
4. APK als Build-Artifact speichern

**Signing-Verhalten im CI:**
- Wenn `ANDROID_KEYSTORE_BASE64` gesetzt ist, wird der Produktions-Keystore wiederhergestellt und für den Release-Build verwendet.
- Wenn keine Signing-Secrets vorhanden sind, wird im Workflow ein temporärer Dummy-Keystore erzeugt und das Release-APK signiert.

**Secrets erforderlich** (für echte Produktions-Signierung):
- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

---

## 🐛 Debugging & Fehlersuche

Siehe [Fehlerbehebung.md](./Fehlerbehebung.md) für aktuellen Projekt-Status, bekannte Probleme und Lösungen.

---

## Technische Details

| Eigenschaft | Wert |
|---|---|
| **Paket-Name** | `com.nicolas.bong_scanner` |
| **Android Mindest-SDK** | 21 (Android 5.0) |
| **Android Ziel-SDK** | 34 (Android 14) |
| **iOS Mindest-Version** | 12.0 |
| **Flutter Version** | 3.44.0+ |
| **Dart Version** | 3.20+ |
| **NDK (optional)** | 25.1.8937393 (für Gemma-Modell) |

---

## � Screenshots & Bilder

Dieser Abschnitt kann Screenshots der App UI zeigen. Um Screenshots hinzuzufügen:

1. **Screenshots-Verzeichnis erstellen:**
   ```bash
   mkdir -p screenshots
   ```

2. **Bilder hinzufügen** (empfohlene Namen):
   - `screenshot_01_home.png` – Home-Screen mit FAB-Menü
   - `screenshot_02_list.png` – Beleg-Liste mit Filtern
   - `screenshot_03_scanning.png` – Kamera-Scan in Aktion
   - `screenshot_04_detail.png` – Beleg-Detail mit Bearbeitung
   - `screenshot_05_ai_setup.png` – KI-Modell Einrichtung
   - `screenshot_06_debug.png` – OCR-Debug UI mit Bounding Boxes

3. **Optionaler Screenshot-Table** (auskommentiert als Template):

```markdown
| Home | Beleg-Liste | Scan | Detail |
|:---:|:---:|:---:|:---:|
| ![Home](screenshots/screenshot_01_home.png) | ![Liste](screenshots/screenshot_02_list.png) | ![Scan](screenshots/screenshot_03_scanning.png) | ![Detail](screenshots/screenshot_04_detail.png) |
| FAB-Menü mit Kamera & Import | Gefilterte Belege | ML Kit OCR | Bearbeiten & Export |
```

---

## 🔗 Features – Schnellübersicht

**Belegverwaltung:**
- 📷 On-Device OCR (Google ML Kit)
- 🗄️ SQLite-Persistenz lokal
- 🖼️ Bild-Verwaltung (Thumbnail & Vollbild)
- ✏️ Inline-Bearbeitung
- 🗑️ Sicheres Löschen

**Kategorisierung:**
- 💶 Automatische Betragserkennung
- 🏷️ Artikel-Kategorien (5 vordefiniert)
- 🤖 KI-Kategorisierung (Gemma, optional)
- 🔢 Auto-Summe

**Suche & Filter:**
- 🔍 Volltextsuche
- 📅 Datum-Filter (Tag/Monat/Jahr)

**Export & Import:**
- 📤 CSV-Export
- 📥 Multi-Galerie-Import (parallel)
- 🔒 SHA-256 Duplikat-Schutz

**UI & Einstellungen:**
- 🌙 Material 3 (Light/Dark)
- 🌍 Deutsches Locale
- ⚡ Konfigurierbare Concurrency

---

## 👥 Entwicklung & Beitragen

### Code-Stil
- Dart: Folge [Effective Dart](https://dart.dev/effective-dart)
- Flutter: Material 3 Best Practices
- Kommentare auf Deutsch

### Workflow
1. Fork das Repo
2. Feature-Branch erstellen: `git checkout -b feature/mein-feature`
3. Änderungen committen: `git commit -am "Beschreibung"`
4. Branch pushen: `git push origin feature/mein-feature`
5. Pull Request öffnen

### Build-Validierung
```bash
# Vor PR/Commit
flutter analyze      # Keine Issues erlaubt
flutter format lib/  # Code-Formatierung
flutter test        # Unit-Tests (falls vorhanden)
```

---

## 📞 Support & Feedback

- **Issues:** [GitHub Issues](https://github.com/nicolasasauer/belegscanner_v2/issues)
- **Diskussionen:** [GitHub Discussions](https://github.com/nicolasasauer/belegscanner_v2/discussions)
- **E-Mail:** [Kontakt via GitHub Profile](https://github.com/nicolasasauer)

---

## �📄 Weiterführende Dokumentation

- [GEMMA_AI_INTEGRATION.md](./GEMMA_AI_INTEGRATION.md) – Technische Details der KI-Integration
- [Fehlerbehebung.md](./Fehlerbehebung.md) – Projekt-Status und bekannte Probleme

---

## Lizenz

MIT © 2026 Nicolas Asauer
