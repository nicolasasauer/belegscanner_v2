import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/gemma_service.dart';
import '../services/backup_service.dart';

// ---------------------------------------------------------------------------
// ModelSetupPage
// ---------------------------------------------------------------------------

/// Einrichtungsseite für das lokale Gemma-Modell.
///
/// Wird über die Einstellungen der App erreichbar gemacht. Erlaubt:
/// - KI-Kategorisierung ein-/ausschalten
/// - Modelldatei aus dem Gerätespeicher importieren
/// - Installiertes Modell anzeigen und entfernen
/// - Modell-Temperatur anpassen
///
/// **Voraussetzung:** Die Nutzer:in muss die Gemma-Modelldatei (.task-Format)
/// vorab auf das Gerät übertragen haben (z.B. via USB, ADB oder Cloud-Sync).
/// Die Datei wird danach in das App-eigene Verzeichnis kopiert und ist dann
/// vollständig offline verfügbar.
class ModelSetupPage extends StatefulWidget {
  const ModelSetupPage({super.key});

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
  final GemmaService _gemma = GemmaService.instance;

  bool _isLoading = false;
  String _loadingMessage = '';
  double? _modelFileSizeMb;
  double _downloadProgress = 0.0;
  bool _wifiOnly = true;
  final List<String> _presets = [
    'https://example.com/gemma2b.task',
    'https://example.com/gemma3b.task',
  ];

  @override
  void initState() {
    super.initState();
    _refreshModelInfo();
    _loadBackupSettings();
  }

  Future<void> _loadBackupSettings() async {
    await BackupService.instance.loadSettings();
    setState(() {
      // nothing else cached here; UI reads from service when building
    });
  }

  // ── Modell-Info ───────────────────────────────────────────────────────────

  Future<void> _refreshModelInfo() async {
    if (_gemma.modelPath != null) {
      try {
        final f = File(_gemma.modelPath!);
        if (f.existsSync()) {
          final bytes = await f.length();
          setState(() {
            _modelFileSizeMb = bytes / (1024 * 1024);
          });
          return;
        }
      } catch (_) {}
    }
    setState(() {
      _modelFileSizeMb = null;
    });
  }

