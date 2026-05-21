import 'dart:convert';

/// Datenmodell für einen gescannten Beleg.
class Receipt {
  /// Eindeutige ID des Belegs (UUID).
  final String id;

  /// Datum des Belegs.
  final DateTime date;

  /// Gesamtbetrag in Euro.
  final double totalAmount;

  /// Liste der erkannten Einzelposten (Format: "Name  Preis").
  final List<String> items;

  /// Kategorien der Einzelposten (parallele Liste zu [items]).
  ///
  /// Wenn kürzer als [items], erhalten fehlende Einträge die Kategorie
  /// „Sonstiges" als Standard. Kann leer sein (Altdaten).
  final List<String> categories;

  /// Permanenter Dateipfad zum gespeicherten Bild des Belegs.
  ///
  /// Kann `null` sein, wenn für diesen Beleg kein Bild vorhanden ist
  /// (z. B. bei Altdaten oder nach einem fehlgeschlagenen Kopiervorgang).
  final String? imagePath;

  /// Erkannter Händler-/Geschäftsname (z. B. "Spar", "dm", "Lidl").
  ///
  /// Kann `null` sein, wenn der Händler nicht erkannt wurde.
  final String? storeName;

  /// Lokale JSON-Datenstruktur der Bounding-Boxen der erkannten Textzeilen.
  /// 
  /// Speichert die OCR-Rohdaten (Koordinaten) als String für das Debugging UI.
  final String? spatialData;

  /// Ungefilterte Rohausgabe des OCR-Scans (kompletter Text-Dump).
  ///
  /// Dient als Debugging-Gedächtnis: enthält alles, was die KI auf dem Bon
  /// erkannt hat, bevor der Filter-Algorithmus greift. Kann `null` sein
  /// bei Altdaten oder wenn die OCR keinen Text zurückgegeben hat.
  final String? rawText;

  /// Verarbeitungsstatus des Belegs.
  ///
  /// Mögliche Werte:
  ///   - `'processing'`: OCR-Verarbeitung läuft im Hintergrund.
  ///   - `'completed'`: Verarbeitung abgeschlossen.
  ///   - `'failed'`: Verarbeitung fehlgeschlagen (z. B. nach App-Neustart).
  final String status;

  /// Fortschritt der Verarbeitung (0.0–1.0).
  ///
  /// Wird während der OCR-Verarbeitung aktualisiert.
  final double progress;

  /// SHA-256-Hash der Bilddatei.
  ///
  /// Dient der Duplikatserkennung: Bevor ein neues Bild verarbeitet wird,
  /// wird geprüft, ob bereits ein Beleg mit demselben Hash existiert.
  /// Kann `null` sein bei Altdaten oder wenn kein Bild vorhanden ist.
  final String? fileHash;

  const Receipt({
    required this.id,
    required this.date,
    required this.totalAmount,
    required this.items,
    this.categories = const [],
    this.imagePath,
    this.storeName,
    this.spatialData,
    this.rawText,
    this.status = 'completed',
    this.progress = 1.0,
    this.fileHash,
  });

  /// Gibt die Kategorie für den Artikel an Index [i] zurück.
  ///
  /// Fällt auf „Sonstiges" zurück, wenn [categories] keinen Eintrag
  /// für diesen Index enthält.
  String categoryAt(int i) =>
      i < categories.length ? categories[i] : 'Sonstiges';

  /// Erstellt eine Kopie des Belegs mit optionalen geänderten Feldern.
  Receipt copyWith({
    String? id,
    DateTime? date,
    double? totalAmount,
    List<String>? items,
    List<String>? categories,
    String? imagePath,
    String? storeName,
    String? spatialData,
    String? rawText,
    String? status,
    double? progress,
    String? fileHash,
  }) {
    return Receipt(
      id: id ?? this.id,
      date: date ?? this.date,
      totalAmount: totalAmount ?? this.totalAmount,
      items: items ?? this.items,
      categories: categories ?? this.categories,
      imagePath: imagePath ?? this.imagePath,
      storeName: storeName ?? this.storeName,
      spatialData: spatialData ?? this.spatialData,
      rawText: rawText ?? this.rawText,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      fileHash: fileHash ?? this.fileHash,
    );
  }

  /// Konvertiert den Beleg in eine Map für die SQLite-Datenbank.
  ///
  /// Die Artikel-Liste und die Kategorien-Liste werden je als JSON-String
  /// gespeichert.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'totalAmount': totalAmount,
      'items': jsonEncode(items),
      'categories': jsonEncode(categories),
      'imagePath': imagePath,
      'storeName': storeName,
      'spatialData': spatialData,
      'rawText': rawText,
      'status': status,
      'progress': progress,
      'fileHash': fileHash,
    };
  }

  /// Erstellt einen [Receipt] aus einer SQLite-Datenbankzeile.
  ///
  /// Verarbeitet Altdaten ohne `categories`-Spalte, indem fehlende Einträge
  /// auf eine leere Liste fallen.
  factory Receipt.fromMap(Map<String, dynamic> map) {
    final rawItems = map['items'] as String;
    final decoded = jsonDecode(rawItems) as List<dynamic>;

    final rawCategories = map['categories'] as String?;
    final categories = rawCategories != null
        ? (jsonDecode(rawCategories) as List<dynamic>).cast<String>()
        : <String>[];

    return Receipt(
      id: map['id'] as String,
      date: DateTime.parse(map['date'] as String),
      totalAmount: (map['totalAmount'] as num).toDouble(),
      items: decoded.cast<String>(),
      categories: categories,
      imagePath: map['imagePath'] as String?,
      storeName: map['storeName'] as String?,
      spatialData: map['spatialData'] as String?,
      rawText: map['rawText'] as String?,
      status: map['status'] as String? ?? 'completed',
      progress: (map['progress'] as num?)?.toDouble() ?? 1.0,
      fileHash: map['fileHash'] as String?,
    );
  }

  @override
  String toString() {
    return 'Receipt(id: $id, date: $date, totalAmount: $totalAmount, '
        'items: $items, categories: $categories, imagePath: $imagePath, '
        'storeName: $storeName, spatialData: ${spatialData != null ? "y" : "n"}, '
        'rawText: ${rawText != null ? "${rawText!.length} chars" : "null"}, '
        'status: $status, progress: $progress, fileHash: $fileHash)';
  }
}
