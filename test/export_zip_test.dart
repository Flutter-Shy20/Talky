import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/db/chat_dao.dart';
import 'package:talky_flutter/core/services/export/export_manifest.dart';
import 'package:talky_flutter/core/services/export/export_scan.dart';
import 'package:talky_flutter/core/services/export/export_zip_builder.dart';
import 'package:talky_flutter/core/services/media_expiry_policy.dart';

/// Chaîne d'export : inventaire d'une période, puis assemblage de l'archive.
///
/// Tout se joue sur un vrai disque et une vraie base en mémoire — c'est le
/// seul moyen de vérifier les deux promesses qui comptent : l'archive ne
/// contient que des fichiers réellement présents, et elle dit ce qui manque.
void main() {
  late AppDatabase db;
  late ChatDao dao;
  late Directory tmp;
  late Directory media;

  const myId = 42;
  final march = DateTime.utc(2026, 3, 14, 9);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(db);
    tmp = await Directory.systemTemp.createTemp('alanya_export_test');
    media = Directory(p.join(tmp.path, 'media_cache'))..createSync();
    MediaExpiryPolicy.resetForTests();
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Écrit un vrai fichier et le message qui le porte.
  Future<File> addMedia({
    required String clientId,
    required int type,
    required String content,
    String? mediaName,
    String? mediaUrl,
    int senderID = 7,
    DateTime? sendAt,
    bool onDisk = true,
    int? mediaSize,
    int? msgID,
  }) async {
    final file = File(p.join(media.path, '$clientId.bin'));
    if (onDisk) await file.writeAsString(content);
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: clientId,
          // Un média téléchargé est toujours confirmé par le serveur, donc
          // porte un msgID non nul. Le verdict du serveur s'y adosse.
          msgID: Value(msgID ?? clientId.hashCode.abs() % 100000 + 1),
          conversationID: 1,
          senderID: senderID,
          sendAt: sendAt ?? march,
          type: Value(type),
          mediaName: Value(mediaName),
          mediaUrl: Value(mediaUrl ?? '/uploads/media/2026-03-14/$clientId.bin'),
          mediaSize: Value(mediaSize),
          localMediaPath: onDisk ? Value(file.path) : const Value.absent(),
          syncPending: const Value(false),
        ));
    return file;
  }

  Future<ExportScanResult> scan_() =>
      ExportScanner(dao).scan(myId, now: DateTime.utc(2026, 3, 20));

  test('le scan mesure au disque et rattrape les tailles nulles', () async {
    await addMedia(clientId: 'photo', type: 1, content: 'x' * 500);

    final result = await scan_();

    expect(result.present.single.bytes, 500);
    expect(result.bytes, 500);
    expect(result.backfilled, 1);

    // Le rattrapage est écrit : la grille « Mes médias » cessera elle aussi
    // de compter ce média pour zéro octet.
    final row = await (db.select(db.localMessages)
          ..where((m) => m.clientId.equals('photo')))
        .getSingle();
    expect(row.mediaSize, 500);
  });

  test('une taille déjà connue n\'est pas réécrite', () async {
    await addMedia(
      clientId: 'photo',
      type: 1,
      content: 'x' * 500,
      mediaSize: 500,
    );
    expect((await scan_()).backfilled, 0);
  });

  test('un média jamais téléchargé est déclaré récupérable', () async {
    // Le serveur l'a encore : la rétention n'est pas connue du client, donc
    // rien ne permet de le déclarer perdu.
    await addMedia(
      clientId: 'jamais',
      type: 1,
      content: '',
      onDisk: false,
    );

    final result = await scan_();
    expect(result.present, isEmpty);
    expect(result.missing.single.reason, MissingReason.neverDownloaded);
    expect(result.recoverable, hasLength(1));
    expect(result.lost, isEmpty);
  });

  test('un média dont la partition a expiré est déclaré perdu', () async {
    // Rétention apprise du serveur : 30 jours. La partition du 1er janvier
    // est tombée bien avant le 20 mars.
    MediaExpiryPolicy.resetForTests(retentionDays: 30);
    await addMedia(
      clientId: 'expire',
      type: 1,
      content: '',
      onDisk: false,
      mediaUrl: '/uploads/media/2026-01-01/expire.bin',
      sendAt: DateTime.utc(2026, 1, 1, 10),
    );

    final result = await scan_();
    expect(result.missing.single.reason, MissingReason.expired);
    // Proposer de le récupérer serait promettre un téléchargement voué au 410.
    expect(result.recoverable, isEmpty);
    expect(result.lost, hasLength(1));
  });

  test('un fichier effacé hors de l\'app est déclaré manquant et désynchronisé',
      () async {
    final file = await addMedia(clientId: 'efface', type: 1, content: 'abc');
    await file.delete();

    final result = await scan_();

    expect(result.present, isEmpty);
    expect(result.missing.single.reason, MissingReason.fileGone);
    // La base ne doit plus prétendre détenir ce fichier, sinon la grille
    // continuerait d'afficher un média qui n'existe pas.
    final row = await (db.select(db.localMessages)
          ..where((m) => m.clientId.equals('efface')))
        .getSingle();
    expect(row.localMediaPath, isNull);
  });

  test('chaque famille de média va dans son dossier', () async {
    await addMedia(clientId: 'img', type: 1, content: 'a');
    await addMedia(clientId: 'vid', type: 2, content: 'b');
    await addMedia(clientId: 'voc', type: 3, content: 'c');
    await addMedia(
      clientId: 'mus',
      type: 3,
      content: 'd',
      mediaName: 'Ndem.mp3',
    );
    await addMedia(clientId: 'doc', type: 4, content: 'e');

    final folders = (await scan_())
        .present
        .map((m) => p.dirname(m.archivePath))
        .toSet();

    expect(folders, {
      'Alanya Images',
      'Alanya Videos',
      // Un vocal enregistré et un morceau importé sont tous deux de type 3 :
      // les mélanger rendrait la musique introuvable au milieu des mémos.
      'Alanya Vocaux',
      'Alanya Musique',
      'Alanya Documents',
    });
  });

  test('deux médias du même jour ne se recouvrent pas', () async {
    await addMedia(clientId: 'a', type: 1, content: 'aaa');
    await addMedia(clientId: 'b', type: 1, content: 'bbb');

    final names = (await scan_()).present.map((m) => m.archivePath).toList();
    expect(names.toSet(), hasLength(2));
    expect(names.first, endsWith('_0001.bin'));
  });

  group('verdict du serveur', () {
    test('ce que le serveur ne liste pas devient perdu', () async {
      // Le client, sans rétention apprise, croit TOUT récupérable. C'est
      // exactement le cas qui faisait promettre 200 téléchargements dont 150
      // échouaient.
      await addMedia(
          clientId: 'a', type: 1, content: '', onDisk: false, msgID: 501);
      await addMedia(
          clientId: 'b', type: 1, content: '', onDisk: false, msgID: 502);

      final scan = await scan_();
      expect(scan.recoverable, hasLength(2));
      expect(scan.verifiedByServer, isFalse);

      // Le serveur n'en détient qu'un.
      final refined = scan.withServerVerdict(
        available: {501},
        sizes: {501: 4096},
      );

      expect(refined.recoverable, hasLength(1));
      expect(refined.lost, hasLength(1));
      // Et le poids annoncé n'est plus une moyenne, c'est le vrai.
      expect(refined.recoverableBytes, 4096);
      expect(refined.verifiedByServer, isTrue);
    });

    test('un serveur muet laisse le verdict du client intact', () async {
      await addMedia(clientId: 'a', type: 1, content: '', onDisk: false);
      final scan = await scan_();
      // L'appelant rend le scan tel quel : l'écran dira « jusqu'à », pas « X ».
      expect(scan.verifiedByServer, isFalse);
      expect(scan.recoverableBytes, isNull);
    });
  });

  group('assemblage', () {
    test('l\'archive contient les fichiers, le manifeste et l\'index',
        () async {
      await addMedia(
        clientId: 'photo',
        type: 1,
        content: 'contenu-photo',
        mediaName: 'IMG_2231.jpg',
      );
      await addMedia(clientId: 'absent', type: 1, content: '', onDisk: false);

      final destination = File(p.join(tmp.path, 'export.zip'));
      final result = await scan_();
      final manifest = await ExportZipBuilder().build(
        destination: destination,
        scan: result,
        alanyaID: myId,
        periodFrom: DateTime.utc(2026, 3, 1),
        periodTo: DateTime.utc(2026, 3, 31),
        indexHtmlBuilder: (m) => '<h1>${m.items.length}</h1>',
      );

      expect(manifest.items, hasLength(1));
      expect(manifest.missing, hasLength(1));
      expect(manifest.items.single.originalName, 'IMG_2231.jpg');
      expect(manifest.items.single.sha256, isNotEmpty);

      final archive = ZipDecoder().decodeBytes(destination.readAsBytesSync());
      final names = archive.files.map((f) => f.name).toSet();
      expect(names, contains('manifest.json'));
      expect(names, contains('index.html'));
      expect(
        names.any((n) => n.startsWith('Alanya Images/')),
        isTrue,
        reason: 'le média doit être rangé dans son dossier',
      );

      // Le manifeste relu depuis l'archive doit être exploitable : c'est lui
      // que la restauration lira.
      final raw = archive.files.firstWhere((f) => f.name == 'manifest.json');
      final reread = ExportManifest.decode(utf8.decode(raw.readBytes()!));
      expect(reread.isSupported, isTrue);
      expect(reread.items.single.clientId, 'photo');
    });

    test('les médias sont stockés, pas compressés', () async {
      // Un contenu très répétitif : compressé il fondrait, stocké il garde sa
      // taille. C'est ce qui distingue les deux modes sans ambiguïté.
      await addMedia(clientId: 'photo', type: 1, content: 'A' * 5000);

      final destination = File(p.join(tmp.path, 'export.zip'));
      await ExportZipBuilder().build(
        destination: destination,
        scan: await scan_(),
        alanyaID: myId,
      );

      final archive = ZipDecoder().decodeBytes(destination.readAsBytesSync());
      final media =
          archive.files.firstWhere((f) => f.name.startsWith('Alanya Images/'));
      expect(media.size, 5000);
      expect(
        media.compression,
        CompressionType.none,
        reason: 'JPEG et MP4 sont déjà compressés : deflate coûterait du '
            'processeur pour un gain nul, parfois négatif',
      );

      // Le manifeste, lui, est du texte : la compression y est payante.
      final manifest =
          archive.files.firstWhere((f) => f.name == 'manifest.json');
      expect(manifest.compression, CompressionType.deflate);
    });

    test('une annulation ne laisse pas d\'archive à moitié écrite', () async {
      await addMedia(clientId: 'photo', type: 1, content: 'x' * 100);
      final destination = File(p.join(tmp.path, 'export.zip'));

      await expectLater(
        ExportZipBuilder().build(
          destination: destination,
          scan: await scan_(),
          alanyaID: myId,
          isCancelled: () => true,
        ),
        throwsA(isA<ExportCancelled>()),
      );

      // Une archive tronquée pèse le poids d'une vraie sans rien valoir : elle
      // occuperait la place qu'on cherchait justement à libérer.
      expect(destination.existsSync(), isFalse);
    });

    test('le manque de place est annoncé avant le premier octet écrit',
        () async {
      await addMedia(clientId: 'photo', type: 1, content: 'x' * 100);
      final destination = File(p.join(tmp.path, 'export.zip'));

      await expectLater(
        ExportZipBuilder().build(
          destination: destination,
          scan: await scan_(),
          alanyaID: myId,
          availableBytes: 1024,
        ),
        throwsA(isA<ExportInsufficientSpace>()),
      );
      expect(destination.existsSync(), isFalse);
    });

    test('la progression est rapportée fichier par fichier', () async {
      await addMedia(clientId: 'a', type: 1, content: 'aa');
      await addMedia(clientId: 'b', type: 1, content: 'bbbb');

      final seen = <int>[];
      await ExportZipBuilder().build(
        destination: File(p.join(tmp.path, 'export.zip')),
        scan: await scan_(),
        alanyaID: myId,
        onProgress: (pr) => seen.add(pr.bytesWritten),
      );
      expect(seen, [2, 6]);
    });
  });
}
