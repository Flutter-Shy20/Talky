import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

/// Qualité WebP des mini-vignettes envoyées avec les messages (0–100). Elles
/// sont affichées floutées : la finesse ne se voit pas, le poids si.
const int kThumbnailQuality = 60;

/// Mini-vignette image (WebP base64) pour l'aperçu destinataire hors téléchargement.
///
/// Redimensionnée côté encode (`targetWidth`) pour rester légère dans le message,
/// puis affichée floutée côté UI tant que le fichier plein n'est pas local.
class ImageThumbnailService {
  ImageThumbnailService._();

  /// Génère une vignette compacte destinée à [mediaThumb].
  static Future<String?> base64ForFile(
    String path, {
    int maxWidth = 120,
  }) async {
    try {
      if (!File(path).existsSync()) return null;
      final raw = await File(path).readAsBytes();
      return base64ForBytes(raw, maxWidth: maxWidth);
    } catch (e) {
      debugPrint('[ImageThumb] base64ForFile échec $path: $e');
      return null;
    }
  }

  /// Même vignette, à partir d'octets déjà en mémoire (pochette extraite des
  /// tags d'un fichier audio, par exemple).
  static Future<String?> base64ForBytes(
    Uint8List raw, {
    int maxWidth = 120,
  }) async {
    try {
      if (raw.isEmpty) return null;

      final codec = await ui.instantiateImageCodec(
        raw,
        targetWidth: maxWidth,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final bd = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bd == null) return null;
        final png = bd.buffer.asUint8List();
        return base64Encode(await _compact(png, image.width, image.height));
      } finally {
        image.dispose();
      }
    } catch (e) {
      debugPrint('[ImageThumb] base64ForBytes échec: $e');
      return null;
    }
  }

  /// La vignette voyage dans chaque message (socket, base du serveur, base
  /// locale de chaque destinataire). Réencodée en WebP, elle pèse plusieurs
  /// fois moins qu'en PNG et garde la transparence ; toutes les versions de
  /// l'app la lisent. En cas d'échec, le PNG part tel quel.
  static Future<Uint8List> _compact(Uint8List png, int width, int height) async {
    try {
      final webp = await FlutterImageCompress.compressWithList(
        png,
        // Bornes égales à la taille de la vignette : aucune réduction de plus.
        minWidth: width,
        minHeight: height,
        quality: kThumbnailQuality,
        format: CompressFormat.webp,
      );
      if (webp.isNotEmpty && webp.length < png.length) return webp;
    } catch (e) {
      debugPrint('[ImageThumb] WebP impossible, PNG conservé: $e');
    }
    return png;
  }
}
