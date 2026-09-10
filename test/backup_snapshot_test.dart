import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/services/backup/backup_crypto.dart';
import 'package:talky_flutter/core/services/backup/backup_snapshot.dart';

/// Instantané de sauvegarde : `VACUUM INTO`, préférences filtrées, relecture.
///
/// Le scénario complet — fabriquer, sceller, rouvrir, relire — est joué ici de
/// bout en bout sur une vraie base. C'est le seul moyen d'éprouver la promesse
/// qui compte : ce qui entre dans une sauvegarde en ressort intact.
void main() {
  late AppDatabase db;
  late Directory tmp;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('alanya_snapshot_test');
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
          content: Value('message $clientId'),
          syncPending: const Value(false),
        ));
  }

  Future<BackupSnapshot> build({Map<String, Object>? prefs}) =>
      BackupSnapshotBuilder(db).build(
        workDir: tmp,
        prefs: prefs ?? const {'app_locale': 'fr', 'theme_mode': 'dark'},
        now: DateTime.utc(2026, 8, 31, 21, 4),
      );

  test('l\'instantané contient la base et les préférences', () async {
    await addMessage('a');
    await addMessage('b');

    final snapshot = await build();
    final archive = ZipDecoder().decodeBytes(snapshot.payload);
    final names = archive.files.map((f) => f.name).toSet();

    expect(names, contains(kSnapshotDbEntry));
    expect(names, contains(kSnapshotPrefsEntry));
    expect(snapshot.meta.messageCount, 2);
    expect(snapshot.meta.schemaVersion, db.schemaVersion);
  });

  test('la copie temporaire de la base ne survit pas à l\'instantané',
      () async {
    await addMessage('a');
    await build();

    // Une base entière laissée en clair dans un dossier de travail serait à
    // la fois une fuite et un gaspillage d'espace.
    final leftovers = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sqlite'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('VACUUM INTO produit une base réellement ouvrable', () async {
    await addMessage('a');
    await addMessage('b');

    final snapshot = await build();
    final content = const BackupSnapshotReader(99).read(
      snapshot.payload,
      declaredSchemaVersion: snapshot.meta.schemaVersion,
    );

    // On réouvre la base extraite : c'est la seule preuve que la copie est
    // cohérente. Recopier le fichier à chaud aurait produit une base que rien
    // ne signale comme corrompue avant ce moment précis.
    final restoredFile = File('${tmp.path}/restaure.sqlite')
      ..writeAsBytesSync(content.database);
    final restored = AppDatabase.forTesting(NativeDatabase(restoredFile));
    addTearDown(restored.close);

    final rows = await restored.select(restored.localMessages).get();
    expect(rows.map((r) => r.clientId), containsAll(['a', 'b']));
    expect(rows.first.content, isNotNull);
  });

  test('les préférences non autorisées ne ressortent pas de la relecture',
      () async {
    // Elles ne devraient pas y entrer, mais une archive fabriquée à la main
    // le pourrait : la liste blanche s'applique donc aussi à la lecture.
    final payload = _zip({
      kSnapshotDbEntry: (await build()).payload,
      kSnapshotPrefsEntry: utf8.encode(jsonEncode({
        'app_locale': 'en',
        'auth_access_token': 'volé',
      })),
    });

    // La base est ici factice, seules les préférences nous intéressent.
    try {
      final content = const BackupSnapshotReader(99)
          .read(payload, declaredSchemaVersion: 1);
      expect(content.prefs['app_locale'], 'en');
      expect(content.prefs.containsKey('auth_access_token'), isFalse);
    } on BackupSnapshotUnreadable {
      fail('la relecture aurait dû aboutir');
    }
  });

  test('une sauvegarde au schéma futur est refusée, pas ouverte', () async {
    final snapshot = await build();
    expect(
      () => const BackupSnapshotReader(26)
          .read(snapshot.payload, declaredSchemaVersion: 99),
      throwsA(isA<BackupSchemaTooRecent>()),
    );
  });

  test('un contenu qui n\'est pas une archive est refusé lisiblement', () {
    expect(
      () => const BackupSnapshotReader(99).read(
        Uint8List.fromList(utf8.encode('pas une archive')),
        declaredSchemaVersion: 1,
      ),
      throwsA(isA<BackupSnapshotUnreadable>()),
    );
  });

  test('des préférences illisibles ne coûtent pas les messages', () async {
    final real = await build();
    final dbBytes = ZipDecoder()
        .decodeBytes(real.payload)
        .files
        .firstWhere((f) => f.name == kSnapshotDbEntry)
        .readBytes()!;

    final payload = _zip({
      kSnapshotDbEntry: dbBytes,
      kSnapshotPrefsEntry: utf8.encode('{ceci n\'est pas du json'),
    });

    final content = const BackupSnapshotReader(99)
        .read(payload, declaredSchemaVersion: 1);
    expect(content.database, isNotEmpty);
    expect(content.prefs, isEmpty);
  });

  group('scellé de bout en bout', () {
    test('fabriquer, sceller, rouvrir, relire rend les mêmes messages',
        () async {
      await addMessage('a');
      final snapshot = await build();
      final key = List<int>.filled(32, 3);

      final sealed = await BackupCrypto().seal(
        plain: snapshot.payload,
        key: key,
        kid: 2,
        alanyaID: 241030112,
        schemaVersion: snapshot.meta.schemaVersion,
      );

      // L'en-tête se lit sans la clé : c'est ce qui permet de demander au
      // serveur la bonne version avant de déchiffrer.
      final header = BackupHeader.decode(sealed);
      expect(header.kid, 2);
      expect(header.schemaVersion, snapshot.meta.schemaVersion);

      final clear = await BackupCrypto().open(archive: sealed, key: key);
      final content = const BackupSnapshotReader(99).read(
        clear,
        declaredSchemaVersion: header.schemaVersion,
      );

      final restoredFile = File('${tmp.path}/final.sqlite')
        ..writeAsBytesSync(content.database);
      final restored = AppDatabase.forTesting(NativeDatabase(restoredFile));
      addTearDown(restored.close);

      final rows = await restored.select(restored.localMessages).get();
      expect(rows.single.clientId, 'a');
      expect(content.prefs['app_locale'], 'fr');
    });
  });
}

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile.bytes(e.key, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
