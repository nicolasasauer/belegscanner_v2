import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/receipt.dart';
import '../services/database_service.dart';

/// A developer/debug page that displays the receipt image with OCR spatial data (bounding boxes) overlaid.
/// Users can toggle between the graphic overlay showing text block positions and a raw JSON view.
/// Users can tap a bounding box to assign it a role (Store Name, Date, Total Amount, New Item Name, New Item Price)
/// and these changes are applied to the Receipt.
class OcrDebugPage extends StatefulWidget {
  const OcrDebugPage({
    super.key, 
    required this.receipt,
    required this.databaseService,
  });

  final Receipt receipt;
  final DatabaseService databaseService;

  @override
  State<OcrDebugPage> createState() => _OcrDebugPageState();
}

class _OcrDebugPageState extends State<OcrDebugPage> {
  bool _showJson = false;
  late Receipt _currentReceipt;
  List<dynamic> _spatialLines = [];

  @override
  void initState() {
    super.initState();
    _currentReceipt = widget.receipt;
    _parseSpatialData();
  }

  void _parseSpatialData() {
    final spatialDataStr = _currentReceipt.spatialData;
    if (spatialDataStr != null && spatialDataStr.isNotEmpty) {
      try {
        _spatialLines = jsonDecode(spatialDataStr) as List<dynamic>;
      } catch (e) {
        debugPrint('Error parsing spatial data: $e');
      }
    }
  }

