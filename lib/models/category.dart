/// Datenmodell für eine benutzerdefinierte Artikel-Kategorie.
class Category {
  /// Eindeutige Datenbank-ID (null vor dem ersten Speichern).
  final int? id;

  /// Anzeigename der Kategorie (z. B. „Lebensmittel").
  final String name;

  /// Kommagetrennte Schlagwörter für die automatische Zuordnung.
  ///
  /// Beispiel: "Bio,Tofu,Milch,Brot"
  final String keywords;

  /// Farbe der Kategorie als Hex-String (z. B. "#4CAF50").
  ///
  /// Wird in der UI als farbiger Indikator angezeigt.
  final String color;

  const Category({
    this.id,
    required this.name,
    required this.keywords,
    this.color = '',
  });

  /// Gibt die Schlagwörter als bereingte Liste zurück (lowercase, ohne Leerzeichen).
  List<String> get keywordList => keywords
      .split(',')
      .map((e) => e.trim().toLowerCase())
      .where((e) => e.isNotEmpty)
      .toList();

  /// Erstellt eine Kopie mit optionalen geänderten Feldern.
  Category copyWith({
    int? id,
    String? name,
    String? keywords,
    String? color,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      keywords: keywords ?? this.keywords,
      color: color ?? this.color,
    );
  }

  /// Konvertiert die Kategorie in eine Map für SQLite.
  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'keywords': keywords,
      'color': color,
    };
  }

  /// Erstellt eine [Category] aus einer SQLite-Datenbankzeile.
  factory Category.fromMap(Map<String, dynamic> map) {
    return Category(
      id: map['id'] as int?,
      name: map['name'] as String,
      keywords: map['keywords'] as String,
      color: (map['color'] as String?) ?? '',
    );
  }

  @override
  String toString() =>
      'Category(id: $id, name: $name, keywords: $keywords, color: $color)';
}