  // ── Aktionen ──────────────────────────────────────────────────────────────

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _gemma.isEnabled = value);
    await _gemma.saveSettings();

    if (value && _gemma.modelPath != null) {
      // Modell beim Aktivieren vorladen (im Hintergrund)
      setState(() {
        _isLoading = true;
        _loadingMessage = 'Modell wird geladen…';
      });
      await _gemma.ensureReady();
      setState(() => _isLoading = false);
    } else if (!value) {
      await _gemma.unloadModel();
    }
  }

  Future<void> _pickAndInstallModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        dialogTitle: 'Gemma-Modelldatei auswählen (.task)',
      );

      if (result == null || result.files.isEmpty) return;
      final sourcePath = result.files.first.path;
      if (sourcePath == null) return;

      // Dateiname validieren
      final ext = p.extension(sourcePath).toLowerCase();
      if (ext != '.task' && ext != '.bin' && ext != '.tflite') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Bitte eine .task-Datei (MediaPipe-Format) auswählen.',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      setState(() {
        _isLoading = true;
        _loadingMessage = 'Modell wird installiert und geladen…\n'
            'Dies kann bei großen Dateien (>1 GB) einige Minuten dauern.';
      });

      final installedPath = await _gemma.installAndLoadModel(sourcePath);

      setState(() => _isLoading = false);
      await _refreshModelInfo();

      if (!mounted) return;
      if (installedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Modell erfolgreich installiert und geladen!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Fehler beim Installieren: ${_gemma.statusMessage}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Datei-Auswahl fehlgeschlagen: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _removeModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modell entfernen?'),
        content: const Text(
          'Die Modelldatei wird aus dem App-Speicher gelöscht. '
          'Die KI-Kategorisierung ist danach nicht mehr verfügbar, '
          'bis ein Modell neu installiert wird.\n\n'
          'Keyword-basierte Kategorisierung bleibt weiterhin aktiv.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Modell wird entfernt…';
    });
    await _gemma.removeModel();
    setState(() => _isLoading = false);
    await _refreshModelInfo();
  }

  Future<void> _testInference() async {
    setState(() {
      _isLoading = true;
      _loadingMessage = 'Testanfrage läuft…';
    });

    final testItems = [
      'Vollmilch 3,5% 1L  1,29',
      'Red Bull Sugarfree 250ml  1,79',
      'Colgate Zahnpasta Total  2,49',
      'Pfand 0,25  0,25',
    ];

    final result = await _gemma.categorizeItems(
      testItems.map((i) => i.split('  ').first).toList(),
      ['Lebensmittel', 'Getränke', 'Drogerie', 'Pfand', 'Sonstiges'],
    );

    setState(() => _isLoading = false);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test-Ergebnis'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Testartikel:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...testItems.asMap().entries.map((e) {
              final cat = result != null && e.key < result.length
                  ? result[e.key]
                  : '—';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${e.value.split('  ').first}  →  $cat',
                  style: const TextStyle(fontSize: 13),
                ),
              );
            }),
            if (result == null) ...[
              const SizedBox(height: 12),
              Text(
                'Fehler: ${_gemma.statusMessage}',
                style: const TextStyle(color: Colors.red),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstallFromUrl({String? presetUrl}) async {
    String? url = presetUrl;
    if (url == null) {
      final controller = TextEditingController();
      url = await showDialog<String?>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Modell-URL eingeben'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://example.com/gemma2b.task',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Download')),
          ],
        ),
      );
    }

    if (url == null || url.isEmpty) return;

    if (_wifiOnly) {
      // Hinweis: tatsächliche Netzwerkkontrolle ist nicht implementiert.
      final proceed = await showDialog<bool?>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Nur WLAN-Download'),
          content: const Text('Der Download ist auf WLAN beschränkt (Hinweis: die App prüft das nicht automatisch). Möchtest du fortfahren?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Fortfahren')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = 'Modell wird heruntergeladen…';
      _downloadProgress = 0.0;
    });

    final installedPath = await _gemma.downloadAndInstallModel(
      url,
      onProgress: (p) {
        setState(() {
          _downloadProgress = p.clamp(0.0, 1.0);
          _loadingMessage = 'Download: ${(p * 100).toStringAsFixed(0)}%';
        });
      },
    );

    setState(() => _isLoading = false);
    await _refreshModelInfo();

    if (!mounted) return;
    if (installedPath != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✓ Modell erfolgreich heruntergeladen und installiert!'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Fehler beim Download: ${_gemma.statusMessage}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lokale KI-Einrichtung'),
        centerTitle: false,
      ),
      body: _isLoading
          ? _buildLoadingOverlay()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Status-Banner ────────────────────────────────────────
                _buildStatusBanner(colorScheme),
                const SizedBox(height: 20),

                // ── Aktivierung ──────────────────────────────────────────
                _buildSection(
                  title: 'KI-Kategorisierung',
                  children: [
                    SwitchListTile(
                      title: const Text('Lokal aktivieren'),
                      subtitle: Text(
                        _gemma.isEnabled
                            ? 'Gemma analysiert Artikel nach dem OCR-Scan.'
                            : 'Nur Keyword-basierte Kategorisierung aktiv.',
                      ),
                      value: _gemma.isEnabled,
                      onChanged:
                          _gemma.modelPath != null ? _toggleEnabled : null,
                    ),
                    if (_gemma.modelPath == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Text(
                          'Zuerst ein Gemma-Modell installieren, '
                          'um die KI zu aktivieren.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                                    ListTile(
                                      leading: const Icon(Icons.download_outlined),
                                      title: const Text('Modell herunterladen'),
                                      subtitle: const Text(
                                        'Modell automatisch herunterladen und installieren',
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        icon: const Icon(Icons.more_vert),
                                        onSelected: (v) => _downloadAndInstallFromUrl(presetUrl: v),
                                        itemBuilder: (ctx) => [
                                          ..._presets.map((p) => PopupMenuItem(value: p, child: Text('Download $p'))),
                                          const PopupMenuItem(value: '__custom__', child: Text('Benutzerdefinierte URL...')),
                                        ],
                                      ),
                                      onTap: () => _downloadAndInstallFromUrl(),
                                    ),
                                    SwitchListTile(
                                      title: const Text('Nur WLAN-Download'),
                                      subtitle: const Text('Verhindert große Mobilfunk-Downloads (Hinweis: Erfordert ggf. Erlaubnis)'),
                                      value: _wifiOnly,
                                      onChanged: (v) => setState(() => _wifiOnly = v),
                                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Modell-Verwaltung ────────────────────────────────────
                _buildSection(
                  title: 'Modell',
                  children: [
                    if (_gemma.modelPath != null && _modelFileSizeMb != null)
                      _buildInstalledModelTile(colorScheme)
                    else
                      _buildNoModelTile(colorScheme),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.folder_open_outlined),
                      title: const Text('Modelldatei auswählen'),
                      subtitle: const Text(
                        'MediaPipe .task-Format (Gemma 2B oder 3B empfohlen)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _pickAndInstallModel,
                    ),
                    if (_gemma.modelPath != null) ...[
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(
                          Icons.play_circle_outline,
                          color: Colors.green,
                        ),
                        title: const Text('Inferenz testen'),
                        subtitle: const Text(
                          'Kurze Testanfrage mit 4 Musterartikeln',
                        ),
                        onTap: _gemma.isReady ? _testInference : null,
                        enabled: _gemma.isReady,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        title: const Text(
                          'Modell entfernen',
                          style: TextStyle(color: Colors.red),
                        ),
                        subtitle: const Text('Löscht die Modelldatei vom Gerät'),
                        onTap: _removeModel,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),

                // ── Erweiterte Einstellungen ─────────────────────────────
                _buildSection(
                  title: 'Erweiterte Einstellungen',
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Inferenz-Temperatur',
                                style: theme.textTheme.bodyMedium,
                              ),
                              Text(
                                _gemma.temperature.toStringAsFixed(2),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                          Slider(
                            value: _gemma.temperature,
                            min: 0.0,
                            max: 1.0,
                            divisions: 10,
                            onChanged: (v) async {
                              setState(() => _gemma.temperature = v);
                              await _gemma.saveSettings();
                            },
                          ),
                          Text(
                            'Niedrig (0.0) = deterministisch, reproducierbar. '
                            'Hoch (1.0) = kreativ, variabel. '
                            'Für Kategorisierung empfohlen: 0.0–0.2.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Anleitung ────────────────────────────────────────────
                _buildSection(
                  title: 'Anleitung',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildStep(
                            '1',
                            'Modell herunterladen',
                            'Gemma 2B-IT im MediaPipe-Format (.task) von '
                                'kaggle.com/models/google/gemma oder über '
                                'Hugging Face herunterladen.',
                          ),
                          const SizedBox(height: 12),
                          _buildStep(
                            '2',
                            'Auf Gerät übertragen',
                            'Die .task-Datei per USB, ADB push oder Cloud-Sync '
                                'in den Download-Ordner des Geräts kopieren.\n'
                                'Beispiel: adb push gemma2b.task /sdcard/Download/',
                          ),
                          const SizedBox(height: 12),
                          _buildStep(
                            '3',
                            'Modell auswählen',
                            '"Modelldatei auswählen" antippen und die '
                                '.task-Datei aus dem Datei-Manager wählen.',
                          ),
                          const SizedBox(height: 12),
                          _buildStep(
                            '4',
                            'KI aktivieren',
                            'Nach erfolgreicher Installation den Schalter '
                                '"Lokal aktivieren" einschalten.',
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.shield_outlined,
                                  color: colorScheme.onPrimaryContainer,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Privacy-first: Alle KI-Inferenzen laufen '
                                    'vollständig lokal auf deinem Gerät. Es werden '
                                    'keine Daten an externe Server gesendet.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _buildSection(
                  title: 'Datenbank-Backup',
                  children: [
                    SwitchListTile(
                      title: const Text('Automatische Backups'),
                      subtitle: const Text('Täglich oder wöchentlich automatische DB-Backups erstellen'),
                      value: BackupService.instance.enabled,
                      onChanged: (v) async {
                        BackupService.instance.enabled = v;
                        await BackupService.instance.saveSettings();
                        setState(() {});
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.schedule_outlined),
                      title: const Text('Frequenz'),
                      subtitle: Text(BackupService.instance.frequency == 'daily' ? 'Täglich' : 'Wöchentlich'),
                      onTap: () async {
                        final choice = await showDialog<String?>(
                          context: context,
                          builder: (ctx) => SimpleDialog(
                            title: const Text('Frequenz wählen'),
                            children: [
                              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'daily'), child: const Text('Täglich')),
                              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'weekly'), child: const Text('Wöchentlich')),
                            ],
                          ),
                        );
                        if (choice != null) {
                          BackupService.instance.frequency = choice;
                          await BackupService.instance.saveSettings();
                          setState(() {});
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.access_time_outlined),
                      title: const Text('Uhrzeit'),
                      subtitle: Text(BackupService.instance.time),
                      onTap: () async {
                        final parts = BackupService.instance.time.split(':');
                        final initial = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
                        final picked = await showTimePicker(context: context, initialTime: initial);
                        if (picked != null) {
                          BackupService.instance.time = '${picked.hour.toString().padLeft(2,'0')}:${picked.minute.toString().padLeft(2,'0')}';
                          await BackupService.instance.saveSettings();
                          setState(() {});
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.history_outlined),
                      title: const Text('Maximale Backup-Versionen'),
                      subtitle: Text('${BackupService.instance.maxVersions}'),
                      onTap: () async {
                        final controller = TextEditingController(text: BackupService.instance.maxVersions.toString());
                        final v = await showDialog<int?>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Anzahl Versionen'),
                            content: TextField(
                              controller: controller,
                              keyboardType: TextInputType.number,
                            ),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Abbrechen')),
                              FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(controller.text)), child: const Text('Speichern')),
                            ],
                          ),
                        );
                        if (v != null && v > 0) {
                          BackupService.instance.maxVersions = v;
                          await BackupService.instance.saveSettings();
                          setState(() {});
                        }
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.backup_outlined),
                      title: const Text('Jetzt Backup erstellen'),
                      onTap: () async {
                        setState(() { _isLoading = true; _loadingMessage = 'Backup läuft…'; });
                        final path = await BackupService.instance.performBackup();
                        setState(() { _isLoading = false; });
                        if (path != null) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup erstellt: ${path.split('/').last}')));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup fehlgeschlagen'), backgroundColor: Colors.red));
                        }
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: _buildBackupListWidget(),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  // ── Hilfs-Widgets ─────────────────────────────────────────────────────────

  Widget _buildLoadingOverlay() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              _loadingMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner(ColorScheme cs) {
    final isReady = _gemma.isReady;
    final isEnabled = _gemma.isEnabled;
    final hasModel = _gemma.modelPath != null;

    Color bgColor;
    Color fgColor;
    IconData icon;
    String title;
    String subtitle;

    if (isReady) {
      bgColor = Colors.green.shade50;
      fgColor = Colors.green.shade800;
      icon = Icons.check_circle_outline;
      title = 'KI aktiv und bereit';
      subtitle = _gemma.statusMessage;
    } else if (hasModel && isEnabled) {
      bgColor = Colors.orange.shade50;
      fgColor = Colors.orange.shade800;
      icon = Icons.hourglass_empty;
      title = 'Modell noch nicht geladen';
      subtitle = 'Wird beim ersten Scan geladen.';
    } else if (hasModel && !isEnabled) {
      bgColor = Colors.grey.shade100;
      fgColor = Colors.grey.shade700;
      icon = Icons.pause_circle_outline;
      title = 'KI deaktiviert';
      subtitle = 'Modell installiert, aber nicht aktiv.';
    } else {
      bgColor = Colors.blue.shade50;
      fgColor = Colors.blue.shade800;
      icon = Icons.info_outline;
      title = 'Kein Modell installiert';
      subtitle = 'Folge der Anleitung unten, um ein Modell einzurichten.';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: fgColor, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: fgColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(color: fgColor, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstalledModelTile(ColorScheme cs) {
    final sizeStr = _modelFileSizeMb != null
        ? '${_modelFileSizeMb!.toStringAsFixed(0)} MB'
        : 'Unbekannte Größe';
    final fileName = p.basename(_gemma.modelPath ?? '');
    return ListTile(
      leading: const Icon(Icons.memory_outlined, color: Colors.green),
      title: Text(fileName),
      subtitle: Text('Installiert · $sizeStr'),
      trailing: _gemma.isReady
          ? const Chip(
              label: Text('Bereit'),
              backgroundColor: Colors.green,
              labelStyle: TextStyle(color: Colors.white, fontSize: 11),
              padding: EdgeInsets.zero,
            )
          : null,
    );
  }

  Widget _buildNoModelTile(ColorScheme cs) {
    return ListTile(
      leading: Icon(Icons.memory_outlined, color: cs.onSurfaceVariant),
      title: const Text('Kein Modell installiert'),
      subtitle: const Text('Wähle eine .task-Datei aus dem Speicher'),
    );
  }

  Widget _buildSection({
    required String title,
    required List<Widget> children,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          ...children,
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String title, String description) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showRestoreDialog() async {
    final backups = await BackupService.instance.listBackups();
    if (backups.isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Keine Backups gefunden'),
          content: const Text('Es wurden keine Backup-Dateien im App-Verzeichnis gefunden.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }

    String? selected;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup auswählen'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: backups.length,
            itemBuilder: (c, i) {
              final f = backups[i] as File;
              return RadioListTile<String>(
                value: f.path,
                groupValue: selected,
                title: Text(p.basename(f.path)),
                subtitle: Text('${f.statSync().modified}'),
                onChanged: (v) => setState(() => selected = v),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (selected == null) return;
              setState(() { _isLoading = true; _loadingMessage = 'Restore läuft…'; });
              final ok = await BackupService.instance.restoreBackup(selected!);
              setState(() { _isLoading = false; });
              if (ok) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup erfolgreich wiederhergestellt. App ggf. neu starten.')));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Restore fehlgeschlagen'), backgroundColor: Colors.red));
              }
            },
            child: const Text('Wiederherstellen'),
          ),
        ],
      ),
    );
  }

  Widget _buildBackupListWidget() {
    return FutureBuilder<List<FileSystemEntity>>(
      future: BackupService.instance.listBackups(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final items = snap.data ?? [];
        if (items.isEmpty) {
          return ListTile(
            leading: const Icon(Icons.check_box_outline_blank),
            title: const Text('Keine Backups'),
            subtitle: const Text('Erstelle ein Backup oder warte auf den geplanten Lauf.'),
          );
        }

        return Column(
          children: items.map((entity) {
            final f = entity as File;
            final name = p.basename(f.path);
            final stat = f.statSync();
            final mod = _formatDateTime(stat.modified);
            final sizeKb = (stat.size / 1024).toStringAsFixed(0);
            return ListTile(
              leading: const Icon(Icons.save_outlined),
              title: Text(name),
              subtitle: Text('Geändert: $mod · ${sizeKb} KB'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Wiederherstellen',
                    icon: const Icon(Icons.restore_outlined),
                    onPressed: () => _confirmAndRestore(f.path),
                  ),
                  IconButton(
                    tooltip: 'Löschen',
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _confirmAndDelete(f.path),
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  String _formatDateTime(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmAndRestore(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup wiederherstellen?'),
        content: const Text('Dieses Backup wird die aktuelle Datenbank ersetzen. Die App sollte danach neu gestartet werden.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Wiederherstellen'),
          ),
        ],
      ),
    );
    if (ok == true) await _performRestore(path);
  }

  Future<void> _performRestore(String path) async {
    setState(() { _isLoading = true; _loadingMessage = 'Backup wird wiederhergestellt…'; });
    final res = await BackupService.instance.restoreBackup(path);
    setState(() { _isLoading = false; });
    if (res) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup wiederhergestellt. Bitte App neu starten.')));
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wiederherstellung fehlgeschlagen'), backgroundColor: Colors.red));
    }
  }

  Future<void> _confirmAndDelete(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backup löschen?'),
        content: const Text('Diese Datei wird dauerhaft gelöscht.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), style: FilledButton.styleFrom(backgroundColor: Colors.red), child: const Text('Löschen')),
        ],
      ),
    );
    if (ok == true) await _performDelete(path);
  }

  Future<void> _performDelete(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
      setState(() {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup gelöscht')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Löschen fehlgeschlagen'), backgroundColor: Colors.red));
    }
  }
}
