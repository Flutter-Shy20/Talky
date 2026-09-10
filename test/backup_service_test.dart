import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/services/backup/backup_crypto.dart';
import 'package:talky_flutter/core/services/backup/backup_service.dart';
import 'package:talky_flutter/core/services/backup/backup_target.dart';
import 'package:talky_flutter/core/services/backup/local_folder_target.dart';

/// Fournisseur de clés en mémoire, à la place du serveur.
///
/// Il rejoue exactement ce que fera le serveur : une version courante pour
/// écrire, et **toutes** les versions passées pour relire — sans quoi une
/// rotation de secret rendrait illisibles toutes les sauvegardes existantes.
class _FakeKeys implements BackupKeyProvider {
  int currentKid;
  final Map<int, List<int>> secrets;

  _FakeKeys({this.currentKid = 1, Map<int, List<int>>? secrets})
      : secrets = secrets ?? {1: List<int>.filled(32, 1)};

  @override
  Future<BackupKey> current() async =>
      BackupKey(currentKid, secrets[currentKid]!);

  @override
  Future<BackupKey> byKid(int kid) async {
    final s = secrets[kid];
    if (s == null) throw StateError('kid inconnu : $kid');
    return BackupKey(kid, s);
  }
}

/// Destination qui échoue au dépôt, pour éprouver la vérification.
class _TruncatingTarget implements BackupTarget {
  final LocalFolderTarget inner;
  _TruncatingTarget(this.inner);

  @override
  String get label => inner.label;

  @override
  Future<List<RemoteArchive>> list() => inner.list();

  @override
  Future<RemoteArchive> write(File local, String name) async {
    // Dépôt partiel : réseau coupé en fin de téléversement, quota atteint.
    final half = await local.readAsBytes();
    final truncated = File('${local.path}.partiel')
      ..writeAsBytesSync(half.sublist(0, half.length ~/ 2));
    return inner.write(truncated, name);
  }

  @override
  Future<File> read(String id, File into) => inner.read(id, into);

  @override
  Future<void> delete(String id) => inner.delete(id);
}

