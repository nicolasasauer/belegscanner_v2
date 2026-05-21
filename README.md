# Bong-Scanner 📷

Eine Flutter-App für Android zum **Einscannen**, **Speichern**, **Durchsuchen** und **Exportieren** von Kassenbons – vollständig On-Device, ohne Cloud.

---

## Screenshots

| Leere Startseite | Beleg-Liste | Scan-Vorgang | Beleg-Detail |
|:---:|:---:|:---:|:---:|
| ![Leere Startseite](screenshots/screenshot_01_empty.png) | ![Beleg-Liste](screenshots/screenshot_02_list.png) | ![Scan-Vorgang](screenshots/screenshot_03_scanning.png) | ![Beleg-Detail](screenshots/screenshot_04_detail.png) |
| Startbildschirm ohne Belege | Gefilterte Beleg-Liste mit Datum-FilterChips | Kamera-Scanner in Aktion | Detail-BottomSheet mit erkannten Positionen und Einzelpreisen |

---

## Features

| # | Feature | Beschreibung |
|---|---|---|
| 📷 | **On-Device OCR** | Belege per Kamera fotografieren – Text wird lokal mit Google ML Kit erkannt, kein Bild verlässt das Gerät |
| 🗄️ | **SQLite-Persistenz** | Alle Belege (Datum, Betrag, Artikel, Bildpfad, Kategorien, OCR-Rohtext) werden dauerhaft in einer lokalen SQLite-Datenbank gespeichert und überleben jeden App-Neustart |
| 🖼️ | **Bild-Thumbnail & Vollbild** | Das Originalbild jedes Belegs wird permanent im App-eigenen Dokumenten-Verzeichnis gespeichert; Thumbnail in der Liste, Vollbild-Ansicht per Antippen im Detail-Sheet |
| 💶 | **Automatische Betragserkennung** | 3-stufige Priorisierung: erst `SUMME`/`TOTAL` zeilenweise, dann andere Gesamt-Keywords per Regex, dann `EUR`/`€`-Muster – verhindert, dass Kassenbonendzeilen den Hauptbetrag überschreiben |
| 🧾 | **Verbesserte Artikelerkennung** | Header-Cut, Footer-Cut, Garbage-Filter; 3-Zeilen-Artikel (Name → Mengenberechnung → Preis) werden korrekt zusammengeführt |
| ✏️ | **Beleg bearbeiten** | Im Detail-BottomSheet können Artikelnamen und Preise direkt bearbeitet, neue Positionen hinzugefügt und einzelne Einträge gelöscht werden |
| 🏷️ | **Artikel-Kategorien** | Jede Einzelposition kann im Bearbeitungs-Modus einer Kategorie zugewiesen werden: Lebensmittel, Drogerie, Freizeit, Transport, Sonstiges |
| 🔢 | **Summe aus Artikeln berechnen** | Ein Knopfdruck im Bearbeitungs-Modus berechnet den Gesamtbetrag automatisch aus der Summe der eingetragenen Einzelpreise |
| 🔍 | **Volltextsuche** | Belege nach Händlername, Betrag oder Stichwörtern in den Einzelpositionen durchsuchen |
| 🗂️ | **Datum-Filter** | Belege nach Tag, Monat und Jahr filtern – kombinierbare FilterChips |
| 📤 | **CSV-Export** | Alle Belege als CSV-Datei exportieren und per Share-Sheet teilen |
| 📥 | **Multi-Galerie-Import** | Mehrere Bonfotos gleichzeitig aus der Gerätegalerie importieren – alle Jobs laufen parallel in einer konfigurierbaren Concurrency-Queue |
| 🔒 | **SHA-256 Duplikatschutz** | Vor der OCR-Verarbeitung wird ein SHA-256-Hash des Bildes berechnet; identische Bilder werden erkannt und übersprungen |
| ⚡ | **Concurrency-Queue** | Maximal N OCR-Jobs laufen gleichzeitig (einstellbar 1–5); weitere Jobs warten in der Warteschlange |
| 🗑️ | **Sicheres Löschen** | Belege per Wisch-Geste löschen – Datenbankeintrag UND Bilddatei werden vollständig entfernt |
| 🌙 | **Material 3** | Light- und Dark-Theme, dynamische Indigo-Farbpalette |
| 🌍 | **Deutsches Locale** | Euro-Formatierung (`42,50 €`) und deutsche Monatsnamen |

---

## Projektstatus

Dieses Repository wurde auf den alten Bong-Scanner-Code zurückgesetzt und mit der neuen lokalen KI-/Gemma-Integration ergänzt.

- `lib/main.dart`, `lib/models/`, `lib/pages/`, `lib/services/`, `lib/widgets/` wurden aus dem alten Projekt übernommen.
- Die neuen KI-Dateien bleiben erhalten: `lib/services/gemma_service.dart`, `lib/services/ai_categorization_service.dart`, `lib/pages/model_setup_page.dart`, `lib/widgets/ai_status_badge.dart`.
- Das Android-Verzeichnis wurde wiederhergestellt und die Gradle-Wrapper-Dateien ergänzt.
- Ein GitHub Actions Workflow zum APK-Build ist jetzt vorhanden unter `.github/workflows/build-apk.yml`.

---

## Technologie

| Komponente | Technologie |
|---|---|
| Framework | **Flutter** (Dart) – Material 3 |
| OCR-Engine | **Google ML Kit** (`google_mlkit_text_recognition`) – lokal auf dem Gerät |
| Datenbank | **sqflite** – SQLite |
| Datei-Sharing | **share_plus** |
| App-Verzeichnisse | **path_provider** |
| Bildauswahl | **image_picker** |
| Formatierung | **intl** |
| IDs | **uuid** |
| Duplikatserkennung | **crypto** |
| Einstellungen | **shared_preferences** |

---

## Installation

### Lokale Entwicklung

```bash
git clone https://github.com/nicolasasauer/belegscanner_v2.git
cd belegscanner_v2
flutter pub get
flutter run
```

### Build APK

```bash
flutter build apk --release
```

### Signierter Release-Build

Für einen signierten Release-Build kannst du entweder eine lokale `android/key.properties`-Datei anlegen oder die folgenden GitHub-Secrets im Workflow verwenden:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Eine Beispielkonfiguration findest du in `android/key.properties.example`.

---

## Testen

```bash
flutter test
```

Aktuell werden vor allem Unit-/Widget-Tests über das Standard-`flutter test`-Setup erwartet.

---

## GitHub Actions

Der Build-Workflow erstellt eine signed Release-APK, wenn entsprechende Secrets gesetzt sind. Das Workflow-File liegt unter `.github/workflows/build-apk.yml`.

---

## App-ID & Kompatibilität

| Eigenschaft | Wert |
|---|---|
| Android-Namespace | `com.nicolas.bong_scanner` |
| Android-AppID | `com.nicolas.bong_scanner` |
| Mindest-SDK | 21 |
| Ziel-SDK | 34 |
| iOS-Mindest-Version | 12.0 |

---

## Lizenz

MIT © 2026 Nicolas Asauer
