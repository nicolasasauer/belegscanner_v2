import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/receipt.dart';
import '../services/category_service.dart';
import '../services/database_service.dart';
import '../services/ocr_service.dart';
import '../pages/ocr_debug_page.dart';

// =============================================================================
// Beleg-Detail BottomSheet Widget
// =============================================================================

/// Detail-Ansicht eines Belegs als BottomSheet mit editierbaren Positionen.
///
/// Wird per [showModalBottomSheet] aus [HomePage] geöffnet.
/// [onShare] und [onSaveToGallery] werden aus dem Parent weitergereicht und
/// steuern Bild-Teilen und Galerie-Speicherung.
class ReceiptDetailView extends StatefulWidget {
  const ReceiptDetailView({
    super.key,
    required this.receipt,
    required this.dateFormat,
    required this.currencyFormat,
    required this.databaseService,
    required this.onSaved,
    this.onShare,
    this.onSaveToGallery,
  });

  final Receipt receipt;
  final DateFormat dateFormat;
  final NumberFormat currencyFormat;
  final DatabaseService databaseService;
  final ValueChanged<Receipt> onSaved;
  final ValueChanged<Receipt>? onShare;
  final ValueChanged<Receipt>? onSaveToGallery;

  @override
  State<ReceiptDetailView> createState() => _ReceiptDetailViewState();
}

class _ReceiptDetailViewState extends State<ReceiptDetailView> {
  late List<TextEditingController> _nameControllers;
  late List<TextEditingController> _priceControllers;

  /// Kategorien der Einzelposten (parallele Liste zu den Controllern).
  late List<String> _categories;

  /// Originale Artikelnamen vor dem Bearbeiten (für den Lern-Feedback-Loop).
  late List<String> _originalNames;

  /// Originale Kategorien vor dem Bearbeiten (für den Lern-Feedback-Loop).
  late List<String> _originalCategories;

  bool _isSaving = false;

  /// Gibt an, ob die Detailansicht im Bearbeitungs-Modus ist.
  bool _isEditing = false;

  /// Lokale Kopie des Gesamtbetrags, der im Edit-Modus überschrieben werden kann.
  late double _editedTotalAmount;

  /// Formatiert Preise im deutschen Dezimalformat (z. B. "1,95").
  final NumberFormat _deDecimalFormat = NumberFormat('#0.00', 'de_DE');

  // ---------------------------------------------------------------------------
  // Easter-Egg: 5-faches schnelles Antippen des Belegbilds öffnet den
  // Raw-OCR-Debug-Modus.
  // ---------------------------------------------------------------------------

  final List<DateTime> _imageTapTimestamps = [];
  static const _debugTapWindow = Duration(seconds: 3);
  static const _debugTapCount = 5;

  @override
  void initState() {
    super.initState();
    _editedTotalAmount = widget.receipt.totalAmount;
    _initControllers(widget.receipt.items);
  }

  void _initControllers(List<String> items) {
    _nameControllers = [];
    _priceControllers = [];
    _categories = [];
    _originalNames = [];
    _originalCategories = [];
    for (var i = 0; i < items.length; i++) {
      final (:name, :price) = parseLineItem(items[i]);
      _nameControllers.add(TextEditingController(text: name));
      final priceCtrl = TextEditingController(
        text: price != null ? _deDecimalFormat.format(price) : '',
      );
      priceCtrl.addListener(_onPriceChanged);
      _priceControllers.add(priceCtrl);
      final cat = widget.receipt.categoryAt(i);
      _categories.add(cat);
      _originalNames.add(name);
      _originalCategories.add(cat);
    }
  }

