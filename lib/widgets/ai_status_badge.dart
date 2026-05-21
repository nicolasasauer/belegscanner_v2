import 'package:flutter/material.dart';

import '../services/gemma_service.dart';

// ---------------------------------------------------------------------------
// AiStatusBadge
// ---------------------------------------------------------------------------

/// Kleines Status-Badge, das den aktuellen KI-Zustand in der AppBar anzeigt.
///
/// Wird in der [HomePage] als `actions`-Element verwendet. Ein Tap öffnet
/// die [ModelSetupPage].
///
/// **Zustände:**
/// - Grüner Chip „KI ✓": Modell geladen und aktiv.
/// - Orangener Chip „KI ●": Aktiviert, aber Modell noch nicht geladen.
/// - Grauer Chip „KI ○": Deaktiviert oder kein Modell installiert.
class AiStatusBadge extends StatelessWidget {
  const AiStatusBadge({
    super.key,
    required this.onTap,
  });

  /// Callback beim Antippen (soll [ModelSetupPage] öffnen).
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gemma = GemmaService.instance;

    final Color color;
    final String label;
    final IconData icon;

    if (gemma.isReady) {
      color = Colors.green;
      label = 'KI ✓';
      icon = Icons.auto_awesome;
    } else if (gemma.isEnabled) {
      color = Colors.orange;
      label = 'KI ●';
      icon = Icons.auto_awesome_outlined;
    } else {
      color = Colors.grey;
      label = 'KI ○';
      icon = Icons.auto_awesome_outlined;
    }

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
