import 'package:flutter/material.dart';

import '../models/receipt.dart';

// =============================================================================
// Verarbeitungs-Platzhalter Widget (shimmer-ähnlich + LinearProgressIndicator)
// =============================================================================

/// Zeigt einen Beleg-Platzhalter während der Hintergrundverarbeitung an.
///
/// Enthält einen [LinearProgressIndicator] für den aktuellen Fortschritt
/// und einen animierten Schimmer-Effekt, der die laufende Verarbeitung signalisiert.
/// Bei [Receipt.status] == `'failed'` wird stattdessen eine Fehler-Karte angezeigt.
class ProcessingReceiptCard extends StatefulWidget {
  const ProcessingReceiptCard({super.key, required this.receipt});

  /// Der Beleg, dessen Verarbeitungsstatus angezeigt wird.
  final Receipt receipt;

  @override
  State<ProcessingReceiptCard> createState() => _ProcessingReceiptCardState();
}

class _ProcessingReceiptCardState extends State<ProcessingReceiptCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFailed = widget.receipt.status == 'failed';

    return AnimatedBuilder(
      animation: _shimmer,
      builder: (_, __) {
        final shimmerAlpha = isFailed ? 0.0 : _shimmer.value * 0.12;
        return Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24.0),
          ),
          elevation: 0.5,
          color: isFailed
              ? colorScheme.errorContainer
              : Color.lerp(
                  colorScheme.surfaceContainerLow,
                  colorScheme.primaryContainer,
                  shimmerAlpha,
                ),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isFailed
                          ? Icons.error_outline
                          : Icons.hourglass_top_outlined,
                      color: isFailed
                          ? colorScheme.onErrorContainer
                          : colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isFailed
                          ? 'Verarbeitung fehlgeschlagen'
                          : 'Wird verarbeitet…',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: isFailed
                                ? colorScheme.onErrorContainer
                                : colorScheme.onSurface,
                          ),
                    ),
                    const Spacer(),
                    if (!isFailed)
                      Text(
                        '${(widget.receipt.progress * 100).round()} %',
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                      ),
                  ],
                ),
                if (!isFailed) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: widget.receipt.progress,
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