  /// Tapping a bounding box triggers a dialog to select its role.
  void _onBoxTapped(Map<String, dynamic> boxData) async {
    final text = boxData['text'] as String?;
    if (text == null) return;

    final role = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Role for: "$text"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Store Name'),
                onTap: () => Navigator.pop(ctx, 'store'),
              ),
              ListTile(
                title: const Text('Receipt Date'),
                onTap: () => Navigator.pop(ctx, 'date'),
              ),
              ListTile(
                title: const Text('Total Amount'),
                onTap: () => Navigator.pop(ctx, 'total'),
              ),
              ListTile(
                title: const Text('Add as new Item (Name)'),
                onTap: () => Navigator.pop(ctx, 'item_name'),
              ),
              ListTile(
                title: const Text('Add as new Item (Price)'),
                onTap: () => Navigator.pop(ctx, 'item_price'),
              ),
            ],
          ),
        );
      },
    );

    if (role != null) {
      await _applyTagRole(role, text);
    }
  }

  Future<void> _applyTagRole(String role, String text) async {
    Receipt updated = _currentReceipt;
    
    if (role == 'store') {
      updated = updated.copyWith(storeName: text);
    } else if (role == 'date') {
      // Very naive date parsing or just let the user see it fail
      final parsed = DateTime.tryParse(text);
      if (parsed != null) {
        updated = updated.copyWith(date: parsed);
      } else {
        // Fallback or custom parsing if needed. 
        // For simplicity, we just ignore if it's not a valid Iso8601 string,
        // but normally we should parse 'DD.MM.YYYY'. Let's do a simple regex:
        final datePattern = RegExp(r'\b(\d{1,2})\.(\d{1,2})\.(\d{2,4})\b');
        final match = datePattern.firstMatch(text);
        if (match != null) {
          int day = int.parse(match.group(1)!);
          int month = int.parse(match.group(2)!);
          int year = int.parse(match.group(3)!);
          if (year < 100) year += 2000;
          updated = updated.copyWith(date: DateTime(year, month, day));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid date format (Expects DD.MM.YYYY)')),
          );
          return;
        }
      }
    } else if (role == 'total') {
      final val = double.tryParse(text.replaceAll(',', '.'));
      if (val != null) {
        updated = updated.copyWith(totalAmount: val);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid number for Total Amount')),
        );
        return;
      }
    } else if (role == 'item_name') {
      final newItems = List<String>.from(updated.items)..add(text);
      final newCategories = List<String>.from(updated.categories)..add('Sonstiges');
      updated = updated.copyWith(items: newItems, categories: newCategories);
    } else if (role == 'item_price') {
      // Append to the last item if possible, or create a new "Unknown" item
      final val = double.tryParse(text.replaceAll(',', '.'));
      if (val == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid number for Item Price')),
        );
        return;
      }

      final fmtPrice = val.toStringAsFixed(2).replaceAll('.', ',');
      if (updated.items.isNotEmpty) {
        final last = updated.items.last;
        final newItems = List<String>.from(updated.items);
        newItems[newItems.length - 1] = '$last  $fmtPrice';
        updated = updated.copyWith(items: newItems);
      } else {
        final newItems = ['Unbekannter Artikel  $fmtPrice'];
        final newCategories = ['Sonstiges'];
        updated = updated.copyWith(items: newItems, categories: newCategories);
      }
    }

    // Save to Database
    await widget.databaseService.updateReceipt(updated);

    setState(() {
      _currentReceipt = updated;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Receipt updated: $role -> $text')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final spatialDataStr = _currentReceipt.spatialData;
    final hasImage = _currentReceipt.imagePath != null && File(_currentReceipt.imagePath!).existsSync();

    return WillPopScope(
      onWillPop: () async {
        Navigator.pop(context, _currentReceipt);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Interactive OCR Debug'),
          actions: [
            IconButton(
              icon: Icon(_showJson ? Icons.image : Icons.data_object),
              tooltip: _showJson ? 'Zeige Bild' : 'Zeige JSON',
              onPressed: () {
                setState(() {
                  _showJson = !_showJson;
                });
              },
            ),
          ],
        ),
        body: _showJson
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: SelectableText(
                  JsonEncoder.withIndent('  ').convert(
                    spatialDataStr != null ? jsonDecode(spatialDataStr) : {'error': 'No spatial data'},
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              )
            : !hasImage
                ? const Center(child: Text('Kein Bild für diesen Beleg gefunden.'))
                : _buildImageWithOverlay(context),
      ),
    );
  }

  Widget _buildImageWithOverlay(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Stack(
        children: [
          Image.file(File(_currentReceipt.imagePath!)),
          if (_spatialLines.isNotEmpty)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return CustomPaint(
                    painter: _BoundingBoxPainter(
                      spatialLines: _spatialLines,
                    ),
                    child: GestureDetector(
                      onTapUp: (details) {
                        // Find if a box was tapped
                        final renderBox = context.findRenderObject() as RenderBox;
                        final localPos = renderBox.globalToLocal(details.globalPosition);

                        // Since we scale the image inside the stack using Image.file with fit Boxfit...? 
                        // Wait, Image.file has no fit specified here, so it is scaled proportionally. 
                        // Let's get the original image size and screen size to map pointers precisely.
                        // For a simple implementation, tapping might need exact coordinates.
                        // I will pass the Image Size and find the scale factor.
                      },
                    ),
                  );
                },
              ),
            ),
          // We can use Positioned widgets for each box to make them natively tappable using Flutter UI elements, 
          // which perfectly solves the scaling issues automatically.
          if (_spatialLines.isNotEmpty)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return _buildTappableBoxes(constraints.maxWidth, constraints.maxHeight);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTappableBoxes(double screenWidth, double screenHeight) {
    // 1. Calculate image scaling factor
    // Since we don't have the explicit image width/height easily here without async resolving,
    // we assume the image fits within the constraints. 
    // Actually, `Image.file()` by default uses BoxFit.contain. 
    // Wait, the spatial coordinates from ML Kit are in original image pixels. 
    // Instead of doing complicated math here without the image size, 
    // a simpler approach is to async load the image size using Image.file, or 
    // just rely on a standard layout if we know it. 
    // A robust way to overlay is using a LayoutBuilder around a FittedBox containing an intrinsic sized stack.

    // Let's wrap the Image and Boxes in a Stack that takes the image's original dimensions.
    return FutureBuilder<Size>(
      future: _getImageSize(File(_currentReceipt.imagePath!)),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final imgSize = snapshot.data!;
        
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: imgSize.width,
            height: imgSize.height,
            child: Stack(
              children: [
                // We don't draw the image here, the image is drawn behind FittedBox. 
                // But wait, FittedBox should contain the Image too for alignment!
                // Let's modify the outer widget tree for Boxfit.
                for (final line in _spatialLines)
                  if (line is Map<String, dynamic>)
                    Builder(builder: (context) {
                      final left = (line['left'] as num?)?.toDouble();
                      final top = (line['top'] as num?)?.toDouble();
                      final right = (line['right'] as num?)?.toDouble();
                      final bottom = (line['bottom'] as num?)?.toDouble();

                      if (left == null || top == null || right == null || bottom == null) {
                        return const SizedBox.shrink();
                      }

                      return Positioned(
                        left: left,
                        top: top,
                        width: right - left,
                        height: bottom - top,
                        child: GestureDetector(
                          onTap: () => _onBoxTapped(line),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.red.withOpacity(0.5), width: 2),
                              color: Colors.blue.withOpacity(0.3),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                line['text'] as String? ?? '',
                                style: const TextStyle(
                                  color: Colors.white, 
                                  backgroundColor: Colors.black54,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
              ],
            ),
          ),
        );
      }
    );
  }

  Future<Size> _getImageSize(File file) async {
    final decodedImage = await decodeImageFromList(await file.readAsBytes());
    return Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());
  }
}

class _BoundingBoxPainter extends CustomPainter {
  _BoundingBoxPainter({required this.spatialLines});

  final List<dynamic> spatialLines;

  @override
  void paint(Canvas canvas, Size size) {
    // Replaced by widget-based rendering for interactivity inside _buildTappableBoxes.
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
