import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_compress/video_compress.dart';

import '../utils/media_staging.dart';
import '../utils/media_upload_limits.dart';

//  Compression des vidéos avant envoi.
//
//  Une vidéo de téléphone partait telle qu'elle avait été filmée : une minute
//  en 1080p ou en 4K dépasse vite le plafond d'envoi, et sur une connexion
//  mobile le temps d'envoi comme celui de téléchargement suit le poids du
//  fichier. Ramenée en 720p à débit fixé, la même vidéo pèse plusieurs fois
//  moins, pour un rendu qu'un écran de téléphone ne distingue pas.
//
//  Sortie : 720p au plus (côté court), 30 images/s au plus, image complète
//  toutes les 3 s, son AAC 64 kbit/s, HDR ramené en SDR. Deux codecs :
//
//  - **H.264 à 2 Mbit/s** (≈ 15 Mo par minute), lu par tous les téléphones ;
//  - **HEVC à 1,3 Mbit/s** (≈ 10 Mo par minute), seulement quand l'appelant
//    l'autorise : le téléphone l'encode par une puce dédiée ET tous les
//    appareils de la discussion le lisent (voir `VideoCodecPolicy`).
//
//  Android passe par Media3 (pont natif `VideoTranscodeBridge`), qui fixe
//  débit et codec ; en cas d'échec, l'ancien moteur (`video_compress`) prend
//  le relais, en H.264. iOS garde `video_compress`, en H.264.
//
//  Trois règles tiennent ce service :
//
//  - **Jamais bloquant.** Toute erreur — métadonnées illisibles, format
//    exotique, compression annulée, résultat plus lourd que l'original — rend
//    le fichier d'origine. Mieux vaut une vidéo lourde qu'une vidéo non envoyée.
//  - **Une compression à la fois.** Les encodeurs matériels sont en nombre
//    limité, et un album envoie trois médias en parallèle : les demandes
//    passent par une file.
//  - **Jamais deux fois.** Le fichier produit porte un suffixe qui dit son
//    codec ; une reprise d'envoi le reconnaît et le laisse tel quel. Seule
//    exception : une vidéo HEVC destinée à une discussion qui ne le lit pas.

/// Codec vidéo d'une sortie, ou d'une source.
enum VideoCodec {
  avc('video/avc'),
  hevc('video/hevc');

  const VideoCodec(this.mime);
  final String mime;

  static VideoCodec? fromMime(String? mime) {
    switch (mime?.toLowerCase()) {
      case 'video/avc':
        return VideoCodec.avc;
      case 'video/hevc':
        return VideoCodec.hevc;
    }
    return null;
  }
}

/// Suffixe des fichiers produits par l'ancien moteur (H.264).
const String kCompressedVideoSuffix = '_c720';

/// Suffixes des fichiers produits par la compression, selon leur codec.
const String kAvcVideoSuffix = '_v264';
const String kHevcVideoSuffix = '_v265';

/// En dessous de ce poids, la vidéo part telle quelle : le gain ne vaudrait
/// pas l'attente de la compression.
const int kCompressVideoAboveBytes = 1024 * 1024;

/// Sans métadonnées lisibles, rien ne dit si la vidéo est trop lourde pour sa
/// durée : on ne compresse qu'au-delà de ce poids.
const int kCompressVideoWithoutFactsAboveBytes = 8 * 1024 * 1024;

/// Dimensions maximales de la sortie (720p), en pixels.
const int kCompressedVideoLongSide = 1280;
const int kCompressedVideoShortSide = 720;

/// Images par seconde au plus : au-delà, le débit part dans une fluidité que
/// l'œil ne réclame pas dans une discussion.
const int kCompressedVideoMaxFrameRate = 30;

/// Débits de sortie, en bits par seconde.
const int kAvcVideoBitrate = 2000000;
const int kHevcVideoBitrate = 1300000;
const int kCompressedAudioBitrate = 64000;

/// Une image complète toutes les N secondes : plus rare, la vidéo pèse moins ;
/// le curseur de lecture se cale alors sur ces images.
const double kVideoIFrameIntervalSeconds = 3;

