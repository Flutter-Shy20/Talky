import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/services/backup/local_folder_target.dart';
import 'package:talky_flutter/core/services/export/export_manifest.dart';

void main() {
  group('ExportManifest', () {
    ExportManifest sample() => ExportManifest(
          alanyaID: 241030112,
          generatedAt: DateTime.utc(2026, 8, 30, 10, 24, 7),
          periodFrom: DateTime.utc(2026, 3, 1),
          periodTo: DateTime.utc(2026, 3, 31),
          conversationID: 12,
          conversationName: 'Ama Nguema',
          retentionDaysKnown: 30,
          items: [
            ExportItem(
              msgID: 90412,
              clientId: 'c_8f21ab',
              conversationID: 12,
              conversationName: 'Ama Nguema',
              senderID: 77,
              senderName: 'Ama Nguema',
              isMine: false,
              type: 1,
              sentAt: DateTime.utc(2026, 3, 14, 9, 12, 44),
              path: 'Alanya Images/2026-03-14_ama-nguema_0001.jpg',
              originalName: 'IMG_2231.jpg',
              bytes: 2841233,
              sha256: '9f2c',
              mediaUrl: '/uploads/media/2026-03-14/media_90412_1.jpg',
            ),
          ],
          missing: const [
            ExportMissing(
              msgID: 90455,
              clientId: 'c_aa01',
              reason: MissingReason.expired,
            ),
            ExportMissing(
              msgID: 90460,
              clientId: 'c_aa02',
              reason: MissingReason.neverDownloaded,
            ),
          ],
        );

    test('survit à un aller-retour JSON sans rien perdre', () {
      final decoded = ExportManifest.decode(sample().encode());

      expect(decoded.alanyaID, 241030112);
      expect(decoded.conversationName, 'Ama Nguema');
      expect(decoded.retentionDaysKnown, 30);
      expect(decoded.items.single.clientId, 'c_8f21ab');
      // Ce couple est ce dont la restauration a besoin pour remettre le
      // fichier en face du bon message : il ne doit jamais se perdre.
      expect(decoded.items.single.msgID, 90412);
      expect(decoded.items.single.sha256, '9f2c');
      expect(decoded.missing.map((m) => m.reason), [
        MissingReason.expired,
        MissingReason.neverDownloaded,
      ]);
    });

    test('la période est écrite en date seule, sans heure ni fuseau', () {
      final json = sample().toJson();
      expect((json['period'] as Map)['from'], '2026-03-01');
      expect((json['period'] as Map)['to'], '2026-03-31');
    });

    test('totalBytes ne compte que ce qui est réellement dans l\'archive', () {
      // Les manquants ne pèsent rien : annoncer leur poids laisserait croire
      // qu'ils sont dedans.
      expect(sample().totalBytes, 2841233);
    });

    test('un motif de manquant inconnu est traité comme perdu', () {
      // Prudence volontaire : venu d'une version plus récente, un motif
      // inconnu supposé récupérable ferait promettre un téléchargement qui
      // échouerait.
      final m = ExportMissing.fromJson(const {
        'msgID': 1,
        'clientId': 'c_x',
        'reason': 'unMotifDuFutur',
      });
      expect(m.reason, MissingReason.expired);
      expect(m.recoverable, isFalse);
    });

    test('un format d\'archive plus récent est signalé, pas lu de travers', () {
      final decoded = ExportManifest.decode(
        '{"format":"alanya-export/2","alanyaID":1,"items":[],"missing":[]}',
      );
      expect(decoded.isSupported, isFalse);
      expect(sample().isSupported, isTrue);
    });
  });

  group('LocalFolderTarget', () {
    late Directory tmp;
    late LocalFolderTarget target;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('alanya_backup_test');
      target = LocalFolderTarget(Directory(p.join(tmp.path, 'Sauvegardes')));
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<File> sourceFile(String name, String content) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsString(content);
      return f;
    }

    test('un dossier absent liste vide plutôt que de lever', () async {
      // Le dossier n'est créé qu'à la première écriture : un dossier vide qui
      // apparaît sans que l'inscrit ait rien demandé est du bruit.
      expect(await target.list(), isEmpty);
      expect(await target.directory.exists(), isFalse);
    });

    test('écrire puis relire rend le même contenu', () async {
      final src = await sourceFile('src.enc', 'contenu-sauvegarde');
      final archive = await target.write(src, 'alanya-backup-1.enc');

      expect(archive.name, 'alanya-backup-1.enc');
      expect(archive.bytes, 'contenu-sauvegarde'.length);
      // La source appartient à l'appelant : on copie, on ne déplace pas.
      expect(await src.exists(), isTrue);

      final into = File(p.join(tmp.path, 'restaure.enc'));
      final read = await target.read(archive.id, into);
      expect(await read.readAsString(), 'contenu-sauvegarde');
    });

    test('la liste est ordonnée du plus récent au plus ancien', () async {
      final a = await sourceFile('a', 'aaa');
      final b = await sourceFile('b', 'bbb');
      final first = await target.write(a, 'ancienne.enc');
      await File(first.id).setLastModified(DateTime(2026, 1, 1));
      await target.write(b, 'recente.enc');

      expect((await target.list()).map((e) => e.name).first, 'recente.enc');
    });

    test('lire une archive absente lève BackupArchiveNotFound', () async {
      // Distingué d'une panne d'entrée-sortie : l'inscrit a pu supprimer sa
      // sauvegarde lui-même, et l'écran doit le dire plutôt que d'afficher
      // une erreur technique.
      expect(
        () => target.read(
          p.join(target.directory.path, 'jamais-ecrite.enc'),
          File(p.join(tmp.path, 'out.enc')),
        ),
        throwsA(isA<BackupArchiveNotFound>()),
      );
    });

    test('supprimer deux fois ne lève pas', () async {
      final src = await sourceFile('c', 'ccc');
      final archive = await target.write(src, 'a-effacer.enc');

      await target.delete(archive.id);
      // Idempotence : sans elle, une reprise après coupure échouerait sur le
      // fichier qu'elle venait justement de finir d'effacer.
      await target.delete(archive.id);
      expect(await target.list(), isEmpty);
    });
  });
}