void main() {
  late AppDatabase db;
  late Directory tmp;
  late LocalFolderTarget target;
  late _FakeKeys keys;

  const alanyaID = 241030112;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('alanya_backup_service');
    target = LocalFolderTarget(Directory(p.join(tmp.path, 'Alanya')));
    keys = _FakeKeys();
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> addMessage(String clientId) {
    return db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: clientId,
          conversationID: 1,
          senderID: 7,
          sendAt: DateTime.utc(2026, 3, 14),
          syncPending: const Value(false),
        ));
  }

  BackupService service({BackupKeyProvider? provider}) =>
      BackupService(db: db, keys: provider ?? keys);

  Future<BackupOutcome> run({
    BackupTarget? to,
    DateTime? now,
    BackupService? svc,
  }) =>
      (svc ?? service()).run(
        target: to ?? target,
        alanyaID: alanyaID,
        prefs: const {'app_locale': 'fr'},
        workDir: Directory(p.join(tmp.path, 'work')),
        now: now ?? DateTime.utc(2026, 8, 31, 21, 4),
      );

  test('une sauvegarde dépose l\'archive et son descriptif en clair', () async {
    await addMessage('a');
    final outcome = await run();

    expect(outcome.succeeded, isTrue);
    expect(outcome.meta!.messageCount, 1);
    expect(outcome.meta!.kid, 1);

    final names = (await target.list()).map((a) => a.name).toSet();
    expect(names, contains(BackupService.metaName(alanyaID)));
    expect(names.any((n) => n.endsWith('.enc')), isTrue);
  });

  test('le descriptif se lit sans clé ni déchiffrement', () async {
    await addMessage('a');
    await run();

    // C'est ce qui permet d'afficher « dernière sauvegarde : hier, 8,2 Mo »
    // dans les réglages sans rien demander au serveur.
    final meta = await service().readMeta(target, alanyaID);
    expect(meta, isNotNull);
    expect(meta!.messageCount, 1);
    expect(meta.kid, 1);
    expect(meta.bytes, greaterThan(0));
  });

  test('deux versions sont conservées, la troisième chasse la plus vieille',
      () async {
    await addMessage('a');
    for (final day in [29, 30, 31]) {
      await run(now: DateTime.utc(2026, 8, day, 21));
    }

    final archives = (await target.list())
        .where((a) => a.name.endsWith('.enc'))
        .map((a) => a.name)
        .toList()
      ..sort();

    expect(archives, hasLength(BackupService.keptVersions));
    // La plus ancienne est partie, les deux récentes restent.
    expect(archives.first, contains('20260830'));
    expect(archives.last, contains('20260831'));
  });

  test('un dépôt partiel est détecté et ne détruit pas l\'existante', () async {
    await addMessage('a');
    // Une première sauvegarde saine.
    await run(now: DateTime.utc(2026, 8, 30, 21));
    final before = (await target.list())
        .where((a) => a.name.endsWith('.enc'))
        .map((a) => a.name)
        .toSet();

    // La suivante arrive tronquée.
    final outcome = await run(
      to: _TruncatingTarget(target),
      now: DateTime.utc(2026, 8, 31, 21),
    );

    expect(outcome.succeeded, isFalse);
    expect(outcome.error, isA<BackupVerificationFailed>());

    // Sans cette vérification, la purge aurait pris le dépôt partiel pour un
    // succès et détruit la dernière sauvegarde valable.
    final after = (await target.list())
        .where((a) => a.name.endsWith('.enc'))
        .map((a) => a.name)
        .toSet();
    expect(after, containsAll(before));
  });

  test('la sauvegarde d\'un autre compte n\'est jamais purgée', () async {
    await addMessage('a');
    // Un même téléphone peut porter deux comptes : effacer l'archive de
    // l'autre serait un dégât irréparable.
    final other = File(p.join(tmp.path, 'autre.enc'))
      ..writeAsStringSync('archive du compte voisin');
    await target.write(other, 'alanya-backup-999-20260101T000000Z.enc');

    for (final day in [29, 30, 31]) {
      await run(now: DateTime.utc(2026, 8, day, 21));
    }

    final names = (await target.list()).map((a) => a.name).toSet();
    expect(names, contains('alanya-backup-999-20260101T000000Z.enc'));
  });

  group('restauration', () {
    test('rend la base et les préférences d\'origine', () async {
      await addMessage('a');
      await addMessage('b');
      final outcome = await run();

      final content = await service().restore(
        target: target,
        archive: outcome.archive!,
        workDir: Directory(p.join(tmp.path, 'restore')),
      );

      final file = File(p.join(tmp.path, 'restaure.sqlite'))
        ..writeAsBytesSync(content.database);
      final restored = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(restored.close);

      final rows = await restored.select(restored.localMessages).get();
      expect(rows.map((r) => r.clientId), containsAll(['a', 'b']));
      expect(content.prefs['app_locale'], 'fr');
    });

    test('une archive ancienne reste lisible après rotation du secret',
        () async {
      await addMessage('a');
      final outcome = await run();

      // Le serveur tourne : nouvelle version courante, ancienne toujours
      // servie. C'est tout l'intérêt du `kid` — sans lui, cette archive
      // deviendrait illisible d'un coup.
      keys
        ..secrets[2] = List<int>.filled(32, 2)
        ..currentKid = 2;

      final content = await service().restore(
        target: target,
        archive: outcome.archive!,
        workDir: Directory(p.join(tmp.path, 'restore')),
      );
      expect(content.database, isNotEmpty);
    });

    test('une version de clé que le serveur ne connaît plus est signalée',
        () async {
      await addMessage('a');
      final outcome = await run();

      // Secret perdu côté serveur : le refus doit être net, pas un plantage.
      final amnesiac = _FakeKeys(currentKid: 5, secrets: {
        5: List<int>.filled(32, 5),
      });

      expect(
        () => service(provider: amnesiac).restore(
          target: target,
          archive: outcome.archive!,
          workDir: Directory(p.join(tmp.path, 'restore')),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('une archive d\'un autre compte reste indéchiffrable', () async {
      await addMessage('a');
      final outcome = await run();

      // Même `kid`, mais secret différent : c'est le chiffrement qui porte le
      // rattachement au compte, pas le compte Google ni le nom du fichier.
      final foreign = _FakeKeys(secrets: {1: List<int>.filled(32, 42)});

      expect(
        () => service(provider: foreign).restore(
          target: target,
          archive: outcome.archive!,
          workDir: Directory(p.join(tmp.path, 'restore')),
        ),
        throwsA(isA<BackupAuthenticationFailed>()),
      );
    });
  });
}