/// Débit total visé pour [codec] (image + son).
int targetBitsPerSecond(VideoCodec codec) =>
    (codec == VideoCodec.hevc ? kHevcVideoBitrate : kAvcVideoBitrate) +
    kCompressedAudioBitrate;

/// Ce qu'on sait d'une vidéo au moment de décider.
@immutable
class VideoFacts {
  const VideoFacts({
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
    this.codec,
    this.frameRate,
  });

  final int sizeBytes;
  final int? width;
  final int? height;
  final double? durationMs;

  /// `null` quand le moteur ne sait pas le lire (iOS) ou pour un codec autre
  /// que H.264 et HEVC.
  final VideoCodec? codec;
  final double? frameRate;
}

/// `true` si le fichier sort déjà de la compression.
bool isCompressedVideoPath(String path) {
  final name = p.basenameWithoutExtension(path);
  return name.endsWith(kCompressedVideoSuffix) ||
      name.endsWith(kAvcVideoSuffix) ||
      name.endsWith(kHevcVideoSuffix);
}

/// Codec d'un fichier produit par la compression, d'après son nom ; `null`
/// pour tout autre fichier.
VideoCodec? codecFromPath(String path) {
  final name = p.basenameWithoutExtension(path);
  if (name.endsWith(kHevcVideoSuffix)) return VideoCodec.hevc;
  if (name.endsWith(kAvcVideoSuffix) || name.endsWith(kCompressedVideoSuffix)) {
    return VideoCodec.avc;
  }
  return null;
}

/// `true` s'il faut compresser cette vidéo avant de l'envoyer en [target].
///
/// Les dimensions et la durée peuvent manquer (métadonnées illisibles) : la
/// décision se prend alors sur le poids seul.
bool shouldCompressVideo(
  String path,
  VideoFacts facts, {
  VideoCodec target = VideoCodec.avc,
}) {
  // Une vidéo HEVC vers une discussion qui ne le lit pas : conversion
  // obligée, quels que soient son poids et son origine.
  final codec = facts.codec ?? codecFromPath(path);
  if (codec == VideoCodec.hevc && target == VideoCodec.avc) return true;

  if (isCompressedVideoPath(path)) return false;
  if (facts.sizeBytes < kCompressVideoAboveBytes) return false;

  final w = facts.width;
  final h = facts.height;
  final ms = facts.durationMs;
  if (w == null || h == null || w <= 0 || h <= 0 || ms == null || ms <= 0) {
    return facts.sizeBytes >= kCompressVideoWithoutFactsAboveBytes;
  }
  // Grand et petit côtés plutôt que largeur et hauteur : une vidéo tournée en
  // portrait est rapportée 720×1280 ou 1280×720 selon la plateforme.
  if (math.max(w, h) > kCompressedVideoLongSide ||
      math.min(w, h) > kCompressedVideoShortSide) {
    return true;
  }
  final fps = facts.frameRate;
  if (fps != null && fps > kCompressedVideoMaxFrameRate + 0.5) return true;
  // Déjà en 720p : on ne recompresse que si le débit dépasse nettement la
  // cible. En dessous, le gain ne vaut pas une perte de qualité de plus.
  final bitsPerSecond = facts.sizeBytes * 8 * 1000 / ms;
  return bitsPerSecond > targetBitsPerSecond(target) * 1.2;
}

/// Poids probable du fichier qui partira pour une vidéo décrite par [facts] :
/// la sortie de la compression quand elle aura lieu (durée ×
/// [maxOutputBitsPerSecond]), sinon le fichier lui-même.
///
/// Sans durée connue, rien ne permet d'estimer la sortie : on s'en tient au
/// poids du fichier.
int estimateUploadBytesFor(
  String path,
  VideoFacts facts, {
  required int maxOutputBitsPerSecond,
}) {
  if (!shouldCompressVideo(path, facts)) return facts.sizeBytes;
  final ms = facts.durationMs;
  if (ms == null || ms <= 0) return facts.sizeBytes;
  final estimated = (ms * maxOutputBitsPerSecond / 8000).ceil();
  // La compression ne garde jamais une sortie plus lourde que l'original.
  return math.min(facts.sizeBytes, estimated);
}

