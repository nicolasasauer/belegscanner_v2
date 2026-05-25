import 'dart:io';

import 'package:flutter/material.dart';

import '../services/image_service.dart';

/// Zeigt ein Vorschau-Bild und erlaubt es, das Bild vor der Verarbeitung
/// zu drehen. Gibt `true` zurück, wenn das Bild (ggf. rotiert) bestätigt
/// wurde, `false` wenn der User abbricht.
class ImageRotationDialog extends StatefulWidget {
  const ImageRotationDialog({super.key, required this.imagePath});

  final String imagePath;

  @override
  State<ImageRotationDialog> createState() => _ImageRotationDialogState();
}

class _ImageRotationDialogState extends State<ImageRotationDialog> {
  int _totalRotation = 0; // 0, 90, 180, 270
  bool _isSaving = false;
  // Verwende einen Key, damit Image.file nach Rotation neu geladen wird
  Key _imageKey = UniqueKey();

  Future<void> _rotate(int delta) async {
    final newRotation = (_totalRotation + delta) % 360;
    setState(() => _isSaving = true);

    final ok = await ImageService.rotateFile(widget.imagePath, delta);

    if (!mounted) return;
    setState(() {
      if (ok) {
        _totalRotation = newRotation;
        _imageKey = UniqueKey();
      }
      _isSaving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Bild ausrichten',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Ist der Beleg richtig ausgerichtet?',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _isSaving
                  ? const SizedBox(
                      height: 320,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Image.file(
                      File(widget.imagePath),
                      key: _imageKey,
                      height: 320,
                      fit: BoxFit.contain,
                    ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _RotateButton(
                  icon: Icons.rotate_left,
                  label: '90° links',
                  onTap: _isSaving ? null : () => _rotate(270),
                ),
                const SizedBox(width: 16),
                _RotateButton(
                  icon: Icons.rotate_right,
                  label: '90° rechts',
                  onTap: _isSaving ? null : () => _rotate(90),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context, false),
                    child: const Text('Abbrechen'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context, true),
                    child: const Text('Weiter'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RotateButton extends StatelessWidget {
  const _RotateButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          children: [
            Icon(icon, size: 32, color: onTap == null ? Colors.grey : null),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
