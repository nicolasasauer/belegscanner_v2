
import 'package:flutter/material.dart';

import '../services/gemma_service.dart';
import '../services/backup_service.dart';

import 'package:url_launcher/url_launcher.dart';

// ---------------------------------------------------------------------------
// ModelSetupPage
// ---------------------------------------------------------------------------

class ModelSetupPage extends StatefulWidget {
  const ModelSetupPage({super.key});

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
  final GemmaService _gemma = GemmaService.instance;

  bool _isDownloading = false;
  int _downloadProgress = 0;
  String _downloadingModelId = '';
  bool _showToken = false;
  bool _isTestRunning = false;
  bool _isTogglingEnabled = false;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _tokenController =
        TextEditingController(text: _gemma.huggingFaceToken ?? '');
    BackupService.instance.loadSettings().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  // ── Aktionen ──────────────────────────────────────────────────────────────

  Future<void> _saveToken() async {
    _gemma.huggingFaceToken = _tokenController.text.trim().isEmpty
        ? null
        : _tokenController.text.trim();
    await _gemma.saveSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Token gespeichert')),
      );
    }
  }

  Future<void> _downloadModel(ModelDefinition model) async {
    // Token prüfen wenn nötig
    if (model.requiresHfToken &&
        (_gemma.huggingFaceToken == null ||
            _gemma.huggingFaceToken!.isEmpty)) {
      _showErrorDialog(
        'HuggingFace Token fehlt',
        'Dieses Modell erfordert einen HuggingFace-Token.\n\n'
            '1. Gehe auf huggingface.co und erstelle einen Account\n'
            '2. Akzeptiere die Gemma-Lizenz auf der Modell-Seite\n'
            '3. Erstelle unter Settings → Access Tokens ein Token\n'
            '4. Trage es oben in das Token-Feld ein',
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${model.name} herunterladen?'),
        content: Text(
          'Modellgröße: ${model.sizeLabel}\n'
          'Empfohlener RAM: ${model.recommendedRam}\n\n'
          'Der Download kann je nach Verbindung einige Minuten dauern.\n'
          'Bitte WLAN verwenden!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Herunterladen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _downloadingModelId = model.id;
    });

    final ok = await _gemma.downloadAndInstall(
      model,
      onProgress: (pct) {
        if (mounted) setState(() => _downloadProgress = pct);
      },
    );

    setState(() {
      _isDownloading = false;
      _downloadingModelId = '';
    });

    if (!mounted) return;
    if (ok) {
      // Automatically enable AI after a successful installation so the user
      // doesn't have to flip the toggle manually.
      if (!_gemma.isEnabled) {
        setState(() => _gemma.isEnabled = true);
        await _gemma.saveSettings();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ ${model.name} installiert und aktiviert!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } else {
      _showErrorDialog(
        'Installation fehlgeschlagen',
        _gemma.statusMessage,
      );
    }
  }

  Future<void> _toggleEnabled(bool value) async {
    setState(() {
      _gemma.isEnabled = value;
      _isTogglingEnabled = true;
    });
    await _gemma.saveSettings();
    if (value) {
      final ok = await _gemma.ensureReady();
      if (!ok && mounted) {
        // Revert toggle – don't leave it stuck in "enabled but broken" state.
        setState(() {
          _gemma.isEnabled = false;
          _isTogglingEnabled = false;
        });
        await _gemma.saveSettings();
        _showErrorDialog(
            'Modell konnte nicht geladen werden', _gemma.statusMessage);
      } else if (mounted) {
        setState(() => _isTogglingEnabled = false);
      }
    } else {
      await _gemma.unloadModel();
      if (mounted) setState(() => _isTogglingEnabled = false);
    }
  }

  Future<void> _removeModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modell entfernen?'),
        content: const Text(
          'Das installierte Modell wird gelöscht.\n'
          'Keyword-Kategorisierung bleibt weiterhin aktiv.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _gemma.removeModel();
    if (mounted) setState(() {});
  }

  Future<void> _testInference() async {
    setState(() => _isTestRunning = true);

    // Show a non-dismissible progress dialog so the user knows the AI is working.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _InferenceLoadingDialog(),
    );

    const testItems = [
      'Vollmilch 3,5% 1L',
      'Red Bull Sugarfree 250ml',
      'Colgate Zahnpasta Total',
      'Pfand 0,25',
    ];
    final result = await _gemma.categorizeItems(
      testItems,
      ['Lebensmittel', 'Getränke', 'Drogerie', 'Pfand', 'Sonstiges'],
    );

    setState(() => _isTestRunning = false);
    if (!mounted) return;
    Navigator.of(context).pop(); // close loading dialog
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test-Ergebnis'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...testItems.asMap().entries.map((e) {
              final cat = result != null && e.key < result.length
                  ? result[e.key]
                  : '—';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(e.value,
                            style: const TextStyle(fontSize: 13))),
                    Text('→ $cat',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }),
            if (result == null) ...[
              const SizedBox(height: 12),
              SelectableText(
                'Fehler: ${_gemma.statusMessage}',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SelectableText(
            message,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lokale KI-Einrichtung'),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusBanner(cs),
          const SizedBox(height: 16),

          // ── HuggingFace Token ──────────────────────────────────────────
          _buildSection(
            title: 'HuggingFace Token',
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Für Gemma-Modelle wird ein HuggingFace-Account und '
                      'ein Access Token benötigt. Lizenz auf der Modell-Seite '
                      'einmalig akzeptieren.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tokenController,
                      obscureText: !_showToken,
                      decoration: InputDecoration(
                        labelText: 'hf_...',
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(_showToken
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              onPressed: () =>
                                  setState(() => _showToken = !_showToken),
                            ),
                            IconButton(
                              icon: const Icon(Icons.save_outlined),
                              tooltip: 'Token speichern',
                              onPressed: _saveToken,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('huggingface.co/settings/tokens'),
                      onPressed: () async {
                        final uri = Uri.parse('https://huggingface.co/settings/tokens');
                        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                      },
                      style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          textStyle: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Modell-Auswahl ─────────────────────────────────────────────
          _buildSection(
            title: 'Modell auswählen & herunterladen',
            children: [
              ...kAvailableModels.map((model) =>
                  _buildModelCard(model, cs, theme)),
            ],
          ),
          const SizedBox(height: 16),

          // ── Aktivierung & Status ───────────────────────────────────────
          if (_gemma.installedModelId != null)
            _buildSection(
              title: 'KI-Kategorisierung',
              children: [
                SwitchListTile(
                  title: const Text('Lokal aktivieren'),
                  subtitle: _isTogglingEnabled
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Wird geladen…'),
                          ],
                        )
                      : Text(
                          _gemma.isEnabled
                              ? 'KI analysiert Artikel nach dem Scan.'
                              : 'Nur Keyword-Kategorisierung aktiv.',
                        ),
                  value: _gemma.isEnabled,
                  onChanged: _isTogglingEnabled ? null : _toggleEnabled,
                ),
                if (_gemma.isReady) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: _isTestRunning
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_circle_outline,
                            color: Colors.green),
                    title: const Text('Inferenz testen'),
                    subtitle: Text(_isTestRunning
                        ? 'KI arbeitet …'
                        : '4 Musterartikel kategorisieren'),
                    onTap: _isTestRunning ? null : _testInference,
                  ),
                ],
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading:
                      const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text('Modell entfernen',
                      style: TextStyle(color: Colors.red)),
                  onTap: _removeModel,
                ),
              ],
            ),
          if (_gemma.installedModelId != null) const SizedBox(height: 16),

          // ── Temperatur ────────────────────────────────────────────────
          _buildSection(
            title: 'Erweiterte Einstellungen',
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Inferenz-Temperatur',
                            style: theme.textTheme.bodyMedium),
                        Text(_gemma.temperature.toStringAsFixed(2),
                            style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: cs.primary)),
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
                      '0.0 = deterministisch · 1.0 = kreativ. '
                      'Für Kategorisierung: 0.0–0.2 empfohlen.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Backup ────────────────────────────────────────────────────
          _buildSection(
            title: 'Datenbank-Backup',
            children: [
              SwitchListTile(
                title: const Text('Automatische Backups'),
                subtitle: const Text(
                    'Täglich oder wöchentlich automatische DB-Backups'),
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
                subtitle: Text(BackupService.instance.frequency == 'daily'
                    ? 'Täglich'
                    : 'Wöchentlich'),
                onTap: () async {
                  final choice = await showDialog<String?>(
                    context: context,
                    builder: (ctx) => SimpleDialog(
                      title: const Text('Frequenz wählen'),
                      children: [
                        SimpleDialogOption(
                            onPressed: () => Navigator.pop(ctx, 'daily'),
                            child: const Text('Täglich')),
                        SimpleDialogOption(
                            onPressed: () => Navigator.pop(ctx, 'weekly'),
                            child: const Text('Wöchentlich')),
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
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Jetzt Backup erstellen'),
                onTap: () async {
                  final path = await BackupService.instance.performBackup();
                  if (!mounted) return;
                  if (path != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            'Backup erstellt: ${path.split('/').last}')));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Backup fehlgeschlagen'),
                        backgroundColor: Colors.red));
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Hilfs-Widgets ─────────────────────────────────────────────────────────

  Widget _buildStatusBanner(ColorScheme cs) {
    final Color bg;
    final Color fg;
    final IconData icon;
    final String title;
    final String subtitle;

    if (_gemma.isReady) {
      bg = Colors.green.shade50;
      fg = Colors.green.shade800;
      icon = Icons.check_circle_outline;
      title = 'KI aktiv und bereit';
      subtitle = _gemma.statusMessage;
    } else if (_gemma.installedModelId != null && _gemma.isEnabled) {
      bg = Colors.orange.shade50;
      fg = Colors.orange.shade800;
      icon = Icons.hourglass_empty;
      title = 'Modell installiert, noch nicht geladen';
      subtitle = 'Wird beim ersten Scan automatisch geladen.';
    } else if (_gemma.installedModelId != null) {
      bg = Colors.grey.shade100;
      fg = Colors.grey.shade700;
      icon = Icons.pause_circle_outline;
      title = 'KI deaktiviert';
      subtitle =
          '${_gemma.installedModel?.name ?? "Modell"} installiert, aber nicht aktiv.';
    } else {
      bg = Colors.blue.shade50;
      fg = Colors.blue.shade800;
      icon = Icons.info_outline;
      title = 'Kein Modell installiert';
      subtitle = 'Wähle unten ein Modell aus und lade es herunter.';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: fg)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(color: fg, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelCard(
      ModelDefinition model, ColorScheme cs, ThemeData theme) {
    final isInstalled = _gemma.installedModelId == model.id;
    final isThisDownloading =
        _isDownloading && _downloadingModelId == model.id;
    final isOtherDownloading =
        _isDownloading && _downloadingModelId != model.id;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isInstalled ? cs.primary : cs.outlineVariant,
          width: isInstalled ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(model.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold)),
                          if (isInstalled) ...[
                            const SizedBox(width: 8),
                            Chip(
                              label: const Text('Installiert'),
                              backgroundColor: cs.primaryContainer,
                              labelStyle: TextStyle(
                                  color: cs.onPrimaryContainer,
                                  fontSize: 11),
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(model.description,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(model.sizeLabel,
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: cs.primary)),
                    Text('RAM: ${model.recommendedRam}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ],
            ),

            // Download-Fortschritt
            if (isThisDownloading) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _downloadProgress / 100),
              const SizedBox(height: 4),
              Text('Herunterladen… $_downloadProgress%',
                  style: theme.textTheme.bodySmall),
            ],

            // Buttons
            if (!isThisDownloading) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isInstalled)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline,
                          size: 16, color: Colors.red),
                      label: const Text('Entfernen',
                          style: TextStyle(color: Colors.red)),
                      onPressed: isOtherDownloading ? null : _removeModel,
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.download_outlined, size: 16),
                      label: Text('Herunterladen (${model.sizeLabel})'),
                      onPressed: isOtherDownloading
                          ? null
                          : () => _downloadModel(model),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
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
            color: Theme.of(context).colorScheme.outlineVariant),
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
}

// ---------------------------------------------------------------------------
// Lade-Dialog während KI-Inferenz
// ---------------------------------------------------------------------------

class _InferenceLoadingDialog extends StatelessWidget {
  const _InferenceLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KI kategorisiert …',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Das lokale Modell arbeitet im Hintergrund.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