/// Poids qui partira réellement pour un média de type [type] (1 photo,
/// 2 vidéo, 3 audio, 4 fichier) : pour une vidéo, la sortie estimée de la
/// compression ; sinon le fichier lui-même. À comparer au plafond du compte
/// ([MediaUploadLimits.maxBytes]) avant d'accepter le média.
Future<int> estimateMediaUploadBytes(File file, {required int type}) async {
  if (type == 2) return VideoUploadCompressor.instance.estimateUploadBytes(file);
  return file.existsSync() ? file.lengthSync() : 0;
}

/// Bornes du facteur de correction de la consigne de débit : jamais plus que
/// la cible (une puce qui reste en dessous n'a rien à corriger), jamais moins
/// de 60 % (une mesure aberrante ne doit pas ruiner l'image).
const double kMinBitrateFactor = 0.6;
const double kMaxBitrateFactor = 1.0;

/// Facteur à appliquer à la prochaine consigne, après qu'une consigne de
/// [requested] bit/s a donné [actual] bit/s avec le facteur [current].
///
/// La puce rend `actual / requested` fois ce qu'on lui demande ; le facteur
/// qui aurait donné exactement la cible est donc `requested / actual`. On s'en
/// rapproche aux deux tiers à chaque vidéo : une scène atypique (très calme,
/// très agitée) ne fait pas tout basculer.
double nextBitrateFactor(
  double current, {
  required int requested,
  required int actual,
}) {
  final ideal = requested / actual;
  final next = current / 3 + ideal * 2 / 3;
  return next.clamp(kMinBitrateFactor, kMaxBitrateFactor).toDouble();
}

/// Correction, propre à CE téléphone et par codec, de la consigne de débit.
///
/// L'encodage se fait en débit constant (voir `VideoTranscodeBridge`), que la
/// plupart des puces tiennent ; ce calibrage rattrape celles qui dépassent
/// malgré tout. Après chaque compression, on compare le débit obtenu au débit
/// demandé, et la consigne suivante est corrigée pour que le débit RÉEL tende
/// vers la cible. Une puce qui respecte la consigne garde un facteur de 1.
class VideoBitrateCalibration {
  const VideoBitrateCalibration();

  /// `cbr` : les facteurs appris en débit variable, faussés par le plancher
  /// de qualité d'Android, ne resservent pas.
  static const _prefix = 'video_bitrate_factor_cbr_';

  /// Une vidéo trop courte ne dit rien de fiable sur l'encodeur.
  static const int minDurationMs = 5000;

  Future<double> factorFor(VideoCodec codec) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble('$_prefix${codec.name}') ?? kMaxBitrateFactor;
      return v.clamp(kMinBitrateFactor, kMaxBitrateFactor).toDouble();
    } catch (_) {
      return kMaxBitrateFactor;
    }
  }

  /// Retient l'écart constaté. Ne lève jamais.
  Future<void> record(
    VideoCodec codec, {
    required int requested,
    required int actual,
    required int durationMs,
  }) async {
    if (requested <= 0 || actual <= 0 || durationMs < minDurationMs) return;
    try {
      final current = await factorFor(codec);
      final next = nextBitrateFactor(current, requested: requested, actual: actual);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('$_prefix${codec.name}', next);
      debugPrint('[VideoCompress] débit ${codec.name} : $requested demandés, '
          '$actual obtenus → facteur ${current.toStringAsFixed(2)} → ${next.toStringAsFixed(2)}');
    } catch (_) {/* calibrage perdu : la consigne reste la cible */}
  }
}

/// Fichier produit par un moteur, et son codec réel : un encodeur qui ne sait
/// pas faire le HEVC demandé peut rendre du H.264.
@immutable
class CompressedVideo {
  const CompressedVideo(this.path, this.codec);
  final String path;
  final VideoCodec codec;
}

