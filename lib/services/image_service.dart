import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Hilfsfunktion für [compute]: Dreht die Bilddatei unter [args['path']]
/// um [args['degrees']] Grad im Uhrzeigersinn und überschreibt sie.
Future<bool> _rotateImageIsolate(Map<String, dynamic> args) async {
  try {
    final path = args['path'] as String;
    final degrees = args['degrees'] as int;
    final file = File(path);
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return false;
    final rotated = img.copyRotate(image, angle: degrees.toDouble());
    await file.writeAsBytes(img.encodeJpg(rotated, quality: 90));
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
