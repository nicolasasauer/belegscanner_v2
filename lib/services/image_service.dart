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

/// Top-level Funktion für [compute]: Baked EXIF-Orientation und rotiert
/// Querformat-Bilder in Hochformat (Kassenbon-Heuristik).
Future<bool> _autoOrientIsolate(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    var image = img.decodeImage(bytes);
    if (image == null) return false;

    bool modified = false;

    // Bake EXIF orientation into pixel data (clears the EXIF tag afterward).
    // img.decodeImage does NOT auto-apply EXIF, so camera photos stored as
    // landscape with orientation=6 must be rotated here to appear upright.
    if (image.exif.imageIfd.hasOrientation &&
        image.exif.imageIfd.orientation != 1) {
      image = img.bakeOrientation(image);
      modified = true;
    }

    // Downscale before any further rotation so the rotate op stays fast.
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > _maxRotationDim) {
      final scale = _maxRotationDim / longest;
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
        interpolation: img.Interpolation.linear,
      );
      modified = true;
    }

    // Receipt heuristic: if still landscape after EXIF bake, rotate 90° CW.
    // Receipts are always portrait — this corrects the common Android case
    // where EXIF data was stripped or absent.
    if (image.width > image.height) {
      image = img.copyRotate(image, angle: 90);
      modified = true;
    }

    if (modified) {
      await File(path).writeAsBytes(img.encodeJpg(image, quality: 88));
    }
    return true;
  } catch (e) {
    debugPrint('[ImageService] autoOrientToPortrait Fehler: $e');
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

  /// Baked EXIF-Orientation und rotiert Querformat-Bilder in Hochformat.
  ///
  /// Muss vor dem OCR-Schritt aufgerufen werden, damit ML Kit und die KI
  /// immer ein aufrecht stehendes Bild erhalten. Gibt [true] bei Erfolg.
  static Future<bool> autoOrientToPortrait(String path) {
    return compute(_autoOrientIsolate, path);
  }
}