/// Le moteur, derrière une interface : les tests le remplacent.
abstract class VideoCompressionEngine {
  /// Débit maximal (image + son) de ce que produit ce moteur, enveloppe
  /// comprise, en bits par seconde : sert à estimer le poids d'une vidéo avant
  /// de la compresser.
  int get maxOutputBitsPerSecond;

  /// Métadonnées de la vidéo, ou `null` si illisibles.
  Future<VideoFacts?> probe(String path);

  /// Vidéo compressée, ou `null` en cas d'échec ou d'annulation.
  Future<CompressedVideo?> compress(
    String path, {
    required VideoCodec codec,
    void Function(double progress)? onProgress,
  });

  /// Supprime la sortie du moteur une fois recopiée.
  Future<void> discard(String path);
}

/// Android : Media3, par le pont natif `VideoTranscodeBridge`.
class _Media3VideoCompressionEngine implements VideoCompressionEngine {
  _Media3VideoCompressionEngine();

  final VideoBitrateCalibration _calibration = const VideoBitrateCalibration();

  static const _channel =
      MethodChannel('com.alanya237.alanya/video_transcode');
  static final Map<String, void Function(double)> _listeners = {};
  static bool _handlerSet = false;
  static int _seq = 0;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'progress') return;
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final progress = (args['progress'] as num?)?.toDouble();
      if (progress != null) _listeners[args['id']]?.call(progress);
    });
  }

  /// 2 Mbit/s d'image et 64 kbit/s de son, avec une marge pour une puce qui
  /// dépasserait la consigne tant que le calibrage n'a pas corrigé l'écart.
  @override
  int get maxOutputBitsPerSecond => 2800000;

  @override
  Future<VideoFacts?> probe(String path) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'probe',
      {'path': path},
    );
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return VideoFacts(
      sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? File(path).lengthSync(),
      width: (m['width'] as num?)?.toInt(),
      height: (m['height'] as num?)?.toInt(),
      durationMs: (m['durationMs'] as num?)?.toDouble(),
      codec: VideoCodec.fromMime(m['videoMime'] as String?),
      frameRate: (m['frameRate'] as num?)?.toDouble(),
    );
  }

  @override
  Future<CompressedVideo?> compress(
    String path, {
    required VideoCodec codec,
    void Function(double progress)? onProgress,
  }) async {
    _ensureHandler();
    final id = '${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    final output = p.join(Directory.systemTemp.path, 'vid_$id.mp4');
    if (onProgress != null) _listeners[id] = onProgress;
    // Consigne corrigée de l'écart propre à la puce de ce téléphone.
    final target =
        codec == VideoCodec.hevc ? kHevcVideoBitrate : kAvcVideoBitrate;
    final requested = (target * await _calibration.factorFor(codec)).round();
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'transcode',
        {
          'id': id,
          'input': path,
          'output': output,
          'videoMime': codec.mime,
          'videoBitrate': requested,
          'audioBitrate': kCompressedAudioBitrate,
          'maxShortSide': kCompressedVideoShortSide,
          'maxFrameRate': kCompressedVideoMaxFrameRate,
          'iFrameIntervalSeconds': kVideoIFrameIntervalSeconds,
        },
      );
      if (raw == null) return null;
      final m = Map<String, dynamic>.from(raw);
      final produced = VideoCodec.fromMime(m['videoMime'] as String?) ?? codec;
      // Un encodeur qui a rendu un autre codec que celui demandé ne dit rien
      // de son écart sur celui-là.
      if (produced == codec) {
        await _calibration.record(
          codec,
          requested: requested,
          actual: (m['averageVideoBitrate'] as num?)?.toInt() ?? 0,
          durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        );
      }
      return CompressedVideo(m['path'] as String? ?? output, produced);
    } on PlatformException catch (e) {
      debugPrint('[VideoCompress] Media3 : ${e.code} ${e.message}');
      final f = File(output);
      if (f.existsSync()) await f.delete();
      return null;
    } finally {
      _listeners.remove(id);
    }
  }

  @override
  Future<void> discard(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

/// iOS, et secours sur Android : `video_compress`, toujours en H.264. Il ne
/// fixe pas de débit, d'où une estimation majorante.
class _PluginVideoCompressionEngine implements VideoCompressionEngine {
  const _PluginVideoCompressionEngine();

  /// Transcoder (Android) vise ≈ 3,9 Mbit/s en 720p et demande jusqu'à
  /// ≈ 1,15 Mbit/s pour un son stéréo ; l'export d'iOS reste en deçà.
  @override
  int get maxOutputBitsPerSecond => 5200000;

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
  Future<CompressedVideo?> compress(
    String path, {
    required VideoCodec codec,
    void Function(double progress)? onProgress,
  }) async {
    final subscription = onProgress == null
        ? null
        : VideoCompress.compressProgress$
            .subscribe((percent) => onProgress(percent / 100));
    try {
      final info = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.Res1280x720Quality,
        deleteOrigin: false,
        includeAudio: true,
      );
      if (info == null || info.isCancel == true || info.path == null) {
        return null;
      }
      return CompressedVideo(info.path!, VideoCodec.avc);
    } finally {
      subscription?.unsubscribe();
    }
  }

  @override
  Future<void> discard(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

/// Media3 d'abord ; s'il échoue, l'ancien moteur, en H.264.
class _FallbackVideoCompressionEngine implements VideoCompressionEngine {
  const _FallbackVideoCompressionEngine(this.primary, this.secondary);

  final VideoCompressionEngine primary;
  final VideoCompressionEngine secondary;

  @override
  int get maxOutputBitsPerSecond => primary.maxOutputBitsPerSecond;

  @override
  Future<VideoFacts?> probe(String path) async {
    try {
      final facts = await primary.probe(path);
      if (facts != null) return facts;
    } catch (e) {
      debugPrint('[VideoCompress] lecture Media3 impossible, repli: $e');
    }
    return secondary.probe(path);
  }

  @override
  Future<CompressedVideo?> compress(
    String path, {
    required VideoCodec codec,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final out = await primary.compress(path, codec: codec, onProgress: onProgress);
      if (out != null) return out;
    } catch (e) {
      debugPrint('[VideoCompress] Media3 en échec, repli: $e');
    }
    return secondary.compress(path, codec: VideoCodec.avc, onProgress: onProgress);
  }

  @override
  Future<void> discard(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

VideoCompressionEngine _defaultEngine() => Platform.isAndroid
    ? _FallbackVideoCompressionEngine(
        _Media3VideoCompressionEngine(),
        const _PluginVideoCompressionEngine(),
      )
    : const _PluginVideoCompressionEngine();

/// Prépare les vidéos à l'envoi. Voir l'en-tête du fichier.
class VideoUploadCompressor {
  VideoUploadCompressor({
    VideoCompressionEngine? engine,
    Directory? outboxDirectory,
  })  : _engine = engine ?? _defaultEngine(),
        _outboxDirectory = outboxDirectory;

  static final VideoUploadCompressor instance = VideoUploadCompressor();

  final VideoCompressionEngine _engine;

  /// Réservé aux tests (évite path_provider), comme pour [stageMediaFile].
  final Directory? _outboxDirectory;

  /// File d'attente : chaque demande attend la fin de la précédente.
  Future<void> _queue = Future<void>.value();

  Future<VideoFacts> _facts(File source) async {
    final size = source.lengthSync();
    VideoFacts? facts;
    try {
      facts = await _engine.probe(source.path);
    } catch (e) {
      debugPrint('[VideoCompress] métadonnées illisibles, décision sur le poids seul: $e');
    }
    return VideoFacts(
      sizeBytes: size,
      width: facts?.width,
      height: facts?.height,
      durationMs: facts?.durationMs,
      codec: facts?.codec ?? codecFromPath(source.path),
      frameRate: facts?.frameRate,
    );
  }

  /// Poids probable du fichier qui partira pour [source] (voir
  /// [estimateUploadBytesFor]), en comptant sur le H.264, le plus lourd des
  /// deux codecs. Permet de refuser tout de suite une vidéo trop longue, sans
  /// attendre la compression. Ne lève jamais.
  Future<int> estimateUploadBytes(File source) async {
    try {
      if (!source.existsSync()) return 0;
      final size = source.lengthSync();
      if (isCompressedVideoPath(source.path) ||
          size < kCompressVideoAboveBytes) {
        return size;
      }
      return estimateUploadBytesFor(
        source.path,
        await _facts(source),
        maxOutputBitsPerSecond: _engine.maxOutputBitsPerSecond,
      );
    } catch (e) {
      debugPrint('[VideoCompress] estimation impossible: $e');
      return source.existsSync() ? source.lengthSync() : 0;
    }
  }

  /// `true` si [path] est une vidéo HEVC : d'après le nom d'un fichier produit
  /// ici, sinon d'après ses métadonnées. `false` dans le doute. Ne lève jamais.
  Future<bool> isHevc(String path) async {
    final known = codecFromPath(path);
    if (known != null) return known == VideoCodec.hevc;
    try {
      if (!File(path).existsSync()) return false;
      return (await _engine.probe(path))?.codec == VideoCodec.hevc;
    } catch (_) {
      return false;
    }
  }

  /// Fichier à envoyer : la vidéo compressée quand c'est utile, sinon
  /// [source] lui-même. Ne lève jamais.
  ///
  /// [allowHevc] : la discussion destinataire lit le HEVC et ce téléphone sait
  /// l'encoder. Sinon, sortie en H.264 — et une source HEVC est convertie.
  /// [onProgress] reçoit l'avancement de la compression (0 à 1).
  Future<File> prepare(
    File source, {
    bool allowHevc = false,
    void Function(double progress)? onProgress,
  }) {
    final run = _queue.then(
      (_) => _prepare(source, allowHevc: allowHevc, onProgress: onProgress),
    );
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<File> _prepare(
    File source, {
    required bool allowHevc,
    void Function(double progress)? onProgress,
  }) async {
    final target = allowHevc ? VideoCodec.hevc : VideoCodec.avc;
    try {
      if (!source.existsSync()) return source;
      final size = source.lengthSync();
      // Décision rapide sans ouvrir la vidéo : déjà compressée dans un codec
      // que la discussion lit.
      final pathCodec = codecFromPath(source.path);
      if (isCompressedVideoPath(source.path) &&
          !(pathCodec == VideoCodec.hevc && target == VideoCodec.avc)) {
        return source;
      }

      final facts = await _facts(source);
      if (!shouldCompressVideo(source.path, facts, target: target)) {
        return source;
      }
      final mustConvert =
          facts.codec == VideoCodec.hevc && target == VideoCodec.avc;

      final out = await _engine.compress(
        source.path,
        codec: target,
        onProgress: onProgress,
      );
      if (out == null) return source;
      try {
        final produced = File(out.path);
        if (!produced.existsSync()) return source;
        final producedSize = produced.lengthSync();
        // Une vidéo déjà très bien encodée peut ressortir plus lourde : on
        // garde alors l'original — sauf s'il fallait quitter le HEVC.
        if (producedSize == 0 || (producedSize >= size && !mustConvert)) {
          return source;
        }

        final staged =
            await stageMediaFile(produced, outboxDirectory: _outboxDirectory);
        final suffix =
            out.codec == VideoCodec.hevc ? kHevcVideoSuffix : kAvcVideoSuffix;
        final marked = p.join(
          staged.parent.path,
          '${p.basenameWithoutExtension(staged.path)}'
          '$suffix${p.extension(staged.path)}',
        );
        final result = await staged.rename(marked);
        debugPrint('[VideoCompress] $size → $producedSize octets (${out.codec.name})');
        return result;
      } finally {
        try {
          await _engine.discard(out.path);
        } catch (_) {/* sortie déjà supprimée — ignoré */}
      }
    } catch (e) {
      debugPrint("[VideoCompress] échec, envoi de l'original: $e");
      return source;
    }
  }
}
