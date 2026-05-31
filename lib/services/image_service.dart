import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Hilfsfunktion für [compute]: Dreht die Bilddatei unter [args['path']]
/// um [args['degrees']] Grad im Uhrzeigersinn und überschreibt sie.
// Max. Kantenlänge für gespeicherte Beleg-Bilder.
// Kamera-Fotos sind oft 4000+ px — für OCR und Anzeige reichen 1920 px.
const _maxRotationDim = 1920;

Future<bool> _rotateImageIsolate(Map<String, dynamic> args) async {
  try {
    final path = args['path'] as String;
    final degrees = args['degrees'] as int;
    final file = File(path);
    final bytes = await file.readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) return false;

    // Downscale before rotating so the operation is fast even for large photos.
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > _maxRotationDim) {
      final scale = _maxRotationDim / longest;
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
        interpolation: img.Interpolation.linear,
      );
    }

    final rotated = img.copyRotate(image, angle: degrees.toDouble());
    await file.writeAsBytes(img.encodeJpg(rotated, quality: 88));
    return true;
  } catch (e) {
    debugPrint('[ImageService] Rotationsfehler: $e');
    return false;
  }
}

class ImageService {
  const ImageService._();

  /// Dreht die Bilddatei unter [path] um [degrees] Grad im Uhrzeigersinn.
  ///
  /// Die Rotation wird in einem Background-Isolate durchgeführt, um den
  /// UI-Thread nicht zu blockieren. Gibt [true] zurück bei Erfolg.
  static Future<bool> rotateFile(String path, int degrees) {
    return compute(_rotateImageIsolate, {'path': path, 'degrees': degrees});
  }
}
