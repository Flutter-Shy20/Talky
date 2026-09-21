import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/theme/locale_controller.dart';
import 'package:talky_flutter/core/services/video_upload_compressor.dart';

import 'fakes/chat_test_harness.dart';

const int _mo = 1024 * 1024;

/// Moteur factice : écrit une « sortie compressée » de [outputBytes] octets.
class _FakeEngine implements VideoCompressionEngine {
  _FakeEngine(this.workDir, {this.outputBytes = 1 * _mo});

  final Directory workDir;
  int outputBytes;
  VideoFacts? facts;
  Object? probeError;
  Object? compressError;
  bool returnNull = false;
  Duration compressDelay = Duration.zero;

  final List<String> compressed = [];
  final List<String> discarded = [];
  int _running = 0;
  int maxConcurrent = 0;

  @override
  Future<VideoFacts?> probe(String path) async {
    if (probeError != null) throw probeError!;
    return facts;
  }

  @override
  Future<String?> compress(String path) async {
    _running++;
    maxConcurrent = _running > maxConcurrent ? _running : maxConcurrent;
    try {
      await Future<void>.delayed(compressDelay);
      if (compressError != null) throw compressError!;
      compressed.add(path);
      if (returnNull) return null;
      final out = File(p.join(workDir.path, 'plugin_out_${compressed.length}.mp4'));
      await out.writeAsBytes(List<int>.filled(outputBytes, 1));
      return out.path;
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
    test('une vidéo légère part telle quelle', () {
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
      expect(
        shouldCompressVideo(
          '/outbox_1$kCompressedVideoSuffix.mp4',
          const VideoFacts(sizeBytes: 40 * _mo),
        ),
        isFalse,
      );
    });

    test('déjà en 720p avec un débit raisonnable : laissée telle quelle', () {
      // 12 Mo sur 60 s ≈ 1,7 Mbit/s.
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

    test('vidéo légère : ni lue ni compressée', () async {
      final src = _video(tmp, 'small.mp4', 2 * _mo);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.compressed, isEmpty);
    });

    test('vidéo lourde : copie compressée et marquée dans l’outbox, sortie du plugin supprimée', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src);

      expect(out.path, isNot(src.path));
      expect(p.dirname(out.path), outbox.path);
      expect(isCompressedVideoPath(out.path), isTrue);
      expect(out.lengthSync(), 1 * _mo);
      expect(src.existsSync(), isTrue, reason: 'l’original n’appartient pas au compresseur');
      expect(engine.discarded, hasLength(1));
      expect(File(engine.discarded.single).existsSync(), isFalse);
    });

    test('le fichier produit n’est pas recompressé à la reprise', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final first = await compressor.prepare(src);
      // Le fichier produit est « lourd » au regard du seuil : seul le suffixe
      // l'empêche d'être recompressé.
      first.writeAsBytesSync(List<int>.filled(20 * _mo, 1));
      final again = await compressor.prepare(first);
      expect(again.path, first.path);
      expect(engine.compressed, hasLength(1));
    });

    test('résultat plus lourd que l’original : on garde l’original', () async {
      engine.outputBytes = 25 * _mo;
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.discarded, hasLength(1), reason: 'la sortie inutile est supprimée');
    });

    test('échec ou annulation du plugin : on envoie l’original', () async {
      final src = _video(tmp, 'big.mp4', 20 * _mo);

      engine.compressError = StateError('plugin');
      expect((await compressor.prepare(src)).path, src.path);

      engine
        ..compressError = null
        ..returnNull = true;
      expect((await compressor.prepare(src)).path, src.path);
    });

    test('métadonnées illisibles : décision sur le poids seul', () async {
      engine.probeError = Exception('illisible');
      final src = _video(tmp, 'big.mp4', 20 * _mo);
      final out = await compressor.prepare(src);
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

    test('demandes simultanées : une seule compression à la fois', () async {
      engine.compressDelay = const Duration(milliseconds: 30);
      final a = _video(tmp, 'a.mp4', 20 * _mo);
      final b = _video(tmp, 'b.mp4', 20 * _mo);
      final c = _video(tmp, 'c.mp4', 20 * _mo);
      final results = await Future.wait([
        compressor.prepare(a),
        compressor.prepare(b),
        compressor.prepare(c),
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

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('video_send_');
      // Un chemin contenant `talky_outbox` : `sendMediaFile` le considère déjà
      // mis en attente et ne passe pas par path_provider.
      outbox = Directory(p.join(tmp.path, 'talky_outbox'))..createSync();
      engine = _FakeEngine(tmp, outputBytes: 3 * _mo);
      // `sendMediaFile` lit la langue (nom du type de document) : sans
      // contrôleur, `LocaleController.instance` lève.
      LocaleController();
      h = ChatTestHarness();
      await h.setUp(
        videoCompressor: VideoUploadCompressor(engine: engine, outboxDirectory: outbox),
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

      final row = (await h.messages()).single;
      expect(row.localMediaPath, sent, reason: 'la bulle de l’expéditeur lit la version compressée');
      expect(row.mediaSize, 3 * _mo, reason: 'le poids transmis est celui du fichier envoyé');
      expect(row.pendingUploadPath, isNull);
      expect(src.existsSync(), isFalse, reason: 'la copie d’origine de l’outbox est libérée');
    });

    test('une photo ne passe jamais par le compresseur', () async {
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
