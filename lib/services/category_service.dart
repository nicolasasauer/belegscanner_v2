import 'package:flutter/material.dart';

/// Hilfsdienst für Kategorie-bezogene Anzeige-Logik.
///
/// Stellt die Liste verfügbarer Kategorien sowie Hilfsmethoden für die
/// Farbanzeige von Kategorie-Labels bereit.
class CategoryService {
  // Nur statische Methoden – keine Instanz nötig.
  CategoryService._();

  /// Alle verfügbaren Kategorie-Namen für die Dropdown-Auswahl.
  static const List<String> availableCategories = [
    'Lebensmittel',
    'Drogerie',
    'Pfand',
    'Getränke',
    'Freizeit',
    'Transport',
    'Sonstiges',
  ];

  /// Hintergrundfarbe für ein Kategorie-Label.
  static Color getCategoryColor(String category) {
    switch (category) {
      case 'Lebensmittel':
        return Colors.green.shade100;
      case 'Drogerie':
        return Colors.blue.shade100;
      case 'Getränke':
        return Colors.orange.shade100;
      case 'Pfand':
        return Colors.purple.shade100;
      default:
        return Colors.grey.shade200;
    }
  }

  /// Textfarbe für ein Kategorie-Label (passend zum Hintergrund).
  static Color getCategoryTextColor(String category) {
    switch (category) {
      case 'Lebensmittel':
        return Colors.green.shade800;
      case 'Drogerie':
        return Colors.blue.shade800;
      case 'Getränke':
        return Colors.orange.shade800;
      case 'Pfand':
        return Colors.purple.shade800;
      default:
        return Colors.grey.shade700;
    }
  }
}