  void _onPriceChanged() {
    if (_isEditing && mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _nameControllers) c.dispose();
    for (final c in _priceControllers) c.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Summen-Logik
  // ---------------------------------------------------------------------------

  double _computeItemsTotal() {
    double total = 0.0;
    for (final c in _priceControllers) {
      final val = double.tryParse(c.text.trim().replaceAll(',', '.'));
      if (val != null) total += val;
    }
    return (total * 100).round() / 100.0;
  }

  void _addItem() {
    final priceCtrl = TextEditingController();
    priceCtrl.addListener(_onPriceChanged);
    setState(() {
      _nameControllers.add(TextEditingController());
      _priceControllers.add(priceCtrl);
      _categories.add('Sonstiges');
      // Newly added items have no original name → no mapping will be learned.
      _originalNames.add('');
      _originalCategories.add('');
    });
  }

  void _syncTotalFromItems() {
    setState(() => _editedTotalAmount = _computeItemsTotal());
  }

  void _deleteItem(int index) {
    if (index < 0 || index >= _nameControllers.length) return;
    _nameControllers[index].dispose();
    _priceControllers[index].dispose();
    setState(() {
      _nameControllers.removeAt(index);
      _priceControllers.removeAt(index);
      if (index < _categories.length) _categories.removeAt(index);
      if (index < _originalNames.length) _originalNames.removeAt(index);
      if (index < _originalCategories.length) {
        _originalCategories.removeAt(index);
      }
    });
  }

  /// Speichert die geänderten Positionen in der Datenbank.
  ///
  /// Für jeden Artikel, dessen Name oder Kategorie gegenüber dem Original
  /// geändert wurde, wird ein Eintrag in der `product_mappings`-Tabelle
  /// gespeichert (Lern-Feedback-Loop).
  Future<void> _saveChanges() async {
    setState(() => _isSaving = true);
    try {
      final newItems = <String>[];
      final newCategories = <String>[];
      for (var i = 0; i < _nameControllers.length; i++) {
        final name = _nameControllers[i].text.trim();
        if (name.isEmpty) continue;
        final priceText = _priceControllers[i].text.trim();
        newItems.add(priceText.isNotEmpty ? '$name  $priceText' : name);
        newCategories.add(
          i < _categories.length ? _categories[i] : 'Sonstiges',
        );
      }

      final updatedReceipt = widget.receipt.copyWith(
        items: newItems,
        categories: newCategories,
        totalAmount: _editedTotalAmount,
      );
      await widget.databaseService.insertReceipt(updatedReceipt);

      // ── Lern-Feedback-Loop ────────────────────────────────────────────────
      // Für jeden Artikel prüfen, ob Name oder Kategorie geändert wurde.
      // Wenn ja, Mapping in product_mappings speichern und SnackBar anzeigen.
      final learnedMappings = <String>[];

      // Kategorien-ID-Lookup: Kategorienamen → Datenbank-ID
      final Map<String, int?> categoryIdByName = {};
      try {
        final cats = await widget.databaseService.getCategories();
        for (final cat in cats) {
          if (cat.id != null) {
            categoryIdByName[cat.name] = cat.id;
          }
        }
      } catch (_) {}

      for (var i = 0; i < _nameControllers.length; i++) {
        final newName = _nameControllers[i].text.trim();
        if (newName.isEmpty) continue;
        final newCategory =
            i < _categories.length ? _categories[i] : 'Sonstiges';
        final originalName = i < _originalNames.length ? _originalNames[i] : '';
        final originalCategory =
            i < _originalCategories.length ? _originalCategories[i] : '';

        // Änderung erkennen: Name oder Kategorie weicht vom Original ab
        final nameChanged =
            originalName.isNotEmpty && newName != originalName;
        final categoryChanged = originalCategory.isNotEmpty &&
            newCategory != originalCategory;

        if ((nameChanged || categoryChanged) && originalName.isNotEmpty) {
          final categoryId = categoryIdByName[newCategory];
          await widget.databaseService.upsertProductMapping(
            originalName,
            newName,
            categoryId,
          );
          learnedMappings.add('$newName → $newCategory');
        }
      }

      if (mounted) {
        widget.onSaved(updatedReceipt);
        setState(() => _isEditing = false);

        // SnackBar für gelernte Mappings anzeigen
        if (learnedMappings.isNotEmpty) {
          final label = learnedMappings.length == 1
              ? 'Gelernt: "${learnedMappings.first}"'
              : 'Gelernt: ${learnedMappings.length} neue Zuordnungen';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(label),
              duration: const Duration(seconds: 3),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Änderungen gespeichert.')),
          );
        }
      }
    } catch (e, st) {
      debugPrint('[ReceiptDetailView] Save failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Speichern fehlgeschlagen. Bitte erneut versuchen.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final itemsTotal = _computeItemsTotal();
    final mismatch = _isEditing &&
        itemsTotal > 0.005 &&
        (itemsTotal - _editedTotalAmount).abs() > 0.005;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scrollController) {
        final hasImage = widget.receipt.imagePath != null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------------------------------
            // Fixer Kopfbereich (nicht gescrollt)
            // ------------------------------------------------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag-Handle
                  Center(
                    child: Container(
                      width: 48,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // Betrag, Datum und Aktions-Icons
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Text(
                              widget.currencyFormat.format(_editedTotalAmount),
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color:
                                        mismatch ? Colors.orange[700] : null,
                                  ),
                            ),
                            if (mismatch) ...[
                              const SizedBox(width: 4),
                              Tooltip(
                                message: 'Summe der Artikel '
                                    '(${widget.currencyFormat.format(itemsTotal)}) '
                                    'weicht ab',
                                child: Icon(
                                  Icons.warning_amber_outlined,
                                  color: Colors.orange[700],
                                  size: 18,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Text(
                        widget.dateFormat.format(widget.receipt.date),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      // Teilen-Icon (nur wenn Belegbild vorhanden)
                      if (hasImage)
                        IconButton(
                          icon: const Icon(Icons.share_outlined),
                          tooltip: 'Belegbild teilen',
                          onPressed: () =>
                              widget.onShare?.call(widget.receipt),
                        ),
                      // Bearbeiten / Speichern-Icon
                      _isEditing
                          ? IconButton(
                              icon: _isSaving
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.check),
                              tooltip: 'Änderungen speichern',
                              onPressed: _isSaving ? null : _saveChanges,
                            )
                          : IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Bearbeiten',
                              onPressed: () =>
                                  setState(() => _isEditing = true),
                            ),
                      // Drei-Punkte-Menü
                      PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.more_vert,
                          semanticLabel: 'Weitere Optionen',
                        ),
                        tooltip: 'Weitere Optionen',
                        onSelected: (value) async {
                          if (value == 'debug_raw_ocr') {
                            final updatedReceipt = await Navigator.push<Receipt>(
                              context,
                              MaterialPageRoute<Receipt>(
                                builder: (_) => OcrDebugPage(
                                  receipt: widget.receipt,
                                  databaseService: widget.databaseService,
                                ),
                              ),
                            );
                            if (updatedReceipt != null && mounted) {
                              widget.onSaved(updatedReceipt);
                              setState(() {
                                // Since we mutate state locally, we might need a whole reload.
                                // Actually, triggering onSaved propagates it up to HomePage.
                                // We can just pop and let the user open it again, or we can update the UI locally:
                                _editedTotalAmount = updatedReceipt.totalAmount;
                                _initControllers(updatedReceipt.items);
                              });
                            }
                          } else if (value == 'save_to_gallery') {
                            widget.onSaveToGallery?.call(widget.receipt);
                          }
                        },
                        itemBuilder: (_) => [
                          if (hasImage)
                            const PopupMenuItem(
                              value: 'save_to_gallery',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.save_alt_outlined,
                                    size: 18,
                                    semanticLabel: '',
                                  ),
                                  SizedBox(width: 8),
                                  Text('In Galerie speichern'),
                                ],
                              ),
                            ),
                          const PopupMenuItem(
                            value: 'debug_raw_ocr',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.bug_report_outlined,
                                  size: 18,
                                  semanticLabel: '',
                                ),
                                SizedBox(width: 8),
                                Text('DEBUG: Raw OCR'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const Divider(height: 24),

                  // Belegbild (antippen → Vollbild)
                  if (hasImage) ...[
                    _buildImagePreview(context),
                    const Divider(height: 24),
                  ],

                  Text(
                    'Erkannte Positionen',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),

            // ------------------------------------------------------------------
            // Scrollbare Artikel-Liste
            // ------------------------------------------------------------------
            Expanded(
              child: _nameControllers.isEmpty && !_isEditing
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          widget.receipt.totalAmount > 0
                              ? 'Keine Einzelpreise erkannt.\n'
                                  'Tippe auf Bearbeiten, um Artikel '
                                  'manuell hinzuzufügen.'
                              : 'Kein Text erkannt. Bitte Beleg '
                                  'erneut scannen.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount:
                          _nameControllers.length + (_isEditing ? 1 : 0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        if (_isEditing && index == _nameControllers.length) {
                          return _buildEditFooter(context);
                        }
                        return _isEditing
                            ? _buildEditItemRow(context, index)
                            : _buildViewItemRow(context, index);
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Easter-Egg Logik
  // ---------------------------------------------------------------------------

  void _onImageTap() {
    final now = DateTime.now();
    _imageTapTimestamps.add(now);
    _imageTapTimestamps.removeWhere(
      (t) => now.difference(t) > _debugTapWindow,
    );
    debugPrint('Tap count: ${_imageTapTimestamps.length}');

    if (_imageTapTimestamps.length >= _debugTapCount) {
      _imageTapTimestamps.clear();
      _triggerDebugMode();
    } else if (_imageTapTimestamps.length == 1) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              FullscreenImageViewer(imagePath: widget.receipt.imagePath!),
        ),
      );
    }
  }

  void _triggerDebugMode() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Entwicklermodus: Rohdaten werden geladen...'),
        duration: Duration(seconds: 2),
      ),
    );
    final updatedReceipt = await Navigator.push<Receipt>(
      context,
      MaterialPageRoute<Receipt>(
        builder: (_) => OcrDebugPage(
          receipt: widget.receipt,
          databaseService: widget.databaseService,
        ),
      ),
    );
    if (updatedReceipt != null && mounted) {
      widget.onSaved(updatedReceipt);
      setState(() {
        _editedTotalAmount = updatedReceipt.totalAmount;
        _initControllers(updatedReceipt.items);
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build-Helpers
  // ---------------------------------------------------------------------------

  Widget _buildImagePreview(BuildContext context) {
    final path = widget.receipt.imagePath!;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onImageTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            Image.file(
              File(path),
              height: 160,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            Container(
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.zoom_in_outlined,
                color: Colors.white,
                size: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewItemRow(BuildContext context, int index) {
    final name = _nameControllers[index].text;
    final priceText = _priceControllers[index].text.trim();
    final category =
        index < _categories.length ? _categories[index] : 'Sonstiges';
    final showChip = category != 'Sonstiges';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(name),
          if (showChip)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: CategoryService.getCategoryColor(category),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                category,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: CategoryService.getCategoryTextColor(category),
                    ),
              ),
            ),
        ],
      ),
      trailing: priceText.isNotEmpty
          ? Text(
              '$priceText €',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            )
          : null,
    );
  }

  Widget _buildEditItemRow(BuildContext context, int index) {
    final category =
        index < _categories.length ? _categories[index] : 'Sonstiges';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _nameControllers[index],
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Artikel',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _priceControllers[index],
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Preis',
                    isDense: true,
                    border: OutlineInputBorder(),
                    suffixText: '€',
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Position entfernen',
                color: Theme.of(context).colorScheme.error,
                onPressed: () => _deleteItem(index),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.label_outline,
                size: 16,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 4),
              DropdownButton<String>(
                value: category,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: Theme.of(context).textTheme.bodySmall,
                items: CategoryService.availableCategories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      while (_categories.length <= index) {
                        _categories.add('Sonstiges');
                      }
                      _categories[index] = val;
                    });
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Position hinzufügen'),
            onPressed: _addItem,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.calculate_outlined),
            label: const Text('Summe aus Artikeln berechnen'),
            onPressed: _syncTotalFromItems,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Vollbild-Bildanzeige mit Zoom
// =============================================================================

/// Vollbild-Ansicht eines Belegbilds mit Pinch-to-Zoom via [InteractiveViewer].
class FullscreenImageViewer extends StatelessWidget {
  const FullscreenImageViewer({super.key, required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Belegbild'),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6.0,
          child: Image.file(
            File(imagePath),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 64,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
