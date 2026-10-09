// L'horloge des messages coincés (pending depuis plus de 2 min → échec) ne
// doit pas toucher un média en cours d'envoi, ni un média qui attend d'être
// renvoyé : une vidéo de quelques minutes passe plus de 2 min entre compression
// et envoi, et la marquer « échec » faisait relancer l'envoi à la main — et
// partir la vidéo deux fois.
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/theme/locale_controller.dart';
import 'package:talky_flutter/talky_api_client.dart' show TalkyException;

import 'fakes/chat_test_harness.dart';

void main() {
  late ChatTestHarness h;
  late Directory tmp;
  late Directory outbox;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('outbox_stuck_');
    // `talky_outbox` dans le chemin : le fichier est considéré déjà mis en
    // attente, sans path_provider.
    outbox = Directory(p.join(tmp.path, 'talky_outbox'))..createSync();
    LocaleController();
    h = ChatTestHarness();
    await h.setUp();
  });

  tearDown(() async {
    await h.tearDown();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File doc(String name) =>
      File(p.join(outbox.path, name))..writeAsBytesSync(List<int>.filled(4096, 1));

  /// Fait comme si le message avait été créé il y a 5 minutes.
  Future<void> backdate(String clientId) =>
      (h.db.update(h.db.localMessages)..where((m) => m.clientId.equals(clientId))).write(
        LocalMessagesCompanion(
          sendAt: Value(DateTime.now().toUtc().subtract(const Duration(minutes: 5))),
        ),
      );

  int uploads() => h.api.httpLog.where((l) => l == 'uploadMedia').length;

  test('envoi qui échoue sur le réseau : relancé par le flush, jamais déclaré en échec', () async {
    h.api.uploadError = TalkyException('réseau', 0);
    await h.repo.sendMediaFile(
      conversationID: ChatTestHarness.convId,
      type: 4,
      file: doc('outbox_a.txt'),
      mediaName: 'a.txt',
    );
    await h.pumpEventQueue();
    final row = (await h.messages()).single;
    expect(row.status, 0, reason: 'erreur passagère : le message reste en attente');
    await backdate(row.clientId);

    await h.repo.flushOutbox();
    await h.pumpEventQueue();

    final after = (await h.messages()).single;
    expect(after.status, 0, reason: 'toujours en attente, pas en échec');
    expect(after.retryCount, 0);
    expect(uploads(), 2, reason: 'le flush a relancé l’envoi de lui-même');

    // Le réseau revient : le flush suivant aboutit, sans geste de l'utilisateur.
    h.api.uploadError = null;
    await h.repo.flushOutbox();
    await h.pumpEventQueue();
    expect((await h.messages()).single.mediaUrl, isNotNull);
  });

  test('envoi long encore en cours : le flush ne le déclare pas en échec', () async {
    h.api.uploadGate = Completer<void>();
    unawaited(h.repo.sendMediaFile(
      conversationID: ChatTestHarness.convId,
      type: 4,
      file: doc('outbox_b.txt'),
      mediaName: 'b.txt',
    ));
    await h.pumpEventQueue();
    final row = (await h.messages()).single;
    await backdate(row.clientId);

    await h.repo.flushOutbox();
    await h.pumpEventQueue();
    expect((await h.messages()).single.status, isNot(4), reason: 'envoi en cours');

    h.api.uploadGate!.complete();
    await h.pumpEventQueue();

    // Envoi tout juste fini : l'horloge repart de là, pas de sendAt.
    await h.repo.flushOutbox();
    await h.pumpEventQueue();
    final done = (await h.messages()).single;
    expect(done.status, isNot(4));
    expect(done.retryCount, 0, reason: 'aucun renvoi : la vidéo ne part pas deux fois');
    expect(uploads(), 1);
  });
}
