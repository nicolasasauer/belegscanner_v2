import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/receipt.dart';
import 'receipt_detail_view.dart';

// =============================================================================
// Beleg-ListTile Widget
// =============================================================================

/// Kompakter ListTile-Eintrag für einen abgeschlossenen Beleg.
///
/// Zeigt Thumbnail, Gesamtbetrag, Datum und Anzahl der Positionen.
/// Ein Tipp auf das Thumbnail öffnet das Bild im Vollbild-Modus.
class ReceiptListTile extends StatelessWidget {
  const ReceiptListTile({
    super.key,
    required this.receipt,
    required this.dateFormat,
    required this.currencyFormat,
    required this.onTap,
  });

  /// Der darzustellende Beleg.
  final Receipt receipt;

  /// Datumsformat (z. B. `d. MMMM yyyy, de_DE`).
  final DateFormat dateFormat;

  /// Währungsformat (z. B. `€ #,##0.00, de_DE`).
  final NumberFormat currencyFormat;

  /// Callback, der beim Antippen der gesamten Kachel aufgerufen wird.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24.0),
      ),
      elevation: 0.5,
      child: ListTile(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24.0),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _buildThumbnail(context),
        title: Text(
          receipt.storeName ?? 'Unbekannter Händler',
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${currencyFormat.format(receipt.totalAmount)} • ${dateFormat.format(receipt.date)}',
        ),
        trailing: Text(
          '${receipt.items.length} Pos.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    final path = receipt.imagePath;
    if (path != null) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => FullscreenImageViewer(imagePath: path),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(path),
            width: 52,
            height: 52,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(context),
          ),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 52,
        height: 52,
        color: Theme.of(context).colorScheme.primaryContainer,
        alignment: Alignment.center,
        child: Icon(
          Icons.receipt_outlined,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
