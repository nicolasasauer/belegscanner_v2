import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/database_service.dart';

/// Dashboard-Seite mit Kuchendiagramm der Ausgaben nach Kategorien.
///
/// Zeigt die Gesamtausgaben des aktuellen Monats aufgeteilt nach Kategorien
/// als PieChart sowie eine Legende mit Prozentwerten darunter.
class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.databaseService});

  final DatabaseService databaseService;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // ---------------------------------------------------------------------------
  // Zustand
  // ---------------------------------------------------------------------------

  List<_CategoryTotal> _totals = [];
  bool _isLoading = true;
  int _touchedIndex = -1;

  /// Der aktuell im Dashboard angezeigte Monat (immer auf den 1. gesetzt).
  late DateTime _selectedMonth;

  final NumberFormat _currencyFormat = NumberFormat.currency(
    locale: 'de_DE',
    symbol: '€',
  );

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonth = DateTime(now.year, now.month, 1);
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    // Kategorien mit Farben aus DB laden
    final categories = await widget.databaseService.getCategories();
    final colorMap = {
      for (final c in categories) c.name: _hexToColor(c.color),
    };

    final rawTotals = await widget.databaseService.getCategoryTotals(month: _selectedMonth);
    final totals = rawTotals
        .map(
          (e) => _CategoryTotal(
            name: e['category'] as String,
            total: e['total'] as double,
            color: colorMap[e['category'] as String] ??
                _fallbackColor(e['category'] as String),
          ),
        )
        .toList();

    if (mounted) {
      setState(() {
        _totals = totals;
        _isLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final monthLabel = DateFormat('MMMM yyyy', 'de_DE').format(_selectedMonth);
    final now = DateTime.now();
    final isCurrentMonth = _selectedMonth.year == now.year &&
        _selectedMonth.month == now.month;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _totals.isEmpty
                ? _buildEmpty(monthLabel, isCurrentMonth)
                : _buildContent(monthLabel, isCurrentMonth),
      ),
    );
  }

  void _goToPreviousMonth() {
    setState(() {
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1, 1);
    });
    _loadData();
  }

  void _goToNextMonth() {
    setState(() {
      _selectedMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
    });
    _loadData();
  }

  /// Baut den Monatsnavigator, der in beiden Build-Methoden verwendet wird.
  Widget _buildMonthNavigator(String monthLabel, bool isCurrentMonth) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Vorheriger Monat',
              onPressed: _goToPreviousMonth,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.calendar_month_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        monthLabel,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Nächster Monat',
              onPressed: isCurrentMonth ? null : _goToNextMonth,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(String monthLabel, bool isCurrentMonth) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        _buildMonthNavigator(monthLabel, isCurrentMonth),
        const SizedBox(height: 32),
        Icon(
          Icons.bar_chart_outlined,
          size: 72,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        const SizedBox(height: 16),
        Text(
          'Keine Ausgaben im $monthLabel',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Scanne einen Beleg, um hier Statistiken zu sehen.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildContent(String monthLabel, bool isCurrentMonth) {
    final total = _totals.fold<double>(0.0, (sum, e) => sum + e.total);

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        // ------------------------------------------------------------------
        // Monatnavigator mit Gesamtbetrag
        // ------------------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Vorheriger Monat',
                  onPressed: _goToPreviousMonth,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.calendar_month_outlined,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            monthLabel,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      Text(
                        'Gesamt: ${_currencyFormat.format(total)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Nächster Monat',
                  onPressed: isCurrentMonth ? null : _goToNextMonth,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ------------------------------------------------------------------
        // Kuchendiagramm
        // ------------------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              height: 260,
              child: PieChart(
                PieChartData(
                  pieTouchData: PieTouchData(
                    touchCallback: (event, response) {
                      setState(() {
                        if (!event.isInterestedForInteractions ||
                            response == null ||
                            response.touchedSection == null) {
                          _touchedIndex = -1;
                          return;
                        }
                        _touchedIndex = response
                            .touchedSection!.touchedSectionIndex;
                      });
                    },
                  ),
                  borderData: FlBorderData(show: false),
                  sectionsSpace: 3,
                  centerSpaceRadius: 50,
                  sections: _buildSections(total),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        // ------------------------------------------------------------------
        // Legende
        // ------------------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kategorien',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                ..._totals.asMap().entries.map(
                      (entry) => _LegendRow(
                        index: entry.key,
                        item: entry.value,
                        total: total,
                        currencyFormat: _currencyFormat,
                        isSelected: entry.key == _touchedIndex,
                        onTap: () => setState(() {
                          _touchedIndex =
                              _touchedIndex == entry.key ? -1 : entry.key;
                        }),
                      ),
                    ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),
      ],
    );
  }

  List<PieChartSectionData> _buildSections(double total) {
    return _totals.asMap().entries.map((entry) {
      final i = entry.key;
      final item = entry.value;
      final pct = total > 0 ? (item.total / total * 100) : 0.0;
      final isTouched = i == _touchedIndex;
      final radius = isTouched ? 72.0 : 58.0;
      final fontSize = isTouched ? 14.0 : 11.0;

      return PieChartSectionData(
        color: item.color,
        value: item.total,
        title: '${pct.toStringAsFixed(1)}%',
        radius: radius,
        titleStyle: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          shadows: const [Shadow(color: Colors.black26, blurRadius: 2)],
        ),
      );
    }).toList();
  }
}

// =============================================================================
// Legende-Zeile
// =============================================================================

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.index,
    required this.item,
    required this.total,
    required this.currencyFormat,
    required this.isSelected,
    required this.onTap,
  });

  final int index;
  final _CategoryTotal item;
  final double total;
  final NumberFormat currencyFormat;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (item.total / total * 100) : 0.0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: isSelected
            ? BoxDecoration(
                color: item.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: item.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                item.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
              ),
            ),
            Text(
              '${pct.toStringAsFixed(1)} %',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: 12),
            Text(
              currencyFormat.format(item.total),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Datenmodell
// =============================================================================

class _CategoryTotal {
  const _CategoryTotal({
    required this.name,
    required this.total,
    required this.color,
  });

  final String name;
  final double total;
  final Color color;
}

// =============================================================================
// Hilfsfunktionen
// =============================================================================

Color _hexToColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  final value = int.tryParse(cleaned, radix: 16) ?? 0x9E9E9E;
  return Color(0xFF000000 | value);
}

/// Liefert eine deterministische Fallback-Farbe für unbekannte Kategorienamen.
Color _fallbackColor(String name) {
  const palette = [
    Color(0xFF9C27B0),
    Color(0xFF00BCD4),
    Color(0xFFFF5722),
    Color(0xFF607D8B),
    Color(0xFF795548),
    Color(0xFF009688),
    Color(0xFFE91E63),
    Color(0xFF3F51B5),
  ];
  return palette[name.hashCode.abs() % palette.length];
}
