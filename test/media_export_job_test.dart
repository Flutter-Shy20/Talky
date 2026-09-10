import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/db/chat_dao.dart';
import 'package:talky_flutter/core/services/export/export_index_html.dart';
import 'package:talky_flutter/core/services/export/export_manifest.dart';
import 'package:talky_flutter/core/services/export/export_zip_builder.dart';
import 'package:talky_flutter/core/services/export/media_export_job.dart';
import 'package:talky_flutter/core/services/media_expiry_policy.dart';

void main() {
  group('MediaExportJob', () {
    late AppDatabase db;
    late ChatDao dao;
    late Directory tmp;
    late Directory media;

    const myId = 42;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      dao = ChatDao(db);
      tmp = await Directory.systemTemp.createTemp('alanya_job_test');
      media = Directory(p.join(tmp.path, 'media_cache'))..createSync();
      MediaExpiryPolicy.resetForTests();
    });

    tearDown(() async {
      await db.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<void> addMedia({
      required String clientId,
      String content = 'abc',
      bool onDisk = true,
    }) async {
      if (onDisk) {
        File(p.join(media.path, '$clientId.bin')).writeAsStringSync(content);
      }
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            clientId: clientId,
            conversationID: 1,
            senderID: 7,
            sendAt: DateTime.utc(2026, 3, 14, 9),
            type: const Value(1),
            mediaUrl: Value('/uploads/media/2026-03-14/$clientId.bin'),
            localMediaPath: onDisk
                ? Value(p.join(media.path, '$clientId.bin'))
                : const Value.absent(),
            syncPending: const Value(false),
          ));
    }

    File dest() => File(p.join(tmp.path, 'export.zip'));

    test('sans récupérateur, aucun octet réseau ne transite', () async {
      await addMedia(clientId: 'present');
      await addMedia(clientId: 'absent', onDisk: false);

      var recovererCalled = false;
      final job = MediaExportJob(dao);
      final result = await job.run(
        myId: myId,
        destination: dest(),
        // Volontairement absent : c'est le mode par défaut, et la règle du
        // produit. Le manquant reste manquant.
        recoverMissing: null,
      );
      expect(recovererCalled, isFalse);

      expect(result.manifest.items, hasLength(1));
      expect(result.manifest.missing, hasLength(1));
      expect(
        result.manifest.missing.single.reason,
        MissingReason.neverDownloaded,
      );
    });

    test('avec récupérateur accepté, le manquant rejoint l\'archive', () async {
      await addMedia(clientId: 'present');
      await addMedia(clientId: 'absent', onDisk: false);

      final asked = <String>[];
      final result = await MediaExportJob(dao).run(
        myId: myId,
        destination: dest(),
        recoverMissing: (clientId) async {
          asked.add(clientId);
          final f = File(p.join(media.path, '$clientId.bin'))
            ..writeAsStringSync('recupere');
          return f.path;
        },
      );

      expect(asked, ['absent']);
      // Le second inventaire l'a mesuré, nommé et numéroté comme les autres.
      expect(result.manifest.items, hasLength(2));
      expect(result.manifest.missing, isEmpty);
    });

    test('un échec de récupération ne fait pas échouer tout l\'export',
        () async {
      await addMedia(clientId: 'present');
      await addMedia(clientId: 'absent', onDisk: false);

      final result = await MediaExportJob(dao).run(
        myId: myId,
        destination: dest(),
        // Renoncer à toute l'archive parce qu'une photo n'est pas revenue
        // serait absurde.
        recoverMissing: (_) async => throw const SocketException('coupé'),
      );

      expect(result.manifest.items, hasLength(1));
      expect(result.manifest.missing, hasLength(1));
    });

    test('un manquant expiré n\'est jamais proposé au téléchargement',
        () async {
      MediaExpiryPolicy.resetForTests(retentionDays: 30);
      await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
            clientId: 'vieux',
            conversationID: 1,
            senderID: 7,
            sendAt: DateTime.utc(2025, 1, 1),
            type: const Value(1),
            mediaUrl: const Value('/uploads/media/2025-01-01/vieux.bin'),
            syncPending: const Value(false),
          ));

      final asked = <String>[];
      await MediaExportJob(dao).run(
        myId: myId,
        destination: dest(),
        recoverMissing: (c) async {
          asked.add(c);
          return null;
        },
      );

      // Le serveur l'a purgé : demander son téléchargement serait promettre
      // un échec.
      expect(asked, isEmpty);
    });

    test('les phases sont annoncées dans l\'ordre', () async {
      await addMedia(clientId: 'a');
      final phases = <ExportPhase>[];

      await MediaExportJob(dao).run(
        myId: myId,
        destination: dest(),
        onStatus: (s) => phases.add(s.phase),
      );

      expect(phases.first, ExportPhase.scanning);
      expect(phases.last, ExportPhase.done);
      expect(phases, contains(ExportPhase.assembling));
      // Aucune récupération n'a été demandée : la phase réseau n'existe pas.
      expect(phases, isNot(contains(ExportPhase.recovering)));
    });

    test('annuler pendant l\'inventaire n\'écrit aucune archive', () async {
      await addMedia(clientId: 'a');
      final job = MediaExportJob(dao)..cancel();

      await expectLater(
        job.run(myId: myId, destination: dest()),
        throwsA(isA<ExportCancelled>()),
      );
      expect(dest().existsSync(), isFalse);
    });

    test('la période affichée exclut la borne du lendemain', () async {
      await addMedia(clientId: 'a');

      final result = await MediaExportJob(dao).run(
        myId: myId,
        destination: dest(),
        from: DateTime.utc(2026, 3, 1),
        // Borne SQL exclusive : le 1er avril à minuit.
        until: DateTime.utc(2026, 4, 1),
      );

      // L'archive doit annoncer « jusqu'au 31 mars », pas « jusqu'au 1er avril ».
      expect(result.manifest.periodTo, DateTime.utc(2026, 3, 31));
    });

    test('l\'index HTML est écrit dans l\'archive', () async {
      await addMedia(clientId: 'a');
      await MediaExportJob(dao).run(myId: myId, destination: dest());

      final archive = ZipDecoder().decodeBytes(dest().readAsBytesSync());
      final index = archive.files.firstWhere((f) => f.name == 'index.html');
      expect(utf8.decode(index.readBytes()!), contains('<!doctype html>'));
    });
  });

  group('buildExportIndexHtml', () {
    ExportManifest manifest({
      List<ExportItem> items = const [],
      List<ExportMissing> missing = const [],
      int? retentionDays,
    }) =>
        ExportManifest(
          alanyaID: 42,
          generatedAt: DateTime.utc(2026, 8, 30, 12),
          items: items,
          missing: missing,
          retentionDaysKnown: retentionDays,
        );

    ExportItem item({String? senderName, String path = 'Alanya Images/a.jpg'}) =>
        ExportItem(
          msgID: 1,
          clientId: 'c',
          conversationID: 1,
          senderID: 7,
          senderName: senderName,
          isMine: false,
          type: 1,
          sentAt: DateTime.utc(2026, 3, 14, 9),
          path: path,
          bytes: 1024,
          sha256: 'x',
          mediaUrl: '/u/a.jpg',
        );

    test('un pseudo hostile est échappé, jamais exécuté', () {
      // Les pseudos viennent d'autres inscrits. Cette page est ouverte hors
      // de l'application, longtemps après, sans aucune protection.
      final html = buildExportIndexHtml(
        manifest(items: [item(senderName: '<script>alert(1)</script>')]),
      );
      expect(html, isNot(contains('<script>alert(1)</script>')));
      expect(html, contains('&lt;script&gt;'));
    });

    test('les espaces des dossiers sont encodés dans les liens', () {
      final html = buildExportIndexHtml(manifest(items: [item()]));
      // Sans encodage, « Alanya Images/a.jpg » casse dans la plupart des
      // navigateurs.
      expect(html, contains('Alanya%20Images/a.jpg'));
    });

    test('la page ne charge aucune ressource distante', () {
      final html = buildExportIndexHtml(manifest(items: [item()]));
      // Elle doit s'ouvrir dans dix ans, hors ligne, à l'identique.
      expect(html, isNot(contains('http://')));
      expect(html, isNot(contains('https://')));
    });

    test('les manquants sont écrits noir sur blanc, avec leur motif', () {
      final html = buildExportIndexHtml(manifest(
        items: [item()],
        missing: const [
          ExportMissing(msgID: 2, clientId: 'x', reason: MissingReason.expired),
          ExportMissing(
            msgID: 3,
            clientId: 'y',
            reason: MissingReason.neverDownloaded,
          ),
        ],
        retentionDays: 30,
      ));

      expect(html, contains('Éléments absents'));
      expect(html, contains('30 jours'));
      expect(html, contains('manifest.json'));
    });

    test('une archive sans manquant ne porte pas la section', () {
      final html = buildExportIndexHtml(manifest(items: [item()]));
      expect(html, isNot(contains('Éléments absents')));
    });
  });
}
