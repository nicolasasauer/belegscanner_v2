import 'package:flutter/material.dart';

// =============================================================================
// FAB-Menü-Element Widget
// =============================================================================

/// Ein einzelner Eintrag im aufgeklappten Speed-Dial-FAB-Menü.
///
/// Besteht aus einem beschrifteten Label-Chip und einem kleinen
/// [FloatingActionButton.small] mit dem angegebenen [icon].
class FabMenuItem extends StatelessWidget {
  const FabMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// Icon, das im kleinen FAB angezeigt wird.
  final IconData icon;

  /// Beschriftung des Label-Chips neben dem FAB.
  final String label;

  /// Callback, der beim Antippen des FAB aufgerufen wird.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
        ),
        const SizedBox(width: 12),
        FloatingActionButton.small(
          heroTag: label,
          onPressed: onPressed,
          child: Icon(icon),
        ),
      ],
    );
  }
}
