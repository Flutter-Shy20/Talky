import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;

import '../utils/media_staging.dart';

//  Compression des photos avant envoi.
//
//  Toutes les photos passent ici, d'où qu'elles viennent : galerie, caméra de
//  l'app, partage depuis une autre app, statuts. Le sélecteur de la galerie ne
//  fait que réduire la taille ; la caméra et le partage ne réduisaient rien, et
//  une photo de téléphone partait alors avec plusieurs Mo.
//
//  Une seule règle : grand côté ramené à 1600 px (jamais agrandi), WebP en
//  qualité 75, métadonnées retirées (position GPS comprise), orientation
//  appliquée à l'image. À taille égale, le WebP pèse 25 à 35 % de moins que le
//  JPEG, et toutes les versions de l'app le lisent.
//
//  Mêmes règles de conduite que pour les vidéos :
//
//  - **Jamais bloquant.** Toute erreur, ou un résultat plus lourd que
//    l'original, rend le fichier d'origine.
//  - **Une compression à la fois.** Décoder une photo de 12 Mpx occupe des
//    dizaines de Mo de mémoire ; un album en enverrait trois en parallèle.
//  - **Jamais deux fois.** Le fichier produit porte le suffixe
//    [kCompressedImageSuffix] ; une reprise d'envoi le laisse tel quel.
//
//  Un GIF n'est jamais touché : la conversion perdrait l'animation. Une photo
//  envoyée comme *document* ne passe pas ici, elle garde sa qualité d'origine.

/// Suffixe du nom des fichiers produits par la compression.
const String kCompressedImageSuffix = '_w1600';

/// Grand côté maximal d'une photo envoyée, en pixels.
const int kCompressedImageLongSide = 1600;

/// Qualité WebP (0–100).
const int kCompressedImageQuality = 75;

/// `true` si le fichier sort déjà de la compression.
bool isCompressedImagePath(String path) =>
    p.basenameWithoutExtension(path).endsWith(kCompressedImageSuffix);

/// `true` s'il faut tenter de compresser cette photo.
bool shouldCompressImage(String path) {
  if (isCompressedImagePath(path)) return false;
  return p.extension(path).toLowerCase() != '.gif';
}

/// Côté court visé, quand le grand côté est ramené à
/// [kCompressedImageLongSide] (ou laissé tel quel s'il est déjà plus petit).
///
/// Le moteur réduit l'image jusqu'à ce qu'un de ses côtés touche la borne
/// demandée. En lui donnant le côté court visé pour les deux bornes, le grand
/// côté tombe juste sur 1600 px, que la photo soit en portrait ou en paysage,
/// et quelle que soit la rotation appliquée ensuite.
int targetShortSide(int width, int height) {
  final long = math.max(width, height);
  final short = math.min(width, height);
  if (long <= kCompressedImageLongSide) return short;
  return (short * kCompressedImageLongSide / long).round();
}

/// Facteur de sous-échantillonnage au décodage (Android) : la plus grande
/// puissance de 2 qui garde au moins [kCompressedImageLongSide] px sur le grand
/// côté. Une photo de 4000 px est décodée en 2000 px, quatre fois moins de
/// mémoire, avant la réduction finale.
int decodeSampleSize(int width, int height) {
  final long = math.max(width, height);
  var sample = 1;
  while (long ~/ (sample * 2) >= kCompressedImageLongSide) {
    sample *= 2;
  }
  return sample;
}

/// Le plugin, derrière une interface : les tests le remplacent.
abstract class ImageCompressionEngine {
  /// Dimensions de la photo, ou `null` si son en-tête est illisible.
  Future<({int width, int height})?> dimensions(String path);

  /// Chemin du fichier WebP produit, ou `null` en cas d'échec.
  Future<String?> compress(
    String path, {
    required int minSide,
    required int sampleSize,
  });

  /// Supprime la sortie du plugin une fois recopiée.
  Future<void> discard(String path);
}

class _PluginImageCompressionEngine implements ImageCompressionEngine {
  const _PluginImageCompressionEngine();

  @override
  Future<({int width, int height})?> dimensions(String path) async {
    // L'en-tête suffit : l'image n'est pas décodée.
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return (width: descriptor.width, height: descriptor.height);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  @override
  Future<String?> compress(
    String path, {
    required int minSide,
    required int sampleSize,
  }) async {
    final target = p.join(
      Directory.systemTemp.path,
      'img_${DateTime.now().microsecondsSinceEpoch}.webp',
    );
    final out = await FlutterImageCompress.compressAndGetFile(
      path,
      target,
      minWidth: minSide,
      minHeight: minSide,
      inSampleSize: sampleSize,
      quality: kCompressedImageQuality,
      format: CompressFormat.webp,
      keepExif: false,
      autoCorrectionAngle: true,
    );
    return out?.path;
  }

  @override
  Future<void> discard(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

/// Prépare les photos à l'envoi. Voir l'en-tête du fichier.
class ImageUploadCompressor {
  ImageUploadCompressor({
    ImageCompressionEngine? engine,
    Directory? outboxDirectory,
  })  : _engine = engine ?? const _PluginImageCompressionEngine(),
        _outboxDirectory = outboxDirectory;

  static final ImageUploadCompressor instance = ImageUploadCompressor();

  final ImageCompressionEngine _engine;

  /// Réservé aux tests (évite path_provider), comme pour [stageMediaFile].
  final Directory? _outboxDirectory;

  /// File d'attente : chaque demande attend la fin de la précédente.
  Future<void> _queue = Future<void>.value();

  /// Fichier à envoyer : la photo compressée quand c'est utile, sinon
  /// [source] lui-même. Ne lève jamais.
  Future<File> prepare(File source) {
    final run = _queue.then((_) => _prepare(source));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<File> _prepare(File source) async {
    try {
      if (!source.existsSync() || !shouldCompressImage(source.path)) {
        return source;
      }
      final size = source.lengthSync();

      // Sans dimensions (en-tête illisible, HEIC sur certains Android), on
      // borne le côté court : la photo reste réduite, un peu moins finement.
      var minSide = kCompressedImageLongSide;
      var sampleSize = 1;
      try {
        final dims = await _engine.dimensions(source.path);
        if (dims != null && dims.width > 0 && dims.height > 0) {
          minSide = targetShortSide(dims.width, dims.height);
          sampleSize = decodeSampleSize(dims.width, dims.height);
        }
      } catch (e) {
        debugPrint('[ImageCompress] dimensions illisibles: $e');
      }

      final out = await _engine.compress(
        source.path,
        minSide: minSide,
        sampleSize: sampleSize,
      );
      if (out == null) return source;
      try {
        final produced = File(out);
        if (!produced.existsSync()) return source;
        final producedSize = produced.lengthSync();
        // Une photo déjà petite et bien compressée peut ressortir plus lourde :
        // on garde alors l'original.
        if (producedSize == 0 || producedSize >= size) return source;

        final staged =
            await stageMediaFile(produced, outboxDirectory: _outboxDirectory);
        final marked = p.join(
          staged.parent.path,
          '${p.basenameWithoutExtension(staged.path)}'
          '$kCompressedImageSuffix${p.extension(staged.path)}',
        );
        final result = await staged.rename(marked);
        debugPrint('[ImageCompress] $size → $producedSize octets');
        return result;
      } finally {
        try {
          await _engine.discard(out);
        } catch (_) {/* sortie déjà supprimée — ignoré */}
      }
    } catch (e) {
      debugPrint("[ImageCompress] échec, envoi de l'original: $e");
      return source;
    }
  }
}
