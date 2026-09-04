import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/services/backup/backup_crypto.dart';
import 'package:talky_flutter/core/services/backup/backup_service.dart';
import 'package:talky_flutter/core/services/backup/backup_snapshot.dart';
import 'package:talky_flutter/core/services/backup/backup_target.dart';
import 'package:talky_flutter/core/services/backup/downloads_mirror_target.dart';
import 'package:talky_flutter/core/services/backup/local_folder_target.dart';
import 'package:talky_flutter/core/services/backup/restore_service.dart';
import 'package:talky_flutter/core/services/backup/restore_state.dart';

/// Les répétitions de restauration réclamées par la conception.
///
/// Une restauration ne se vérifie pas en la relisant. Ces scénarios doivent
/// tous produire un refus **lisible** ou une réparation, jamais un plantage ni
/// une base à moitié écrite. Ils sont jouables ici parce que le service reçoit
/// sa destination et sa base en paramètres, au lieu d'aller chercher Drive
/// lui-même.
class _Keys implements BackupKeyProvider {
  final Map<int, List<int>> secrets;
  final int currentKid;
  _Keys({this.currentKid = 1, Map<int, List<int>>? secrets})
      : secrets = secrets ?? {1: List<int>.filled(32, 1)};

  @override
  Future<BackupKey> current() async =>
      BackupKey(currentKid, secrets[currentKid]!);

  @override
  Future<BackupKey> byKid(int kid) async {
    final s = secrets[kid];
    if (s == null) throw const BackupKeyUnknown(0);
    return BackupKey(kid, s);
  }
}

/// Le serveur ne connaît plus cette version de clé.
class BackupKeyUnknown implements Exception {
  final int kid;
  const BackupKeyUnknown(this.kid);
  @override
  String toString() => 'BackupKeyUnknown($kid)';
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late LocalFolderTarget target;
  late _Keys keys;

