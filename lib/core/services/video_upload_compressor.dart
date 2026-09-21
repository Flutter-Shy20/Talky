import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:video_compress/video_compress.dart';

import '../utils/media_staging.dart';

//  Compression des vidéos avant envoi.
//
//  Une vidéo de téléphone partait telle qu'elle avait été filmée : une minute
//  en 1080p ou en 4K approche vite le plafond de 50 Mo, et sur une connexion
//  mobile le temps d'envoi comme celui de téléchargement suit le poids du
//  fichier. Ramenée en 720p, la même vidéo pèse plusieurs fois moins, pour un
//  rendu qu'un écran de téléphone ne distingue pas.
//
//  Trois règles tiennent ce service :
//
//  - **Jamais bloquant.** Toute erreur — métadonnées illisibles, format
//    exotique, compression annulée, résultat plus lourd que l'original — rend
//    le fichier d'origine. Mieux vaut une vidéo lourde qu'une vidéo non envoyée.
//  - **Une compression à la fois.** Le plugin lève `StateError` si une seconde
//    compression démarre pendant la première, alors qu'un album envoie trois
//    médias en parallèle : les demandes passent par une file.
//  - **Jamais deux fois.** Le fichier produit porte le suffixe
//    [kCompressedVideoSuffix] ; une reprise d'envoi (échec réseau, redémarrage
//    de l'app) le reconnaît et le laisse tel quel.

/// Suffixe du nom des fichiers produits par la compression.
const String kCompressedVideoSuffix = '_c720';

/// En dessous de ce poids, la vidéo part telle quelle : le gain ne vaudrait
/// pas l'attente de la compression.
const int kCompressVideoAboveBytes = 8 * 1024 * 1024;

/// Grand côté de la sortie, en pixels (720p).
const int kCompressedVideoLongSide = 1280;

/// Débit au-delà duquel une vidéo déjà en 720p est tout de même recompressée.
const int kCompressVideoAboveBitsPerSecond = 3000000;

/// Ce qu'on sait d'une vidéo au moment de décider.
@immutable
class VideoFacts {
  const VideoFacts({
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
  });

  final int sizeBytes;
  final int? width;
  final int? height;
  final double? durationMs;
}

/// `true` si le fichier sort déjà de la compression.
bool isCompressedVideoPath(String path) =>
    p.basenameWithoutExtension(path).endsWith(kCompressedVideoSuffix);

/// `true` s'il vaut la peine de compresser cette vidéo avant l'envoi.
///
/// Les dimensions et la durée peuvent manquer (métadonnées illisibles) : la
/// décision se prend alors sur le poids seul.
bool shouldCompressVideo(String path, VideoFacts facts) {
  if (isCompressedVideoPath(path)) return false;
  if (facts.sizeBytes < kCompressVideoAboveBytes) return false;

  final w = facts.width;
  final h = facts.height;
  final ms = facts.durationMs;
  if (w != null && h != null && w > 0 && h > 0 && ms != null && ms > 0) {
    // Grand côté plutôt que largeur : une vidéo tournée en portrait est
    // rapportée 720×1280 ou 1280×720 selon la plateforme.
    final longSide = math.max(w, h);
    final bitsPerSecond = facts.sizeBytes * 8 * 1000 / ms;
    if (longSide <= kCompressedVideoLongSide &&
        bitsPerSecond <= kCompressVideoAboveBitsPerSecond) {
      return false;
    }
  }
  return true;
}

/// Le plugin, derrière une interface : les tests le remplacent.
abstract class VideoCompressionEngine {
  /// Métadonnées de la vidéo, ou `null` si illisibles.
  Future<VideoFacts?> probe(String path);

  /// Chemin du fichier compressé, ou `null` en cas d'échec ou d'annulation.
  Future<String?> compress(String path);

  /// Supprime la sortie du plugin une fois recopiée.
  Future<void> discard(String path);
}

class _PluginVideoCompressionEngine implements VideoCompressionEngine {
  const _PluginVideoCompressionEngine();

  @override
  Future<VideoFacts?> probe(String path) async {
    final info = await VideoCompress.getMediaInfo(path);
    return VideoFacts(
      sizeBytes: info.filesize ?? File(path).lengthSync(),
      width: info.width,
      height: info.height,
      durationMs: info.duration,
    );
  }

  @override
  Future<String?> compress(String path) async {
    final info = await VideoCompress.compressVideo(
      path,
      quality: VideoQuality.Res1280x720Quality,
      deleteOrigin: false,
      includeAudio: true,
    );
    if (info == null || info.isCancel == true) return null;
    return info.path;
  }

  @override
  Future<void> discard(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

/// Prépare les vidéos à l'envoi. Voir l'en-tête du fichier.
class VideoUploadCompressor {
  VideoUploadCompressor({
    VideoCompressionEngine? engine,
    Directory? outboxDirectory,
  })  : _engine = engine ?? const _PluginVideoCompressionEngine(),
        _outboxDirectory = outboxDirectory;

  static final VideoUploadCompressor instance = VideoUploadCompressor();

  final VideoCompressionEngine _engine;

  /// Réservé aux tests (évite path_provider), comme pour [stageMediaFile].
  final Directory? _outboxDirectory;

  /// File d'attente : chaque demande attend la fin de la précédente.
  Future<void> _queue = Future<void>.value();

  /// Fichier à envoyer : la vidéo compressée quand c'est utile, sinon
  /// [source] lui-même. Ne lève jamais.
  Future<File> prepare(File source) {
    final run = _queue.then((_) => _prepare(source));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<File> _prepare(File source) async {
    try {
      if (!source.existsSync()) return source;
      final size = source.lengthSync();
      // Décision rapide sans ouvrir la vidéo : déjà compressée, ou trop légère
      // pour que le gain vaille l'attente.
      if (!shouldCompressVideo(source.path, VideoFacts(sizeBytes: size))) {
        return source;
      }

      VideoFacts? facts;
      try {
        facts = await _engine.probe(source.path);
      } catch (e) {
        debugPrint('[VideoCompress] métadonnées illisibles, décision sur le poids seul: $e');
      }
      final decision = VideoFacts(
        sizeBytes: size,
        width: facts?.width,
        height: facts?.height,
        durationMs: facts?.durationMs,
      );
      if (!shouldCompressVideo(source.path, decision)) return source;

      final out = await _engine.compress(source.path);
      if (out == null) return source;
      try {
        final produced = File(out);
        if (!produced.existsSync()) return source;
        final producedSize = produced.lengthSync();
        // Une vidéo déjà très bien encodée peut ressortir plus lourde : on
        // garde alors l'original.
        if (producedSize == 0 || producedSize >= size) return source;

        final staged =
            await stageMediaFile(produced, outboxDirectory: _outboxDirectory);
        final marked = p.join(
          staged.parent.path,
          '${p.basenameWithoutExtension(staged.path)}'
          '$kCompressedVideoSuffix${p.extension(staged.path)}',
        );
        final result = await staged.rename(marked);
        debugPrint('[VideoCompress] $size → $producedSize octets');
        return result;
      } finally {
        try {
          await _engine.discard(out);
        } catch (_) {/* sortie déjà supprimée — ignoré */}
      }
    } catch (e) {
      debugPrint("[VideoCompress] échec, envoi de l'original: $e");
      return source;
    }
  }
}
