import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:talky_flutter/core/theme/locale_controller.dart';
import 'package:talky_flutter/core/utils/media_upload_limits.dart';
import 'package:talky_flutter/core/services/video_upload_compressor.dart';

import 'fakes/chat_test_harness.dart';

const int _mo = 1024 * 1024;

/// Débit maximal annoncé par le moteur factice (celui de Media3).
const int _maxBps = 2600000;

/// Moteur factice : écrit une « sortie compressée » de [outputBytes] octets.
class _FakeEngine implements VideoCompressionEngine {
  _FakeEngine(this.workDir);

  final Directory workDir;
  int outputBytes = 1 * _mo;
  VideoFacts? facts;
  Object? probeError;
  Object? compressError;
  bool returnNull = false;
  Duration compressDelay = Duration.zero;

  /// Codec réellement produit : celui demandé, sauf s'il est forcé (encodeur
  /// sans HEVC, qui rend du H.264).
  VideoCodec? producedCodec;

  final List<({String path, VideoCodec codec})> compressed = [];
  final List<String> discarded = [];
  int _running = 0;
  int maxConcurrent = 0;

  @override
  int get maxOutputBitsPerSecond => _maxBps;

  @override
  Future<VideoFacts?> probe(String path) async {
    if (probeError != null) throw probeError!;
    return facts;
  }

  @override
  Future<CompressedVideo?> compress(
    String path, {
    required VideoCodec codec,
    void Function(double progress)? onProgress,
  }) async {
    _running++;
    maxConcurrent = _running > maxConcurrent ? _running : maxConcurrent;
    try {
      await Future<void>.delayed(compressDelay);
      if (compressError != null) throw compressError!;
      compressed.add((path: path, codec: codec));
      onProgress?.call(0.5);
      onProgress?.call(1.0);
      if (returnNull) return null;
      final out = File(p.join(workDir.path, 'plugin_out_${compressed.length}.mp4'));
      await out.writeAsBytes(List<int>.filled(outputBytes, 1));
      return CompressedVideo(out.path, producedCodec ?? codec);
    } finally {
      _running--;
    }
  }

  @override
  Future<void> discard(String path) async {
    discarded.add(path);
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }
}

File _video(Directory dir, String name, int bytes) {
  final f = File(p.join(dir.path, name));
  f.writeAsBytesSync(List<int>.filled(bytes, 0));
  return f;
}

