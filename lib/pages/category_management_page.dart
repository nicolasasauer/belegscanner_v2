import 'package:flutter/material.dart';

import '../models/category.dart';
import '../services/database_service.dart';

/// Seite zur Verwaltung benutzerdefinierter Artikel-Kategorien.
///
/// Zeigt eine Liste aller Kategorien mit ihren Schlagwörtern und ermöglicht:
///   - Hinzufügen neuer Kategorien
///   - Bearbeiten bestehender Kategorien
///   - Löschen von Kategorien (Wischen oder Löschen-Icon)
class CategoryManagementPage extends StatefulWidget {
  const CategoryManagementPage({
    super.key,
    required this.databaseService,
  });

  final DatabaseService databaseService;

  @override
  State<CategoryManagementPage> createState() => _CategoryManagementPageState();
}

class _CategoryManagementPageState extends State<CategoryManagementPage> {
  List<Category> _categories = [];
  bool _isLoading = true;

  // Vordefinierte Farboptionen für neue Kategorien
  static const _colorOptions = [
    '#4CAF50', // Grün
    '#2196F3', // Blau
    '#FF9800', // Orange
    '#FFC107', // Gelb
    '#F44336', // Rot
    '#9C27B0', // Lila
    '#00BCD4', // Cyan
    '#607D8B', // Blau-Grau
  ];

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final categories = await widget.databaseService.getCategories();
    if (mounted) {
      setState(() {
        _categories = categories;
        _isLoading = false;
      });
    }
  }

  /// Öffnet den Hinzufügen/Bearbeiten-Dialog.
  ///
  /// Wenn [category] angegeben ist, wird die bestehende Kategorie bearbeitet;
  /// andernfalls wird eine neue Kategorie angelegt.
  Future<void> _openCategoryDialog({Category? category}) async {
    final nameController = TextEditingController(text: category?.name ?? '');
    final keywordsController =
        TextEditingController(text: category?.keywords ?? '');
    String selectedColor = category?.color.isNotEmpty == true
        ? category!.color
        : _colorOptions.first;

    try {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              return AlertDialog(
                title: Text(
                  category == null
                      ? 'Kategorie hinzufügen'
                      : 'Kategorie bearbeiten',
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name
                      TextField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'z. B. Lebensmittel',
                          border: OutlineInputBorder(),
                        ),
                        textCapitalization: TextCapitalization.sentences,
                      ),
                      const SizedBox(height: 16),
                      // Schlagwörter
                      TextField(
                        controller: keywordsController,
                        decoration: const InputDecoration(
                          labelText: 'Schlagwörter',
                          hintText: 'z. B. Milch,Brot,Obst',
                          helperText:
                              'Mehrere Schlagwörter durch Komma trennen',
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      // Farbe
                      Text(
                        'Farbe',
                        style: Theme.of(ctx).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _colorOptions.map((hex) {
                          final color = _hexToColor(hex);
                          final isSelected = selectedColor == hex;
                          return GestureDetector(
                            onTap: () =>
                                setDialogState(() => selectedColor = hex),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: isSelected
                                    ? Border.all(
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .onSurface,
                                        width: 2.5,
                                      )
                                    : null,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Abbrechen'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Speichern'),
                  ),
                ],
              );
            },
          );
        },
      );

      if (confirmed != true) return;

      final name = nameController.text.trim();
      if (name.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Name darf nicht leer sein.')),
          );
        }
        return;
      }

      final updated = Category(
        id: category?.id,
        name: name,
        keywords: keywordsController.text.trim(),
        color: selectedColor,
      );

      if (category == null) {
        await widget.databaseService.insertCategory(updated);
      } else {
        await widget.databaseService.updateCategory(updated);
      }

      await _loadCategories();
    } finally {
      nameController.dispose();
      keywordsController.dispose();
    }
  }

  Future<void> _deleteCategory(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kategorie löschen?'),
        content: Text(
          'Möchtest du die Kategorie „${category.name}" wirklich löschen?\n\n'
          'Bereits gespeicherte Belege behalten ihre zugeordneten Kategorien.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await widget.databaseService.deleteCategory(category.id!);
    await _loadCategories();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kategorien verwalten'),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _categories.isEmpty
              ? _buildEmptyState()
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  itemCount: _categories.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final cat = _categories[index];
                    return _CategoryTile(
                      category: cat,
                      onEdit: () => _openCategoryDialog(category: cat),
                      onDelete: () => _deleteCategory(cat),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCategoryDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Kategorie hinzufügen'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.label_outline,
              size: 72,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Noch keine Kategorien vorhanden.\nTippe auf „Kategorie hinzufügen".',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Kategorie-ListTile Widget
// =============================================================================

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.onEdit,
    required this.onDelete,
  });

  final Category category;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final color =
        category.color.isNotEmpty ? _hexToColor(category.color) : null;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      elevation: 0.5,
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor:
              color ?? Theme.of(context).colorScheme.primaryContainer,
          radius: 18,
          child: Text(
            category.name.isNotEmpty ? category.name[0].toUpperCase() : '?',
            style: TextStyle(
              color: color != null
                  ? _contrastColor(color)
                  : Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          category.name,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        subtitle: category.keywords.isNotEmpty
            ? Text(
                category.keywords,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              )
            : const Text('Keine Schlagwörter'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Bearbeiten',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Löschen',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Farb-Hilfsfunktionen
// =============================================================================

/// Fallback-Farbe (mittleres Grau) für ungültige Hex-Codes.
const int _kFallbackColorValue = 0xFF9E9E9E;

/// Luminanz-Schwellenwert zur Bestimmung des Kontrast-Textfarbe.
///
/// Werte über diesem Schwellenwert gelten als „hell" → schwarze Schrift.
/// Werte darunter gelten als „dunkel" → weiße Schrift.
const double _kLuminanceThreshold = 0.45;

/// Konvertiert einen Hex-Farbcode (z. B. "#4CAF50") in eine [Color].
Color _hexToColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16) ?? _kFallbackColorValue;
  return Color(0xFF000000 | value);
}

/// Gibt Schwarz oder Weiß zurück, je nachdem welche Farbe auf [background]
/// besser lesbar ist (einfacher Kontrast-Check).
Color _contrastColor(Color background) {
  final luminance = background.computeLuminance();
  return luminance > _kLuminanceThreshold ? Colors.black : Colors.white;
}
