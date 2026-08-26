import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talky_flutter/core/db/app_database.dart';
import 'package:talky_flutter/core/db/chat_dao.dart';

/// Filtres de « Mes médias » (discussion, période, famille de média).
///
/// Ils sont poussés en SQL et non joués en mémoire : la requête est plafonnée
/// à 2000 lignes, filtrer après coup découperait dans les 2000 médias les plus
/// récents au lieu des 2000 médias les plus récents *qui correspondent*.
/// Ces tests verrouillent donc le comportement de la requête elle-même.
void main() {
  late AppDatabase db;
  late ChatDao dao;

  const myId = 42;
  final march10 = DateTime.utc(2026, 3, 10, 9);
  final march31 = DateTime.utc(2026, 3, 31, 14);
  final april2 = DateTime.utc(2026, 4, 2, 8);

  /// Un média téléchargé sur l'appareil, seule chose que « Mes médias » liste.
  Future<void> insertMedia({
    required String clientId,
    required int conversationID,
    required int senderID,
    required int type,
    required DateTime sendAt,
  }) {
    return db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: clientId,
          conversationID: conversationID,
          senderID: senderID,
          sendAt: sendAt,
          type: Value(type),
          mediaUrl: Value('/uploads/media/$clientId.bin'),
          localMediaPath: Value('/tmp/$clientId.bin'),
          syncPending: const Value(false),
        ));
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ChatDao(db);

    await insertMedia(
      clientId: 'photo_conv1_mars10',
      conversationID: 1,
      senderID: 7,
      type: 1,
      sendAt: march10,
    );
    await insertMedia(
      clientId: 'video_conv1_mars31',
      conversationID: 1,
      senderID: myId,
      type: 2,
      sendAt: march31,
    );
    await insertMedia(
      clientId: 'vocal_conv2_mars10',
      conversationID: 2,
      senderID: 7,
      type: 3,
      sendAt: march10,
    );
    await insertMedia(
      clientId: 'fichier_conv2_avril2',
      conversationID: 2,
      senderID: 7,
      type: 4,
      sendAt: april2,
    );
  });

  tearDown(() async => db.close());

  Future<List<String>> ids({
    int? conversationID,
    DateTime? from,
    DateTime? until,
    List<int> types = kMyMediaTypes,
    bool? mineOnly,
  }) async {
    final rows = await dao
        .watchLocalMedia(
          myId,
          conversationID: conversationID,
          from: from,
          until: until,
          types: types,
          mineOnly: mineOnly,
        )
        .first;
    return rows.map((r) => r.message.clientId).toList();
  }

  test('sans filtre, les quatre familles de médias remontent', () async {
    expect(
      await ids(),
      containsAll([
        'photo_conv1_mars10',
        'video_conv1_mars31',
        'vocal_conv2_mars10',
        'fichier_conv2_avril2',
      ]),
    );
  });

  test('le filtre discussion ne garde que la conversation choisie', () async {
    expect(
      await ids(conversationID: 1),
      unorderedEquals(['photo_conv1_mars10', 'video_conv1_mars31']),
    );
  });

  test('le filtre famille ne garde que le type demandé', () async {
    expect(await ids(types: const [3]), ['vocal_conv2_mars10']);
    expect(await ids(types: const [4]), ['fichier_conv2_avril2']);
  });

  test('la borne de fin est exclusive : un média du 31 mars à 14 h entre '
      'dans « jusqu\'au 31 mars »', () async {
    final result = await ids(
      from: DateTime.utc(2026, 3, 1),
      // Lendemain minuit du dernier jour voulu, comme le calcule l'écran.
      until: DateTime.utc(2026, 4, 1),
    );
    expect(result, unorderedEquals(
      ['photo_conv1_mars10', 'video_conv1_mars31', 'vocal_conv2_mars10'],
    ));
    expect(result, isNot(contains('fichier_conv2_avril2')));
  });

  test('discussion et période se combinent', () async {
    expect(
      await ids(
        conversationID: 1,
        from: DateTime.utc(2026, 3, 20),
        until: DateTime.utc(2026, 4, 1),
      ),
      ['video_conv1_mars31'],
    );
  });

  test('une liste de types vide ne vide pas la grille', () async {
    // Un appelant qui passerait `const []` obtiendrait sinon zéro résultat
    // sans qu'aucun filtre n'ait été demandé — on retombe sur tous les types.
    expect((await ids(types: const [])).length, 4);
  });

  test('conversationIdsWithLocalMedia ne liste que les discussions '
      'qui ont un média sur l\'appareil', () async {
    await db.into(db.localMessages).insert(LocalMessagesCompanion.insert(
          clientId: 'texte_conv3',
          conversationID: 3,
          senderID: 7,
          sendAt: march10,
          syncPending: const Value(false),
        ));
    expect(await dao.conversationIdsWithLocalMedia(myId), {1, 2});
  });
}