void main() {
  group('shouldCompressVideo', () {
    test('une vidéo légère sans métadonnées part telle quelle', () {
      expect(
        shouldCompressVideo('/v.mp4', const VideoFacts(sizeBytes: 5 * _mo)),
        isFalse,
      );
    });

    test('une vidéo lourde sans métadonnées est compressée', () {
      expect(
        shouldCompressVideo('/v.mp4', const VideoFacts(sizeBytes: 40 * _mo)),
        isTrue,
      );
    });

    test('un fichier déjà compressé ne l’est jamais une seconde fois', () {
      for (final suffix in const [kCompressedVideoSuffix, kAvcVideoSuffix]) {
        expect(
          shouldCompressVideo(
            '/outbox_1$suffix.mp4',
            const VideoFacts(sizeBytes: 40 * _mo),
          ),
          isFalse,
        );
      }
    });

    test('moins de 1 Mo : jamais compressée, même en 1080p', () {
      expect(
        shouldCompressVideo(
          '/v.mp4',
          const VideoFacts(sizeBytes: 900 * 1024, width: 1920, height: 1080, durationMs: 2000),
        ),
        isFalse,
      );
    });

    test('déjà en 720p avec un débit raisonnable : laissée telle quelle', () {
      // 12 Mo sur 60 s ≈ 1,7 Mbit/s, sous la cible H.264 + 20 %.
      expect(
        shouldCompressVideo(
          '/v.mp4',
          const VideoFacts(sizeBytes: 12 * _mo, width: 720, height: 1280, durationMs: 60000),
        ),
        isFalse,
      );
    });

    test('720p mais débit élevé : compressée', () {
      // 40 Mo sur 30 s ≈ 11 Mbit/s.
      expect(
        shouldCompressVideo(
          '/v.mp4',
          const VideoFacts(sizeBytes: 40 * _mo, width: 1280, height: 720, durationMs: 30000),
        ),
        isTrue,
      );
    });

    test('720p à 60 images/s : compressée, même à débit modéré', () {
      expect(
        shouldCompressVideo(
          '/v.mp4',
          const VideoFacts(
            sizeBytes: 12 * _mo, width: 1280, height: 720, durationMs: 60000, frameRate: 60,
          ),
        ),
        isTrue,
      );
    });

    test('1080p : compressée, quelle que soit l’orientation rapportée', () {
      for (final dims in const [(1920, 1080), (1080, 1920)]) {
        expect(
          shouldCompressVideo(
            '/v.mp4',
            VideoFacts(sizeBytes: 12 * _mo, width: dims.$1, height: dims.$2, durationMs: 60000),
          ),
          isTrue,
        );
      }
    });

    test('HEVC vers une discussion en H.264 : conversion obligée, même légère', () {
      const small = VideoFacts(
        sizeBytes: 500 * 1024, width: 1280, height: 720, durationMs: 5000, codec: VideoCodec.hevc,
      );
      expect(shouldCompressVideo('/v.mp4', small), isTrue);
      expect(shouldCompressVideo('/v.mp4', small, target: VideoCodec.hevc), isFalse);
      // Un fichier produit en HEVC, reconnu à son nom.
      expect(
        shouldCompressVideo('/x$kHevcVideoSuffix.mp4', const VideoFacts(sizeBytes: 5 * _mo)),
        isTrue,
      );
      expect(
        shouldCompressVideo(
          '/x$kHevcVideoSuffix.mp4',
          const VideoFacts(sizeBytes: 5 * _mo),
          target: VideoCodec.hevc,
        ),
        isFalse,
      );
    });
  });

  group('estimateUploadBytesFor', () {
    test('une vidéo légère part telle quelle : son propre poids', () {
      expect(
        estimateUploadBytesFor('/v.mp4', const VideoFacts(sizeBytes: 5 * _mo),
            maxOutputBitsPerSecond: _maxBps),
        5 * _mo,
      );
    });

    test('vidéo lourde : durée × débit maximal du moteur', () {
      const facts = VideoFacts(
        sizeBytes: 150 * _mo, width: 1920, height: 1080, durationMs: 60000,
      );
      expect(
        estimateUploadBytesFor('/v.mp4', facts, maxOutputBitsPerSecond: _maxBps),
        60 * _maxBps ~/ 8,
      );
    });

    test('une vidéo 4K de 300 Mo et de cinq minutes tient sous la limite', () {
      const facts = VideoFacts(
        sizeBytes: 300 * _mo, width: 3840, height: 2160, durationMs: 300000,
      );
      expect(
        estimateUploadBytesFor('/v.mp4', facts, maxOutputBitsPerSecond: _maxBps),
        lessThan(kMaxMediaUploadBytes),
      );
    });

    test('durée inconnue : on s’en tient au poids du fichier', () {
      expect(
        estimateUploadBytesFor('/v.mp4', const VideoFacts(sizeBytes: 150 * _mo),
            maxOutputBitsPerSecond: _maxBps),
        150 * _mo,
      );
    });

    test('l’estimation ne dépasse jamais le fichier d’origine', () {
      const facts = VideoFacts(
        sizeBytes: 20 * _mo, width: 1920, height: 1080, durationMs: 120000,
      );
      expect(
        estimateUploadBytesFor('/v.mp4', facts, maxOutputBitsPerSecond: _maxBps),
        20 * _mo,
      );
    });
  });

  group('calibrage du débit', () {
    test('Galaxy S10 : 2,0 demandés, 2,44 obtenus → la consigne baisse', () {
      final next = nextBitrateFactor(1.0, requested: 2000000, actual: 2440000);
      // Idéal 0,82 ; on s'en rapproche aux deux tiers.
      expect(next, closeTo(1 / 3 + 0.8197 * 2 / 3, 0.001));
      expect(next, lessThan(1.0));
    });

    test('converge vers la consigne qui donne la cible', () {
      // Une puce qui rend toujours 22 % de plus que demandé.
      var factor = 1.0;
      for (var i = 0; i < 6; i++) {
        final requested = (kAvcVideoBitrate * factor).round();
        factor = nextBitrateFactor(factor, requested: requested, actual: (requested * 1.22).round());
      }
      final obtenu = kAvcVideoBitrate * factor * 1.22;
      expect(obtenu, closeTo(kAvcVideoBitrate, kAvcVideoBitrate * 0.02));
    });

    test('une puce qui respecte la consigne garde le facteur 1', () {
      expect(nextBitrateFactor(1.0, requested: 2000000, actual: 2000000), 1.0);
      // En dessous de la cible (scène calme) : jamais au-dessus de 1.
      expect(nextBitrateFactor(1.0, requested: 2000000, actual: 1200000), 1.0);
    });

    test('une mesure aberrante ne descend pas sous 60 %', () {
      expect(nextBitrateFactor(0.6, requested: 1200000, actual: 9000000), kMinBitrateFactor);
    });

    test('mémorisé par codec, ignoré pour une vidéo trop courte', () async {
      SharedPreferences.setMockInitialValues({});
      const cal = VideoBitrateCalibration();
      expect(await cal.factorFor(VideoCodec.avc), 1.0);

      await cal.record(VideoCodec.avc, requested: 2000000, actual: 2440000, durationMs: 2000);
      expect(await cal.factorFor(VideoCodec.avc), 1.0, reason: 'moins de 5 s : rien de fiable');

      await cal.record(VideoCodec.avc, requested: 2000000, actual: 2440000, durationMs: 41000);
      expect(await cal.factorFor(VideoCodec.avc), lessThan(1.0));
      expect(await cal.factorFor(VideoCodec.hevc), 1.0, reason: 'chaque codec a son écart');
    });
  });

  group('VideoUploadCompressor', () {
    late Directory tmp;
    late Directory outbox;
    late _FakeEngine engine;
    late VideoUploadCompressor compressor;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('video_compress_');
      outbox = Directory(p.join(tmp.path, 'outbox'))..createSync();
      engine = _FakeEngine(tmp);
      compressor = VideoUploadCompressor(engine: engine, outboxDirectory: outbox);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('vidéo légère : pas compressée', () async {
      final src = _video(tmp, 'small.mp4', 900 * 1024);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.compressed, isEmpty);
    });

    test('vidéo lourde : H.264 par défaut, marquée dans l’outbox, sortie du moteur supprimée', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src);

      expect(engine.compressed.single.codec, VideoCodec.avc);
      expect(p.dirname(out.path), outbox.path);
      expect(p.basenameWithoutExtension(out.path), endsWith(kAvcVideoSuffix));
      expect(out.lengthSync(), 1 * _mo);
      expect(src.existsSync(), isTrue, reason: 'l’original n’appartient pas au compresseur');
      expect(engine.discarded, hasLength(1));
      expect(File(engine.discarded.single).existsSync(), isFalse);
    });

    test('discussion qui lit le HEVC : sortie HEVC, marquée comme telle', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src, allowHevc: true);
      expect(engine.compressed.single.codec, VideoCodec.hevc);
      expect(p.basenameWithoutExtension(out.path), endsWith(kHevcVideoSuffix));
    });

    test('encodeur sans HEVC : le H.264 rendu est marqué H.264', () async {
      engine.producedCodec = VideoCodec.avc;
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src, allowHevc: true);
      expect(p.basenameWithoutExtension(out.path), endsWith(kAvcVideoSuffix));
    });

    test('la progression remonte à l’appelant', () async {
      final seen = <double>[];
      await compressor.prepare(_video(tmp, 'big.mp4', 20 * _mo), onProgress: seen.add);
      expect(seen, [0.5, 1.0]);
    });

    test('le fichier produit n’est pas recompressé à la reprise', () async {
      final first = await compressor.prepare(_video(tmp, 'big.mp4', 20 * _mo));
      // Le fichier produit est « lourd » au regard du seuil : seul le suffixe
      // l'empêche d'être recompressé.
      first.writeAsBytesSync(List<int>.filled(20 * _mo, 1));
      final again = await compressor.prepare(first);
      expect(again.path, first.path);
      expect(engine.compressed, hasLength(1));
    });

    test('vidéo HEVC produite ici, transférée vers une discussion en H.264 : convertie', () async {
      final hevc = _video(outbox, 'x$kHevcVideoSuffix.mp4', 5 * _mo);
      engine.outputBytes = 6 * _mo; // plus lourde : on la garde quand même
      final out = await compressor.prepare(hevc);
      expect(engine.compressed.single.codec, VideoCodec.avc);
      expect(p.basenameWithoutExtension(out.path), endsWith(kAvcVideoSuffix));

      final untouched = await compressor.prepare(hevc, allowHevc: true);
      expect(untouched.path, hevc.path, reason: 'la discussion lit le HEVC');
    });

    test('source HEVC légère (iPhone, par ex.) vers une discussion en H.264 : convertie', () async {
      engine.facts = const VideoFacts(
        sizeBytes: 600 * 1024, width: 1280, height: 720, durationMs: 4000, codec: VideoCodec.hevc,
      );
      final src = _video(tmp, 'clip.mov', 600 * 1024);
      final out = await compressor.prepare(src);
      expect(engine.compressed.single.codec, VideoCodec.avc);
      expect(p.basenameWithoutExtension(out.path), endsWith(kAvcVideoSuffix));
    });

    test('résultat plus lourd que l’original : on garde l’original', () async {
      engine.outputBytes = 25 * _mo;
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.discarded, hasLength(1), reason: 'la sortie inutile est supprimée');
    });

    test('échec ou annulation du moteur : on envoie l’original', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);

      engine.compressError = StateError('moteur');
      expect((await compressor.prepare(src)).path, src.path);

      engine
        ..compressError = null
        ..returnNull = true;
      expect((await compressor.prepare(src)).path, src.path);
    });

    test('métadonnées illisibles : décision sur le poids seul', () async {
      engine.probeError = Exception('illisible');
      final out = await compressor.prepare(_video(tmp, 'big.mp4', 20 * _mo));
      expect(isCompressedVideoPath(out.path), isTrue);
    });

    test('déjà en 720p avec un débit raisonnable : pas de compression', () async {
      final src = _video(tmp, 'hd.mp4', 12 * _mo);
      engine.facts = const VideoFacts(
        sizeBytes: 12 * _mo, width: 1280, height: 720, durationMs: 90000,
      );
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.compressed, isEmpty);
    });

    test('estimation : durée × débit maximal du moteur, sans rien compresser', () async {
      final src = _video(tmp, 'long.mp4', 20 * _mo);
      engine.facts = const VideoFacts(
        sizeBytes: 20 * _mo, width: 1920, height: 1080, durationMs: 10000,
      );
      expect(await compressor.estimateUploadBytes(src), 10 * _maxBps ~/ 8);
      expect(engine.compressed, isEmpty);
    });

    test('estimation : métadonnées illisibles, poids du fichier', () async {
      engine.probeError = Exception('illisible');
      final src = _video(tmp, 'opaque.mp4', 20 * _mo);
      expect(await compressor.estimateUploadBytes(src), 20 * _mo);
    });

    test('isHevc : d’après le nom d’un fichier produit, sinon d’après ses métadonnées', () async {
      expect(await compressor.isHevc('/x$kHevcVideoSuffix.mp4'), isTrue);
      expect(await compressor.isHevc('/x$kAvcVideoSuffix.mp4'), isFalse);
      final src = _video(tmp, 'clip.mp4', 2 * _mo);
      engine.facts = const VideoFacts(sizeBytes: 2 * _mo, codec: VideoCodec.hevc);
      expect(await compressor.isHevc(src.path), isTrue);
      engine.probeError = Exception('illisible');
      expect(await compressor.isHevc(src.path), isFalse, reason: 'dans le doute, non');
    });

    test('demandes simultanées : une seule compression à la fois', () async {
      engine.compressDelay = const Duration(milliseconds: 30);
      final results = await Future.wait([
        for (final n in ['a', 'b', 'c']) compressor.prepare(_video(tmp, '$n.mp4', 20 * _mo)),
      ]);
      expect(engine.maxConcurrent, 1);
      expect(results.map((f) => isCompressedVideoPath(f.path)), everyElement(isTrue));
      expect(results.map((f) => f.path).toSet(), hasLength(3));
    });
  });

  group('Envoi d’une vidéo dans une conversation', () {
    late ChatTestHarness h;
    late Directory tmp;
    late Directory outbox;
    late _FakeEngine engine;
    late Set<int> hevcConversations;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('video_send_');
      // Un chemin contenant `talky_outbox` : `sendMediaFile` le considère déjà
      // mis en attente et ne passe pas par path_provider.
      outbox = Directory(p.join(tmp.path, 'talky_outbox'))..createSync();
      engine = _FakeEngine(tmp)..outputBytes = 3 * _mo;
      hevcConversations = {};
      // `sendMediaFile` lit la langue (nom du type de document) : sans
      // contrôleur, `LocaleController.instance` lève.
      LocaleController();
      h = ChatTestHarness();
      await h.setUp(
        videoCompressor: VideoUploadCompressor(engine: engine, outboxDirectory: outbox),
        hevcAllowed: (id) async => hevcConversations.contains(id),
      );
    });

    tearDown(() async {
      await h.tearDown();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('la vidéo envoyée est la version compressée, et la ligne locale suit', () async {
      final src = _video(outbox, 'outbox_src.mp4', 30 * _mo);

      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 2,
        file: src,
        mediaDuration: 60,
      );
      await h.pumpEventQueue();

      expect(h.api.uploadedPaths, hasLength(1));
      final sent = h.api.uploadedPaths.single;
      expect(isCompressedVideoPath(sent), isTrue);
      expect(engine.compressed.single.codec, VideoCodec.avc);

      final row = (await h.messages()).single;
      expect(row.localMediaPath, sent, reason: 'la bulle de l’expéditeur lit la version compressée');
      expect(row.mediaSize, 3 * _mo, reason: 'le poids transmis est celui du fichier envoyé');
      expect(row.pendingUploadPath, isNull);
      expect(src.existsSync(), isFalse, reason: 'la copie d’origine de l’outbox est libérée');
      expect(h.repo.compressionProgress.value, isEmpty, reason: 'la bulle ne reste pas sur « Compression… »');
    });

    test('discussion qui lit le HEVC : la vidéo part en HEVC', () async {
      hevcConversations.add(ChatTestHarness.convId);
      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 2,
        file: _video(outbox, 'outbox_src.mp4', 30 * _mo),
      );
      await h.pumpEventQueue();

      expect(engine.compressed.single.codec, VideoCodec.hevc);
      expect(p.basenameWithoutExtension(h.api.uploadedPaths.single), endsWith(kHevcVideoSuffix));
    });

    test('transfert d’une vidéo HEVC : copie serveur là où le HEVC est lu, H.264 ailleurs', () async {
      hevcConversations.addAll({ChatTestHarness.convId, 20});
      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 2,
        file: _video(outbox, 'outbox_src.mp4', 30 * _mo),
      );
      await h.pumpEventQueue();
      final source = (await h.messages()).single;
      expect(p.basenameWithoutExtension(source.localMediaPath!), endsWith(kHevcVideoSuffix));

      final result = await h.repo.forwardMessage(
        source: source,
        targetConversationIDs: [20, 30],
      );
      await h.pumpEventQueue();

      expect(result.succeeded, 2);
      expect(h.api.forwardedTargets, [
        [20],
      ], reason: 'la discussion 20 lit le HEVC : transfert habituel');
      expect(engine.compressed.last.codec, VideoCodec.avc, reason: 'la discussion 30 reçoit du H.264');
      expect(p.basenameWithoutExtension(h.api.uploadedPaths.last), endsWith(kAvcVideoSuffix));
    });

    test('une photo ne passe jamais par le compresseur vidéo', () async {
      final photo = File(p.join(outbox.path, 'outbox_photo.jpg'))
        ..writeAsBytesSync(List<int>.filled(20 * _mo, 0));

      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 1,
        file: photo,
      );
      await h.pumpEventQueue();

      expect(engine.compressed, isEmpty);
      expect(h.api.uploadedPaths.single, photo.path);
    });

    test('reprise d’un envoi déjà compressé : le fichier part tel quel', () async {
      final already = _video(outbox, 'outbox_x$kCompressedVideoSuffix.mp4', 30 * _mo);

      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 2,
        file: already,
      );
      await h.pumpEventQueue();

      expect(engine.compressed, isEmpty);
      expect(h.api.uploadedPaths.single, already.path);
      final row = (await h.messages()).single;
      expect(row.localMediaPath, already.path);
      // Valeur jamais réécrite : celle relevée à l'insertion.
      expect(row.mediaSize, const Value(30 * _mo).value);
    });
  });
}
