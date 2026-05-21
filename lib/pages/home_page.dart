import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/receipt.dart';
import '../pages/model_setup_page.dart';
import '../services/database_service.dart';
import '../services/export_service.dart';
import '../services/ocr_service.dart';
import '../services/processor_service.dart';
import '../widgets/ai_status_badge.dart';
import '../widgets/fab_menu_item.dart';
import '../widgets/filter_bar.dart';
import '../widgets/processing_receipt_card.dart';
import '../widgets/receipt_detail_view.dart';
import '../widgets/receipt_list_tile.dart';
import 'category_management_page.dart';

/// Hauptseite der Bong-Scanner-App.
///
/// Zeigt eine gefilterte Liste der gescannten Belege und ermöglicht
/// das Starten eines neuen Scans über den FloatingActionButton.
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.databaseService});

  /// Optionaler gemeinsam genutzter Datenbankservice.
  final DatabaseService? databaseService;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ---------------------------------------------------------------------------
  // Zustand
  // ---------------------------------------------------------------------------

  final List<Receipt> _receipts = [];
  bool _isScanning = false;
  int? _selectedDay;
  int? _selectedMonth;
  int? _selectedYear;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearching = false;
  bool _isFabExpanded = false;
  bool _sortAscending = false;
  /// Aktuelles Sortierfeld: `'date'` (Standard) oder `'amount'`.
  String _sortField = 'date';

  // ---------------------------------------------------------------------------
  // Services & Formatter
  // ---------------------------------------------------------------------------

  late final DatabaseService _databaseService;
  late final OcrService _ocrService;
  late final ProcessorService _processorService;

  final NumberFormat _currencyFormat = NumberFormat.currency(
    locale: 'de_DE',
    symbol: '€',
  );
  final DateFormat _dateFormat = DateFormat('d. MMMM yyyy', 'de_DE');

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _databaseService = widget.databaseService ?? DatabaseService();
    _ocrService = OcrService(databaseService: _databaseService);
    _processorService = ProcessorService(databaseService: _databaseService)
      ..onReceiptUpdated = _onReceiptUpdated;
    Future.delayed(const Duration(milliseconds: 500), () async {
      await _processorService.loadSettings();
      await _processorService.markInterruptedAsFailed();
      await _loadReceipts();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Wird aufgerufen, sobald [ProcessorService] einen Beleg aktualisiert hat.
  ///
  /// Ersetzt den bestehenden Eintrag in [_receipts] oder entfernt ihn, wenn
  /// er als Duplikat übersprungen wurde.
  void _onReceiptUpdated(Receipt updated) {
    if (!mounted) return;
    setState(() {
      if (updated.status == 'duplicate') {
        // Duplikat-Platzhalter aus der UI entfernen
        _receipts.removeWhere((r) => r.id == updated.id);
      } else {
        final idx = _receipts.indexWhere((r) => r.id == updated.id);
        if (idx != -1) {
          _receipts[idx] = updated;
        }
      }
    });
  }

  Future<void> _loadReceipts() async {
    final receipts = await _databaseService.getAllReceipts();
    if (mounted) {
      setState(() {
        _receipts
          ..clear()
          ..addAll(receipts);
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Berechnete Eigenschaften
  // ---------------------------------------------------------------------------

  List<Receipt> get _filteredReceipts {
    return _receipts.where((receipt) {
      if (_selectedDay != null && receipt.date.day != _selectedDay) {
        return false;
      }
      if (_selectedMonth != null && receipt.date.month != _selectedMonth) {
        return false;
      }
      if (_selectedYear != null && receipt.date.year != _selectedYear) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchesMerchant = (receipt.storeName?.toLowerCase().contains(q) ?? false) ||
            (receipt.items.isNotEmpty && receipt.items.first.toLowerCase().contains(q));
        final matchesAmount =
            receipt.totalAmount.toString().contains(q) ||
                _currencyFormat.format(receipt.totalAmount).contains(q);
        final matchesItems =
            receipt.items.any((item) => item.toLowerCase().contains(q));
        final matchesRawText = receipt.rawText?.toLowerCase().contains(q) ?? false;
        
        if (!matchesMerchant && !matchesAmount && !matchesItems && !matchesRawText) {
          return false;
        }
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final int cmp;
        if (_sortField == 'amount') {
          cmp = a.totalAmount.compareTo(b.totalAmount);
        } else {
          cmp = a.date.compareTo(b.date);
        }
        return _sortAscending ? cmp : -cmp;
      });
  }

  // ---------------------------------------------------------------------------
  // Aktionen
  // ---------------------------------------------------------------------------

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDay = picked.day;
        _selectedMonth = picked.month;
        _selectedYear = picked.year;
      });
    }
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDay = null;
        _selectedMonth = picked.month;
        _selectedYear = picked.year;
      });
    }
  }

  Future<void> _pickYear() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDay = null;
        _selectedMonth = null;
        _selectedYear = picked.year;
      });
    }
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    try {
      final receipt = await _ocrService.scanReceipt();
      if (receipt != null && mounted) {
        await _databaseService.insertReceipt(receipt);
        setState(() => _receipts.add(receipt));
        if (receipt.totalAmount == 0.0 && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Betrag konnte nicht automatisch erkannt werden. '
                'Bitte manuell prüfen.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Hoppla, da ist beim Scannen etwas schiefgelaufen. '
              'Bitte versuche es erneut.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  void _clearFilters() {
    setState(() {
      _selectedDay = null;
      _selectedMonth = null;
      _selectedYear = null;
    });
  }

  void _clearSearch() {
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _isSearching = false;
    });
  }

  Future<void> _importFromGallery() async {
    try {
      // Mehrere Bilder auswählen; gibt Platzhalter-Receipts zurück
      final placeholders = await _ocrService.pickMultipleImages();
      if (placeholders.isEmpty || !mounted) return;

      // Zähler zurücksetzen und alle Platzhalter sofort in DB + UI eintragen
      _processorService.skippedDuplicates = 0;
      for (final placeholder in placeholders) {
        await _databaseService.insertReceipt(placeholder);
        if (mounted) setState(() => _receipts.insert(0, placeholder));
      }

      // Alle Jobs in die Warteschlange einreihen
      for (final placeholder in placeholders) {
        _processorService.enqueue(placeholder);
      }

      // Nach Abschluss aller Jobs ggf. Duplikat-Meldung anzeigen
      // Wir warten kurz und prüfen dann wiederholt, bis die Queue leer ist.
      _waitForQueueAndNotify(placeholders.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Hoppla, da ist beim Importieren etwas schiefgelaufen. '
              'Bitte versuche es erneut.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Wartet asynchron, bis alle [total] Jobs abgeschlossen sind, und zeigt
  /// dann eine Zusammenfassung an (inkl. Duplikate).
  void _waitForQueueAndNotify(int total) {
    // Polling: alle 500 ms prüfen, ob noch 'processing'-Belege vorhanden sind.
    Future.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      final processing =
          _receipts.where((r) => r.status == 'processing').toList();
      if (processing.isNotEmpty) {
        _waitForQueueAndNotify(total);
        return;
      }
      // Alle Jobs fertig → Zusammenfassung anzeigen
      final dupes = _processorService.skippedDuplicates;
      if (dupes > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              dupes == 1
                  ? '1 Duplikat wurde übersprungen.'
                  : '$dupes Duplikate wurden übersprungen.',
            ),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () =>
                  ScaffoldMessenger.of(context).hideCurrentSnackBar(),
            ),
          ),
        );
        _processorService.skippedDuplicates = 0;
      }
    });
  }

  Future<void> _deleteReceipt(Receipt receipt) async {
    await _databaseService.deleteReceipt(receipt.id);
    if (receipt.imagePath != null) {
      final imageFile = File(receipt.imagePath!);
      if (imageFile.existsSync()) {
        try {
          await imageFile.delete();
        } catch (_) {}
      }
    }
    if (mounted) {
      setState(() => _receipts.removeWhere((r) => r.id == receipt.id));
    }
  }

  // ---------------------------------------------------------------------------
  // Export / Sharing  (dünne UI-Wrapper um ExportService)
  // ---------------------------------------------------------------------------

  /// Teilt das Belegbild über das native Share-Sheet.
  Future<void> _shareReceipt(Receipt receipt) async {
    try {
      await ExportService.shareImage(receipt);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Teilen fehlgeschlagen. Bitte erneut versuchen.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Speichert das Belegbild in der Gerätegalerie.
  Future<void> _saveToGallery(Receipt receipt) async {
    try {
      final fileName = ExportService.getExportFileName(receipt);
      final success = await ExportService.saveImageToGallery(receipt);
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Als $fileName in Galerie gespeichert')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Speichern in Galerie fehlgeschlagen. Bitte erneut versuchen.',
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Speichern in Galerie fehlgeschlagen. Bitte erneut versuchen.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  /// Exportiert alle Belege als CSV und teilt sie über das Share-Sheet.
  Future<void> _exportToCsv() async {
    if (_receipts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keine Belege zum Exportieren vorhanden.'),
        ),
      );
      return;
    }
    try {
      final cacheDir = await _databaseService.getDatabasesDirectory();
      await ExportService.shareCsv(_receipts, cacheDir);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Export fehlgeschlagen. Bitte versuche es erneut.',
            ),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _exportKnowledge() async {
    try {
      await ExportService.exportKnowledge(_databaseService);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler beim Exportieren: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _importKnowledge() async {
    try {
      final count = await ExportService.importKnowledge(_databaseService);
      if (!mounted) return;
      if (count >= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$count Mappings erfolgreich importiert.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fehler beim Importieren: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Zeigt die Detail-Ansicht eines Belegs in einem BottomSheet.
  void _showReceiptDetails(Receipt receipt) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(ctx).bottom,
        ),
        child: ReceiptDetailView(
          receipt: receipt,
          dateFormat: _dateFormat,
          currencyFormat: _currencyFormat,
          databaseService: _databaseService,
          onSaved: (updatedReceipt) {
            setState(() {
              final idx =
                  _receipts.indexWhere((r) => r.id == updatedReceipt.id);
              if (idx != -1) _receipts[idx] = updatedReceipt;
            });
          },
          onShare: _shareReceipt,
          onSaveToGallery: _saveToGallery,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredReceipts;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Händler, Betrag, OCR-Text…',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                style: TextStyle(color: colorScheme.onSurface),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : const Text('Bong-Scanner'),
        centerTitle: !_isSearching,
        actions: [
          if (!_isSearching)
            AiStatusBadge(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ModelSetupPage()),
                ).then((_) {
                  if (mounted) setState(() {});
                });
              },
            ),
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Suche schließen',
              onPressed: _clearSearch,
            )
          else
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Belege durchsuchen',
              onPressed: () => setState(() => _isSearching = true),
            ),
          if (_receipts.isNotEmpty)
            PopupMenuButton<String>(
              icon: Icon(
                _sortField == 'amount'
                    ? Icons.euro
                    : Icons.calendar_today,
              ),
              tooltip: 'Sortierung',
              onSelected: (value) {
                setState(() {
                  if (value == 'date_asc') {
                    _sortField = 'date';
                    _sortAscending = true;
                  } else if (value == 'date_desc') {
                    _sortField = 'date';
                    _sortAscending = false;
                  } else if (value == 'amount_asc') {
                    _sortField = 'amount';
                    _sortAscending = true;
                  } else if (value == 'amount_desc') {
                    _sortField = 'amount';
                    _sortAscending = false;
                  }
                });
              },
              itemBuilder: (context) => [
                CheckedPopupMenuItem(
                  value: 'date_desc',
                  checked: _sortField == 'date' && !_sortAscending,
                  child: const Text('Datum (neu → alt)'),
                ),
                CheckedPopupMenuItem(
                  value: 'date_asc',
                  checked: _sortField == 'date' && _sortAscending,
                  child: const Text('Datum (alt → neu)'),
                ),
                CheckedPopupMenuItem(
                  value: 'amount_desc',
                  checked: _sortField == 'amount' && !_sortAscending,
                  child: const Text('Betrag (hoch → niedrig)'),
                ),
                CheckedPopupMenuItem(
                  value: 'amount_asc',
                  checked: _sortField == 'amount' && _sortAscending,
                  child: const Text('Betrag (niedrig → hoch)'),
                ),
              ],
            ),
          if (_receipts.isNotEmpty && !_isSearching)
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: 'Belege als CSV exportieren',
              onPressed: _isScanning ? null : _exportToCsv,
            ),
          if ((_selectedDay != null ||
                  _selectedMonth != null ||
                  _selectedYear != null) &&
              !_isSearching)
            IconButton(
              icon: const Icon(Icons.filter_alt_off),
              tooltip: 'Filter zurücksetzen',
              onPressed: _clearFilters,
            ),
          if (!_isSearching)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Weitere Optionen',
              onSelected: (value) {
                if (value == 'export_knowledge') {
                  _exportKnowledge();
                } else if (value == 'import_knowledge') {
                  _importKnowledge();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'export_knowledge',
                  child: Text('Wissen exportieren (JSON)'),
                ),
                const PopupMenuItem(
                  value: 'import_knowledge',
                  child: Text('Wissen importieren (JSON)'),
                ),
              ],
            ),
        ],
        bottom: _isScanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: Column(
        children: [
          FilterBar(
            hasReceipts: _receipts.isNotEmpty,
            selectedDay: _selectedDay,
            selectedMonth: _selectedMonth,
            selectedYear: _selectedYear,
            onPickDay: _pickDay,
            onPickMonth: _pickMonth,
            onPickYear: _pickYear,
            onClearAll: _clearFilters,
          ),
          Expanded(
            child: Stack(
              children: [
                filtered.isEmpty
                    ? _buildEmptyState()
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 4),
                        itemBuilder: (context, index) {
                          final receipt = filtered[index];
                          return Dismissible(
                            key: ValueKey(receipt.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .errorContainer,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Icon(
                                Icons.delete_outline,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                            ),
                            confirmDismiss: (_) async {
                              return await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Beleg löschen?'),
                                      content: const Text(
                                        'Möchtest du diesen Beleg und das '
                                        'zugehörige Bild wirklich löschen?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Abbrechen'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Löschen'),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                            },
                            onDismissed: (_) => _deleteReceipt(receipt),
                            child: receipt.status == 'processing' ||
                                    receipt.status == 'failed'
                                ? ProcessingReceiptCard(receipt: receipt)
                                : ReceiptListTile(
                                    receipt: receipt,
                                    dateFormat: _dateFormat,
                                    currencyFormat: _currencyFormat,
                                    onTap: () => _showReceiptDetails(receipt),
                                  ),
                          );
                        },
                      ),

                // FAB-Menü-Hintergrund
                if (_isFabExpanded)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _isFabExpanded = false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        color: colorScheme.scrim.withValues(alpha: 0.25),
                      ),
                    ),
                  ),

                // Scan/Import-Overlay
                if (_isScanning)
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: Container(
                      color: colorScheme.scrim.withValues(alpha: 0.15),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            'Verarbeitung läuft…',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: colorScheme.onSurface),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _buildFab(context),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DrawerHeader(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 40,
                      color:
                          Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Bong-Scanner',
                      style:
                          Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('Kategorien verwalten'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CategoryManagementPage(
                        databaseService: _databaseService,
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Einstellungen'),
                onTap: () {
                  Navigator.pop(context);
                  _showSettingsDialog();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Zeigt einen Einstellungs-Dialog mit einem Slider für die maximale
  /// Anzahl gleichzeitiger Verarbeitungs-Jobs.
  Future<void> _showSettingsDialog() async {
    double current = _processorService.maxConcurrent.toDouble();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Einstellungen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Parallele Verarbeitungs-Jobs: ${current.round()}',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              Slider(
                value: current,
                min: 1,
                max: 5,
                divisions: 4,
                label: current.round().toString(),
                onChanged: (v) => setDialogState(() => current = v),
              ),
              const SizedBox(height: 4),
              Text(
                'Höhere Werte verarbeiten mehr Bilder gleichzeitig, '
                'können aber die App verlangsamen.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () async {
                // maxConcurrent wird sofort gesetzt; laufende Jobs werden
                // nicht abgebrochen. Der neue Wert gilt für alle folgenden
                // Job-Starts, sobald ein aktiver Slot frei wird.
                _processorService.maxConcurrent = current.round();
                await _processorService.saveSettings();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFab(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        AnimatedSlide(
          offset: _isFabExpanded ? Offset.zero : const Offset(0, 0.5),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _isFabExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_isFabExpanded,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FabMenuItem(
                    icon: Icons.photo_library_outlined,
                    label: 'Bilder Import',
                    onPressed: () {
                      setState(() => _isFabExpanded = false);
                      _importFromGallery();
                    },
                  ),
                  const SizedBox(height: 10),
                  FabMenuItem(
                    icon: Icons.camera_alt_outlined,
                    label: 'Kamera Scan',
                    onPressed: () {
                      setState(() => _isFabExpanded = false);
                      _startScan();
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
        FloatingActionButton(
          heroTag: 'mainFab',
          onPressed: _isScanning
              ? null
              : () => setState(() => _isFabExpanded = !_isFabExpanded),
          tooltip: _isFabExpanded ? 'Menü schließen' : 'Beleg hinzufügen',
          child: AnimatedRotation(
            turns: _isFabExpanded ? 0.125 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.add),
          ),
        ),
      ],
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
              Icons.receipt_long_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _receipts.isEmpty
                  ? 'Noch keine Belege vorhanden.\nTippe auf „Beleg hinzufügen", um loszulegen.'
                  : 'Keine Belege für den gewählten Filter.',
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
