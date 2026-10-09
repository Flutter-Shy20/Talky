import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/services/image_upload_compressor.dart';
import 'package:talky_flutter/core/theme/locale_controller.dart';

import 'fakes/chat_test_harness.dart';

const int _ko = 1024;

/// Moteur factice : écrit une « sortie WebP » de [outputBytes] octets.
class _FakeEngine implements ImageCompressionEngine {
  _FakeEngine(this.workDir);

  final Directory workDir;
  int outputBytes = 200 * _ko;
  ({int width, int height})? dims;
  Object? dimsError;
  Object? compressError;
  bool returnNull = false;
  Duration compressDelay = Duration.zero;

  final List<({String path, int minSide, int sampleSize})> calls = [];
  final List<String> discarded = [];
  int _running = 0;
  int maxConcurrent = 0;

  @override
  Future<({int width, int height})?> dimensions(String path) async {
    if (dimsError != null) throw dimsError!;
    return dims;
  }

  @override
  Future<String?> compress(
    String path, {
    required int minSide,
    required int sampleSize,
  }) async {
    _running++;
    maxConcurrent = _running > maxConcurrent ? _running : maxConcurrent;
    try {
      await Future<void>.delayed(compressDelay);
      if (compressError != null) throw compressError!;
      calls.add((path: path, minSide: minSide, sampleSize: sampleSize));
      if (returnNull) return null;
      final out = File(p.join(workDir.path, 'plugin_out_${calls.length}.webp'));
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

File _photo(Directory dir, String name, int bytes) {
  final f = File(p.join(dir.path, name));
  f.writeAsBytesSync(List<int>.filled(bytes, 0));
  return f;
}

void main() {
  group('targetShortSide', () {
    test('paysage 4000×3000 : grand côté ramené à 1600, côté court à 1200', () {
      expect(targetShortSide(4000, 3000), 1200);
    });

    test('portrait 3000×4000 : même résultat, quelle que soit l’orientation', () {
      expect(targetShortSide(3000, 4000), 1200);
    });

    test('déjà sous 1600 px : jamais agrandie', () {
      expect(targetShortSide(1200, 800), 800);
      expect(targetShortSide(1600, 900), 900);
    });
  });

  group('decodeSampleSize', () {
    test('garde au moins 1600 px sur le grand côté', () {
      expect(decodeSampleSize(1600, 1200), 1);
      expect(decodeSampleSize(3199, 2000), 1);
      expect(decodeSampleSize(3200, 2400), 2);
      expect(decodeSampleSize(4000, 3000), 2);
      expect(decodeSampleSize(8000, 6000), 4);
    });
  });

  group('shouldCompressImage', () {
    test('photos ordinaires : oui', () {
      expect(shouldCompressImage('/a.jpg'), isTrue);
      expect(shouldCompressImage('/a.PNG'), isTrue);
      expect(shouldCompressImage('/a.heic'), isTrue);
      expect(shouldCompressImage('/a.webp'), isTrue);
    });

    test('un GIF garde son animation : non', () {
      expect(shouldCompressImage('/a.gif'), isFalse);
    });

    test('un fichier déjà compressé : non', () {
      expect(shouldCompressImage('/outbox/x$kCompressedImageSuffix.webp'), isFalse);
    });
  });

  group('ImageUploadCompressor', () {
    late Directory tmp;
    late Directory outbox;
    late _FakeEngine engine;
    late ImageUploadCompressor compressor;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('image_compress_');
      outbox = Directory(p.join(tmp.path, 'outbox'))..createSync();
      engine = _FakeEngine(tmp);
      compressor = ImageUploadCompressor(engine: engine, outboxDirectory: outbox);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('photo lourde : WebP marqué dans l’outbox, sortie du plugin supprimée', () async {
      engine.dims = (width: 4000, height: 3000);
      final src = _photo(tmp, 'big.jpg', 4 * 1024 * _ko);

      final out = await compressor.prepare(src);

      expect(isCompressedImagePath(out.path), isTrue);
      expect(p.extension(out.path), '.webp');
      expect(out.parent.path, outbox.path);
      expect(out.lengthSync(), 200 * _ko);
      expect(engine.calls.single.minSide, 1200);
      expect(engine.calls.single.sampleSize, 2);
      expect(engine.discarded, hasLength(1));
      expect(src.existsSync(), isTrue, reason: 'l’original ne nous appartient pas');
    });

    test('un GIF part tel quel, sans passer par le plugin', () async {
      final src = _photo(tmp, 'anim.gif', 3 * 1024 * _ko);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.calls, isEmpty);
    });

    test('le fichier produit n’est pas recompressé à la reprise', () async {
      engine.dims = (width: 4000, height: 3000);
      final first = await compressor.prepare(_photo(tmp, 'a.jpg', 4 * 1024 * _ko));
      final again = await compressor.prepare(first);
      expect(again.path, first.path);
      expect(engine.calls, hasLength(1));
    });

    test('résultat plus lourd que l’original : on garde l’original', () async {
      engine.outputBytes = 300 * _ko;
      final src = _photo(tmp, 'small.jpg', 150 * _ko);
      final out = await compressor.prepare(src);
      expect(out.path, src.path);
      expect(engine.discarded, hasLength(1), reason: 'la sortie inutile est supprimée');
    });

    test('échec du plugin : on envoie l’original', () async {
      engine.compressError = Exception('format inconnu');
      final src = _photo(tmp, 'x.jpg', 2 * 1024 * _ko);
      expect((await compressor.prepare(src)).path, src.path);

      engine
        ..compressError = null
        ..returnNull = true;
      expect((await compressor.prepare(src)).path, src.path);
    });

    test('dimensions illisibles : réduction par le côté court, sans sous-échantillonnage', () async {
      engine.dimsError = Exception('HEIC');
      final src = _photo(tmp, 'x.heic', 2 * 1024 * _ko);
      final out = await compressor.prepare(src);
      expect(isCompressedImagePath(out.path), isTrue);
      expect(engine.calls.single.minSide, kCompressedImageLongSide);
      expect(engine.calls.single.sampleSize, 1);
    });

    test('demandes simultanées : une seule compression à la fois', () async {
      engine.compressDelay = const Duration(milliseconds: 30);
      final results = await Future.wait([
        for (final n in ['a', 'b', 'c'])
          compressor.prepare(_photo(tmp, '$n.jpg', 2 * 1024 * _ko)),
      ]);
      expect(engine.maxConcurrent, 1);
      expect(results.map((f) => isCompressedImagePath(f.path)), everyElement(isTrue));
      expect(results.map((f) => f.path).toSet(), hasLength(3));
    });
  });

  group('Envoi d’une photo dans une conversation', () {
    late ChatTestHarness h;
    late Directory tmp;
    late Directory outbox;
    late _FakeEngine engine;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('image_send_');
      // Un chemin contenant `talky_outbox` : `sendMediaFile` le considère déjà
      // mis en attente et ne passe pas par path_provider.
      outbox = Directory(p.join(tmp.path, 'talky_outbox'))..createSync();
      engine = _FakeEngine(tmp)..dims = (width: 4000, height: 3000);
      LocaleController();
      h = ChatTestHarness();
      await h.setUp(
        imageCompressor: ImageUploadCompressor(engine: engine, outboxDirectory: outbox),
      );
    });

    tearDown(() async {
      await h.tearDown();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('la photo envoyée est la version WebP, et la ligne locale suit', () async {
      final src = _photo(outbox, 'outbox_src.jpg', 4 * 1024 * _ko);

      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 1,
        file: src,
      );
      await h.pumpEventQueue();

      final sent = h.api.uploadedPaths.single;
      expect(isCompressedImagePath(sent), isTrue);
      expect(p.extension(sent), '.webp');

      final row = (await h.messages()).single;
      expect(row.localMediaPath, sent, reason: 'la bulle de l’expéditeur lit la version compressée');
      expect(row.mediaSize, 200 * _ko, reason: 'le poids transmis est celui du fichier envoyé');
      expect(row.pendingUploadPath, isNull);
      expect(src.existsSync(), isFalse, reason: 'la copie d’origine de l’outbox est libérée');
    });

    test('un document ne passe jamais par le compresseur de photos', () async {
      final doc = File(p.join(outbox.path, 'outbox_scan.jpg'))
        ..writeAsBytesSync(List<int>.filled(4 * 1024 * _ko, 0));

      await h.repo.sendMediaFile(
        conversationID: ChatTestHarness.convId,
        type: 4,
        file: doc,
        mediaName: 'scan.jpg',
      );
      await h.pumpEventQueue();

      expect(engine.calls, isEmpty);
      expect(h.api.uploadedPaths.single, doc.path);
    });
  });
}
