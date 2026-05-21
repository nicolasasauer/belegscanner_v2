import 'package:flutter/material.dart';

// =============================================================================
// Filter-Bar Widget
// =============================================================================

/// Horizontale Chip-Leiste zur Datums-Filterung der Beleg-Liste.
///
/// Zeigt je einen [FilterChip] für Tag, Monat und Jahr. Ist mindestens ein
/// Filter aktiv, erscheint zusätzlich ein „Alle anzeigen"-Chip.
/// Das Widget wird ausgeblendet, wenn noch keine Belege vorhanden sind und
/// kein Filter aktiv ist.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.hasReceipts,
    required this.selectedDay,
    required this.selectedMonth,
    required this.selectedYear,
    required this.onPickDay,
    required this.onPickMonth,
    required this.onPickYear,
    required this.onClearAll,
  });

  /// Gibt an, ob bereits Belege in der Liste vorhanden sind.
  final bool hasReceipts;

  /// Ausgewählter Tag (1–31) oder `null` wenn kein Tag-Filter aktiv.
  final int? selectedDay;

  /// Ausgewählter Monat (1–12) oder `null` wenn kein Monats-Filter aktiv.
  final int? selectedMonth;

  /// Ausgewähltes Jahr oder `null` wenn kein Jahres-Filter aktiv.
  final int? selectedYear;

  /// Callback zum Öffnen des Tag-Pickers.
  final VoidCallback onPickDay;

  /// Callback zum Öffnen des Monats-Pickers.
  final VoidCallback onPickMonth;

  /// Callback zum Öffnen des Jahres-Pickers.
  final VoidCallback onPickYear;

  /// Callback zum Zurücksetzen aller aktiven Filter.
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final hasFilter =
        selectedDay != null || selectedMonth != null || selectedYear != null;
    if (!hasReceipts && !hasFilter) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildDateChip(
                context: context,
                label: selectedDay != null
                    ? 'Tag: ${selectedDay.toString().padLeft(2, '0')}.'
                        '${(selectedMonth ?? 0).toString().padLeft(2, '0')}.'
                        '${selectedYear?.toString() ?? '----'}'
                    : 'Tag',
                isSelected: selectedDay != null,
                onTap: onPickDay,
              ),
              const SizedBox(width: 8),
              _buildDateChip(
                context: context,
                label: selectedMonth != null && selectedDay == null
                    ? 'Monat: ${_monthName(selectedMonth!)} $selectedYear'
                    : 'Monat',
                isSelected: selectedMonth != null && selectedDay == null,
                onTap: onPickMonth,
              ),
              const SizedBox(width: 8),
              _buildDateChip(
                context: context,
                label: selectedYear != null &&
                        selectedMonth == null &&
                        selectedDay == null
                    ? 'Jahr: $selectedYear'
                    : 'Jahr',
                isSelected: selectedYear != null &&
                    selectedMonth == null &&
                    selectedDay == null,
                onTap: onPickYear,
              ),
              if (hasFilter) ...[
                const SizedBox(width: 12),
                ActionChip(
                  avatar: const Icon(Icons.clear, size: 16),
                  label: const Text('Alle anzeigen'),
                  onPressed: onClearAll,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _buildDateChip({
    required BuildContext context,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onTap(),
      avatar: isSelected ? null : const Icon(Icons.calendar_today, size: 14),
      visualDensity: VisualDensity.compact,
    );
  }

  String _monthName(int month) {
    const names = [
      'Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun',
      'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez',
    ];
    return month >= 1 && month <= 12 ? names[month - 1] : '';
  }
}