  const alanyaID = 241030112;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('alanya_restore_drills');
    target = LocalFolderTarget(Directory(p.join(tmp.path, 'Alanya')));
    keys = _Keys();
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<RemoteArchive> makeBackup() async {
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: 'a',
          conversationID: 1,
          senderID: 7,
          sendAt: DateTime.utc(2026, 3, 14),
          syncPending: const Value(false),
        ));
    final outcome = await BackupService(db: db, keys: keys).run(
      target: target,
      alanyaID: alanyaID,
      prefs: const {'app_locale': 'fr'},
      workDir: Directory(p.join(tmp.path, 'work')),
      now: DateTime.utc(2026, 8, 31, 21),
    );
    expect(outcome.succeeded, isTrue);
    return outcome.archive!;
  }

  Future<BackupSnapshotContent> restore({
    BackupKeyProvider? provider,
    RemoteArchive? archive,
  }) async {
    return BackupService(db: db, keys: provider ?? keys).restore(
      target: target,
      archive: archive ?? (await target.list()).firstWhere(
            (a) => a.name.endsWith('.enc'),
          ),
      workDir: Directory(p.join(tmp.path, 'restore')),
    );
  }

  group('destinations', () {
    test('le miroir ne fait jamais échouer une sauvegarde', () async {
      // Le canal de plateforme n'existe pas dans un test : `_mirror` lève et
      // avale. La sauvegarde doit aboutir quand même — le magasin de travail
      // a l'archive, et c'est lui qui compte au quotidien.
      final mirrored = DownloadsMirrorTarget(target);
      final outcome = await BackupService(db: db, keys: keys).run(
        target: mirrored,
        alanyaID: alanyaID,
        prefs: const {},
        workDir: Directory(p.join(tmp.path, 'work')),
        now: DateTime.utc(2026, 8, 31, 21),
      );
      expect(outcome.succeeded, isTrue);
      expect(await mirrored.list(), isNotEmpty);
    });

    test('une archive désignée à la main se lit comme une autre', () async {
      final archive = await makeBackup();

      // Après réinstallation, l'application ne peut plus lister ses fichiers
      // dans Download : l'inscrit en désigne un, et tout le reste du code —
      // déchiffrement, contrôle du kid, dépôt en deux temps — ne voit pas la
      // différence.
      final picked = PickedArchiveTarget(File(archive.id));
      final listed = await picked.list();
      expect(listed, hasLength(1));

      final content = await BackupService(db: db, keys: keys).restore(
        target: picked,
        archive: listed.first,
        workDir: Directory(p.join(tmp.path, 'restore_pick')),
      );
      expect(looksLikeSqlite(content.database), isTrue);
    });

    test('une destination en lecture seule refuse d\'être écrite', () async {
      final picked = PickedArchiveTarget(File(p.join(tmp.path, 'x.enc')));
      expect(
        () => picked.write(File(p.join(tmp.path, 'y')), 'y.enc'),
        throwsUnsupportedError,
      );
      // Et supprimer n'a aucun effet : le fichier appartient à l'inscrit.
      await picked.delete('x');
    });
  });

  // ── Répétition 1 ───────────────────────────────────────────────────

  test('archive tronquée : refus net, la base n\'est pas touchée', () async {
    final archive = await makeBackup();
    final file = File(archive.id);
    final bytes = await file.readAsBytes();
    await file.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));

    await expectLater(
      restore(),
      throwsA(anyOf(
        isA<BackupAuthenticationFailed>(),
        isA<BackupFormatInvalid>(),
      )),
    );
  });

  // ── Répétition 2 ───────────────────────────────────────────────────

  test('schéma plus récent que l\'application : refus explicite', () async {
    // Ouvrir une base au schéma futur, c'est la corrompre : les migrations
    // Drift savent avancer, jamais reculer.
    final snapshot = await BackupSnapshotBuilder(db).build(
      workDir: Directory(p.join(tmp.path, 'w2')),
      prefs: const {},
    );
    expect(
      () => const BackupSnapshotReader(26)
          .read(snapshot.payload, declaredSchemaVersion: 999),
      throwsA(isA<BackupSchemaTooRecent>()),
    );
  });

  // ── Répétition 3 ───────────────────────────────────────────────────

  test('version de clé inconnue : signalée avant tout déchiffrement',
      () async {
    final archive = await makeBackup();

    // L'en-tête se lit sans la clé : c'est ce qui permet d'annoncer le
    // problème AVANT de télécharger huit mégaoctets pour rien.
    final header = BackupHeader.decode(await File(archive.id).readAsBytes());
    expect(header.kid, 1);

    final amnesiac = _Keys(currentKid: 9, secrets: {9: List.filled(32, 9)});
    await expectLater(
      restore(provider: amnesiac),
      throwsA(isA<BackupKeyUnknown>()),
    );
  });

  // ── Répétition 4 ───────────────────────────────────────────────────

  test('archive d\'un autre compte : indéchiffrable', () async {
    await makeBackup();
    final foreign = _Keys(secrets: {1: List<int>.filled(32, 42)});
    await expectLater(
      restore(provider: foreign),
      throwsA(isA<BackupAuthenticationFailed>()),
    );
  });

  // ── Répétition 5 ───────────────────────────────────────────────────

  test('destination vide : aucune sauvegarde, aucun plantage', () async {
    final archives = await target.list();
    expect(archives, isEmpty);
    // L'appelant distingue « ce compte Google n'en contient pas » d'une
    // erreur réseau : ici, la liste vide est une réponse, pas un échec.
  });

  // ── Répétition 6 ───────────────────────────────────────────────────

  group('coupure en pleine écriture', () {
    late File dbFile;
    late RestoreStage stage;

    setUp(() {
      dbFile = File(p.join(tmp.path, 'talky_chat.sqlite'))
        ..writeAsStringSync('ancienne base');
      stage = RestoreStage.unknown;
    });

    RestoreService service({bool failOnClose = false}) => RestoreService(
          closeDatabase: () async {
            if (failOnClose) throw const SocketException('coupure');
          },
          applyPrefs: (_) async {},
        );

    test('l\'état reste intermédiaire, ce que le démarrage saura voir',
        () async {
      await expectLater(
        service(failOnClose: true).apply(
          databaseFile: dbFile,
          content: BackupSnapshotContent(
            database: Uint8List.fromList(List.filled(32, 1)),
            prefs: const {},
          ),
          markInProgress: () async => stage = RestoreStage.inProgress,
          markDone: () async => stage = RestoreStage.done,
        ),
        throwsA(isA<RestoreFailed>()),
      );

      // C'est la marque qui compte : au redémarrage, `inProgress` impose de
      // vider et de reproposer. Une demi-restauration est pire que pas de
      // restauration — les trous deviendraient permanents et silencieux.
      expect(stage, RestoreStage.inProgress);
      // Et le fichier de travail ne traîne pas.
      expect(File('${dbFile.path}.incoming').existsSync(), isFalse);
    });

    test('les fichiers annexes de SQLite sont supprimés', () async {
      // Faute classique : remplacer la base en laissant le journal d'écriture
      // anticipée de l'ANCIENNE. SQLite l'appliquerait à la nouvelle et la
      // corromprait — silencieusement, l'erreur n'apparaissant que bien plus
      // tard.
      File('${dbFile.path}-wal').writeAsStringSync('ancien journal');
      File('${dbFile.path}-shm').writeAsStringSync('ancienne mémoire');

      await service().apply(
        databaseFile: dbFile,
        content: BackupSnapshotContent(
          database: Uint8List.fromList(List.filled(64, 7)),
          prefs: const {},
        ),
        markInProgress: () async => stage = RestoreStage.inProgress,
        markDone: () async => stage = RestoreStage.done,
      );

      expect(File('${dbFile.path}-wal').existsSync(), isFalse);
      expect(File('${dbFile.path}-shm').existsSync(), isFalse);
      expect(stage, RestoreStage.done);
      expect(dbFile.readAsBytesSync().first, 7);
    });

    test('vider après une coupure efface aussi les annexes', () async {
      File('${dbFile.path}-wal').writeAsStringSync('journal');
      await service().wipe(dbFile);

      expect(dbFile.existsSync(), isFalse);
      expect(File('${dbFile.path}-wal').existsSync(), isFalse);
    });

    test('une sauvegarde vide est refusée avant toute destruction', () async {
      await expectLater(
        service().apply(
          databaseFile: dbFile,
          content: BackupSnapshotContent(
            database: Uint8List(0),
            prefs: const {},
          ),
          markInProgress: () async => stage = RestoreStage.inProgress,
          markDone: () async => stage = RestoreStage.done,
        ),
        throwsA(isA<RestoreFailed>()),
      );

      // Rien n'a commencé, donc rien n'est à réparer : l'ancienne base est
      // intacte et l'état n'a même pas bougé.
      expect(stage, RestoreStage.unknown);
      expect(dbFile.readAsStringSync(), 'ancienne base');
    });
  });

  group('mise en place en deux temps', () {
    late File dbFile;
    late RestoreStage stage;

    RestoreService service() => RestoreService(
          closeDatabase: () async {},
          applyPrefs: (_) async {},
        );

    setUp(() {
      dbFile = File(p.join(tmp.path, 'talky_chat.sqlite'))
        ..writeAsStringSync('ancienne base');
      stage = RestoreStage.unknown;
    });

    Future<BackupSnapshotContent> realContent() async {
      await makeBackup();
      return restore();
    }

    test('déposer ne touche pas encore à la base en place', () async {
      await service().stagePending(
        databaseFile: dbFile,
        content: await realContent(),
        markPendingSwap: () async => stage = RestoreStage.pendingSwap,
      );

      // Toute la difficulté est là : l'application tourne encore, sa base est
      // peut-être déjà ouverte. On ne touche à rien.
      expect(dbFile.readAsStringSync(), 'ancienne base');
      expect(File('${dbFile.path}.incoming').existsSync(), isTrue);
      expect(stage, RestoreStage.pendingSwap);
    });

    test('l\'échange au démarrage met la base en place et purge les annexes',
        () async {
      File('${dbFile.path}-wal').writeAsStringSync('ancien journal');
      await service().stagePending(
        databaseFile: dbFile,
        content: await realContent(),
        markPendingSwap: () async => stage = RestoreStage.pendingSwap,
      );

      expect(await RestoreService.applyPendingSwap(dbFile), isTrue);
      expect(looksLikeSqlite(dbFile.readAsBytesSync()), isTrue);
      expect(File('${dbFile.path}-wal').existsSync(), isFalse);
      expect(File('${dbFile.path}.incoming').existsSync(), isFalse);

      // Et la base mise en place s'ouvre réellement.
      final restored = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(restored.close);
      final rows = await restored.select(restored.localMessages).get();
      expect(rows.single.clientId, 'a');
    });

    test('un dépôt disparu ne condamne pas la restauration', () async {
      // L'état dit « en attente » mais le fichier n'est plus là — écarté parce
      // qu'illisible, ou effacé. Laisser cet état condamnerait la restauration
      // en silence : elle ne serait plus jamais reproposée, et l'inscrit
      // n'aurait aucun moyen de le savoir.
      expect(await RestoreService.applyPendingSwap(dbFile), isFalse);
      // C'est à l'appelant de remettre l'état à zéro ; ici on vérifie surtout
      // que rien n'a été détruit au passage.
      expect(dbFile.readAsStringSync(), 'ancienne base');
    });

    test('sans dépôt en attente, le démarrage ne fait rien', () async {
      expect(await RestoreService.applyPendingSwap(dbFile), isFalse);
      expect(dbFile.readAsStringSync(), 'ancienne base');
    });

    test('un dépôt corrompu est écarté sans toucher à la base', () async {
      File('${dbFile.path}.incoming').writeAsStringSync('pas une base SQLite');

      expect(await RestoreService.applyPendingSwap(dbFile), isFalse);
      // Installer un contenu qui n'ouvrira jamais rendrait l'application
      // inutilisable au lancement suivant, sans recours.
      expect(dbFile.readAsStringSync(), 'ancienne base');
      expect(File('${dbFile.path}.incoming').existsSync(), isFalse);
    });

    test('un contenu qui n\'est pas une base est refusé avant d\'écrire',
        () async {
      await expectLater(
        service().stagePending(
          databaseFile: dbFile,
          content: BackupSnapshotContent(
            database: Uint8List.fromList(List.filled(64, 9)),
            prefs: const {},
          ),
          markPendingSwap: () async => stage = RestoreStage.pendingSwap,
        ),
        throwsA(isA<RestoreFailed>()),
      );
      expect(stage, RestoreStage.unknown);
      expect(File('${dbFile.path}.incoming').existsSync(), isFalse);
    });
  });

  test('une restauration réussie rend la base d\'origine', () async {
    final archive = await makeBackup();
    final content = await restore(archive: archive);

    expect(looksLikeSqlite(content.database), isTrue);
    expect(content.prefs['app_locale'], 'fr');

    final file = File(p.join(tmp.path, 'verif.sqlite'))
      ..writeAsBytesSync(content.database);
    final restored = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(restored.close);
    final rows = await restored.select(restored.localMessages).get();
    expect(rows.single.clientId, 'a');
  });

  group('rebond sur la version précédente', () {
    // `keptVersions` vaut deux, et la seconde existe pour ce jour-là. Le code
    // prenait pourtant `archives.first` et abandonnait sur échec : on gardait
    // un filet dans lequel personne ne tombait jamais.

    /// Écrase les premiers octets : l'en-tête ne sera plus reconnu.
    Future<void> abimer(RemoteArchive archive) async {
      final f = File(archive.id);
      final octets = await f.readAsBytes();
      octets.setRange(0, 4, const [0, 0, 0, 0]);
      await f.writeAsBytes(octets, flush: true);
    }

    Future<BackupSnapshotContent> restaurerLaPlusRecenteLisible() async {
      final candidates = BackupService.candidatesFor(
        alanyaID,
        await target.list(),
      );
      return BackupService(db: db, keys: keys).restoreFirstReadable(
        target: target,
        candidates: candidates,
        workDir: Directory(p.join(tmp.path, 'restore')),
      );
    }

    test('la plus récente est corrompue : la précédente sauve la mise',
        () async {
      final ancienne = await makeBackup();
      // Une seconde plus tard, sinon les deux portent le même nom : les
      // horodatages sont à la seconde près.
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            clientId: 'b',
            conversationID: 1,
            senderID: 7,
            sendAt: DateTime.utc(2026, 3, 15),
            syncPending: const Value(false),
          ));
      final recente = await BackupService(db: db, keys: keys).run(
        target: target,
        alanyaID: alanyaID,
        // Une valeur DIFFÉRENTE de l'ancienne : sans ça, l'assertion finale
        // passerait quelle que soit l'archive relue, et le test ne prouverait
        // rien du rebond.
        prefs: const {'app_locale': 'en'},
        workDir: Directory(p.join(tmp.path, 'work2')),
        now: DateTime.utc(2026, 8, 31, 22),
      );
      expect(recente.succeeded, isTrue);
      expect(recente.archive!.name.compareTo(ancienne.name), greaterThan(0),
          reason: 'la plus récente doit trier après, sur le nom');

      await abimer(recente.archive!);

      // Avant cette correction : exception, et l'ancienne intacte juste à côté.
      final content = await restaurerLaPlusRecenteLisible();
      expect(content.prefs['app_locale'], 'fr',
          reason: "c'est bien l'ANCIENNE qui a été relue, la récente étant"
              ' illisible');
    });

    test('les deux sont illisibles : échec net, pas de plantage', () async {
      final a = await makeBackup();
      final b = await BackupService(db: db, keys: keys).run(
        target: target,
        alanyaID: alanyaID,
        prefs: const {},
        workDir: Directory(p.join(tmp.path, 'work2')),
        now: DateTime.utc(2026, 8, 31, 22),
      );
      await abimer(a);
      await abimer(b.archive!);

      await expectLater(
        restaurerLaPlusRecenteLisible(),
        throwsA(isA<BackupFormatInvalid>()),
      );
    });

    test('destination vide : erreur explicite, pas une exception obscure',
        () async {
      await expectLater(
        restaurerLaPlusRecenteLisible(),
        throwsA(isA<BackupFormatInvalid>()),
      );
    });
  });

  group('choix des candidates', () {
    RemoteArchive faux(String name) => RemoteArchive(
          id: name,
          name: name,
          bytes: 1,
          // Volontairement à l'envers de l'ordre des noms : c'est tout l'objet
          // du test. La purge trie sur le nom parce que certaines destinations
          // réécrivent l'heure de modification au dépôt ; la restauration
          // s'appuyait pourtant dessus.
          modifiedAt: DateTime.utc(2020),
        );

    test('trie sur le nom, du plus récent au plus ancien', () {
      final out = BackupService.candidatesFor(15, [
        faux('alanya-backup-15-20260101T000000Z.enc'),
        faux('alanya-backup-15-20260901T000000Z.enc'),
        faux('alanya-backup-15-20260501T000000Z.enc'),
      ]);
      expect(out.map((a) => a.name).toList(), [
        'alanya-backup-15-20260901T000000Z.enc',
        'alanya-backup-15-20260501T000000Z.enc',
        'alanya-backup-15-20260101T000000Z.enc',
      ]);
    });

    test("écarte les archives d'un autre compte", () {
      // Deux comptes Alanya sur le même téléphone. Restaurer celle de l'autre
      // échouerait au déchiffrement — la clé est dérivée du compte, donc aucune
      // fuite — mais l'inscrit n'y comprendrait rien.
      final out = BackupService.candidatesFor(15, [
        faux('alanya-backup-99-20260901T000000Z.enc'),
        faux('alanya-backup-15-20260101T000000Z.enc'),
      ]);
      expect(out.map((a) => a.name).toList(),
          ['alanya-backup-15-20260101T000000Z.enc']);
    });

    test('écarte le descriptif en clair', () {
      final out = BackupService.candidatesFor(15, [
        faux('alanya-backup-15-latest.json'),
        faux('alanya-backup-15-20260101T000000Z.enc'),
      ]);
      expect(out, hasLength(1));
    });

    test('identifiant inconnu : rend tout plutôt que rien', () {
      final out = BackupService.candidatesFor(0, [
        faux('alanya-backup-99-20260901T000000Z.enc'),
        faux('alanya-backup-15-20260101T000000Z.enc'),
      ]);
      expect(out, hasLength(2));
    });
  });
}
